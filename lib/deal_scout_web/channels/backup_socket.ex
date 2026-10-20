defmodule DealScoutWeb.BackupSocket do
  use Phoenix.Socket
  require Logger

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
    configured = configured_token()

    cond do
      is_nil(configured) or configured == "" ->
        false

      token = extract_token(params, connect_info) ->
        Plug.Crypto.secure_compare(token, configured)

      true ->
        false
    end
  end

  defp extract_token(params, connect_info) do
    cond do
      is_binary(params["token"]) and String.trim(params["token"]) != "" ->
        String.trim(params["token"])

      # Header authorization if present in connect_info
      headers = connect_info[:x_headers] ->
        find_bearer_token(headers)

      true ->
        nil
    end
  end

  defp find_bearer_token(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, "Bearer " <> token} ->
        if String.downcase(key) == "authorization", do: String.trim(token)

      _ ->
        nil
    end)
  end

  defp find_bearer_token(_), do: nil

  defp configured_token do
    case Application.get_env(:deal_scout, :backup_token, System.get_env("ADMIN_BACKUP_TOKEN")) do
      token when is_binary(token) ->
        trimmed = String.trim(token)
        if trimmed != "", do: trimmed, else: nil

      _ ->
        nil
    end
  end

  defp format_remote_ip(%{address: address}) when is_tuple(address) do
    address |> :inet.ntoa() |> to_string()
  end

  defp format_remote_ip(_), do: "unknown"
end
