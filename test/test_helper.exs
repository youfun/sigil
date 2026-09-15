ExUnit.configure(exclude: [:slow, :e2e, :external_api])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Sigil.Repo, :manual)

# Start Tool Registry for agent/tool tests.
# If the app is already running, this is a no-op.
case Sigil.Tool.Registry.start_link([]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

unless Process.whereis(Sigil.ExportSnapshot.Binding) do
  {:ok, _} = Sigil.ExportSnapshot.Binding.start_link([])
end

# Start Extension Registry for hook/extension tests.
# If the app is already running, this is a no-op.
unless Process.whereis(Sigil.Extension.Registry) do
  Sigil.Extension.Registry.start_link(name: Sigil.Extension.Registry)
end

unless Process.whereis(Sigil.Extension.Supervisor) do
  Sigil.Extension.Supervisor.start_link([])
end

unless Process.whereis(Sigil.Extension.Mount) do
  Sigil.Extension.Mount.start_link([])
end
