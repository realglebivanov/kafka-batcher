defmodule KafkaBatcher.Client.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(client :: atom()) :: Supervisor.on_start()
  def start_link(client) do
    Supervisor.start_link(__MODULE__, client, name: __MODULE__)
  end

  @spec child_spec(client :: atom()) :: Supervisor.child_spec()
  def child_spec(client) do
    Supervisor.child_spec(
      __MODULE__,
      id: {__MODULE__, client},
      start: {__MODULE__, :start_link, [client]}
    )
  end

  @impl true
  def init(client) do
    children = [
      KafkaBatcher.ConnectionManager.child_spec(client)
      | collector_specs(client)
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end

  def collector_specs(client) do
    collector_configs = KafkaBatcher.Config.get_configs_by_collector!(client)

    child_specs =
      Enum.reduce(
        collector_configs,
        [],
        fn {collector, config}, specs ->
          collector_spec = collector.child_spec(config)
          accum_sup_spec = KafkaBatcher.AccumulatorsPoolSupervisor.child_spec(config)

          [collector_spec, accum_sup_spec | specs]
        end
      )

    Enum.reverse(child_specs)
  end
end
