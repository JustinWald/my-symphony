defmodule SymphonyElixir.Management.Scheduler do
  @moduledoc "Durable weekly scheduling; each operation runs in its own supervised task."
  use GenServer
  alias SymphonyElixir.Management.{Audit, Collector, Delivery, Proposals, Reports, Settings, Store}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    enabled = Application.get_env(:symphony_elixir, :management_jobs_enabled, true)
    if enabled, do: Process.send_after(self(), :tick, 1_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, running) do
    Process.send_after(self(), :tick, 30_000)

    running =
      Enum.reduce(
        [
          {:collector, &Collector.collect/0},
          {:delivery, &Delivery.drain/0},
          {:publication, &Reports.publish/0},
          {:audit, &audit_job/0}
        ],
        running,
        fn {name, fun}, acc ->
          launch(acc, name, fun)
        end
      )

    config = Settings.config()

    running =
      if config["delivery_enabled"] == true and due?(config, DateTime.utc_now()),
        do:
          launch(running, :weekly, fn ->
            :ok = Reports.weekly()
            Store.put("weekly_schedule_last", DateTime.to_iso8601(DateTime.utc_now()))
          end),
        else: running

    {:noreply, running}
  end

  def handle_info({reference, _result}, running) when is_reference(reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, Map.reject(running, fn {_name, ref} -> ref == reference end)}
  end

  def handle_info({:DOWN, reference, :process, _pid, _reason}, running) do
    {:noreply, Map.reject(running, fn {_name, ref} -> ref == reference end)}
  end

  defp audit_job do
    now = DateTime.utc_now()
    config = Settings.config()

    if get_in(config, ["audit", "enabled"]) == true and due?(config, now, :audit) do
      Reports.weekly(DateTime.add(now, 1800), notify: false)
      Audit.run()
      Proposals.prepare()
      Store.put("audit_schedule_last", DateTime.to_iso8601(now))
    end
  end

  @spec due?(map(), DateTime.t(), :weekly | :audit) :: boolean()
  def due?(config, now, kind \\ :weekly) do
    weekly =
      Map.merge(%{"enabled" => true, "day" => "Mon", "time" => "09:00", "timezone" => "UTC"}, config["weekly"] || %{})

    offset = if kind == :audit, do: 1800, else: 0
    enabled = kind == :audit or weekly["enabled"] == true
    reference = DateTime.add(now, offset, :second, Tzdata.TimeZoneDatabase)
    key = if kind == :audit, do: "audit_schedule_last", else: "weekly_schedule_last"
    timezone = if weekly["timezone"] == "UTC", do: "Etc/UTC", else: weekly["timezone"]

    with true <- enabled,
         true <- is_binary(timezone),
         {:ok, local} <- DateTime.shift_zone(reference, timezone, Tzdata.TimeZoneDatabase),
         index when is_integer(index) <- Enum.find_index(~w(Mon Tue Wed Thu Fri Sat Sun), &(&1 == weekly["day"])),
         value when is_binary(value) <- weekly["time"],
         {:ok, time} <- Time.from_iso8601(value <> ":00") do
      monday = Date.add(DateTime.to_date(local), 1 - Date.day_of_week(local))
      scheduled_date = Date.add(monday, index)

      case DateTime.new(scheduled_date, time, timezone, Tzdata.TimeZoneDatabase) do
        {:ok, scheduled} -> due_since?(now, DateTime.add(scheduled, -offset, :second, Tzdata.TimeZoneDatabase), key)
        {:ambiguous, first, _} -> due_since?(now, DateTime.add(first, -offset, :second, Tzdata.TimeZoneDatabase), key)
        {:gap, _, after_gap} -> due_since?(now, DateTime.add(after_gap, -offset, :second, Tzdata.TimeZoneDatabase), key)
      end
    else
      _ -> false
    end
  end

  defp due_since?(now, scheduled, key) do
    previous = Store.get(key)

    DateTime.compare(now, scheduled) != :lt and
      (is_nil(previous) or
         case DateTime.from_iso8601(previous) do
           {:ok, at, _} -> DateTime.compare(at, scheduled) == :lt
           _ -> true
         end)
  end

  defp launch(running, name, fun) do
    if Map.has_key?(running, name) do
      running
    else
      task = Task.Supervisor.async_nolink(SymphonyElixir.Management.Tasks, fun)
      Map.put(running, name, task.ref)
    end
  end
end
