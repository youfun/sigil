defmodule Sigil.Extension.ToolBehaviourTest do
  use ExUnit.Case, async: true

  alias Sigil.Agent.Tool

  describe "Extension tool behaviour" do
    test "extension tools must implement Sigil.Agent.Tool behaviour" do
      # An extension tool is just a regular tool module that implements
      # Sigil.Agent.Tool behaviour. The only difference is its naming
      # convention: it must provide sigil_name/0 returning "ext__<ext>__<tool>"
      mod = TestExtensionTool

      assert mod.name() == "ext__test__ping"
      assert is_binary(mod.description())
      assert mod.input_schema() != %{}
      assert mod.concurrent?() == true

      assert {:ok, result} = mod.execute(%{}, %{})
      assert result == "pong"
    end

    test "extension tool in Tool.Registry is dispatchable" do
      # Register the tool and verify it can be dispatched
      :ok = Sigil.Tool.Registry.register(TestExtensionTool)

      {:ok, entry} = Sigil.Tool.Registry.get("ext__test__ping")
      assert {:ok, "pong"} = entry.executor.(%{}, %{})
    end

    test "extension tool appears in tool defs for provider" do
      :ok = Sigil.Tool.Registry.register(TestExtensionTool)

      defs = Sigil.Tool.Registry.tool_defs()
      ping_def = Enum.find(defs, &(&1.name == "ext__test__ping"))
      assert ping_def != nil
      assert ping_def.description == "Simple ping test tool"
    end
  end
end
