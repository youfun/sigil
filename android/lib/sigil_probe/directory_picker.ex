defmodule SigilProbe.DirectoryPicker do
  @moduledoc """
  `Sigil.Host` `:directory_picker` for the phone host.

  The web workspace UI asks the host to pick a directory; on the phone the
  picker is the in-app folder browser of `SigilProbe.HomeScreen`, so the
  request is forwarded to the current screen process as
  `{:directory_picker, context}`. The screen is looked up under
  `:sigil_probe, :directory_picker_screen` (tests) or the Mob router name
  `:mob_screen`, which forwards unknown messages to the visible screen.
  """

  @spec request_directory_picker(map()) :: :ok | {:error, :unavailable}
  def request_directory_picker(context) when is_map(context) do
    case screen() do
      pid when is_pid(pid) ->
        send(pid, {:directory_picker, context})
        :ok

      _ ->
        {:error, :unavailable}
    end
  end

  defp screen do
    case Application.get_env(:sigil_probe, :directory_picker_screen) do
      pid when is_pid(pid) -> pid
      name when is_atom(name) and not is_nil(name) -> Process.whereis(name)
      _ -> Process.whereis(:mob_screen)
    end
  end
end
