defmodule DealScout.Backup.StatusTest do
  use ExUnit.Case, async: false

  alias DealScout.Backup

  setup do
    Backup.reset_status()
    :ok
  end

  test "returns initial status with no connected clients and lag_seconds -1" do
    status = Backup.get_status()

    assert status.client_connected == false
    assert status.connected_client == nil
    assert status.lag_seconds == -1
    assert status.files_synced_count == 0
    assert status.bytes_synced_count == 0
    assert is_integer(status.uptime_seconds)
  end

  test "tracks client connection and disconnection" do
    Backup.client_connected("nas-box-1", %{remote_ip: "192.168.1.100", hostname: "homelab"})

    status = Backup.get_status()
    assert status.client_connected == true
    assert status.connected_client.client_id == "nas-box-1"
    assert status.connected_client.remote_ip == "192.168.1.100"
    assert status.connected_client.hostname == "homelab"
    assert %DateTime{} = status.connected_client.connected_at

    Backup.client_disconnected("nas-box-1")

    status_after = Backup.get_status()
    assert status_after.client_connected == false
    assert status_after.connected_client == nil
  end

  test "tracks file transfer statistics, lag_seconds, and ping timestamps" do
    Backup.client_connected("nas-box-2", %{})
    Backup.record_file_sent("generations/gen1/wal/00000001.wal.lz4", 1024)
    Backup.record_file_sent("generations/gen1/wal/00000002.wal.lz4", 2048)

    status = Backup.get_status()
    assert status.files_synced_count == 2
    assert status.bytes_synced_count == 3072
    assert status.last_file_sent == "generations/gen1/wal/00000002.wal.lz4"
    assert %DateTime{} = status.last_sync_at
    assert status.lag_seconds >= 0

    Backup.record_ping("nas-box-2")
    status_ping = Backup.get_status()
    assert %DateTime{} = status_ping.last_ping_at
  end

  test "read_replica_file validates path traversal, computes sha256, and records transfer" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "deal_scout_backup_read_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    wal_dir = Path.join(tmp_dir, "generations/gen1/wal")
    File.mkdir_p!(wal_dir)
    rel_path = "generations/gen1/wal/00000001.wal.lz4"
    payload = "wal-frame-bytes"
    File.write!(Path.join(tmp_dir, rel_path), payload)

    assert {:ok, file} = Backup.read_replica_file(rel_path, replica_dir: tmp_dir)
    assert file.path == rel_path
    assert file.size == byte_size(payload)
    assert file.sha256 == Backup.sha256_hex(payload)
    assert Base.decode64!(file.data) == payload

    assert {:error, msg1} = Backup.read_replica_file("../../etc/passwd", replica_dir: tmp_dir)
    assert msg1 =~ "traversal"

    assert {:error, msg2} = Backup.read_replica_file("/etc/shadow", replica_dir: tmp_dir)
    assert msg2 =~ "Absolute"
  end
end
