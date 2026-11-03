# 0002: Litestream WAL Streaming over Outbound WebSockets for Homelabs

We replicate SQLite WAL frames to private homelab NAS nodes by streaming Litestream LTX/WAL frames over a secure Phoenix WebSocket channel (`/socket/backup`), accompanied by periodic HTTP `VACUUM INTO` snapshots.

### Context & Trade-off
Private homelabs and NAS devices typically sit behind CGNAT, firewalls, and Tailscale with zero inbound open ports and dynamic IPs, making push replication impossible without exposing public ports. Storing backups in public S3 buckets incurs recurring storage and egress costs.

By running a lightweight client (`dealscout_backup_client.py`) on the NAS that dials outbound to DealScout via WebSocket, the NAS pulls real-time transaction frames securely with zero port forwarding.
