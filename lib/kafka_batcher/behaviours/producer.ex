defmodule KafkaBatcher.Behaviours.Producer do
  @moduledoc """
  KafkaBatcher.Behaviours.Producer adds an abstraction level over producer implementations in various Kafka libs.
  Defines the callbacks that a Kafka producer should implement
  """
  @type event :: KafkaBatcher.MessageObject.t()
  @type events :: list(event())
  @type client :: atom()

  @callback do_produce(
              client :: client(),
              events :: events(),
              topic :: binary(),
              partition :: non_neg_integer() | nil,
              config :: Keyword.t()
            ) :: :ok | {:error, binary() | atom()}

  @callback get_partitions_count(
              client :: client(),
              binary()
            ) :: {:ok, integer()} | {:error, binary() | atom()}

  @callback start_client(client :: client()) :: {:ok, pid()} | {:error, any()}

  @callback start_producer(
              client :: client(),
              binary(),
              Keyword.t()
            ) :: :ok | {:error, any()}
end
