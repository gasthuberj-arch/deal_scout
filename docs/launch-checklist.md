# Weekend Launch Runbook & Checklist 🚀

Operational checklist to cut over DealScout to a custom domain for the friends alpha before Black Friday.

---

## 1. Domain Registration & DNS Setup (5 minutes)

1. Register your domain (e.g. on Porkbun, Spaceship, or Netcup).
2. Look up your Fly.io IP addresses:
   ```bash
   fly ips list
   ```
3. In your registrar DNS panel, add two apex records:
   * **A Record:** `@` -> `<Your Fly IPv4>`
   * **AAAA Record:** `@` -> `<Your Fly IPv6>`
   *(Optional)* Add a `CNAME` for `www` if desired.

---

## 2. Fly.io Volume Resize (1 minute)

Scale the existing live persistent volume to 3 GB:
```bash
# 1. List current volumes to find the ID
fly volumes list

# 2. Extend the existing volume to 3GB (free tier covers up to 3GB)
fly volumes extend <VOLUME_ID> -s 3
```

---

## 3. Fly.io Secrets & TLS Certificate (2 minutes)

1. Provision Let's Encrypt TLS on Fly:
   ```bash
   fly certs add <your-domain.de>
   ```
2. Set production runtime environment variables:
   ```bash
   fly secrets set \
     PHX_HOST="<your-domain.de>" \
     INVITE_CODE="<your-secret-code>" \
     LEGAL_OPERATOR_NAME="DealScout Testbetrieb" \
     LEGAL_OPERATOR_EMAIL="your-email@example.com"
   ```

---

## 4. Deploy Application (2 minutes)

Deploy the updated muted-by-default audio code and 3 GB volume configuration:
```bash
fly deploy
```

Check the health status and logs:
```bash
fly status
fly logs
```

---

## 5. Friends Alpha Verification (5 minutes)

1. Open `https://<your-domain.de>/users/register`.
2. Verify registration with your invite code works and logs you in immediately.
3. Test creating a keyword alert rule (e.g., `RTX 4070` or `Lego`).
4. Click the **"Muted"** button on `/matches` to confirm audio toggle works.
5. Send the domain link and invite code to friends!
