defmodule SymphonyElixir.Management.SchedulerTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Management.{Scheduler, Settings, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "management-scheduler-#{System.unique_integer([:positive])}")
    Application.put_env(:symphony_elixir, :management_state_dir, root)

    Application.put_env(:symphony_elixir, :management_policy, %{
      "repo" => "example/project",
      "github_auth_mode" => "separate"
    })

    Application.put_env(:symphony_elixir, :management_http_options, plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared()
    start_supervised!(SymphonyElixir.Management.Supervisor)

    on_exit(fn ->
      for key <- [:management_state_dir, :management_policy, :management_http_options],
          do: Application.delete_env(:symphony_elixir, key)

      File.rm_rf!(root)
    end)

    :ok
  end

  test "a stalled collector does not block heartbeat and a failed task can be relaunched" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.host == "api.github.com" do
        send(parent, {:collector_waiting, self()})

        receive do
          :release -> Req.Test.json(conn, [])
        end
      else
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    day = Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(Date.utc_today()) - 1)

    Settings.save(
      %{
        "delivery_enabled" => true,
        "notifications" => %{"email" => %{"enabled" => false}},
        "weekly" => %{"day" => day, "time" => "00:00", "timezone" => "UTC"}
      },
      %{
        "github_token" => "synthetic",
        "slack_webhook" => "https://hooks.slack.com/services/synthetic"
      }
    )

    send(Scheduler, :tick)
    assert_receive {:collector_waiting, collector}, 1000
    assert wait_until(fn -> Store.rows("SELECT COUNT(*) AS n FROM reports") == [%{"n" => 1}] end)
    assert Map.has_key?(:sys.get_state(Scheduler), :collector)
    send(Scheduler, :tick)
    assert :sys.get_state(Scheduler)[:collector]
    Task.Supervisor.terminate_child(SymphonyElixir.Management.Tasks, collector)
    assert wait_until(fn -> not Map.has_key?(:sys.get_state(Scheduler), :collector) end)
    send(Scheduler, :tick)
    assert_receive {:collector_waiting, replacement}, 1000
    refute replacement == collector
    send(replacement, :release)
    assert_receive {:collector_waiting, ^replacement}, 1000
    send(replacement, :release)
    assert wait_until(fn -> not Map.has_key?(:sys.get_state(Scheduler), :collector) end)
    assert [%{"n" => 2}] = Store.rows("SELECT COUNT(*) AS n FROM deliveries")
  end

  test "DST folds run once at the first occurrence and gaps advance to a real local time" do
    fold = %{"weekly" => %{"day" => "Sun", "time" => "01:30", "timezone" => "America/Chicago"}}
    refute Scheduler.due?(fold, ~U[2026-11-01 06:29:00Z])
    assert Scheduler.due?(fold, ~U[2026-11-01 06:30:00Z])
    gap = %{"weekly" => %{"day" => "Sun", "time" => "02:30", "timezone" => "America/Chicago"}}
    refute Scheduler.due?(gap, ~U[2026-03-08 07:59:00Z])
    assert Scheduler.due?(gap, ~U[2026-03-08 08:00:00Z])
    Store.put("weekly_schedule_last", "2026-03-08T08:00:00Z")
    refute Scheduler.due?(gap, ~U[2026-03-08 09:00:00Z])

    for weekly <- [%{"day" => "bad"}, %{"timezone" => "Invalid/Zone"}, %{"time" => "bad"}, %{"time" => nil}] do
      refute Scheduler.due?(%{"weekly" => weekly}, DateTime.utc_now())
    end
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

  test "audit has a separate durable schedule thirty minutes before delivery" do
    config = %{"weekly" => %{"enabled" => false, "day" => "Mon", "time" => "09:00", "timezone" => "UTC"}}
    refute Scheduler.due?(config, ~U[2026-11-09 08:29:00Z], :audit)
    assert Scheduler.due?(config, ~U[2026-11-09 08:30:00Z], :audit)
    Store.put("audit_schedule_last", "corrupt old timestamp")
    assert Scheduler.due?(config, ~U[2026-11-09 08:30:00Z], :audit)
    Store.put("audit_schedule_last", "2026-11-09T08:30:00Z")
    refute Scheduler.due?(config, ~U[2026-11-09 09:00:00Z], :audit)
    day = Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(Date.utc_today()) - 1)

    Application.put_env(:symphony_elixir, :management_policy, %{
      "weekly" => %{"day" => day, "time" => "00:00"},
      "audit" => %{"enabled" => true, "codex_binary" => "/bin/false", "max_calls_per_week" => 1}
    })

    Store.put("audit_schedule_last", nil)
    send(Scheduler, :tick)
    assert wait_until(fn -> is_binary(Store.get("audit_schedule_last")) end)
  end
end
