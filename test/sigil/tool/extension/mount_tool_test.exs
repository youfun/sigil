defmodule Sigil.Tool.Extension.MountToolTest do
  use ExUnit.Case, async: false

  alias Sigil.Tool.Extension.MountApply
  alias Sigil.Tool.Extension.MountDrop

  setup do
    n = System.unique_integer([:positive])
    id = "toolmem#{n}"

    on_exit(fn ->
      _ = Sigil.Extension.Mount.unmount(id)
    end)

    {:ok, n: n, id: id}
  end

  test "ext__mount__apply compiles source and registers the tool", %{n: n, id: id} do
    assert MountApply.name() == "ext__mount__apply"

    source = """
    defmodule Ext.ToolMem#{n}.Ping do
      @behaviour Sigil.Agent.Tool
      def name, do: "ext__toolmem#{n}__ping"
      def description, do: "mounted"
      def input_schema, do: %{"type" => "object", "properties" => %{}}
      def execute(_input, _context), do: {:ok, "from-tool"}
    end
    """

    assert {:ok, out} = MountApply.execute(%{"name" => id, "source" => source}, %{})
    assert out =~ id
    assert {:ok, entry} = Sigil.Tool.Registry.get("ext__toolmem#{n}__ping")
    assert {:ok, "from-tool"} = entry.executor.(%{}, %{})
  end

  test "ext__mount__drop unregisters a previous mount", %{n: n, id: id} do
    source = """
    defmodule Ext.ToolMem#{n}.Ping do
      @behaviour Sigil.Agent.Tool
      def name, do: "ext__toolmem#{n}__ping"
      def description, do: "mounted"
      def input_schema, do: %{"type" => "object", "properties" => %{}}
      def execute(_input, _context), do: {:ok, "x"}
    end
    """

    assert {:ok, _} = MountApply.execute(%{"name" => id, "source" => source}, %{})
    assert {:ok, _} = Sigil.Tool.Registry.get("ext__toolmem#{n}__ping")
    assert {:ok, _} = MountDrop.execute(%{"name" => id}, %{})
    assert Sigil.Tool.Registry.get("ext__toolmem#{n}__ping") == :error
  end
end
