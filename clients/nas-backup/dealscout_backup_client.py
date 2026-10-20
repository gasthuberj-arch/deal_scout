#!/usr/bin/env python3
"""
DealScout NAS Backup Client
Runs on your NixOS server / NAS.
Connects outbound via WebSocket to DealScout server (zero inbound ports required).
Receives Litestream replica frames in real time and maintains an atomic, verified
local replica for instant point-in-time restores.
"""

import argparse
import asyncio
import base64
import hashlib
import json
import logging
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
    import websockets
except ImportError:
    websockets = None

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] [%(levelname)s] [DealScout.BackupClient] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("DealScoutBackupClient")


class DealScoutBackupClient:
    def __init__(
        self,
        server_url: str,
        token: str,
        backup_dir: Path,
        client_id: str = None,
        once: bool = False,
        verify_interval_hours: int = 24,
    ):
        self.server_url = self._normalize_ws_url(server_url)
        self.token = token
        self.backup_dir = Path(backup_dir).resolve()
        self.client_id = client_id or f"{socket.gethostname()}-nixos"
        self.once = once
        self.verify_interval_hours = verify_interval_hours
        self.last_verification_time = 0

        self.ref_counter = 0
        self.join_ref = "1"
        self.pending_requests = {}
        self.ws = None

        self.backup_dir.mkdir(parents=True, exist_ok=True)

    def _normalize_ws_url(self, url: str) -> str:
        url = url.rstrip("/")
        if url.startswith("https://"):
            url = "wss://" + url[8:]
        elif url.startswith("http://"):
            url = "ws://" + url[7:]
        elif not url.startswith("ws://") and not url.startswith("wss://"):
            url = "wss://" + url
        return url

    def next_ref(self) -> str:
        self.ref_counter += 1
        return str(self.ref_counter)

    def scan_local_files(self) -> list:
        """Scan locally saved replica files to resume sync without re-downloading."""
        local_files = []
        for p in self.backup_dir.rglob("*"):
            if p.is_file() and not p.name.endswith(".tmp"):
                rel = p.relative_to(self.backup_dir).as_posix()
                local_files.append(rel)
        return local_files

    async def connect_and_sync(self):
        ws_endpoint = f"{self.server_url}/socket/backup/websocket?token={self.token}&client_id={self.client_id}&vsn=2.0.0"
        logger.info(f"Connecting outbound to DealScout server: {self.server_url} (client_id: {self.client_id})")

        backoff = 3
        while True:
            try:
                async with websockets.connect(
                    ws_endpoint,
                    ping_interval=20,
                    ping_timeout=20,
                    max_size=50 * 1024 * 1024,  # Allow up to 50MB messages
                ) as ws:
                    self.ws = ws
                    logger.info("Connected successfully to DealScout backup socket!")
                    backoff = 3  # reset backoff on success

                    # Join channel
                    self.join_ref = self.next_ref()
                    msg_ref = self.next_ref()
                    join_payload = [
                        self.join_ref,
                        msg_ref,
                        "backup:sync",
                        "phx_join",
                        {"version": "1.0", "hostname": socket.gethostname()},
                    ]
                    await ws.send(json.dumps(join_payload))

                    # Start reader and heartbeat tasks
                    reader_task = asyncio.create_task(self._socket_reader(ws, self.join_ref))
                    heartbeat_task = asyncio.create_task(self._heartbeat_loop(ws))

                    done, pending = await asyncio.wait(
                        [reader_task, heartbeat_task],
                        return_when=asyncio.FIRST_COMPLETED,
                    )

                    for task in pending:
                        task.cancel()

                    if self.once:
                        logger.info("One-shot sync mode finished. Exiting.")
                        return

            except Exception as e:
                logger.warning(f"Connection lost or failed: {e}. Reconnecting in {backoff}s...")
                if self.once:
                    sys.exit(1)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60)

    async def _heartbeat_loop(self, ws):
        """Send regular Phoenix channel heartbeats and trigger periodic verification."""
        while True:
            await asyncio.sleep(25)
            ref = self.next_ref()
            heartbeat = [None, ref, "phoenix", "heartbeat", {}]
            await ws.send(json.dumps(heartbeat))

            # Periodic verification
            now = time.time()
            if now - self.last_verification_time >= self.verify_interval_hours * 3600:
                self.verify_database_integrity()
                self.last_verification_time = now

    async def _socket_reader(self, ws, join_ref: str):
        """Read incoming frames from Phoenix Channel."""
        async for raw_message in ws:
            try:
                msg = json.loads(raw_message)
                if not isinstance(msg, list) or len(msg) < 5:
                    continue

                msg_join_ref, msg_ref, topic, event, payload = msg

                if topic == "backup:sync":
                    if event == "phx_reply":
                        ref_str = str(msg_ref)
                        if ref_str in self.pending_requests:
                            fut = self.pending_requests.pop(ref_str)
                            if not fut.done():
                                fut.set_result(payload)
                        else:
                            status = payload.get("status")
                            response = payload.get("response", {})
                            if status == "ok" and "message" in response and "DealScout Backup Sync Channel" in response.get("message", ""):
                                logger.info("Joined backup:sync topic! Spawning sync handshake task...")
                                asyncio.create_task(self._perform_handshake())

                    elif event == "new_file":
                        # Server pushed a live notification of a new WAL frame!
                        asyncio.create_task(self._handle_new_file_notification(payload))

            except Exception as e:
                logger.error(f"Error handling message: {e}", exc_info=True)

    async def _perform_handshake(self):
        """Send local files list and request all missing frames."""
        local_files = self.scan_local_files()
        logger.info(f"Local replica contains {len(local_files)} files. Requesting delta status...")

        ref = self.next_ref()
        fut = asyncio.get_event_loop().create_future()
        self.pending_requests[str(ref)] = fut

        handshake_msg = [
            self.join_ref,
            ref,
            "backup:sync",
            "handshake",
            {"have_files": local_files},
        ]
        await self.ws.send(json.dumps(handshake_msg))

        res = await fut
        missing_files = res.get("response", {}).get("missing_files", [])
        logger.info(f"Handshake complete: {len(missing_files)} missing frames to download.")

        for item in missing_files:
            rel_path = item.get("path")
            await self._download_file(rel_path)

        logger.info("Initial sync caught up! Ready for live WAL streaming.")
        self.verify_database_integrity()

        if self.once:
            await self.ws.close()

    async def _handle_new_file_notification(self, payload: dict):
        """Server notified us that Litestream produced a new WAL or snapshot frame."""
        rel_path = payload.get("path")
        size = payload.get("size")
        logger.info(f"Live delta notification: {rel_path} ({size} bytes). Downloading...")
        await self._download_file(rel_path)

    async def _download_file(self, rel_path: str):
        """Request and atomically write a file from the server."""
        ref = self.next_ref()
        fut = asyncio.get_event_loop().create_future()
        self.pending_requests[str(ref)] = fut

        req_msg = [
            self.join_ref,
            ref,
            "backup:sync",
            "request_file",
            {"path": rel_path},
        ]
        await self.ws.send(json.dumps(req_msg))

        res = await fut
        resp_data = res.get("response", {})

        if res.get("status") != "ok":
            logger.error(f"Failed to fetch {rel_path}: {resp_data.get('reason')}")
            return

        b64_data = resp_data.get("data")
        expected_sha = resp_data.get("sha256")
        expected_size = resp_data.get("size")

        binary_content = base64.b64decode(b64_data)

        # Integrity verify sha256
        actual_sha = hashlib.sha256(binary_content).hexdigest().lower()
        if expected_sha and actual_sha != expected_sha.lower():
            logger.error(f"Checksum mismatch for {rel_path}! Expected {expected_sha}, got {actual_sha}. Discarding.")
            return

        target_file = self.backup_dir / rel_path
        target_file.parent.mkdir(parents=True, exist_ok=True)

        # Atomic write via tempfile in the same directory
        tmp_file = target_file.with_suffix(target_file.suffix + ".tmp")
        with open(tmp_file, "wb") as f:
            f.write(binary_content)

        tmp_file.replace(target_file)
        logger.info(f"Saved: {rel_path} ({len(binary_content)} bytes, sha256: {actual_sha[:8]}...)")

    def verify_database_integrity(self):
        """Run litestream restore and sqlite3 PRAGMA integrity_check to verify backup."""
        litestream_bin = shutil.which("litestream")
        sqlite3_bin = shutil.which("sqlite3")

        if not litestream_bin or not sqlite3_bin:
            logger.debug("litestream or sqlite3 binary not found in PATH; skipping PRAGMA integrity_check.")
            return

        # Check if we have any replica generations
        gens_dir = self.backup_dir / "generations"
        if not gens_dir.exists() or not any(gens_dir.iterdir()):
            logger.debug("No generations in replica dir yet; skipping restore verification.")
            return

        with tempfile.TemporaryDirectory() as tmpdir:
            test_db = Path(tmpdir) / "verify.db"
            logger.info("Running automated backup integrity check...")

            # Litestream restore
            cmd_restore = [
                litestream_bin,
                "restore",
                "-if-replica-exists",
                "-o",
                str(test_db),
                f"file://{self.backup_dir}",
            ]

            proc = subprocess.run(cmd_restore, capture_output=True, text=True)
            if proc.returncode != 0:
                logger.error(f"litestream restore check failed: {proc.stderr}")
                return

            if not test_db.exists():
                logger.warning("litestream restore completed but verify.db was not produced.")
                return

            # SQLite integrity check
            cmd_check = [sqlite3_bin, str(test_db), "PRAGMA integrity_check;"]
            proc_check = subprocess.run(cmd_check, capture_output=True, text=True)

            output = proc_check.stdout.strip()
            if proc_check.returncode == 0 and output == "ok":
                db_size_mb = test_db.stat().st_size / (1024 * 1024)
                logger.info(f"[INTEGRITY OK] SQLite backup verified non-corrupted! ({db_size_mb:.2f} MB)")
            else:
                logger.error(f"[INTEGRITY ERROR] PRAGMA integrity_check returned: {output} / {proc_check.stderr}")


