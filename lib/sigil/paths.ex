defmodule Sigil.Paths do
  @moduledoc """
  Locations for priv/ and static assets.

  Hosts that unpack a flat OTP tree set `:priv_dir` on `Sigil.Host`.
  """

  @spec priv_dir() :: String.t()
  def priv_dir, do: Sigil.Host.priv_dir()

  @spec static_root() :: String.t()
  def static_root, do: Path.join(priv_dir(), "static")

  @spec migrations_dir() :: String.t()
  def migrations_dir, do: Path.join(priv_dir(), "repo/migrations")
end
