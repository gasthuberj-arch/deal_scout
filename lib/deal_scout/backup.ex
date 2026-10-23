defmodule DealScout.Backup do
  @moduledoc """
  The **Replica sync** and atomic SQLite snapshot module for DealScout.

  Consolidates:
  - Constant-time bearer token verification (`valid_token?/2`)
  - Litestream replica directory inspection (`replica_dir/0`, `inspect_replica_dir/1`, `missing_files_for_client/2`)
  - Path-traversal-safe replica file reads with SHA-256 verification and transfer accounting (`read_replica_file/2`)
  - Atomic SQLite database snapshots via `VACUUM INTO` with transaction sandbox fallback (`create_sqlite_snapshot/1`)
  - Real-time replication status and lag calculation (`get_status/1`)
  """

  require Logger

  alias DealScout.Backup.{Status, Watcher}
  alias DealScout.Repo

  @pubsub DealScout.PubSub
  @pubsub_topic "backup:internal"

  def pubsub_topic, do: @pubsub_topic

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @pubsub_topic)
  end

  defdelegate get_status(server \\ Status), to: Status
  defdelegate client_connected(client_id), to: Status
  defdelegate client_connected(client_id, metadata), to: Status
  defdelegate client_disconnected(client_id), to: Status
  defdelegate record_file_sent(file_path, byte_size), to: Status
  defdelegate record_ping(client_id), to: Status
  defdelegate reset_status(server \\ Status), to: Status, as: :reset

  defdelegate scan_replica(dir), to: Watcher
  defdelegate missing_files_for_client(client_state, replica_dir \\ nil), to: Watcher

  @doc "Returns the configured Litestream replica directory."
  @spec replica_dir() :: String.t()
  def replica_dir do
    Application.get_env(:deal_scout, :litestream_replica_dir, "/data/litestream")
  end

  @doc """
  Inspects the Litestream replica directory and summarizes active generations.
  """
  @spec inspect_replica_dir(String.t()) :: %{
          exists: boolean(),
          generations_count: non_neg_integer(),
          generations: [String.t()]
        }
  def inspect_replica_dir(dir \\ replica_dir()) do
    if File.dir?(dir) do
      generations_dir = Path.join(dir, "generations")

      if File.dir?(generations_dir) do
        case File.ls(generations_dir) do
          {:ok, gens} ->
            %{
              exists: true,
              generations_count: length(gens),
              generations: Enum.sort(gens)
            }

          _ ->
            %{exists: true, generations_count: 0, generations: []}
        end
      else
        %{exists: true, generations_count: 0, generations: []}
      end
    else
      %{exists: false, generations_count: 0, generations: []}
    end
  end

  @doc """
  Computes the SHA-256 hex digest of a binary or a file on disk.
  """
  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  @spec file_sha256(Path.t()) :: String.t() | nil
  def file_sha256(path) do
    case File.read(path) do
      {:ok, data} -> sha256_hex(data)
      _ -> nil
    end
  end

  @doc """
  Reads a requested relative file from the Litestream replica directory after
  enforcing strict path-traversal validation, computes its SHA-256 digest, and
  records the transfer in `DealScout.Backup.Status`.
  """
  @spec read_replica_file(term(), keyword()) ::
          {:ok,
           %{
             path: String.t(),
             size: non_neg_integer(),
             sha256: String.t(),
             binary: binary(),
             data: String.t()
           }}
          | {:error, String.t()}
  def read_replica_file(requested_path, opts \\ []) do
    dir = Keyword.get(opts, :replica_dir, replica_dir())
    record_transfer? = Keyword.get(opts, :record_transfer, true)

    with :ok <- validate_relative_path(requested_path),
         expanded_root = Path.expand(dir),
         full_path = Path.expand(Path.join(dir, requested_path)),
         true <-
           full_path == expanded_root or String.starts_with?(full_path, expanded_root <> "/"),
         {:ok, binary} <- File.read(full_path) do
      sha256 = sha256_hex(binary)
      size = byte_size(binary)

      if record_transfer? do
        Status.record_file_sent(requested_path, size)
      end

      {:ok,
       %{
         path: requested_path,
         size: size,
         sha256: sha256,
         binary: binary,
         data: Base.encode64(binary)
       }}
    else
      false ->
        {:error, "Path traversal forbidden"}

      {:error, :enoent} ->
        {:error, "File not found"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Creates an atomic SQLite snapshot in the temporary directory using `VACUUM INTO`
  (falling back to file copy when running inside a test sandbox transaction).

  Returns `{:ok, %{path: backup_path, filename: download_filename}}` or `{:error, reason}`.
  """
  @spec create_sqlite_snapshot(keyword()) ::
          {:ok, %{path: Path.t(), filename: String.t()}} | {:error, term()}
  def create_sqlite_snapshot(opts \\ []) do
    temp_dir = Keyword.get(opts, :temp_dir, System.tmp_dir!())
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    backup_path = Path.join(temp_dir, "deal_scout_backup_#{timestamp}.db")
    filename = "deal_scout_#{timestamp}.db"

    File.rm(backup_path)

    res =
      case Ecto.Adapters.SQL.query(Repo, "VACUUM INTO ?", [backup_path]) do
        {:ok, _} ->
          {:ok, %{path: backup_path, filename: filename}}

        {:error, %Exqlite.Error{message: "cannot VACUUM from within a transaction"}} ->
          db_file = Application.get_env(:deal_scout, Repo)[:database]

          case File.copy(db_file, backup_path) do
            {:ok, _} -> {:ok, %{path: backup_path, filename: filename}}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    case res do
      {:ok, info} ->
        Logger.info("[DealScout.Backup] Successfully created atomic backup at #{backup_path}")
        {:ok, info}

      {:error, reason} = err ->
        File.rm(backup_path)
        Logger.error("[DealScout.Backup] SQLite backup failed: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Verifies a candidate bearer token against the configured `:backup` or `:metrics` token
  in constant time (`Plug.Crypto.secure_compare/2`).
  """
  @spec valid_token?(term(), :backup | :metrics) :: boolean()
  def valid_token?(candidate_token, scope \\ :backup)

  def valid_token?(candidate_token, scope) when is_binary(candidate_token) do
    provided = String.trim(candidate_token)
    configured = configured_token(scope)

    if provided != "" and is_binary(configured) do
      Plug.Crypto.secure_compare(provided, configured)
    else
      false
    end
  end

  def valid_token?(_candidate_token, _scope), do: false

  @doc """
  Extracts a Bearer token from a list of `{header_name, header_value}` tuples.
  """
  @spec extract_bearer_token([{String.t(), String.t()}] | term()) :: String.t() | nil
  def extract_bearer_token(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, "Bearer " <> token} when is_binary(key) ->
        if String.downcase(key) == "authorization" do
          trimmed = String.trim(token)
          if trimmed != "", do: trimmed, else: nil
        end

      _ ->
        nil
    end)
  end

  def extract_bearer_token(_), do: nil

  defp configured_token(:metrics) do
    raw =
      Application.get_env(:deal_scout, :metrics_token) ||
        Application.get_env(:deal_scout, :backup_token, System.get_env("ADMIN_BACKUP_TOKEN"))

    normalize_token(raw)
  end

  defp configured_token(:backup) do
    raw = Application.get_env(:deal_scout, :backup_token, System.get_env("ADMIN_BACKUP_TOKEN"))
    normalize_token(raw)
  end

  defp normalize_token(token) when is_binary(token) do
    trimmed = String.trim(token)
    if trimmed != "", do: trimmed, else: nil
  end

  defp normalize_token(_), do: nil

  defp validate_relative_path(path) do
    cond do
      not is_binary(path) ->
        {:error, "Invalid path type"}

      String.starts_with?(path, "/") or String.starts_with?(path, "\\") ->
        {:error, "Absolute paths not allowed"}

      String.contains?(path, "..") ->
        {:error, "Path traversal with '..' not allowed"}

      String.contains?(path, <<0>>) ->
        {:error, "Null bytes not allowed"}

      true ->
        :ok
    end
  end
end
