defmodule Sigil.PathsTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:sigil, :host)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sigil, :host, previous),
        else: Application.delete_env(:sigil, :host)
    end)

    :ok
  end

  test "priv_dir uses Application.app_dir off device" do
    Application.delete_env(:sigil, :host)
    assert Sigil.Paths.priv_dir() == Application.app_dir(:sigil, "priv")
    assert Sigil.Paths.static_root() == Path.join(Application.app_dir(:sigil, "priv"), "static")
  end

  test "priv_dir uses Host.priv_dir when configured" do
    Sigil.Host.put!(%{priv_dir: "/tmp/mob-beams/priv"})
    assert Sigil.Paths.priv_dir() == "/tmp/mob-beams/priv"
    assert Sigil.Paths.migrations_dir() == "/tmp/mob-beams/priv/repo/migrations"
  end

  test "Home.expand maps ~/.sigil onto Host.data_dir" do
    Sigil.Host.put!(%{data_dir: "/tmp/mob-data"})
    assert Sigil.Home.expand("~/.sigil/models.json") == "/tmp/mob-data/.sigil/models.json"
  end

  test "phone host tools drop bash and keep grep" do
    Sigil.Host.put!(%{
      data_dir: "/tmp/mob-data",
      priv_dir: "/tmp/mob-beams/priv",
      shell: false,
      terminal: false,
      desktop_browser: false,
      webview_browser: true,
      beam_eval: false,
      mcp: false
    })

    names = Enum.map(Sigil.Agent.default_tools(), & &1.name())
    refute "bash" in names
    assert "browser" in names
    assert "preview_serve" in names
    assert "android_open_url" in names
    assert "android_open_file" in names
    assert "android_share_file" in names
    assert "run_elixir_script" in names
    assert "read" in names
    assert "grep" in names
    refute "ext__beam__eval" in names
    refute "ext__beam__sql" in names
  end

  test "session events observations and auth resolve under Host.data_dir" do
    Sigil.Host.put!(%{data_dir: "/tmp/mob-data"})

    assert Sigil.SessionStore.File.session_path("s1") ==
             "/tmp/mob-data/.sigil/sessions/s1.json"

    assert Sigil.EventRecorder.event_path("s1") ==
             "/tmp/mob-data/.sigil/events/s1.jsonl"

    assert Sigil.Memory.ObservationStore.base_dir() ==
             "/tmp/mob-data/.sigil/observations"

    assert Sigil.Agent.Auth.Storage.file_path() ==
             "/tmp/mob-data/.sigil/auth.json"
  end
end
