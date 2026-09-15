defmodule Sigil.MCP.Config do
  @moduledoc """
  Top-level result of MCP configuration loading.

  Contains merged and validated server configs plus diagnostics.
  """
  defstruct servers: %{}, diagnostics: []

  @type t :: %__MODULE__{
          servers: %{String.t() => Sigil.MCP.ServerConfig.t()},
          diagnostics: [Sigil.MCP.Diagnostic.t()]
        }
end
