defmodule TestHookModule do
  @moduledoc false
  @behaviour Sigil.Extension.Hook

  alias Sigil.Extension.Event

  @impl true
  def handle_event(%Event{}, _ctx) do
    :ok
  end
end
