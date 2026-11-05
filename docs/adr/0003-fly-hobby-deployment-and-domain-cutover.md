# 0003: Fly.io Sub-$5 Free Tier Architecture & Weekend Launch Strategy

We host DealScout in production on Fly.io's Frankfurt region (`fra`) using a single persistent 3 GB NVMe volume, invite-code gated registration, and default-muted audio alerts, while keeping transactional email (Resend) deferred until public scaling.

### Context & Trade-offs

1. **Volume & Compute Economics:**
   Fly.io waives invoices totaling under $5.00/month. By sizing our single shared-CPU VM (512 MB RAM) with a 3 GB persistent SQLite volume, total infrastructure cost remains $0.00/month while providing 3x the storage headroom for scraped deals and WAL journals.

2. **Invite-Gated Closed Alpha:**
   Rather than open public registration, account creation requires an `INVITE_CODE`. This protects the small 512 MB BEAM VM from unexpected traffic spikes, allows safe friends-and-family testing, and permits using a lightweight non-commercial beta disclaimer for German § 5 TMG compliance during the alpha phase.

3. **Muted-by-Default Audio Chimes:**
   Browser autoplay policies (Chrome, Safari, Firefox) block Web Audio API execution without prior user interaction. Defaulting to muted audio prevents unhandled browser audio exceptions on first load and avoids intrusive surprise alerts, while giving users a clear one-click toggle to test and enable chimes.

4. **Deferred Outbound Email:**
   Because registration immediately logs users into an active session upon submitting a valid invite code, email verification is non-blocking. Deferring Resend DNS setup allows rapid domain cutover for the weekend alpha without blocking on third-party mail provider approval.
