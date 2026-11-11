defmodule SymphonyElixir.Management.RecorderTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Recorder, Store, UsageHistory}

  setup do
    root = Path.join(System.tmp_dir!(), "management-recorder-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, root)
    Application.put_env(:symphony_elixir, :management_policy, %{})
    start_supervised!(SymphonyElixir.Management.Supervisor)
    Process.put(:management_session, %{session: "thread", issue: 1, model: "model", effort: "high"})
    Process.put(:management_started, System.monotonic_time(:millisecond))

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :management_state_dir)
      Application.delete_env(:symphony_elixir, :management_policy)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "metadata is durable while prompts, protocol output and tool calls are discarded" do
    at = ~U[2026-11-11 10:00:00Z]
    Recorder.observe(%{event: :session_started, timestamp: at})

    Recorder.observe(%{
      event: :notification,
      timestamp: at,
      payload: %{
        "params" => %{
          "tokenUsage" => %{"total" => %{"inputTokens" => 100, "outputTokens" => 20}},
          "prompt" => "NEVER-PERSIST-ME"
        }
      }
    })

    Recorder.observe(%{event: :turn_completed, timestamp: at})
    Recorder.observe(%{event: :turn_failed, timestamp: at})
    Recorder.observe(%{event: :turn_cancelled, timestamp: at})
    Recorder.observe(%{event: :session_finished, timestamp: DateTime.add(at, 60)})
    :sys.get_state(Recorder)
    refute inspect(Store.rows("SELECT data FROM events")) =~ "NEVER-PERSIST-ME"
    assert [%{"input" => 100, "output" => 20}] = Store.rows("SELECT input,output FROM usage_observations")

    assert [%{"runtime_seconds" => seconds, "failures" => 2, "incomplete" => false}] =
             UsageHistory.sessions(~U[2026-11-11 00:00:00Z], ~U[2026-11-12 00:00:00Z], 1)

    assert_in_delta seconds, 60, 0.001
  end

  test "absent context is ignored and a finished session without usage stays incomplete" do
    Process.delete(:management_session)
    assert :ok = Recorder.observe(%{event: :notification})
    Process.put(:management_session, %{session: "missing", issue: 1, model: nil, effort: nil})
    Process.delete(:management_started)
    Recorder.observe(%{event: :session_started})
    Recorder.observe(%{event: :session_finished})
    :sys.get_state(Recorder)
    assert [%{"data" => data}] = Store.rows("SELECT data FROM events WHERE kind='finish'")
    assert Jason.decode!(data)["usage_missing"] == true
  end

  test "a stalled writer cannot grow the protocol-side queue without a bound" do
    :sys.suspend(Recorder)

    try do
      for _ <- 1..1005, do: Recorder.observe(%{event: :notification})
      assert {:message_queue_len, count} = Process.info(Process.whereis(Recorder), :message_queue_len)
      assert count <= 1000
    after
      :sys.resume(Recorder)
    end

    :sys.get_state(Recorder)
    Recorder.observe(%{event: :session_finished})
    :sys.get_state(Recorder)
    assert [%{"data" => data}] = Store.rows("SELECT data FROM events WHERE kind='finish'")
    assert Jason.decode!(data)["dropped"] >= 5
  end

  test "a lost owner produces a censored interruption, without inventing successful usage", %{root: root} do
    parent = self()

    owner =
      spawn(fn ->
        context = Recorder.begin_session(root, %{id: "1"}, nil)
        send(parent, {:session, context.session})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:session, session}, 3000
    :sys.get_state(Recorder)
    send(owner, :stop)

    assert wait_until(fn ->
             Store.rows("SELECT data FROM events WHERE kind='finish' AND json_extract(data,'$.session')=?", [session]) !=
               []
           end)

    [%{"data" => text}] =
      Store.rows("SELECT data FROM events WHERE kind='finish' AND json_extract(data,'$.session')=?", [session])

    data = Jason.decode!(text)
    assert data["end_kind"] == "owner_exit"
    assert data["usage_missing"]
    assert data["returncode"] == nil
  end

  test "writer restart recovers live monitoring and marks observation continuity as incomplete", %{root: root} do
    context = Recorder.begin_session(root, %{id: "1"}, nil)
    :sys.get_state(Recorder)
    old = Process.whereis(Recorder)
    Process.exit(old, :kill)

    assert wait_until(fn ->
             pid = Process.whereis(Recorder)
             is_pid(pid) and pid != old
           end)

    Recorder.observe(%{
      event: :notification,
      management_context: context,
      payload: %{"params" => %{"total_token_usage" => %{"input_tokens" => 10, "output_tokens" => 1}}}
    })

    Recorder.finish_session(context)
    :sys.get_state(Recorder)

    [%{"data" => text}] =
      Store.rows("SELECT data FROM events WHERE kind='finish' AND json_extract(data,'$.session')=?", [context.session])

    assert Jason.decode!(text)["observation_gap"]
  end

  test "a prior runtime's unfinished sample is closed as unknown during recovery" do
    Store.event(
      "prior:start",
      "start",
      %{session: "prior", runtime_id: "previous", owner_pid: "<0.1.0>"},
      1,
      ~U[2026-11-11 00:00:00Z]
    )

    old = Process.whereis(Recorder)
    Process.exit(old, :kill)

    assert wait_until(fn ->
             pid = Process.whereis(Recorder)
             is_pid(pid) and pid != old
           end)

    :sys.get_state(Recorder)
    [%{"data" => text}] = Store.rows("SELECT data FROM events WHERE id='prior:finish'")
    assert Jason.decode!(text)["end_kind"] == "runtime_restart"
  end

  defp wait_until(check, attempts \\ 100)
  defp wait_until(_check, 0), do: false

  defp wait_until(check, attempts) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(10)
          wait_until(check, attempts - 1)
        )
  end

  test "unavailable writer and late monitor messages cannot lose control of a coding session", %{root: root} do
    stop_supervised!(SymphonyElixir.Management.Supervisor)
    assert :ok = Recorder.observe(%{event: :notification})
    assert Process.get({:management_dropped, "thread"}) == 1
    start_supervised!(SymphonyElixir.Management.Supervisor)
    send(Recorder, {:DOWN, make_ref(), :process, self(), :normal})
    :sys.get_state(Recorder)
    bad = Recorder.begin_session(root <> <<0>>, nil, nil)
    Recorder.finish_session(bad)
    context = Recorder.begin_session(root <> "/missing", nil, nil)
    Recorder.finish_session(context)
    remote = Recorder.begin_session(root, nil, "remote-host")
    Recorder.finish_session(remote)
    :sys.get_state(Recorder)
    assert [%{"n" => 3}] = Store.rows("SELECT COUNT(*) AS n FROM events WHERE kind='finish'")
  end

  test "recovery tolerates missing or malformed owner metadata" do
    for {name, extra} <- [{"missing", %{}}, {"invalid", %{runtime_id: Recorder.runtime_id(), owner_pid: "not-a-pid"}}] do
      Store.event(name <> ":start", "start", Map.put(extra, :session, name), nil, DateTime.utc_now())
    end

    old = Process.whereis(Recorder)
    Process.exit(old, :kill)
    assert wait_until(fn -> is_pid(Process.whereis(Recorder)) and Process.whereis(Recorder) != old end)
    :sys.get_state(Recorder)
    assert [%{"n" => 2}] = Store.rows("SELECT COUNT(*) AS n FROM events WHERE kind='finish'")
  end

  test "revision attribution captures the checkout before the harness begins", %{root: root} do
    for args <- [["init", "-b", "main"], ["-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "--allow-empty", "-m", "fixture"]] do
      assert {_, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    end

    context = Recorder.begin_session(root, nil, nil)
    assert byte_size(context.revision) == 40
    Recorder.finish_session(context)
  end

  test "missing host executables leave revision attribution unknown without blocking observations", %{root: root} do
    previous = System.fetch_env!("PATH")

    context =
      try do
        System.put_env("PATH", root)
        Recorder.begin_session(root, nil, nil)
      after
        System.put_env("PATH", previous)
      end

    assert context.revision == nil
    Recorder.finish_session(context)
  end
end
