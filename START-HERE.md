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
| **02** | Base OS install, **4** bare-metal hosts — **host-4 first**, it carries MAAS | [`docs/02-host-install.md`](docs/02-host-install.md) + [`airgap-media.md`](docs/airgap-media.md) | **READY** — two decisions first, §1 and §10 |
| **03** | libvirt on host-4, compose `svc-mgmt-01` by hand | [`docs/03-host-services.md`](docs/03-host-services.md) | **HOST PREP DONE** 2026-09-02 — host-4 verified clean after a cold boot: mirror apt, br0, LUKS-backed image pool, NAT off. **`svc-mgmt-01` not yet composed.** libvirt, not LXD - runbook §2.6 |
| 04 | Enclave services — Pro contract server, Landscape mirror, Harbor, MAAS | not written | Blocked: **Q9** — the air-gapped Pro procedure is Knowledge Base material, not public. This is the gate on everything downstream |
| 05 | Harden hosts — Pro, FIPS, STIG | not written | **Cannot run before 04.** Pro attach in an air gap needs the contract server on `svc-01`. Also needs Q13 (your AO), Q19/Q20/Q21 |
| 06 | Compose and deploy the 6 cluster VMs | not written | After 05. Each guest needs its own Pro attach, FIPS and STIG pass |
| 07 | Bootstrap Kubernetes | not written | **Q8 ANSWERED** — no FIPS channel exists; needs the `core22` FIPS base snap. After 06 |
| 08 | Storage — **Ceph (debs)** and ceph-csi | not written | After 07. **Not MicroCeph** — runbook §2.5 |
| 09 | Validation and ATO evidence | not written | Includes the host-failure rehearsal, before go-live |
| 10 | Day-2 patching | not written | Blocked: Q6 — offline bundle size and cadence |

Q-numbers are in [`docs/open-questions.md`](docs/open-questions.md).

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
