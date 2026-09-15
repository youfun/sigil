defmodule Sigil.MCP.ToolBridge do
  @moduledoc """
  Bridges MCP server tools into Sigil.Tool.Registry as virtual tools.
  """

  alias Sigil.MCP.ServerConfig

  @spec register_server_tools(pid(), ServerConfig.t()) :: {:ok, [String.t()]} | {:error, term()}
  def register_server_tools(runtime_pid, %ServerConfig{name: server_name}) do
    case Sigil.MCP.ServerRuntime.tools(runtime_pid) do
      {:ok, tools} ->
        registered =
          Enum.map(tools, fn tool ->
            namespaced = namespaced_name(server_name, tool.name)

            executor = fn input, _context ->
              Sigil.MCP.ServerRuntime.call_tool(runtime_pid, tool.name, input)
            end

            :ok =
              Sigil.Tool.Registry.register_virtual(
                namespaced,
                tool.description,
                tool.input_schema,
                executor,
                meta: %{source: :mcp, server: server_name, remote_name: tool.name}
              )

            namespaced
          end)

        {:ok, registered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def unregister_server_tools(_server_name, tool_names \\ nil) do
    case tool_names do
      nil ->
        :ok

      names when is_list(names) ->
        Enum.each(names, &Sigil.Tool.Registry.unregister/1)
        :ok
    end
  end

  def namespaced_name(server_name, tool_name) do
    "mcp__#{server_name}__#{tool_name}"
  end
end
