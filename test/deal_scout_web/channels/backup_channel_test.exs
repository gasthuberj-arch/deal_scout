defmodule DealScoutWeb.BackupChannelTest do
  use DealScoutWeb.ChannelCase

  alias DealScoutWeb.{BackupSocket, BackupChannel}

  @test_token "channel-secret-token-12345"

  setup do
    prev_app_token = Application.get_env(:deal_scout, :backup_token)
    Application.put_env(:deal_scout, :backup_token, @test_token)

    tmp_dir =
      Path.join(System.tmp_dir!(), "dealscout_channel_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    prev_replica_dir = Application.get_env(:deal_scout, :litestream_replica_dir)
    Application.put_env(:deal_scout, :litestream_replica_dir, tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)

      if prev_app_token do
        Application.put_env(:deal_scout, :backup_token, prev_app_token)
      else
        Application.delete_env(:deal_scout, :backup_token)
      end

      if prev_replica_dir do
        Application.put_env(:deal_scout, :litestream_replica_dir, prev_replica_dir)
      else
        Application.delete_env(:deal_scout, :litestream_replica_dir)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "BackupSocket rejects connection without valid token" do
    assert :error = connect(BackupSocket, %{"token" => "invalid-token"})
    assert :error = connect(BackupSocket, %{})
  end

  test "BackupSocket accepts connection with valid token" do
    assert {:ok, socket} =
             connect(BackupSocket, %{"token" => @test_token, "client_id" => "nas-test-1"})

    assert socket.assigns.client_id == "nas-test-1"
  end

  test "client can join backup:sync and receive handshake", %{tmp_dir: tmp_dir} do
    # Populate a fake replica file
    gen_dir = Path.join(tmp_dir, "generations/gen1/wal")
    File.mkdir_p!(gen_dir)
    test_file = Path.join(gen_dir, "00000001.wal.lz4")
    File.write!(test_file, "wal-frame-content")

    {:ok, socket} =
      connect(BackupSocket, %{"token" => @test_token, "client_id" => "nas-client-2"})

    {:ok, reply, socket} = subscribe_and_join(socket, BackupChannel, "backup:sync")

    assert reply.status == "connected"

    # Handshake
    ref = push(socket, "handshake", %{"have_files" => []})
    assert_reply ref, :ok, %{missing_files: missing, missing_count: 1}
    assert [%{path: "generations/gen1/wal/00000001.wal.lz4"}] = missing
  end

  test "client can request and receive binary file with verified sha256", %{tmp_dir: tmp_dir} do
    gen_dir = Path.join(tmp_dir, "generations/gen2/snapshots")
    File.mkdir_p!(gen_dir)
    snapshot_path = Path.join(gen_dir, "00000000.snapshot.lz4")
    content = "snapshot-binary-lz4-payload"
    File.write!(snapshot_path, content)
    expected_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    {:ok, socket} = connect(BackupSocket, %{"token" => @test_token})
    {:ok, _reply, socket} = subscribe_and_join(socket, BackupChannel, "backup:sync")

    ref =
      push(socket, "request_file", %{"path" => "generations/gen2/snapshots/00000000.snapshot.lz4"})

    assert_reply ref, :ok, resp

    assert resp.path == "generations/gen2/snapshots/00000000.snapshot.lz4"
    assert resp.sha256 == expected_sha
    assert resp.size == byte_size(content)
    assert Base.decode64!(resp.data) == content
  end

  test "request_file prevents path traversal attacks", %{tmp_dir: _tmp_dir} do
    {:ok, socket} = connect(BackupSocket, %{"token" => @test_token})
    {:ok, _reply, socket} = subscribe_and_join(socket, BackupChannel, "backup:sync")

    # Try relative traversal
    ref1 = push(socket, "request_file", %{"path" => "../../etc/passwd"})
    assert_reply ref1, :error, %{reason: reason1}
    assert reason1 =~ "traversal"

    # Try absolute path
    ref2 = push(socket, "request_file", %{"path" => "/etc/shadow"})
    assert_reply ref2, :error, %{reason: reason2}
    assert reason2 =~ "Absolute"
  end

  test "client receives live push notifications when a new frame is generated", %{
    tmp_dir: _tmp_dir
  } do
    {:ok, socket} = connect(BackupSocket, %{"token" => @test_token})
    {:ok, _reply, _socket} = subscribe_and_join(socket, BackupChannel, "backup:sync")

    # Broadcast a new frame over internal PubSub
    Phoenix.PubSub.broadcast(
      DealScout.PubSub,
      "backup:internal",
      {:new_backup_file, "generations/gen3/wal/00000010.wal.lz4", "/dummy", 512, "abc123sha"}
    )

    assert_push "new_file", %{
      path: "generations/gen3/wal/00000010.wal.lz4",
      size: 512,
      sha256: "abc123sha"
    }
  end

  test "ping message replies with timestamp", %{tmp_dir: _tmp_dir} do
    {:ok, socket} = connect(BackupSocket, %{"token" => @test_token})
    {:ok, _reply, socket} = subscribe_and_join(socket, BackupChannel, "backup:sync")

    ref = push(socket, "ping", %{})
    assert_reply ref, :ok, %{pong: ts}
    assert is_integer(ts)
  end
end
