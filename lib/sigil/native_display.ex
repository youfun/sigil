defmodule Sigil.NativeDisplay do
  @moduledoc """
  Bridgeless native overlay boundary.

  The host installs a 2-arity runner via `:sigil, :native_display`.
  This is not `Mob.UI.webview` and must not inject `window.mob`.
  """

  @spec command(term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
  def command(cmd, opts \\ []) do
    case Application.get_env(:sigil, :native_display) do
      fun when is_function(fun, 2) -> fun.(cmd, opts)
      _ -> {:error, :not_configured}
    end
  end
end
