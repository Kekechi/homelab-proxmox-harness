# Cold-Start Resume — Session Brief

Status: planning complete, ready for execution
Objective: Fix cloud-init first-boot apt contention, add controlled apt upgrade,
and achieve a green full cold rebuild with idempotency + gate negative test.

Work plan for an autonomous agent, not a design record.
Prior session journal: `.claude/session/next-autorun-journal.md`

---

## 1. Operating model

Continuation of the cold-start verification session (2026-06-19). That session
found and fixed three cold-start bugs (flock detector, teardown purge-race,
readiness probe) but halted at the deploy/PKI phase — root-ca VM first-boot apt
contention from cloud-init `package_upgrade: true` baked into the VM template.

This session: apply the decided fix (`cloud-init status --wait` + Ansible-managed
`apt upgrade`), then drive through the remaining verification criteria the prior
session couldn't reach (green rebuild, idempotency, gate negative test).

The code change is small (2 Ansible tasks). The session's value is in the cold
rebuild verification, not the code.

---

## 2. Autonomy contract

### Authorization manifest

| # | Action class | Decision | Scope |
|---|---|---|---|
| 1 | Full sandbox teardown `--include-vms` | **Authorized** | sandbox pool only |
| 2 | Recreate LXC/VM via PVE API + cloud-init | **Authorized** | sandbox pool, existing vmids |
| 3 | `terraform apply` with plan file | **Authorized** | sandbox only, plan-file required |
| 4 | Ansible playbooks against sandbox hosts | **Authorized** | sandbox inventory only |
| 5 | Edit `ansible/roles/common/tasks/main.yml` | **Authorized** | 2 tasks: cloud-init wait + apt upgrade |
| 6 | `git commit` (local only) | **Authorized** | no secrets, no topology, intent-level |
| 7 | Regenerate offline root CA (`.pki/`) | **Authorized** | cold rebuild regenerates trust chain |
| 8 | Write scoped MinIO key to `.envrc` | **Authorized** | gitignored, bootstrap-minio.sh output |
| 9 | Deliberate fault injection for gate test | **Authorized** | WS4 only, sandbox, reversed after test |
| 10 | `git push` | **Forbidden** | |
| 11 | Modify `.devcontainer/` | **Forbidden** | |
| 12 | `terraform state rm/mv/import`, force-unlock | **Forbidden** | |
| 13 | Create PVE users/roles/tokens, move pools | **Forbidden** | |
| 14 | Any production apply | **Forbidden** | |

Enforcement tiers:
- **Environment-enforced** (free safety): #10 (settings.json deny), #13/#14
  (token lacks privileges, production token absent).
- **Discipline-required**: #11, #12 (policy only — structural deny rules exist
  in settings.json for push; `.devcontainer/` protected by CLAUDE.md + hook).

### Stop conditions

1. Same step fails twice with the same root cause.
2. Second workaround at the same layer for the same problem — wrong-layer signal.
3. A verification criterion fails with no root-cause hypothesis.
4. An action not on the Authorized manifest.
5. New work that shifts the objective beyond "green cold rebuild + idempotency +
   gate test."
6. **Rebuild budget: 3 full `--include-vms` rebuilds.** If all 3 fail, halt with
   evidence. Budget-free `--from` resumes are unlimited (they don't burn a full
   rebuild) but a resume that hits a RESUME-ARTIFACT (not a real bug) twice →
   abandon resumes, spend a full rebuild.

### Journal protocol

Journal file: `.claude/session/cold-start-resume-journal.md`
Contains: objective line, decisions + rationale, open-decisions ledger, step
ledger (`step → outcome → artifact link`). Updated after every phase completion
or failure.

---

## 3. Prerequisites (operator, before the session)

None. All prerequisites are in-repo or handled by the loop.

The stale-IP reuse delay (~19 min per MinIO recreate) is a known cost — the
probe handles it, the session just takes longer. Not a prerequisite; deferred to
a paired on-node diagnostic session with the operator.

---

## 4. Workstreams (dependency order)

### WS1 — Cloud-init wait + apt upgrade *(code change)*

**Approach:** Add two tasks to `ansible/roles/common/tasks/main.yml`:

1. **`cloud-init status --wait`** — immediately before the "Quiesce automatic
   apt" block (~line 189), NOT the absolute first task (CA trust + `/etc/hosts`
   lines 6-50 must stay first — they don't touch apt). Waits for cloud-init
   (including `package_upgrade`) to finish before any apt operations.
   Guard: `failed_when: false` (cloud-init absent on LXCs → command fails →
   Ansible continues, harmless no-op).

