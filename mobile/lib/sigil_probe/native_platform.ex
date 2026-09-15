defmodule SigilProbe.NativePlatform do
  @moduledoc """
  Which native renderer is hosting SigilProbe.

  Mix tests never load `mob_nif`, so the default is `:android` (the Compose
  host the tests assert against). The device sets this once in `App.on_start`.
  """

  @type t :: :android | :ios

  @spec put!(t()) :: :ok
  def put!(platform) when platform in [:android, :ios] do
    Application.put_env(:sigil_probe, :native_platform, platform)
  end

  @spec get() :: t()
  def get, do: Application.get_env(:sigil_probe, :native_platform) || detect()

  @spec ios?() :: boolean()
  def ios?, do: get() == :ios

  @spec android?() :: boolean()
  def android?, do: get() == :android

  @spec detect() :: t()
  def detect do
    try do
      case :mob_nif.platform() do
        :ios -> :ios
        _ -> :android
      end
    rescue
      ArgumentError -> :android
      ErlangError -> :android
    catch
      :error, :undef -> :android
      :error, {:nif_not_loaded, _} -> :android
    end
  end

  @spec dist_node(t()) :: atom()
  def dist_node(:ios), do: :"sigil_probe_ios@127.0.0.1"
  def dist_node(_), do: :"sigil_probe_android@127.0.0.1"
end
