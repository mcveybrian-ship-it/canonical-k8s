# START HERE

The map. **One table, one screen.** Find your step, open its document, do the work there.
Nothing on this page is executed — the commands live in the step documents.

**Naming:** step number = document name = script name. Step 02 is `docs/02-host-install.md`
and `scripts/install/02-*`. No exceptions.

---

> **Some documents in this repo are local-only.** `HANDOFF.md`, `docs/open-questions.md`,
> `docs/runbook.md`, `artifact/` and `archive/` are client-private engagement material and are
> gitignored — they exist on the working machine but are never pushed. Links to them below will
> not resolve in a clone. Everything else here is reusable tooling.

## The build

| Step | Do this | Open this | Status |
|---|---|---|---|
| **00** | Download and verify the Ubuntu media | [`docs/00-downloads.md`](docs/00-downloads.md) | **DONE** 2026-08-27 — GPG signature check still outstanding, carries into step 01 |
| **01** | Pathfinder: validate FIPS/STIG, then test the autoinstall | [`docs/01-pathfinder.md`](docs/01-pathfinder.md) | Pass 1 **DONE** · Pass 2 **you are here** |
| **02** | Base OS install, **4** bare-metal hosts | [`docs/02-host-install.md`](docs/02-host-install.md) + [`airgap-media.md`](docs/airgap-media.md) | ✅ **ALL FOUR HOSTS BUILT.** `host-4` 2026-09-01 · **`host-1` `host-2` `host-3` 2026-09-17**, all three verified: `sda` → LUKS → `vg0` with the six STIG LVs, `nvme0n1p1` 500 GB encrypted for the pg guest with **the remainder left raw for Ceph**, `crypt-data` on a keyfile so only the OS volume prompts, no default route, `svm`+`kvm_amd` live, TPM 2.0. **`DATA_VG_SIZE` proven on three machines.** ⚠️ Secure Boot did NOT stay enabled — TPM unlock stays parked (§6.3i.1). ⚠️ Data disks differ per host (953.9 GB · 931.5 GB · 1.8 TB) so **OSDs must be evened at the smallest remainder** — runbook §9a.2. §4c's firmware checklist needs the review in §4c-REVIEW before it is reused |
| **03** | libvirt on host-4, compose `svc-mgmt-01` by hand | [`docs/03-host-services.md`](docs/03-host-services.md) | **DONE** 2026-09-03 — host-4 prepared and `svc-mgmt-01` composed and verified at `10.2.20.161`: cloud-init clean in 54s, 9/9 packages from the mirror, no default route. Six traps recorded in §5c, five of which failed silently |
| **04** | Enclave services — Pro contract server, Landscape mirror, Harbor, MAAS | [`docs/runbook.md`](docs/runbook.md) §4, §6.1 | **LARGELY DONE** — **Q9 CLOSED**, the air-gapped Pro procedure is public tooling and is executed in §6.1. Contract server, MAAS (+DHCP) and Harbor (+Trivy) all running in the gap. Landscape mirrored, not deployed. Enterprise Store **dropped** — snaps served as files, §4.6 |
| **05** | Harden hosts — Pro, FIPS, STIG | [`docs/runbook.md`](docs/runbook.md) **§6.0 is the ordered procedure**, **§10d is day-2 patching**; [`scripts/install/05-harden-host.sh`](scripts/install/05-harden-host.sh) drives it. **Unattended:** place the machine's credentials file first and delete it after ([`docs/airgap-media.md`](docs/airgap-media.md) §9; runbook §6.0 steps 11a / 16a) | **SEVEN OF EIGHT MACHINES HARDENED.** `host-1` `host-2` `host-3` **COMPLETE 2026-09-17 at `213 pass / 3 fail`** — the best in the enclave, and the only machines where all three findings are decisions rather than defects. `host-3` was driven entirely by `05-harden-host.sh` and hit 213/3 first time. The earlier five sit at six findings because **`ufw` and the GRUB password were never completed there** — completable engineering work, not accepted risk (`HANDOFF.md` §3). 🔴 **A patch cycle REVERTS hardening** — three packages, three controls, measured on two machines: §10d. ⬜ Owed on host-1/2/3: `collect`, `audit-volume.sh install`, the step-15 functional test, and a written deviation for `service_sssd_enabled` |
| 06 | Compose and harden the 10 cluster guests (3 PG, 3 K8S control plane, 4 workers) | [`docs/06-guest-vms.md`](docs/06-guest-vms.md) — **MECHANISM BUILT AND PROVEN 2026-09-27** (all four slices on throwaway pg-01) | After 05, on the host each guest is mapped to: `sudo ./03-compose-vm.sh <vm> --harden --cred-dir <stick>` — the guest hardens itself from first boot, nobody logs in (~16 min, watch `sudo sh -c 'cat $(ls -1r <pool>/console/<vm>-console.log*)' \| grep -a ENCLAVE-HARDEN`) — then after `DONE`, `sudo ./03-compose-vm.sh <vm> --finish`. ✅ **pg-01..03 BUILT this way 2026-09-27** (step 06a). ~~Owed first: 05's audit-offload step, 3.39~~ — the audit-offload step shipped 2026-09-27 (V-270817 closed) and 3.39's clock alerts are live. ✅ **The seven K8S guests BUILT this way 2026-10-14** (each 211/4, finished) — their ufw table (D4) written first, B-07 A3; they carry IPv6 too (`docs/07-kubernetes.md` §3.3) |
| 07 | Bootstrap Kubernetes | [`docs/07-kubernetes.md`](docs/07-kubernetes.md) — 🔄 **CLUSTER RUNNING 2026-10-14**: 7 nodes Ready, HA (3 etcd voters), every pod Running | `scripts/install/07-kubernetes.sh`: `images-export` / `images-load` / `images-check` (stage-01), then on the nodes `node-prep` (all) → `bootstrap` (cp-01) → `join-tokens` + `join` (tokens as files) → `k8s enable load-balancer` once the workers are in. FIPS base snaps pinned and verified (snapd 2.78+fips, core22 20260125+fips, k8s 1.36.4). After the build: `encrypt check`, then `encrypt retire` on each control plane (Secrets at rest, §3.12). ✅ Verified (`verify`) and the API VIP live, 2026-10-14; ssh stays on the workers (K-B reversed); survivability C1–C5 passed 2026-10-14/15; **Secrets encrypted at rest 2026-10-15** (V-274882). ✅ **Cluster monitoring (G10) 2026-10-15** — proven by failure (§3.13). ✅ **Nightly etcd backups (G9) 2026-10-16** — two stores, restore-tested (§3.14). ⬜ Owed: the power-down order (3.57), the front door — backlog B-07 |
| 08 | Storage — **Ceph (debs)** and ceph-csi | not written | After 07. **Not MicroCeph** — runbook §2.5 |
| **06a** | **PostgreSQL HA on three guest VMs** — one per physical host, Patroni with its own etcd, synchronous replication | **[`docs/06a-postgres-ha.md`](docs/06a-postgres-ha.md) — as built, with diagrams, every step and its evidence.** Design history: [`docs/runbook.md`](docs/runbook.md) **§9a**, corrected in **§9a.1**, storage in **§9a.2** | 🔨 **BUILDING — slices 1–5 of 6 PASSED 2026-09-27/28** (4: monitoring, maintenance and failover proven live; 5: pgBackRest to two stores, point-in-time restore proven from each) with [`scripts/install/06a-postgres-ha.sh`](scripts/install/06a-postgres-ha.sh) (`etcd`, `etcd-check`, `patroni`, `patroni-check`; as-built notes in runbook §9a.3): pg-01..03 composed `--harden` and hardened themselves (211/4, Evaluate-STIG Open 4 each); etcd with mutual TLS; Patroni + PostgreSQL 16 — pg-01 Leader, pg-02 Sync Standby, pg-03 Replica, node-to-node auth by certificate only, a synchronous commit proven. ⬜ Next: **slice 6**, the PostgreSQL STIG scan (needs the CAC download). Status lives in `docs/backlog.md` B-06a. *Design history:* **DESIGNED 2026-09-16, REVISED 2026-09-17.** Application state does NOT live in the cluster, and the database does **NOT** live on Ceph — the 1 TB M.2 on hosts 1–3 is split: half an encrypted LV for the pg data disk, half raw for `k8s-wk-0N`'s OSD. **Costs Ceph ~800 GB → ~400 GB working, and `k8s-wk-04`'s OSD must be trimmed to match. Do it before the first OSD exists — `--dmcrypt` is create-time only.** §9a.1 corrects four defects in the original design: both recovery paths terminate on host-4, a hand-set `synchronous_standby_names` is overwritten by Patroni, the sizing did not fit the hardware, and the two etcd clusters shared one device. ~~Blocked on one input — how many databases~~ ✅ answered 2026-09-23: one application's database (backlog B-06a) |
| 09 | Validation and ATO evidence | [`docs/runbook.md`](docs/runbook.md) §10, **§10.1** | **PARTLY WRITTEN.** **Evaluate-STIG** assessed and in use — DISA **V1R6** content, CKL/CKLB output an assessor actually consumes, and the measured USG-vs-V1R6 delta that answers open question 18. Still to do: Answer Files for our deviations, the USG↔V1R6 correlator (or a STIG Manager feed — ask the AO), and the host-failure rehearsal before go-live |
| **09a** | Monitoring, compliance and patch posture | [`docs/compliance/dashboards-and-metrics.md`](docs/compliance/dashboards-and-metrics.md) + [`docs/runbook.md`](docs/runbook.md) §10a | **DONE 2026-09-15.** Prometheus, Alertmanager and Grafana on `svc-obs-01`, all three scraped; exporters plus the **textfile** and **systemd** collectors on all five in-gap machines; **34 alert rules in 9 groups**; compliance, backup, Harbor/Trivy and patch facts on a 15-minute timer; **5 provisioned dashboards**. §8 of that document is the exact rebuild sequence. **What it found:** audit records dropped on four machines, a backup chain that could never have worked, Trivy scanning against data dated 2026-09-08 (Q27), `esm-apps` off enclave-wide, and 1 pending security update on `host-4`. ⬜ **No notification path** — Q26 |
| 10 | Day-2 patching | not written | Blocked: Q6 — offline bundle size and cadence |

