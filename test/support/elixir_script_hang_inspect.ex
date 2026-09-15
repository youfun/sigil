defmodule Sigil.Tool.Builtin.ElixirScriptHangInspect do
  @moduledoc false
  defstruct []
end

defimpl Inspect, for: Sigil.Tool.Builtin.ElixirScriptHangInspect do
  def inspect(_value, _opts) do
    receive do
      :never -> "%Sigil.Tool.Builtin.ElixirScriptHangInspect{}"
    end
  end
end
