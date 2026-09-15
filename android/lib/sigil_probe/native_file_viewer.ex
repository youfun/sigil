defmodule SigilProbe.NativeFileViewer do
  @moduledoc """
  Read-only viewer metadata and Mob nodes.

  `prepare/1` resolves the path and classifies from the **name** only.
  It does not open the file. Bytes are read on Android from one checked fd.

  HomeScreen shows the Mob `:file_viewer` node. Bytes stay on Android.

  External kinds use `export/2`, which is only
  `Platform.export_file(caller, request_id, generation, workspace_path, relative_path)`.
  Foundation also has
  `open_snapshot(caller, request_id, generation, snapshot_id, owner_request_id)` and
  `share_snapshot/5` with the same arity — those run **after** an export
  result exists. This module does not call them.

  Platform snapshot JSON uses snake_case (`snapshot_id`, `owner_request_id`).
  """

  import SigilProbe.NativeUI

  alias Sigil.WorkspaceFiles

  defstruct identity: nil, status: :closed, error: nil

  @type status :: :closed | :ready | :external | :error
  @type t :: %__MODULE__{identity: Identity.t() | nil, status: status(), error: term()}

  defmodule Identity do
    @moduledoc false

    @enforce_keys [:workspace_id, :workspace_root, :relative_path, :request_id, :generation]
    defstruct [
      :workspace_id,
      :workspace_root,
      :relative_path,
      :request_id,
      :generation,
      :display_name,
      :kind,
      :mime
    ]

    @type t :: %__MODULE__{
            workspace_id: String.t(),
            workspace_root: String.t(),
            relative_path: String.t(),
            request_id: String.t(),
            generation: integer(),
            display_name: String.t() | nil,
            kind: :text | :image | :external | nil,
            mime: String.t() | nil
          }

    def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

    def new(attrs) when is_map(attrs) do
      workspace_id = string(attrs, :workspace_id)
      workspace_root = string(attrs, :workspace_root)
      relative_path = string(attrs, :relative_path)
      request_id = string(attrs, :request_id)
      generation = integer(attrs, :generation)

      if workspace_id && workspace_root && relative_path && request_id && generation do
        {:ok,
         %__MODULE__{
           workspace_id: workspace_id,
           workspace_root: workspace_root,
           relative_path: relative_path,
           request_id: request_id,
           generation: generation,
           display_name: string(attrs, :display_name) || Path.basename(relative_path),
           kind: kind(attrs),
           mime: string(attrs, :mime)
         }}
      else
        {:error, :invalid_identity}
      end
    end

    def new(_), do: {:error, :invalid_identity}

    def same_file?(%__MODULE__{} = a, %__MODULE__{} = b) do
      a.workspace_id == b.workspace_id and
        a.relative_path == b.relative_path and
        a.request_id == b.request_id and
        a.generation == b.generation
    end

    def same_file?(_, _), do: false

    # `attrs` come from `NativeWorkspaceOpen.authorize/2` (atom keys only).
    defp string(attrs, key) do
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end

    defp integer(attrs, key) do
      case Map.get(attrs, key) do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {n, ""} -> n
            _ -> nil
          end

        _ ->
          nil
      end
    end

    defp kind(attrs) do
      case Map.get(attrs, :kind) do
        kind when kind in [:text, :image, :external] -> kind
        "text" -> :text
        "image" -> :image
        "external" -> :external
        _ -> nil
      end
    end
  end

  @snapshot_keys ~w(snapshot_id path display_name size_bytes mime state owner_request_id)

  def new, do: %__MODULE__{}
  def snapshot_keys, do: @snapshot_keys

  @spec prepare(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(attrs) do
    with {:ok, identity} <- Identity.new(attrs),
         {:ok, _path} <-
           WorkspaceFiles.resolve(identity.workspace_root, identity.relative_path, :file),
         {:ok, kind, mime} <- WorkspaceFiles.kind_from_name(identity.display_name) do
      identity = %{identity | kind: kind, mime: mime}
      status = if kind == :external, do: :external, else: :ready
      {:ok, %__MODULE__{identity: identity, status: status}}
    end
  end

  def close(%__MODULE__{} = state), do: %{state | identity: nil, status: :closed, error: nil}

  @spec export(Identity.t(), keyword()) :: {:ok, :async} | {:ok, map()} | {:error, term()}
  def export(%Identity{} = identity, opts \\ []) do
    export = Keyword.get(opts, :export) || (&default_export/5)
    caller = Keyword.get(opts, :caller, self())

    export.(
      caller,
      identity.request_id,
      identity.generation,
      identity.workspace_root,
      identity.relative_path
    )
  end

  def viewer_node(%__MODULE__{identity: %Identity{} = identity, status: status} = state) do
    node(
      :file_viewer,
      id: "file-viewer-#{identity.request_id}-#{identity.generation}",
      workspace_id: identity.workspace_id,
      workspace_root: identity.workspace_root,
      relative_path: identity.relative_path,
      request_id: identity.request_id,
      generation: identity.generation,
      display_name: identity.display_name,
      kind: kind_name(identity.kind),
      mime: identity.mime || "",
      status: Atom.to_string(status),
      error: error_text(state.error)
    )
  end

  def viewer_node(%__MODULE__{}), do: nil

  defp default_export(caller, request_id, generation, workspace_root, relative_path) do
    SigilProbe.Platform.export_file(
      caller,
      request_id,
      generation,
      workspace_root,
      relative_path
    )
  end

  defp kind_name(nil), do: ""
  defp kind_name(kind), do: Atom.to_string(kind)
  defp error_text(nil), do: ""
  defp error_text(reason), do: inspect(reason)
end
