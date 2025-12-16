defmodule KafkaBatcher.Config do
  @moduledoc """
  KafkaBatcher configuration processing.
  All config parameters are described in details in README.md
  Examples of configs can be found in the files config/test.exs and test/support/collectors/collector_handlers.ex
  """

  defmodule SASLConfigError do
    defexception [:message]

    def exception(_term) do
      %SASLConfigError{message: "Sasl config error"}
    end
  end

  defmodule CollectorMissingError do
    defexception [:message]

    def exception(term) do
      %CollectorMissingError{message: "Collector #{inspect(term)} missing"}
    end
  end

  defmodule BadConfigError do
    defexception [:message]

    def exception(term) do
      %BadConfigError{message: "Topic config error #{inspect(term)}"}
    end
  end

  @type sasl_mechanism() :: :plain | :scram_sha_256 | :scram_sha_512
  @type sasl_type() :: {sasl_mechanism(), binary(), binary()} | :undefined

  @spec general_producer_config(client :: atom()) :: Keyword.t()
  def general_producer_config(client) do
    client_config = client |> get_client_config() |> Keyword.get(:kafka, [])

    client_producer_config =
      client_config
      |> Keyword.take(allowed_producer_keys())
      |> set_endpoints()
      |> set_sasl()
      |> set_ssl()

    Keyword.merge(default_producer_config(), client_producer_config)
  end

  @doc """
  Return all configured topics with its config.
  """
  @spec get_configs_by_topic_name(client :: atom()) :: list({binary(), Keyword.t()})
  def get_configs_by_topic_name(client) do
    get_configs_by_collector!(client)
    |> Enum.map(fn {_, config} ->
      {Keyword.fetch!(config, :topic_name), config}
    end)
    |> Enum.into(%{})
  end

  @spec get_configs_by_collector!(client :: atom()) :: list({atom(), Keyword.t()})
  def get_configs_by_collector!(client) do
    Enum.map(fetch_runtime_configs(client), fn {collector, runtime_config} ->
      config =
        general_producer_config(client)
        |> Keyword.merge(get_compile_config!(collector))
        |> Keyword.merge(runtime_config)

      case validate_config!({collector, config}) do
        :ok ->
          {collector, config}

        {:error, reasons} ->
          raise(KafkaBatcher.Config.BadConfigError, "Collector config failed: #{inspect(reasons)}")
      end
    end)
  end

  @spec get_collector_config(client :: atom(), topic_name :: binary()) :: Keyword.t()
  def get_collector_config(client, topic_name) do
    case get_configs_by_topic_name(client)[topic_name] do
      nil -> general_producer_config(client)
      config -> config
    end
  end

  @spec build_topic_config(opts :: Keyword.t()) :: Keyword.t()
  def build_topic_config(opts) do
    default_config = default_producer_config()

    allowed_producer_keys()
    |> Enum.map(fn key -> {key, Keyword.get(opts, key) || Keyword.get(default_config, key)} end)
    |> Enum.filter(fn {_, value} -> value != nil end)
  end

  @spec fetch_endpoints!(client :: atom()) :: list({binary(), non_neg_integer()})
  def fetch_endpoints!(client) do
    client
    |> get_client_config()
    |> Keyword.get(:kafka, [])
    |> Keyword.fetch!(:endpoints)
    |> parse_endpoints()
  end

  defp parse_endpoints(endpoints) do
    endpoints |> String.split(",") |> Enum.map(&parse_endpoint/1)
  end

  defp parse_endpoint(url) do
    [host, port] = String.split(url, ":")
    {host, :erlang.binary_to_integer(port)}
  end

  defp validate_config!({collector, config}) do
    required_keys()
    |> Enum.reduce(
      [],
      fn
        key, acc when is_atom(key) ->
          case Keyword.has_key?(config, key) do
            true ->
              acc

            false ->
              ["collector #{inspect(collector)}. Not found required key #{inspect(key)}" | acc]
          end

        %{cond: condition, keys: keys}, acc ->
          case check_conditions?(condition, config) do
            true ->
              check_keys(keys, config, collector, acc)

            false ->
              acc
          end
      end
    )
    |> case do
      [] -> :ok
      reasons -> {:error, reasons}
    end
  end

  defp check_keys(keys, config, collector, acc) do
    case keys -- Keyword.keys(config) do
      [] ->
        acc

      fields ->
        ["collector #{inspect(collector)}. Not found required keys #{inspect(fields)}" | acc]
    end
  end

  defp check_conditions?(cond, config) do
    Enum.all?(
      cond,
      fn {key, value} ->
        Keyword.get(config, key) == value
      end
    )
  end

  defp required_keys do
    [
      :topic_name,
      %{cond: [collect_by_partition: true], keys: [:partition_fn]},
      %{cond: [collect_by_partition: false], keys: [:partition_strategy]}
    ]
  end

  defp set_endpoints(config) do
    Keyword.update!(config, :endpoints, &parse_endpoints/1)
  end

  defp set_sasl(config) do
    new_sasl =
      case validate_sasl_config!(Keyword.get(config, :sasl)) do
        {:ok, sasl_config_tuple} -> sasl_config_tuple
        _ -> :undefined
      end

    Keyword.put(config, :sasl, new_sasl)
  end

  defp allowed_producer_keys do
    keys =
      default_producer_config()
      |> Keyword.keys()

    [[:endpoints, :partition_fn, :topic_name, :ssl, :sasl] | keys]
    |> List.flatten()
  end

  @spec validate_sasl_config!(map() | nil) :: {:ok, sasl_type()} | {:error, :is_not_set} | no_return()
  defp validate_sasl_config!(%{mechanism: mechanism, login: login, password: password} = config) do
    valid_mechanism = mechanism in [:plain, :scram_sha_256, :scram_sha_512]

    if valid_mechanism && password != nil && login != nil do
      {:ok, {mechanism, login, password}}
    else
      raise(KafkaBatcher.Config.SASLConfigError, "SASL config failed: #{inspect(config)}")
    end
  end

  defp validate_sasl_config!(sasl_config) when sasl_config == nil or sasl_config == %{} do
    {:error, :is_not_set}
  end

  defp validate_sasl_config!(bad_sasl_config) do
    raise(KafkaBatcher.Config.SASLConfigError, "SASL config failed: #{inspect(bad_sasl_config)}")
  end

  defp set_ssl(config) do
    Keyword.put(config, :ssl, get_ssl(config))
  end

  defp get_ssl(config) do
    Keyword.get(config, :ssl, false)
  end

  defp get_compile_config!(module) do
    with {:module, ^module} <- Code.ensure_compiled(module),
         {:ok, [_ | _] = config} <- {:ok, module.get_compile_config()} do
      config
    else
      _ ->
        raise(KafkaBatcher.Config.CollectorMissingError, "Collector: #{inspect(module)} missing")
    end
  end

  defp fetch_runtime_configs(client) do
    client_config = get_client_config(client)

    for collector <- Keyword.get(client_config, :collectors, []) do
      case Keyword.fetch(client_config, collector) do
        {:ok, config} ->
          {collector, config}

        _ ->
          {collector, []}
      end
    end
  end

  defp get_client_config(client) do
    Application.get_env(:kafka_batcher, client, [])
  end

  defp default_producer_config do
    [
      ## brod producer parameters
      ## https://github.com/kafka4beam/brod/blob/master/src/brod_producer.erl
      allow_topic_auto_creation: false,
      partition_strategy: :random,
      required_acks: -1,
      ## KafkaBatcher parameters
      ## specified start pool processes for collection events by partitions
      collect_by_partition: false,
      ## send metric values to prom_ex application
      telemetry: true,
      # This module implements logic for force pushing current batch to Kafka,
      # without waiting for other conditions (on size and/or interval).
      batch_flusher: KafkaBatcher.Accumulator.DefaultBatchFlusher,
      # These parameters are required for the collector
      max_wait_time: 1_000,
      batch_size: 10,
      min_delay: 0,
      max_batch_bytesize: 1_000_000
    ]
  end
end
