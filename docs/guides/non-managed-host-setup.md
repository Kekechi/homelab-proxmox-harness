# Non-Managed Host Setup

Steps for onboarding an infrastructure host that is not managed by Ansible — for example,
a hypervisor node, a network appliance, or any host that needs to participate in the
internal network but is not in `config/<env>.yml`.

Three steps, in order:

1. **DNS entry** — required for name resolution and ACME HTTP-01 challenge
2. **CA certificate trust** — required to trust internal TLS endpoints
3. **ACME enrollment** — only if the host itself serves TLS

---

## Step 1 — Add a DNS record

For hosts in `config/<env>.yml` (IaC-managed services), records are populated automatically
by `make ansible-dns-records`. Skip this step for those hosts.

For hosts not in config, add the record manually via the PowerDNS Auth API. The API is
bound to loopback on the dns-auth LXC, so the call must be made from that host:

```bash
ssh root@<dns-auth-host> "curl -s -X PATCH \
  http://127.0.0.1:8081/api/v1/servers/localhost/zones/<your-domain>. \
  -H 'X-API-Key: <your-pdns-auth-api-key>' \
  -H 'Content-Type: application/json' \
  -d '{
    \"rrsets\": [{
      \"name\": \"<hostname>.<your-domain>.\",
      \"type\": \"A\",
      \"ttl\": 3600,
      \"changetype\": \"REPLACE\",
      \"records\": [{\"content\": \"<host-ip>\", \"disabled\": false}]
    }]
  }'"
```

The `PDNS_AUTH_API_KEY` is in `.envrc`. A 204 response indicates success.

> **Note:** Records added this way are not tracked in `config/<env>.yml`. The
> `dns-records.yml` playbook will report them as stale but will not delete them.

Verify resolution before proceeding:

```bash
dig +short <hostname>.<your-domain> @<dns-dist-ip>
```

---

## Step 2 — Trust the internal root CA

The host must trust the internal root CA before it can verify any internal TLS endpoint,
including the issuing CA during ACME enrollment in Step 3.

**Download the root CA certificate:**

```bash
# Accept the TLS warning on first contact — this is expected
curl -k https://ca.<your-domain>/roots.pem -o root_ca.crt
```

Or copy it from the controller:

```bash
scp /workspace/.pki/root_ca.crt <host>:/tmp/root_ca.crt
```

**Install on Debian/Ubuntu-based hosts:**

```bash
cp root_ca.crt /usr/local/share/ca-certificates/internal-root-ca.crt
update-ca-certificates
```

**For appliances with a trust store UI**, import `root_ca.crt` via the appliance's
certificate management interface. The exact path varies by platform — look for
"CA certificates", "trusted authorities", or "certificate store" in the settings.

---

## Step 3 — ACME enrollment (if the host serves TLS)

Skip this step if the host does not need its own TLS certificate.

The hostname in the certificate request must match `*.<domain_name>` — the CA's authority
policy rejects requests outside this domain. Confirm the hostname set in Step 1 matches.

### Finding your ACME config values

| Value | Where it comes from |
|---|---|
| ACME directory URL | `https://ca.<domain_name>/acme/<acme-provisioner-name>/directory` |
| CA base URL | `https://ca.<domain_name>` |

To find the ACME-type provisioner name:

```bash
step ca provisioner list \
  --ca-url https://ca.<your-domain> \
  --root /etc/ssl/certs/internal-root-ca.pem
```

Look for the entry with `"type": "ACME"`. In this deployment the provisioner is named
`acme-1` — the directory URL is `https://ca.<your-domain>/acme/acme-1/directory`.

### Appliances with a built-in ACME client — Proxmox example

Proxmox VE has a built-in ACME client but the GUI only supports Let's Encrypt. Custom ACME
directories require the CLI. Account registration is cluster-wide (once); certificate
issuance must be run per node.

**Restart pveproxy** first so Proxmox picks up the root CA installed in Step 2:

```bash
systemctl restart pveproxy
```

**Register the ACME account (once per cluster)** — run on any one node:

```bash
pvenode acme account register internal admin@<your-domain> \
  --directory https://ca.<your-domain>/acme/acme-1/directory
```

The email is required by Proxmox syntactically but step-ca only stores it as metadata —
nothing is ever sent to it. A placeholder under your internal domain is fine.

Verify: `pvenode acme account info internal`

**Configure and order a certificate (per node)** — run on each node:

```bash
pvenode config set --acme account=internal,domains=<node-hostname>.<your-domain>
pvenode acme cert order
```

Renewal is handled automatically by `pveproxy` — no cron needed.

> **HTTP-01 requirement:** The issuing CA must be able to reach port 80 on the requesting
> host at `http://<hostname>/.well-known/acme-challenge/`. Verify this path is reachable
> from the issuing CA's network segment.

### Hosts without a built-in ACME client

Install [acme.sh](https://github.com/acmesh-official/acme.sh) per its official instructions,
then point it at the internal CA:

```bash
acme.sh --register-account \
  --server https://ca.<your-domain>/acme/acme-1/directory

acme.sh --issue \
  --server https://ca.<your-domain>/acme/acme-1/directory \
  -d <hostname>.<your-domain> \
  --webroot /path/to/webroot
```

For appliances that can import certs but lack a shell ACME client, issue the certificate
from another host on the same network segment, then import the cert and key via the
appliance's UI.

### JWK issuance (fallback)

If ACME is not an option — for example, the host cannot expose an HTTP challenge endpoint —
the issuing CA also has a JWK provisioner. This requires the `step` CLI and the
`STEP_CA_PROVISIONER_PASSWORD` from `.envrc`. Renewal is manual.

See `ansible/roles/minio/tasks/tls.yml` for a reference implementation.
