defmodule Sigil.Security.PathValidator do
  @moduledoc """
  Path security validation — prevent path traversal and ensure safe file access.

  Validates that resolved paths stay within the workspace and checks file
  accessibility.
  """

  @doc """
  Validate that a path exists and is readable.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_readable(String.t()) :: :ok | {:error, String.t()}
  def validate_readable(path) do
    with :ok <- check_exists(path),
         :ok <- check_not_directory(path) do
      case File.stat(path) do
        {:ok, %{access: access}} when access in [:read, :read_write] -> :ok
        {:ok, _} -> {:error, "#{path}: Permission denied (EACCES)"}
        {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Validate that a path (or its parent directory) is writeable.
  """
  @spec validate_writeable(String.t()) :: :ok | {:error, String.t()}
  def validate_writeable(path) do
    if File.exists?(path) do
      if is_writeable?(path) do
        :ok
      else
        {:error, "#{path}: Read-only file (EACCES)"}
      end
    else
      target = Path.dirname(path)

      if is_writeable?(target) do
        :ok
      else
        {:error, "#{path}: Parent directory not writeable (EACCES)"}
      end
    end
  end

  @doc """
  Validate that a resolved path is within the allowed workspace.
  """
  @spec validate_within_workspace(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_within_workspace(path, workspace) when is_binary(workspace) do
    expanded = Path.expand(path)
    resolved = resolve_symlink(expanded)
    ws = Path.expand(workspace)

    if String.starts_with?(resolved, ws <> "/") or resolved == ws do
      :ok
    else
      {:error, "Path traversal blocked: #{path} is outside workspace"}
    end
  end

  @doc """
  Validate that a directory path is under the allowed root directory.

  Uses `Path.safe_relative_to/2` when the root exists (strict validation with
  symlink resolution). Falls back to a string-prefix check when the root does
  not yet exist (e.g. a brand new `session_store_dir` before `mkdir_p`).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_under_root(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_under_root(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)

    # When the path exists (real file or directory), use Path.safe_relative_to/2
    # for strict containment with symlink resolution.  This is the authoritative
    # check because it operates on the *resolved* path on disk.
    #
    # When the path does NOT yet exist (e.g. a subdirectory that will be created),
    # Path.safe_relative_to returns :error for non-existent targets, which would
    # incorrectly flag legitimate sub-paths.  Fall back to a string-prefix check.
    if expanded_path == expanded_root do
      :ok
    else
      # When the path exists (real file or directory), use Path.safe_relative_to/2
      # for strict containment with symlink resolution.
      if File.exists?(expanded_path) do
        case Path.safe_relative_to(expanded_path, expanded_root) do
          {:ok, _relative} -> :ok
          :error -> {:error, "Path traversal blocked: #{path} is outside #{root}"}
        end
      else
        # Path doesn't exist yet — fall back to string-prefix check.
        root_prefix =
          if String.ends_with?(expanded_root, "/"), do: expanded_root, else: expanded_root <> "/"

        if String.starts_with?(expanded_path, root_prefix) do
          :ok
        else
          {:error, "Path traversal blocked: #{path} is outside #{root}"}
        end
      end
    end
  end

  @doc false
  @spec resolve_symlink(String.t()) :: String.t()
  def resolve_symlink(path) do
    resolve_symlink(path, MapSet.new())
  end

  defp resolve_symlink(path, seen) do
    with {:ok, target} <- File.read_link(path),
         false <- MapSet.member?(seen, path) do
      resolved =
        if Path.type(target) == :absolute do
          target
        else
          Path.expand(target, Path.dirname(path))
        end

      resolve_symlink(resolved, MapSet.put(seen, path))
    else
      _ -> path
    end
  end

  # ── Private helpers ──

  defp check_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, "#{path}: No such file"}
  end

  defp check_not_directory(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} -> {:error, "#{path}: Is a directory"}
      _ -> :ok
    end
  end

  defp is_writeable?(path) do
    case File.stat(path) do
      {:ok, %{access: access}} when access in [:write, :read_write] -> true
      _ -> false
    end
  end
end
