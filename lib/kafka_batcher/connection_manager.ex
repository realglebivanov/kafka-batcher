defmodule KafkaBatcher.ConnectionManager do
  @moduledoc """
  Abstraction layer over Kafka library.

  Manages a connection to Kafka, producers processes and does reconnect if something goes wrong.
  """

  require Logger

  defmodule State do
    @moduledoc "State of ConnectionManager process"
    @enforce_keys [:client]
    defstruct @enforce_keys ++ [client_started: false, client_pid: nil]

    @type t :: %State{
            client: atom(),
            client_started: boolean(),
            client_pid: nil | pid()
          }
  end

  @producer Application.compile_env(:kafka_batcher, :producer_module, KafkaBatcher.Producers.Kaffe)
  @error_notifier Application.compile_env(:kafka_batcher, :error_notifier, KafkaBatcher.DefaultErrorNotifier)
  @reconnect_timeout Application.compile_env(:kafka_batcher, :reconnect_timeout, 5_000)

  use GenServer

  # Public API
  @spec start_link(client :: atom()) :: GenServer.on_start()
  def start_link(client) do
    GenServer.start_link(__MODULE__, client, name: __MODULE__)
  end

  @doc "Returns a specification to start this module under a supervisor"
  @spec child_spec(client :: atom()) :: Supervisor.child_spec()
  def child_spec(client) do
    %{
      id: {__MODULE__, client},
      start: {__MODULE__, :start_link, [client]},
      type: :worker
    }
  end

  @doc "Checks that Kafka client is already started"
  @spec client_started?(client :: atom()) :: boolean()
  def client_started?(client) do
    GenServer.call({__MODULE__, client}, :client_started?)
  end

  ##
  ## Callbacks
  ##

  @impl GenServer
  def init(client) do
    Process.flag(:trap_exit, true)
    {:ok, %State{client: client}, {:continue, :start_client}}
  end

  @impl GenServer
  def handle_continue(:start_client, state) do
    {:noreply, connect(state)}
  end

  @impl GenServer
  def handle_call(:client_started?, _from, %State{client_started: started?} = state) do
    {:reply, started?, state}
  end

  def handle_call(msg, _from, state) do
    Logger.warning("KafkaBatcher: Unexpected call #{inspect(msg)}")
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %State{client_pid: nil} = state) do
    Logger.info("""
      KafkaBatcher: Client was crashed #{inspect(pid)}, but reconnect is already in progress.
      Reason: #{inspect(reason)}
    """)

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, %State{client_pid: pid} = state) do
    Logger.info("KafkaBatcher: Client was crashed #{inspect(pid)}. Reason #{inspect(reason)}. Trying to reconnect")
    state = connect(%State{state | client_pid: nil, client_started: false})
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    Logger.info("KafkaBatcher: Retry connection")
    {:noreply, connect(state)}
  end

  def handle_info(msg, state) do
    Logger.warning("KafkaBatcher: Unexpected info #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Logger.info("KafkaBatcher: Terminating #{__MODULE__}. Reason #{inspect(reason)}")
    {:noreply, state}
  end

  ##
  ## INTERNAL FUNCTIONS
  ##

  defp connect(state) do
    case prepare_connection(state) do
      {:ok, pid} ->
        %State{state | client_started: true, client_pid: pid}

      :retry ->
        Process.send_after(self(), :reconnect, @reconnect_timeout)
        %State{state | client_started: false, client_pid: nil}
    end
  end

  defp start_producers(%State{} = state) do
    state.client
    |> KafkaBatcher.Config.get_configs_by_topic_name()
    |> Enum.reduce_while(:ok, fn {topic_name, config}, _ ->
      case @producer.start_producer(state.client, topic_name, config) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          @error_notifier.report(
            type: "KafkaBatcherProducerStartFailed",
            message: "Topic: #{topic_name}. Reason #{inspect(reason)}"
          )

          {:halt, :error}
      end
    end)
  end

  defp prepare_connection(state) do
    case start_client(state) do
      {:ok, pid} ->
        case start_producers(state) do
          :ok -> {:ok, pid}
          :error -> :retry
        end

      {:error, reason} ->
        @error_notifier.report(
          type: "KafkaBatcherClientStartFailed",
          message: "Kafka client start failed: #{inspect(reason)}"
        )

        :retry
    end
  end

  defp start_client(%State{} = state) do
    case @producer.start_client(state.client) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("KafkaBatcher: Kafka client already started: #{inspect(pid)}")
        {:ok, pid}

      error ->
        error
    end
  end
end