Q-numbers are in [`docs/open-questions.md`](docs/open-questions.md).

**There is no SSP yet, and [`docs/compliance/ssp-inputs.md`](docs/compliance/ssp-inputs.md) is why that
is survivable.** Twenty-two places in the documents said *"state this in the SSP"* — every one a fact
somebody judged important enough for the accreditation package, written in an aside with nothing
collecting it. That file is the register: the statement, the evidence, and where it came from. **The
SSP's template is the AO's call; the content is ours, and the content is what was at risk of being
lost.**

**A pushed change does not reach a timer by itself.** The nightly and periodic jobs (`enclave-vm-backup`,
`enclave-facts`, `enclave-k8s-facts`) run a **root-owned runtime copy** in `/usr/local/lib/enclave`, not
the repository (backlog 3.11). After pushing a change to anything a timer runs, re-run that timer's
installer: `vm-backup.sh schedule --at <its time>` — **in Central time, `BACKUP_TZ`, today `02:00`**, not UTC —
`monitoring.sh facts-timer`, `monitoring.sh k8s-facts-timer`; or, to refresh the code without touching any timer,
`install-runtime.sh` alone. Then check `cat /usr/local/lib/enclave/.source` shows the pushed commit. **A
`Persistent` timer re-created with a calendar whose last occurrence is newer than its last run fires at
once:** on 2026-10-15 `--at 07:00` was read as 07:00 Central (12:00 UTC), later than that day's 07:00 UTC
run, so a full backup started immediately and the nightly moved into working hours. A dry run
from the repository proves nothing about what the timer runs. On 2026-10-15 a backup-target change
was pushed and dry-run checked, and the nightly ran the old code anyway (backlog 3.67).

