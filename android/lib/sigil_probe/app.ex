defmodule SigilProbe.App do
  @moduledoc "Application entry point for SigilProbe."

  use Mob.App

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: SigilProbe.HomeScreen)
  end

  @known_api_hosts [
    "api.stepfun.com",
    "api.openai.com",
    "api.anthropic.com",
    "api.deepseek.com",
    "zenmux.ai",
    "api.x.ai"
  ]

  @impl Mob.App
  def on_start do
    start_runtime!()
  end

  def start_runtime! do
    Mob.DNS.configure_pure_beam()

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Application.ensure_all_started(:castore)
    load_cacerts()
    Req.default_options(plugins: [SigilProbe.ReqDNS])
    configure_sigil!()
    Mob.DNS.preresolve(@known_api_hosts)
    {:ok, _} = Application.ensure_all_started(:sigil)
    :ok = ensure_task_supervisor()
    :ok = SigilProbe.ShareIntake.Lock.ensure_started()
    :ok = SigilProbe.ShareCopy.ensure_started()
    # Loads :sigil_browser so nif_ready is set before HomeScreen can mount
    # and before hot share JNI callbacks are useful.
    SigilProbe.Browser.Engine.install!()
    Sigil.Runtime.configure_notify_adapter()
    Sigil.Runtime.mark_interrupted_runs()

    Ecto.Migrator.with_repo(Sigil.Repo, fn repo ->
      Ecto.Migrator.run(repo, Sigil.Paths.migrations_dir(), :up, all: true)
    end)

    unless Process.whereis(:mob_screen) do
      Mob.Screen.start_root(SigilProbe.HomeScreen)
    end

    if Sigil.Host.dist?() do
      Mob.Dist.ensure_started(node: :"sigil_probe_android@127.0.0.1", cookie: :mob_secret)
    end

    :ok
  end

  def ensure_task_supervisor do
    spec = {Task.Supervisor, name: SigilProbe.TaskSupervisor}

    case Process.whereis(Sigil.Supervisor) do
      nil ->
        raise "Sigil.Supervisor is not running; start :sigil before ensure_task_supervisor/0"

      _pid ->
        case Supervisor.start_child(Sigil.Supervisor, spec) do
          {:ok, _} -> :ok
          {:ok, _, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, :already_present} -> :ok
          {:error, {:already_present, _}} -> :ok
        end
    end
  end

  # Mix config/*.exs is not loaded on device. Set the env Phoenix and Ecto
  # need before `Application.ensure_all_started(:sigil)`.
  defp configure_sigil! do
    data_dir = Mob.data_dir()
    beams_dir = System.get_env("MOB_BEAMS_DIR")

    priv_dir =
      if beams_dir, do: Path.join(beams_dir, "priv"), else: Application.app_dir(:sigil, "priv")

    debug? = System.get_env("MOB_RELEASE") != "1"

    Sigil.Host.put!(%{
      data_dir: data_dir,
      priv_dir: priv_dir,
      shell: false,
      terminal: false,
      desktop_browser: false,
      webview_browser: true,
      system_intents: true,
      directory_picker: SigilProbe.DirectoryPicker,
      script_http: :platform_dns_ca,
      beam_eval: false,
      mcp: false,
      dist: debug?
    })

    System.put_env("HOME", data_dir)
    System.put_env("SIGIL_WORKSPACE", Path.join(data_dir, "workspace"))
    System.put_env("SIGIL_MODELS_FILE", Path.join(data_dir, ".sigil/models.json"))
    System.put_env("SIGIL_WORKSPACES_FILE", Path.join(data_dir, ".sigil/workspaces.json"))
    maybe_set_models_seed(priv_dir)

    liveview_port = Application.get_env(:mob, :liveview_port, default_liveview_port())
    Application.put_env(:mob, :liveview_port, liveview_port)
    Application.put_env(:mob, :host_url, "http://127.0.0.1:#{liveview_port}/")

    Application.put_env(:phoenix, :json_library, Sigil.JSON)
    Application.put_env(:sigil, :ecto_repos, [Sigil.Repo])
    Application.put_env(:sigil, :extension_hot_reload, false)
    Application.put_env(:sigil, :trust_project_code, false)
    Application.put_env(:sigil, :android_intent, SigilProbe.AndroidIntent)
    Application.put_env(:sigil, :notifier, :sigil_notify)

    Application.put_env(:sigil, Sigil.Repo,
      database: Path.join(data_dir, "sigil.db"),
      pool_size: 5
    )

    Application.put_env(:sigil, SigilWeb.Gettext,
      default_locale: "zh_CN",
      locales: ~w(zh_CN en)
    )

    Application.put_env(:sigil_probe, SigilProbe.Gettext,
      default_locale: "zh_CN",
      locales: ~w(zh_CN en)
    )

    configure_staging_roots!()

    secret = host_secret(data_dir)
    origin = "http://127.0.0.1:#{liveview_port}"

    Application.put_env(:sigil, SigilWeb.Endpoint,
      adapter: Bandit.PhoenixAdapter,
      url: [host: "127.0.0.1", port: liveview_port],
      http: [ip: {127, 0, 0, 1}, port: liveview_port],
      check_origin: [origin],
      debug_errors: debug?,
      server: true,
      secret_key_base: secret,
      pubsub_server: Sigil.PubSub,
      live_view: [signing_salt: String.slice(secret, 0, 8)],
      render_errors: [
        formats: [html: SigilWeb.ErrorHTML, json: SigilWeb.ErrorJSON],
        layout: false
      ],
      code_reloader: false,
      watchers: [],
      live_reload: [patterns: []]
    )
  end

  # Mix config/*.exs is not loaded on device. Cleanup roots must be the
  # real Android cacheDir/controlled_import path from the JNI/runtime env
  # (MOB_CACHE_DIR). Host Mix never sets that env, so tests keep injecting
  # :staging_roots themselves.
  def configure_staging_roots!(env \\ System.get_env()) do
    case Map.get(env, "MOB_CACHE_DIR") do
      dir when is_binary(dir) and dir != "" ->
        Application.put_env(:sigil_probe, :staging_roots, [
          Path.join(dir, "controlled_import")
          | share_intake_root(env)
        ])

        :ok

      _ ->
        case share_intake_root(env) do
          [] ->
            :ok

          roots ->
            Application.put_env(:sigil_probe, :staging_roots, roots)
            :ok
        end
    end
  end

  @doc false
  def maybe_set_models_seed(priv_dir, env \\ System.get_env())
      when is_binary(priv_dir) do
    seed = Path.join(priv_dir, "models.seed.json")
    suffix = env["MOB_NODE_SUFFIX"]

    cond do
      suffix not in ["foundationtest", "nativechat"] ->
        :ignored

      File.exists?(seed) ->
        System.put_env("SIGIL_MODELS_SEED", seed)
        :seed

      true ->
        :default
    end
  end

  defp share_intake_root(env) do
    case Map.get(env, "MOB_DATA_DIR") do
      dir when is_binary(dir) and dir != "" -> [Path.join(dir, "share_intake")]
      _ -> []
    end
  end

  defp host_secret(data_dir) do
    path = Path.join(data_dir, ".sigil/endpoint_secret")

    case File.read(path) do
      {:ok, secret} when byte_size(secret) >= 64 ->
        String.trim(secret)

      _ ->
        secret = :crypto.strong_rand_bytes(48) |> Base.encode64()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, secret)
        secret
    end
  end

  defp load_cacerts do
    path = CAStore.file_path()

    case Mob.Certs.load_cacerts(path) do
      :ok -> :ok
      {:error, reason} -> raise "failed to load CA bundle at #{path}: #{inspect(reason)}"
    end
  end

  defp default_liveview_port do
    System.get_env("SIGIL_HTTP_PORT", "5088") |> String.to_integer()
  end
end
