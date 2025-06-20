defmodule KafkaBatcher.Behaviours.Accumulator do
  alias KafkaBatcher.MessageObject

  @typep topic_name :: String.t()
  @typep partition :: non_neg_integer() | nil

  @callback start_link(Keyword.t()) :: GenServer.on_start()
  @callback child_spec(Keyword.t()) :: Supervisor.child_spec()
  @callback add_event(MessageObject.t(), topic_name()) :: term()
  @callback add_event(MessageObject.t(), topic_name(), partition()) :: term()
end
