defmodule SymphonyElixir.Management.Recorder do
  @moduledoc "Bounded asynchronous lifecycle observations, with explicit interrupted samples."
  use GenServer
  alias SymphonyElixir.Management.{Command, Store, Usage, UsageHistory}
  alias SymphonyElixir.Workflow
  @fingerprint :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower)
  @fields [:session, :model, :effort, :thread, :workflow, :phase, :revision]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: SymphonyElixir.Project.name(__MODULE__, Keyword.get(opts, :project, SymphonyElixir.Project.current())))

  @spec runtime_id() :: String.t()
  def runtime_id do
    case Application.get_env(:symphony_elixir, :management_runtime_id) do
      nil ->
        id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        Application.put_env(:symphony_elixir, :management_runtime_id, id)
        id

      id ->
        id
    end
  end

  @spec begin_session(Path.t(), map() | nil, String.t() | nil) :: map() | nil
  def begin_session(workspace, issue, worker_host) do
    if SymphonyElixir.Project.whereis(SymphonyElixir.Project.name(__MODULE__)) do
      started = System.monotonic_time(:millisecond)

      context = %{
        session: "worker-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        issue: if(issue, do: issue.id),
        model: nil,
        effort: nil,
        owner: self(),
        runtime_id: runtime_id(),
        started_monotonic: started,
        phase: "worker",
        revision: revision(if(is_nil(worker_host), do: workspace)),
        workflow: workflow_hash()
      }

      observe(%{event: :session_started, timestamp: DateTime.utc_now(), management_context: context})
      context
    end
  end

  @spec finish_session(map() | nil, boolean()) :: :ok
  def finish_session(context, failed \\ false) do
    if context do
      if failed, do: Process.put({:management_failed, context.session}, true)
      observe(%{event: :session_finished, timestamp: DateTime.utc_now(), management_context: context})

      Enum.each(
        [:management_failed, :management_dropped, :management_writer, :management_gap],
        &Process.delete({&1, context.session})
      )
    end

    :ok
  end

  @spec observe(map()) :: :ok
  def observe(message) do
    context = message[:management_context] || Process.get(:management_session)
    context = if context, do: Map.put_new(context, :owner, self())

    if context && message.event in [:turn_failed, :turn_cancelled, :turn_ended_with_error, :startup_failed] do
      Process.put({:management_failed, context.session}, true)
    end

    enqueue(SymphonyElixir.Project.whereis(SymphonyElixir.Project.name(__MODULE__)), context, message)
    :ok
  end

  defp enqueue(_pid, nil, _message), do: :ok
  defp enqueue(nil, context, _message), do: dropped(context)

  defp enqueue(pid, context, message) do
    previous = Process.get({:management_writer, context.session}, pid)
    if previous != pid, do: Process.put({:management_gap, context.session}, true)
    Process.put({:management_writer, context.session}, pid)

    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} when count < 1000 ->
        metadata =
          Map.take(message, [:event, :timestamp])
          |> Map.merge(%{
            seconds: elapsed(context),
            dropped: Process.get({:management_dropped, context.session}, 0),
            observation_gap: Process.get({:management_gap, context.session}, false),
            returncode: if(Process.get({:management_failed, context.session}, false), do: 1, else: 0)
          })

        GenServer.cast(pid, {:observe, context, metadata, Usage.normalize(message[:payload] || %{})})

      _ ->
        dropped(context)
    end
  end

  defp dropped(context),
    do: Process.put({:management_dropped, context.session}, Process.get({:management_dropped, context.session}, 0) + 1)

  defp elapsed(context) do
    case context[:started_monotonic] || Process.get(:management_started) do
      nil -> nil
      started -> (System.monotonic_time(:millisecond) - started) / 1000
    end
  end

  @impl true
  def init(opts) do
    SymphonyElixir.Project.bind(Keyword.get(opts, :project, SymphonyElixir.Project.current()))
    runtime_id()
    {:ok, recover()}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:observe, context, metadata, usage}, state) do
    state = monitor_owner(context, state)
    at = metadata[:timestamp] || DateTime.utc_now()
    id = context.session <> ":" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    data = event_data(context, metadata)
    persist_usage(usage, id, context, at)
    data = finish_metadata(metadata.event, context, data)
    persist_event(kind(metadata.event), id, context, data, at)
    {:noreply, if(metadata.event == :session_finished, do: stop_monitor(context.session, state), else: state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state, fn {_session, {monitor, _context}} -> monitor == ref end) do
      nil ->
        {:noreply, state}

      {session, {_ref, context}} ->
        interrupt(context, "owner_exit")
        {:noreply, Map.delete(state, session)}
    end
  end

  defp event_data(context, metadata) do
    context
    |> Map.take(@fields)
    |> Map.merge(%{
      status: status(metadata.event),
      seconds: metadata.seconds,
      dropped: metadata.dropped,
      observation_gap: metadata.observation_gap,
      returncode: metadata.returncode,
      bridge: "native:" <> @fingerprint,
      runtime_id: context[:runtime_id] || runtime_id(),
      owner_pid: context |> Map.fetch!(:owner) |> :erlang.pid_to_list() |> List.to_string()
    })
  end

  defp finish_metadata(:session_finished, context, data) do
    missing =
      Store.rows("SELECT COUNT(*) AS n FROM usage_observations WHERE session=?", [context.session]) == [%{"n" => 0}]

    Map.put(data, :usage_missing, missing)
  end

  defp finish_metadata(_event, _context, data), do: data

  defp persist_event(nil, _id, _context, _data, _at), do: :ok

  defp persist_event("start", _id, context, data, at) do
    key = context.session <> ":start"

    if Store.rows("SELECT id FROM events WHERE id=?", [key]) == [] do
      Store.event(key, "start", data, context.issue, at)
    end
  end

  defp persist_event("finish", _id, context, data, at),
    do: Store.event(context.session <> ":finish", "finish", data, context.issue, at)

  defp persist_event(kind, id, context, data, at), do: Store.event(id, kind, data, context.issue, at)
  defp persist_usage(:missing, _id, _context, _at), do: :ok

  defp persist_usage({:ok, counters}, id, context, at) do
    issue = if context.issue, do: to_string(context.issue)

    UsageHistory.record(%{
      id: id,
      session: context.session,
      at: at,
      issue: issue,
      model: context.model,
      effort: context.effort,
      usage: counters
    })
  end

  defp monitor_owner(context, state) do
    if Map.has_key?(state, context.session),
      do: state,
      else: Map.put(state, context.session, {Process.monitor(context.owner), context})
  end

  defp stop_monitor(session, state) do
    {{ref, _}, rest} = Map.pop(state, session)
    Process.demonitor(ref, [:flush])
    rest
  end

  defp recover do
    Store.rows(
      "SELECT s.issue,s.data FROM events s WHERE s.kind='start' AND json_type(s.data,'$.session')='text' AND NOT EXISTS(SELECT 1 FROM events f WHERE f.kind='finish' AND json_extract(f.data,'$.session')=json_extract(s.data,'$.session'))"
    )
    |> Enum.reduce(%{}, &recover_session/2)
  end

  defp recover_session(row, state) do
    data = Jason.decode!(row["data"])
    identity = %{session: data["session"], issue: row["issue"], model: data["model"], effort: data["effort"]}
    context = Map.merge(identity, %{runtime_id: data["runtime_id"], owner: owner(data)})

    if context.owner && Process.alive?(context.owner) do
      monitor_owner(context, state)
    else
      interrupt(context, "runtime_restart")
      state
    end
  end

  defp owner(%{"runtime_id" => id, "owner_pid" => pid}) when is_binary(pid) do
    if id == runtime_id(), do: :erlang.list_to_pid(String.to_charlist(pid))
  rescue
    _ -> nil
  end

  defp owner(_), do: nil

  defp interrupt(context, reason) do
    Store.event(
      context.session <> ":finish",
      "finish",
      %{
        session: context.session,
        usage_missing: true,
        end_kind: reason,
        status: "unknown",
        seconds: nil,
        returncode: nil
      },
      context.issue,
      DateTime.utc_now()
    )
  end

  defp revision(nil), do: nil

  defp revision(workspace) do
    case Command.run("git", ["rev-parse", "HEAD"], workspace, 2_000) do
      {:ok, value} -> if Regex.match?(~r/\A[a-f0-9]{40,64}\z/, value), do: value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp workflow_hash do
    with {:ok, %{size: size}} when size <= 200_000 <- File.stat(Workflow.workflow_file_path()),
         {:ok, text} <- File.read(Workflow.workflow_file_path()) do
      :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  end

  defp kind(:session_started), do: "start"
  defp kind(:session_finished), do: "finish"
  defp kind(:startup_failed), do: "startup_failure"
  defp kind(event) when event in [:turn_completed, :turn_failed, :turn_cancelled], do: "turn"
  defp kind(_), do: nil
  defp status(:turn_completed), do: "completed"
  defp status(:turn_failed), do: "failed"
  defp status(:turn_cancelled), do: "interrupted"
  defp status(event), do: to_string(event)
end
