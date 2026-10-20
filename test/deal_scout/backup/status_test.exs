defmodule DealScout.Backup.StatusTest do
  use ExUnit.Case, async: false

  alias DealScout.Backup.Status, as: BackupStatus

  setup do
    BackupStatus.reset()
    :ok
  end

  test "returns initial status with no connected clients" do
    status = BackupStatus.get_status()

    assert status.client_connected == false
    assert status.connected_client == nil
    assert status.files_synced_count == 0
    assert status.bytes_synced_count == 0
    assert is_integer(status.uptime_seconds)
  end

  test "tracks client connection and disconnection" do
    BackupStatus.client_connected("nas-box-1", %{remote_ip: "192.168.1.100", hostname: "homelab"})

    status = BackupStatus.get_status()
    assert status.client_connected == true
    assert status.connected_client.client_id == "nas-box-1"
    assert status.connected_client.remote_ip == "192.168.1.100"
    assert status.connected_client.hostname == "homelab"
    assert %DateTime{} = status.connected_client.connected_at

    BackupStatus.client_disconnected("nas-box-1")

    status_after = BackupStatus.get_status()
    assert status_after.client_connected == false
    assert status_after.connected_client == nil
  end

  test "tracks file transfer statistics and ping timestamps" do
    BackupStatus.client_connected("nas-box-2", %{})
    BackupStatus.record_file_sent("generations/gen1/wal/00000001.wal.lz4", 1024)
    BackupStatus.record_file_sent("generations/gen1/wal/00000002.wal.lz4", 2048)

    status = BackupStatus.get_status()
    assert status.files_synced_count == 2
    assert status.bytes_synced_count == 3072
    assert status.last_file_sent == "generations/gen1/wal/00000002.wal.lz4"
    assert %DateTime{} = status.last_sync_at

    BackupStatus.record_ping("nas-box-2")
    status_ping = BackupStatus.get_status()
    assert %DateTime{} = status_ping.last_ping_at
  end
end
