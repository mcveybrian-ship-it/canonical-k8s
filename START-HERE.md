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
| **05** | Harden hosts — Pro, FIPS, STIG | [`docs/runbook.md`](docs/runbook.md) **§6.0 is the ordered procedure**, **§10d is day-2 patching**; [`scripts/install/05-harden-host.sh`](scripts/install/05-harden-host.sh) drives it | **SEVEN OF EIGHT MACHINES HARDENED.** `host-1` `host-2` `host-3` **COMPLETE 2026-09-17 at `213 pass / 3 fail`** — the best in the enclave, and the only machines where all three findings are decisions rather than defects. `host-3` was driven entirely by `05-harden-host.sh` and hit 213/3 first time. The earlier five sit at six findings because **`ufw` and the GRUB password were never completed there** — completable engineering work, not accepted risk (`HANDOFF.md` §3). 🔴 **A patch cycle REVERTS hardening** — three packages, three controls, measured on two machines: §10d. ⬜ Owed on host-1/2/3: `collect`, `audit-volume.sh install`, the step-15 functional test, and a written deviation for `service_sssd_enabled` |
| 06 | Compose and deploy the 6 cluster VMs | not written | After 05. Each guest needs its own Pro attach, FIPS and STIG pass |
| 07 | Bootstrap Kubernetes | not written | **Q8 ANSWERED** — no FIPS channel exists; needs the `core22` FIPS base snap. After 06 |
| 08 | Storage — **Ceph (debs)** and ceph-csi | not written | After 07. **Not MicroCeph** — runbook §2.5 |
| **06a** | **PostgreSQL HA on three guest VMs** — one per physical host, Patroni with its own etcd, synchronous replication | [`docs/runbook.md`](docs/runbook.md) **§9a**, corrected in **§9a.1**, storage in **§9a.2** | **DESIGNED 2026-09-16, REVISED 2026-09-17, not built.** Application state does NOT live in the cluster, and the database does **NOT** live on Ceph — the 1 TB M.2 on hosts 1–3 is split: half an encrypted LV for the pg data disk, half raw for `k8s-wk-0N`'s OSD. **Costs Ceph ~800 GB → ~400 GB working, and `k8s-wk-04`'s OSD must be trimmed to match. Do it before the first OSD exists — `--dmcrypt` is create-time only.** §9a.1 corrects four defects in the original design: both recovery paths terminate on host-4, a hand-set `synchronous_standby_names` is overwritten by Patroni, the sizing did not fit the hardware, and the two etcd clusters shared one device. ⬜ Blocked on one input — how many databases, and is this one app's state or a shared service — which is the **same uncaptured requirement** that blocks the Ceph OSD size and therefore the BOM |
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
