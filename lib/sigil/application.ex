defmodule Sigil.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    case Sigil.Agent.ModelConfig.ensure_config() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Sigil] model config skipped: #{reason}")
    end

    children =
      [
        SigilWeb.Telemetry,
        Sigil.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:sigil, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:sigil, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Sigil.PubSub},
        {Registry, keys: :unique, name: Sigil.SessionRegistry},
        {Registry, keys: :unique, name: Sigil.AgentRunRegistry},
        {Registry, keys: :unique, name: Sigil.AgentRunSupervisorRegistry},
        {Registry, keys: :unique, name: Sigil.AgentRunQueueRegistry},
        Sigil.Preview.Store,
        Sigil.ExportSnapshot.Binding,
        Sigil.Preview.Listener,
        Sigil.Browser.Display,
        Sigil.Tool.Registry,
        {Sigil.Extension.Registry, name: Sigil.Extension.Registry},
        Sigil.Extension.Supervisor,
        Sigil.Extension.Mount,
        {Sigil.Extension.HotReloader,
         enabled: Application.get_env(:sigil, :extension_hot_reload, true),
         trusted_project?: Sigil.ProjectTrust.enabled?()}
      ] ++
        terminal_children() ++
        browser_children() ++
        [
          Sigil.SessionSupervisor,
          Sigil.AgentRunSupervisor,
          {Task.Supervisor, name: Sigil.AgentRunTaskSupervisor},
          Sigil.Runtime.TaskTracker
        ] ++
        mcp_children() ++
        [SigilWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sigil.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SigilWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end

  defp terminal_children do
    if Sigil.Host.terminal?() do
      [Sigil.Terminal.Registry, Sigil.Terminal.Supervisor]
    else
      []
    end
  end

  defp browser_children do
    desktop =
      if Sigil.Host.desktop_browser?() do
        [Sigil.Browser.Registry, Sigil.Browser.Supervisor]
      else
        []
      end

    webview =
      if Sigil.Host.webview_browser?() do
        [
          {Registry, keys: :unique, name: Sigil.Browser.WebViewRegistry},
          Sigil.Browser.WebViewSupervisor
        ]
      else
        []
      end

    desktop ++ webview
  end

  defp mcp_children do
    if Sigil.Host.mcp?() do
      [Sigil.MCP.RuntimeSupervisor, Sigil.MCP, Sigil.MCP.DeferredBootstrap]
    else
      []
    end
  end
end
