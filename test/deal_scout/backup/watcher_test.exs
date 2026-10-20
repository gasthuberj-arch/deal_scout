defmodule DealScout.Backup.WatcherTest do
  use ExUnit.Case, async: false

  alias DealScout.Backup.Watcher, as: BackupWatcher

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "deal_scout_watcher_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "scan_replica returns empty list for empty directory", %{tmp_dir: tmp_dir} do
    assert BackupWatcher.scan_replica(tmp_dir) == []
  end

  test "scan_replica discovers and calculates sha256 for files in directory tree", %{
    tmp_dir: tmp_dir
  } do
    gen_dir = Path.join(tmp_dir, "generations/gen_abc/wal")
    File.mkdir_p!(gen_dir)
    wal_file = Path.join(gen_dir, "00000001.wal.lz4")
    content = "binary-wal-data-chunk-test"
    File.write!(wal_file, content)

    expected_sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    files = BackupWatcher.scan_replica(tmp_dir)
    assert length(files) == 1
    [file] = files

    assert file.path == "generations/gen_abc/wal/00000001.wal.lz4"
    assert file.size == byte_size(content)
    assert file.sha256 == expected_sha
  end

  test "missing_files_for_client correctly filters files client already has", %{tmp_dir: tmp_dir} do
    wal_dir = Path.join(tmp_dir, "generations/gen1/wal")
    File.mkdir_p!(wal_dir)

    File.write!(Path.join(wal_dir, "00000001.wal.lz4"), "frame-1")
    File.write!(Path.join(wal_dir, "00000002.wal.lz4"), "frame-2")
    File.write!(Path.join(wal_dir, "00000003.wal.lz4"), "frame-3")

    # Client has frame 1
    client_state = %{"have_files" => ["generations/gen1/wal/00000001.wal.lz4"]}
    missing = BackupWatcher.missing_files_for_client(client_state, tmp_dir)

    missing_paths = Enum.map(missing, & &1.path)

    assert missing_paths == [
             "generations/gen1/wal/00000002.wal.lz4",
             "generations/gen1/wal/00000003.wal.lz4"
           ]
  end

  test "watcher broadcasts new files to PubSub topic", %{tmp_dir: tmp_dir} do
    # Subscribe to internal backup pubsub
    Phoenix.PubSub.subscribe(DealScout.PubSub, "backup:internal")

    # Start supervised watcher pointing to this tmp_dir with 50ms poll
    watcher =
      start_supervised!(
        {BackupWatcher, [replica_dir: tmp_dir, poll_interval_ms: 50, name: :test_watcher]}
      )

    # Now create a new file
    wal_dir = Path.join(tmp_dir, "generations/gen_pubsub/wal")
    File.mkdir_p!(wal_dir)
    file_path = Path.join(wal_dir, "00000009.wal.lz4")
    content = "new-wal-streamed-content"
    File.write!(file_path, content)

    # Force check
    BackupWatcher.check_now(watcher)

    assert_receive {:new_backup_file, "generations/gen_pubsub/wal/00000009.wal.lz4", _full, size,
                    sha256},
                   2_000

    assert size == byte_size(content)
    assert is_binary(sha256)
  end
end
