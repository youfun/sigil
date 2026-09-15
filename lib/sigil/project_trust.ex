defmodule Sigil.ProjectTrust do
  @moduledoc """
  Controls whether project-local configuration may execute code.

  User-level extensions and MCP configuration remain available. Project-local
  `.sigil/extensions`, `.mcp.json`, and `.sigil/mcp.json` are disabled by
  default and require an explicit opt-in.
  """

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Keyword.get_lazy(opts, :trusted_project?, fn ->
      Application.get_env(:sigil, :trust_project_code, false)
    end) == true
  end
end