2. **`apt: upgrade: dist`** — after "Update apt cache", before "Install base
   packages". Runs a full dist-upgrade under Ansible's control. `lock_timeout:
   600` backstop (consistent with existing tasks). On first cold-start deploy
   this is a near-no-op (cloud-init already upgraded); on day-2 deploys it
   catches packages released since last run.

**Fix layer:** Ansible role (coordination, not workaround — `cloud-init status
--wait` is cloud-init's own synchronization primitive).

**Authorized actions:** ⊆ {5, 6}.

**Verification criterion:** green deploy/PKI phase on a full cold rebuild (WS2).
The cloud-init wait task runs; the apt upgrade task runs; the "Install base
packages" task succeeds without lock contention.

**Expansion-prone?** No. Two tasks, well-understood.

---

### WS2 — Full cold rebuild *(verification)*

**Approach:** `bash scripts/loop/run.sh sandbox --include-vms` — a true
from-nothing rebuild. Exercises all prior fixes end-to-end:
- teardown purge-wait (64744c1)
- flock apt-lock detector (164fe66)
- readiness probe (dfcb1a1)
- mask+kill auto-apt services (460c429, belt-and-suspenders)
- **NEW: cloud-init wait + apt upgrade (WS1)**

Budget: 3 full rebuilds. Budget-free `--from` resumes for diagnosed
resume-artifacts (stale known_hosts, etc.).

**Authorized actions:** ⊆ {1, 2, 3, 4, 7, 8}.

**Verification criterion:** `run.sh` exits 0, gate phase (`make verify-all`)
passes. All phases secrets→teardown→minio→configure→init→plan→apply→deploy→gate→verify
complete without error.

**Expansion-prone?** Yes — cold rebuilds surface new bugs. The prior session
found 3 (flock, teardown-race, apt-contention). Stop conditions bound this:
same-step-twice or budget-exhausted → halt.

---

### WS3 — Idempotency re-run *(verification)*

**Approach:** After a green WS2, re-run the deploy phase via
`bash scripts/loop/run.sh sandbox --from deploy --to deploy`. This re-runs all
Ansible playbooks (PKI→Nexus→DNS→log_server) against the already-deployed
system. The root-ca VM start API call is idempotent (already running).

**Authorized actions:** ⊆ {4}.

**Verification criterion:** `changed=0` across all Ansible plays. The apt
upgrade task reports `changed=false` (packages already current from the WS2 run
minutes ago). The cloud-init wait is a no-op (cloud-init finished long ago).
Exception: if `apt upgrade` alone shows `changed>0` due to a newly-published
package between WS2 and WS3 (unlikely, minutes apart), that is NOT an
idempotency bug — verify by inspecting the task output for the specific package.
Any other `changed>0` is a real idempotency bug to diagnose.

**Expansion-prone?** Low. Idempotency failures are usually quick to diagnose
(a task missing `changed_when` or a non-idempotent command).

---

### WS4 — Gate negative test *(verification)*

**Approach:** With a green system from WS2, inject a concrete fault: stop the
DNSdist service (`ansible -i inventory/ -m service -a 'name=dnsdist state=stopped'
--limit dns_dist`). Confirm `make verify-all` exits non-zero (the dns-dist
verify target should catch the stopped service). Then reverse the fault (restart
the service) and confirm the gate passes again.

**Authorized actions:** ⊆ {4, 9}.

**Verification criterion:** `make verify-all` exits non-zero with the fault
injected; exits 0 after reversal. The gate is not a rubber stamp.

**Expansion-prone?** No. One inject, one check, one reversal.

---

## 5. Sequencing rationale

WS1 → WS2 → WS3 → WS4 is a hard chain:
- WS1 (code) must be committed before WS2 (rebuild) exercises it.
- WS2 (green rebuild) is the prerequisite for WS3 (idempotency) and WS4 (gate test).
- WS3 and WS4 are independent of each other but both need a green system —
  run WS3 first (lower risk of disturbing the system), then WS4.

No independent doc workstreams this time — the prior session completed those.

Expected wall-clock: ~45-60 min for WS2 (dominated by the ~19 min stale-IP
MinIO wait + deploy phases), ~15 min for WS3, ~5 min for WS4. Total ~1-1.5 hr
if WS2 passes on rebuild #1.

---

## 6. Open items (deferred, with destination)

- **Stale-IP reuse MinIO delay** — paired on-node diagnostic session with
  operator (ip neigh, bridge fdb, conntrack on pve3). PVE 9.1.1 `lxc/exec`
  returns 501. Probe handles it; session is slow, not broken.
- **D1 — `minio.tls:true` cold-start (CA bootstrap paradox)** → `/design`
- **D2 — PKI provisioner naming + over-broad JWK scope** → `/design`
- **D3 — config `hostname:` field redesign** → `/design`
- **Un-pushed commits (c4501c8..64744c1 + this session's commits)** — review +
  push in a separate operator-attended step.
- **`--include-vms` default flip** — operator-directed, not autonomous.
- **minio re-enroll (oneshot+timer)** — blocked on `minio.tls:true`.
- **D5 syslog port dedup** — low-priority, design-clear, no session needed.
- **Splunk deprecation / Wazuh eval** → `/design`, large.
- **Commit the prior brief** (`docs/design/cold-start-verification-doc-hygiene.md`)
  — operator will handle.
