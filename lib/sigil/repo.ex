defmodule Sigil.Repo do
  use Ecto.Repo,
    otp_app: :sigil,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    config =
      if Sigil.Host.configured?() do
        Keyword.put(config, :database, Path.join(Sigil.Host.data_dir(), "sigil.db"))
      else
        config
      end

    {:ok, config}
  end
end
