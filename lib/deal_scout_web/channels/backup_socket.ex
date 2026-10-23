defmodule DealScoutWeb.BackupSocket do
  use Phoenix.Socket
  require Logger

  alias DealScout.Backup

  channel "backup:sync", DealScoutWeb.BackupChannel

  @impl true
  def connect(params, socket, connect_info) do
    if authorized?(params, connect_info) do
      client_id = Map.get(params, "client_id", "nas-backup-client")
      remote_ip = format_remote_ip(connect_info[:peer_data])

      socket =
        socket
        |> assign(:client_id, client_id)
        |> assign(:remote_ip, remote_ip)

      {:ok, socket}
    else
      Logger.warning("[DealScout.BackupSocket] Unauthorized connection attempt rejected.")
      :error
    end
  end

  @impl true
  def id(socket), do: "backup_socket:#{socket.assigns.client_id}"

  defp authorized?(params, connect_info) do
    token =
      if is_binary(params["token"]) and String.trim(params["token"]) != "" do
        params["token"]
      else
        Backup.extract_bearer_token(connect_info[:x_headers])
      end

    Backup.valid_token?(token, :backup)
  end

  defp format_remote_ip(%{address: address}) when is_tuple(address) do
    address |> :inet.ntoa() |> to_string()
  end

  defp format_remote_ip(_), do: "unknown"
end
