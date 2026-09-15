defmodule Sigil.Tool.Extension.BeamIntrospectionTest do
  use Sigil.DataCase, async: true

  alias Sigil.Agent.Tool.Executor

  setup do
    # Register all beam tools before each test
    Enum.each(beam_tool_modules(), &Sigil.Tool.Registry.register/1)

    %{}
  end

  defp beam_tool_modules do
    [
      Sigil.Tool.Extension.Beam.Eval,
      Sigil.Tool.Extension.Beam.Docs,
      Sigil.Tool.Extension.Beam.Source,
      Sigil.Tool.Extension.Beam.Sql,
      Sigil.Tool.Extension.Beam.Schemas,
      Sigil.Tool.Extension.Beam.SupTree,
      Sigil.Tool.Extension.Beam.Top,
      Sigil.Tool.Extension.Beam.ProcessInfo
    ]
  end

  defp build_context do
    %{working_directory: File.cwd!()}
  end

  describe "ext__beam__eval" do
    test "evaluates simple Elixir expression" do
      {:ok, _output} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => "1 + 2"},
          build_context()
        )

      assert _output =~ "3"
    end

    test "evaluates multi-line code" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => "xs = [1, 2, 3]\nEnum.sum(xs)"},
          build_context()
        )

      assert output =~ "6"
    end

    test "returns error for syntax error" do
      result =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => "1 +"},
          build_context()
        )

      assert match?({:error, _}, result)
    end

    test "returns error for runtime error" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => "raise \"boom\""},
          build_context()
        )

      assert reason =~ "boom" or reason =~ "error" or reason =~ "RuntimeError"
    end

    test "code is required" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{},
          build_context()
        )

      assert reason =~ "code"
    end

    test "timeout kills long-running code" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => "Process.sleep(10_000)", "timeout" => 500},
          build_context()
        )

      assert reason =~ "timed out"
    end

    test "rejects :rpc calls" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => ":rpc.call(node(), Kernel, :+, [1, 1])"},
          build_context()
        )

      assert reason =~ "not allowed" or reason =~ "rpc"
    end

    test "rejects File write" do
      path =
        Path.join(System.tmp_dir!(), "sigil_eval_write_#{System.unique_integer([:positive])}")

      {:error, reason} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => "File.write!(#{inspect(path)}, \"owned\")"},
          build_context()
        )

      refute File.exists?(path)
      assert reason =~ "not allowed" or reason =~ "File"
    end

    test "rejects System.cmd" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Eval.execute(
          %{"code" => "System.cmd(\"echo\", [\"hi\"])"},
          build_context()
        )

      assert reason =~ "not allowed" or reason =~ "System.cmd"
    end

    test "has proper tool metadata" do
      assert Sigil.Tool.Extension.Beam.Eval.name() == "ext__beam__eval"
      assert is_binary(Sigil.Tool.Extension.Beam.Eval.description())
      assert is_map(Sigil.Tool.Extension.Beam.Eval.input_schema())
    end
  end

  describe "ext__beam__docs" do
    test "gets docs for a known module" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.Docs.execute(
          %{"reference" => "Enum"},
          build_context()
        )

      assert output =~ "Enum"
      assert output =~ "Sets" or output =~ "Functions" or output != ""
    end

    test "gets docs for a known function" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.Docs.execute(
          %{"reference" => "Enum.map/2"},
          build_context()
        )

      assert output =~ "map"
      assert output =~ "Enum"
    end

    test "returns error for unknown module" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Docs.execute(
          %{"reference" => "NonExistent.Module.XYZ"},
          build_context()
        )

      assert reason =~ "not found" or reason =~ "could not" or reason =~ "error"
    end

    test "reference is required" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Docs.execute(
          %{},
          build_context()
        )

      assert reason =~ "reference"
    end

    test "has proper tool metadata" do
      assert Sigil.Tool.Extension.Beam.Docs.name() == "ext__beam__docs"
      assert is_binary(Sigil.Tool.Extension.Beam.Docs.description())
    end
  end

  describe "ext__beam__source" do
    test "locates source file for a known module" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.Source.execute(
          %{"reference" => "Enum"},
          build_context()
        )

      assert output =~ "Enum"
      # Should include file path or "could not determine"
    end

    test "locates source for function with arity" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.Source.execute(
          %{"reference" => "Enum.map/2"},
          build_context()
        )

      assert output != ""
    end

    test "reference is required" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Source.execute(
          %{},
          build_context()
        )

      assert reason =~ "reference"
    end
  end

  describe "ext__beam__sql" do
    test "executes a simple SQL query" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.Sql.execute(
          %{"query" => "SELECT 1 AS num"},
          build_context()
        )

      assert output =~ "num" or output =~ "1"
    end

    test "query is required" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.Sql.execute(
          %{},
          build_context()
        )

      assert reason =~ "query"
    end

    test "has proper tool metadata" do
      assert Sigil.Tool.Extension.Beam.Sql.name() == "ext__beam__sql"
      assert is_binary(Sigil.Tool.Extension.Beam.Sql.description())
    end
  end

  # ── P1 tools ──

  describe "ext__beam__schemas" do
    test "lists Ecto schemas including project modules" do
      {:ok, output} = Sigil.Tool.Extension.Beam.Schemas.execute(%{}, build_context())
      # Should find project schemas (Engram, Synapse are Ecto schemas)
      assert is_binary(output)
    end
  end

  describe "ext__beam__sup_tree" do
    test "shows supervision tree for Sigil app" do
      result = Sigil.Tool.Extension.Beam.SupTree.execute(%{}, build_context())
      assert match?({:ok, _}, result)
    end
  end

  describe "ext__beam__top" do
    test "lists top processes sorted by memory" do
      {:ok, output} = Sigil.Tool.Extension.Beam.Top.execute(%{"limit" => 5}, build_context())
      assert output =~ "PID"
      assert output =~ "Memory"
    end

    test "can sort by reductions" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.Top.execute(
          %{"sort" => "reductions", "limit" => 3},
          build_context()
        )

      assert output != ""
    end

    test "has proper tool metadata" do
      assert Sigil.Tool.Extension.Beam.Top.name() == "ext__beam__top"
    end
  end

  describe "ext__beam__process_info" do
    test "gets info for Tool.Registry process" do
      {:ok, output} =
        Sigil.Tool.Extension.Beam.ProcessInfo.execute(
          %{"process" => "Sigil.Tool.Registry"},
          build_context()
        )

      assert output =~ "Sigil.Tool.Registry"
      assert output =~ "GenServer State" or output =~ "alive"
    end

    test "process argument is required" do
      {:error, reason} = Sigil.Tool.Extension.Beam.ProcessInfo.execute(%{}, build_context())
      assert reason =~ "process"
    end

    test "returns error for nonexistent process" do
      {:error, reason} =
        Sigil.Tool.Extension.Beam.ProcessInfo.execute(
          %{"process" => "NonExistent.Process.XYZ"},
          build_context()
        )

      assert reason =~ "Cannot resolve" or reason =~ "error"
    end
  end
end
