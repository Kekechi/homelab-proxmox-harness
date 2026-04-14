# Trusting the Internal Root CA

## Server trust (automatic)

All Ansible-managed hosts trust the internal root CA automatically via the `common`
role. Running `ansible-playbook playbooks/site.yml` is sufficient — no separate step needed.

If the root CA cert is not yet on the controller (`/workspace/.pki/root_ca.crt`),
the role skips trust setup with a warning. Run `pki-setup.yml` first.

---

## User device trust (manual one-time setup)

Download the root CA certificate from the issuing CA:

```
https://ca.<your-sandbox-domain>/roots.pem
```

Accept the one-time browser TLS warning — this is expected. You are downloading
the cert that will remove this warning permanently once installed.

> **Production:** Uses a separate issuing CA at `ca.<your-prod-domain>`.

---

### Windows

Open PowerShell as Administrator:

```powershell
certutil -addstore Root roots.pem
```

Or manually: **Start → Manage computer certificates → Trusted Root Certification
Authorities → Certificates → right-click → All Tasks → Import** → select `roots.pem`.

---

### macOS

Double-click the downloaded `roots.pem` file. Keychain Access opens.

1. Find **Homelab Root CA** in the login keychain
2. Double-click it → expand **Trust**
3. Set **When using this certificate** to **Always Trust**
4. Close and authenticate with your password

---

### iOS

1. Open Safari and navigate to `https://ca.<your-sandbox-domain>/roots.pem`
2. Accept the TLS warning
3. Tap **Allow** when prompted to download a configuration profile
4. Open **Settings** — a banner at the top shows **Profile Downloaded**. Tap it and install.
5. Go to **Settings → General → About → Certificate Trust Settings**
6. Enable the toggle for **Homelab Root CA**

---

### Linux desktop

```bash
sudo cp roots.pem /usr/local/share/ca-certificates/internal-root-ca.crt
sudo update-ca-certificates
```

---

### Proxmox host

Same as Linux desktop — the Proxmox host runs Debian.

---

### Android

Deferred. Full instructions when needed.

General path: **Settings → Security → Install certificate → CA certificate** → select `roots.pem`.