def load_token(args) -> str:
    if args.token:
        return args.token
    if args.token_file and os.path.isfile(args.token_file):
        with open(args.token_file, "r") as f:
            return f.read().strip()
    env_token = os.environ.get("ADMIN_BACKUP_TOKEN") or os.environ.get("DEALSCOUT_BACKUP_TOKEN")
    if env_token:
        return env_token.strip()
    return ""


def main():
    if websockets is None:
        logger.error("The 'websockets' Python package is required. On NixOS, include pkgs.python3Packages.websockets.")
        sys.exit(1)

    parser = argparse.ArgumentParser(description="DealScout Outbound NAS Backup Client")
    parser.add_argument(
        "--server-url",
        default=os.environ.get("DEALSCOUT_SERVER_URL", "http://localhost:4000"),
        help="DealScout server URL (e.g. wss://dealscout.fly.dev or http://localhost:4000)",
    )
    parser.add_argument("--token", help="Admin backup Bearer token")
    parser.add_argument(
        "--token-file",
        default=os.environ.get("DEALSCOUT_TOKEN_FILE"),
        help="Path to token file (useful for NixOS agenix/sops secrets)",
    )
    parser.add_argument(
        "--backup-dir",
        default=os.environ.get("DEALSCOUT_BACKUP_DIR", os.path.expanduser("~/backups/deal_scout")),
        help="Local directory to store Litestream replica files",
    )
    parser.add_argument("--client-id", default=os.environ.get("DEALSCOUT_CLIENT_ID"), help="Client ID for tracking")
    parser.add_argument("--once", action="store_true", help="Sync once and exit instead of continuous streaming")
    parser.add_argument(
        "--verify-interval-hours",
        type=int,
        default=24,
        help="Interval in hours for PRAGMA integrity_check (default: 24)",
    )

    args = parser.parse_args()
    token = load_token(args)

    if not token:
        logger.error("Authentication token is required via --token, --token-file, or ADMIN_BACKUP_TOKEN env var.")
        sys.exit(1)

    client = DealScoutBackupClient(
        server_url=args.server_url,
        token=token,
        backup_dir=Path(args.backup_dir),
        client_id=args.client_id,
        once=args.once,
        verify_interval_hours=args.verify_interval_hours,
    )

    try:
        asyncio.run(client.connect_and_sync())
    except KeyboardInterrupt:
        logger.info("Process interrupted by user. Exiting cleanly.")


if __name__ == "__main__":
    main()