## What step 01 is for

It answers one question that can invalidate the OS decision: **can a FIPS stream be enabled on
Ubuntu 24.04 at all?** Canonical's public pages are future-tense on this and roughly seventeen
months stale, so it cannot be settled from documentation — only by attaching a Pro token to a
real 24.04 machine and looking.

If it comes back empty there is no workaround inside Ubuntu, and the choice becomes waiting on
Canonical or reverting to 22.04. That is why it runs **before hardware is committed**.

It starts from bare metal: writing the USB, walking the Ubuntu Server installer, getting the
scripts onto the machine, then running the checks. You cannot validate anything until the OS
is on the box.

The same pass also collects the disk serials and interface names that step 02's autoinstall
template needs, so one trip to the pathfinder feeds the next step.

**→ [`docs/01-pathfinder.md`](docs/01-pathfinder.md)**

## Lab vs production — every difference

**Read this before building production from this repository.** The lab proves the procedure on
smaller hardware; everything below is built differently there, and each lab value is declared in
one place — the `lab` profile of `scripts/enclave/vm-specs.env`, selected by `/etc/enclave-profile`
on the machine — so that a production build, with no profile file, gets the production value or a
refusal. **A difference that is not in this table is a defect: add it here the day it is made.**

| what | lab | production | where it is declared |
|---|---|---|---|
| Host hardware | host-1/2: Ryzen 3 4300U, 4 threads, 30 GiB · host-3: Ryzen Embedded R2544, 8 threads, 31 GiB · host-4: 16 threads, 125 GiB (`vm-specs.env`, measured 2026-09-18) | the hardware spec, backlog 2.8 (~6 drives per host) | backlog 2.8 |
| Guest sizes | control plane 2 vCPU · 6 GiB · 60 GB; worker 4 · 12 · 60; pg 2 · 4 · 40 | 4 · 16 · 100; 8 · 32 · 100; pg per `vm-specs.env` | `vm-specs.env` `VM_*`, lab profile |
| Service VM placement | all four on host-4 (no room on hosts 1–3) | one per host (`PLACE_SVC_*`) | `vm-specs.env`, lab profile |
| Data disk device | the same NVMe as the VM pool — a **written waiver** | a different physical device, or the composer refuses | `vm-specs.env` (the waiver comment) |
| **Ceph OSD, k8s-wk-04** | **a 500 GB logical volume on host-4's OS disk** (`lv:vg0/k8s-wk-04-osd`) — host-4's spare NVMe holds the pgBackRest store | **a dedicated raw drive** — one more drive in host-4's spec | `vm-specs.env` `OSD_K8S_WK_04`: **empty in production, so B-08 refuses** until it is named (backlog 3.48, decided 2026-10-14) |
| Ceph OSD, k8s-wk-01..03 | the ~450 GB left unpartitioned on host-1..3's NVMe | a dedicated raw drive per worker | `vm-specs.env` `OSD_K8S_WK_0N` (empty in production) |
| Backup copies to the vault and the NAS — **network storage, if the site has any** | the Dell's vault (`10.2.30.170`) and the NAS (`10.2.30.171`), nightly — the VM backups, **the etcd snapshot store** (`BACKUP_THIRD_EXTRA='etcd'`, G9) and the pgBackRest store | **the site's NAS or SAN if it has one** — set `BACKUP_THIRD_ADDR` (and `BACKUP_PGBR_COPY`) to it; **none if it has none**, and everything still runs on the in-enclave stores (host-4's backup volume, host-3). Nothing is configured, and nothing fails, for the absence (backlog 3.29) | `vm-specs.env` `BACKUP_THIRD_ADDR`, `BACKUP_PGBR_COPY`: **set only in the lab profile** (moved there 2026-10-15) |
| **Second copy of host-4's backups** | **host-3** — `BACKUP_SECOND_OVERRIDE='host-4=host-3'`: the ring's next host, host-1, reached 85% with its Kubernetes guests | the plain ring (host-4 → host-1), every pool sized for one incoming copy (2.8) | `vm-specs.env` `BACKUP_SECOND_OVERRIDE`: **empty in production, set only in the lab profile** (backlog 3.61, decided 2026-10-15). In effect only after `vm-backup.sh schedule` refreshes host-4's runtime copy (3.67) |
| Lab-only machines and network | `lab-vault`, `lab-nas`, the storage switch, the FortiGate | none of them | `docs/lab-network.md` |
| Site credentials | `make-credentials.sh --any-dir` on stage-01, a copy per host over ssh, shredded after use | the registered `enclave-cred` stick, attached read-only | `docs/airgap-media.md` §9 |
| Kubernetes Secrets passphrase (`K8S_SECRETS_PASS`, 3.64) | typed at the prompt by `encrypt stage` on each control plane (2026-10-15) — no credentials file was placed; its envelope is the operator's to seal | in each control plane's credentials file from `make-credentials.sh`, chosen and sealed by the two custodians — `node-prep` reads it, nobody types it | `docs/07-kubernetes.md` §3.12, `airgap-media.md` §9.6 |
| **VM backup volume, hosts 1–3** (3.68) | a 1 TiB iSCSI LUN each from the NAS's `archive` pool, LUKS-encrypted by the host; no second, third or pgBackRest copy from them | **the site's LUN** (`BACKUP_ISCSI_PORTAL`, `BACKUP_ISCSI_TARGET_HOST_N`), or **a local drive per host** (`BACKUP_LUKS_UUID_HOST_N`), sized in 2.8. Production names none until the site does, and `reattach` refuses until then | `vm-specs.env` lab profile; `lab-network.md` (the NAS steps) |
| host-4's backup volume | a USB SSD (`BACKUP_LUKS_UUID_HOST_4`, lab profile) — a STIG USB-window exception at each attach | the site's LUN or a local drive, as above — no USB | `vm-specs.env` |
| etcd snapshot stores (G9) | host-4's backup volume and host-3, pushed by the control planes | **the same** — `ETCD_BACKUP_STORES` follows `BACKUP_DEST`, so a site LUN mounted there holds host-4's store | `vm-specs.env` `ETCD_BACKUP_STORES` (07-kubernetes.md §3.14) |
| Cluster images into Harbor | `images-load` from stage-01 over the gap cable | on svc-harbor-01 from svc-repo-01's `/oci/` — **the in-gap fetch is not built yet** (directory listing is off) | `docs/07-kubernetes.md` §3.1, §7 |
| stage-01's enclave address | `10.2.20.160`, temporary, for the build | removed at cutover — nothing inside depends on stage-01 | `enclave-addresses.env` |
| Dead-worker fencing (H2) | a documented manual step — no BMCs | automatic, through each host's BMC | backlog B-07 (H2), 2.8 |

## Before you start, gather

- An Ubuntu Pro token — <https://ubuntu.com/pro/dashboard>, free personal tier is fine
- The pathfinder machine, bare metal, with **temporary internet access** (`pro attach` needs it)
- Two USB sticks — one installer, one autoinstall seed
- BMC address and credentials, serial-over-LAN configured

## Decisions locked

Do not reopen without updating [`docs/open-questions.md`](docs/open-questions.md).

| | |
|---|---|
| Platform | Canonical Kubernetes **v1.36.4, snap rev 5526** — `1.36-classic/stable` was unpublished; taken from `candidate`, side-loaded by revision |
| OS | Ubuntu 24.04 LTS, host and guest |
| Image variant | Minimal on the **7** cluster nodes; standard server on the **4 hosts** and the **3 service VMs** |
| Datastore | Embedded etcd — the 1.36 default; `k8s-dqlite` was removed in 1.36 |
| Storage | **Ceph from `noble-updates/main` debs** on the worker VMs, via ceph-csi — **not** MicroCeph (runbook §2.5) |
| Host provisioning | Autoinstall from media, **not** MAAS — MAAS runs on a VM on a host, so it cannot install that host |
| Hypervisor | **libvirt/KVM from debs** — **not** LXD, which is snap-only on `base: core24` with no FIPS channel (runbook §2.6) |
| Hosts | **4** — hosts 1–3 carry a control plane + worker each; host-4 carries 3 service VMs + the 4th worker |

## Everything else

| File | Job |
|---|---|
| [`airgapped-setup-machine/README.md`](airgapped-setup-machine/README.md) | **STAGE-01** — the online staging machine and sole dev workstation. **§0 is the single home for what is left to do on it.** Not a numbered step; it underpins 04 and 10 |
| [`docs/airgap-media.md`](docs/airgap-media.md) | What goes on the USB drives, and what makes an offline install work |
| [`docs/open-questions.md`](docs/open-questions.md) | What is unanswered, grouped by who answers it |
| [`docs/runbook.md`](docs/runbook.md) | Reference architecture — *why* the design is what it is, with sources. **Not a step list.** Cited by §-number |
| [`HANDOFF.md`](HANDOFF.md) | The bake-off record — why Canonical was chosen over VerteX |
| [`CLAUDE.md`](CLAUDE.md) | Working rules for Claude Code sessions |
| [`scripts/install/`](scripts/install/) | Scripts, numbered to match the steps |

**Nothing in steps 02–10 has been executed.** Procedures are drafted against fetched vendor
documentation, with `[VERIFY]` marking anything that could not be confirmed. Those markers are
work items, not commentary.
