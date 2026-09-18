# Backlog — the single live list of what is outstanding

**This file is the one place to look for "what is left." It is maintained, not archaeological.**

Created 2026-09-18 because the answer to that question was spread across `airgapped-setup-machine/README.md` §0a (priority order, buried in 1,100 lines), `docs/open-questions.md` (the questions, with their history), `docs/compliance/ssp-inputs.md` (the 🔴 statements) and `docs/compliance/baseline/README.md` (which artifacts exist). **None of those is wrong; none of them is a list.**

## How this file works

| | |
|---|---|
| **One home per fact** | An item lives here as a ROW. Its detail, history and evidence stay where they already are, referenced by section or question number. Do not copy the detail in — it will diverge |
| **Updated every session** | When something closes it moves to §9 with a date, it does not vanish. When something new is found it gets a row the same day it is found |
| **Nothing is deleted** | A closed item that turns out not to be closed needs its history. §9 is append-only |
| **Status is honest** | ⬜ not started · 🔄 in progress · ⏸️ deferred *by a named decision* · 🔴 blocked · ✅ done |
| **No secrets** | This file is TRACKED and `origin` is public. Same discipline as the README: no passwords, no keys, no token-bearing paths |

**If you are an assistant reading this: update it as part of the work, not as a separate task afterwards.** A backlog that is maintained at the end of a session is a backlog that is maintained on the sessions that do not run out of room.

---

## 1. 🔴 Red flags — stated in `ssp-inputs.md`, unaddressed

These are the ones an assessor reads first. All four are architectural, not paperwork.

| | Item | Why it matters | Status |
|---|---|---|---|
| **1.1** | **No remote recovery path of any kind** — LUKS prompts at a physical console on every host | A power event, kernel panic or failed boot needs a human at the rack. Proven on host-4 2026-09-16: one reboot took the whole enclave down until somebody typed a passphrase | 🔴 open · `ssp-inputs.md` §2.1a |
| **1.2** | **Both recovery paths terminate on host-4** | host-4 runs all four service VMs *and* holds the backup drive. It is the single point of failure for the thing meant to survive a failure | 🔴 open · §3.2 |
| **1.3** | **Survives one host failure, not a site event** | Replica-3 across three hosts cannot self-heal, and every copy is in one room | 🔴 open · §3.1 |
| **1.4** | **The cryptographic-boundary exception has to be won, not assumed** | The FIPS posture is strong and measured (§1.1), but the boundary claim is a negotiation, not a measurement | 🔴 open · §1.3 |

## 2. Big moves — at most one at a time, and they have an order

| | Item | Notes | Status |
|---|---|---|---|
| **2.1** | **Prove a restore works** on one throwaway guest | **Cheapest big win.** CP-4 has *no evidence of any kind*, and `vm-backup.sh` has only `restore-plan` — a printed manual procedure, no restore command. De-risks everything below it. Costs an afternoon, not an outage | ⬜ **recommended first** |
| **2.2** | **Move `svc-repo-01` off host-4** | Closes §3.2. host-1/2/3 now have 300 GB pools sitting empty and libvirt running. **Prerequisite for 2.3** — wiping host-4 today takes the apt mirror every other machine installs from | ⬜ blocked on 2.1 being sensible first |
| **2.3** | **Rebuild host-4** from current scripts | Every gap it has is "built before this fix existed" — the two-line tmpfiles, missing logrotate `create`s, no ufw table. Also the first real proof `05-harden-host.sh` is reproducible end to end | 🔴 blocked on 2.2 |
| **2.4** | **TPM unlock for LUKS** | The only thing that removes §2.1a. Already parameterised as `LUKS_UNLOCK`, never exercised. Q20 answered: TPM recommended for production | ⬜ open |
| **2.5** | **Resume the Kubernetes build** — 9 VMs, then K8s, then Ceph | ⏸️ **Paused by decision 2026-09-18.** Nothing half-done. Phase 4 needs only the base image copied and `/etc/enclave/profile` written. ⚠️ Ceph has **never been executed** and wants a dedicated device per OSD this hardware does not have (`ssp-inputs.md` §4.1c) | ⏸️ deferred |

## 3. Medium — contained, with a clear finish line

| | Item | Notes | Status |
|---|---|---|---|
| **3.1** | **Write host-4's and `svc-mgmt-01`'s ufw rule tables**, then enable | ⏸️ **Deferred by decision 2026-09-18.** NOT a one-liner: both default policies are DROP and host-4's table has two rows with **no `22/tcp`** — enabling as-is drops SSH on a machine with no BMC and cuts bridged traffic for every guest. `svc-mgmt-01`'s MAAS port list is still unconfirmed | ⏸️ deferred |
| **3.2** | **Implement the weekly Trivy DB carry-in** | The AO answered Q27 on 2026-09-18 (weekly). **The process does not exist yet** — the decision is recorded, the mechanism is not built | ⬜ **owed by a decision already made** |
| **3.3** | **Run the V-270754 ufw 443 test** | Engineering half is unrun; the acceptance half is Q25 (deferred). Two owners, one V-ID | ⬜ open |
| **3.4** | **V-270651** AIDE config integrity | Needs a pristine `aide-common` .deb carried in | ⬜ open |
| **3.5** | **V-270747** data-at-rest write-up · **V-270719** PPSM | Paperwork against mechanisms that already exist | ⬜ open |
| **3.6** | **Make `esm-apps` consistent** across all eight | Enabled inconsistently; `esm-infra` too. It was entitled all along and simply never switched on | ⬜ open |
| **3.7** | **Root CA key custody** | A policy question, not a mechanism | ⬜ open · `ssp-inputs.md` §2.5 |
| **3.8** | **Retire or justify the second USB disk on host-4** | The old WD easystore (`sdb`, 4.5 T, LUKS) is still plugged in and unmounted. Either a free second copy or a USB device on the hypervisor for no reason | ⬜ open |

## 4. Documents — 6 of 10 baseline artifacts not started

| Artifact | Notes | Status |
|---|---|---|
| `ssp.md` | The centre of the package. Blocked on the control baseline — **and the AO is Brian for now, so he can unblock it** | 🔴 blocked on a baseline decision |
| `sar.md` | **Generate from the CKLs, do not write** | ⬜ |
| `sap.md` | Procedure exists (runbook §6.0, §10.1); needs assessor independence and a schedule | ⬜ |
| `ir-plan.md` | Write for the inherited case by default | ⬜ |
| `rar.md` | Raw material is good — recovery-path analysis, the TPM trade, replica-3 | ⬜ |
| `boundary.md` | Text exists in runbook §1.2/§3.1. The diagram is not mine to draw | ⬜ |

✅ Written 2026-09-17: `poam.md`, `cm-plan.md`, `contingency-plan.md`, `iscm-strategy.md`.

## 5. Questions

**The AO's** (Brian, for now) — `docs/open-questions.md`:

| | Question | Status |
|---|---|---|
| **Q25** | Five Not Reviewed controls needing a signature. The audit-offload half (V-270658/V-270817) converts straight into engineering the moment it is answered | ⏸️ deferred 2026-09-18 |
| **Q22** | How much usable persistent storage the workload needs. Drivers now named — **map storage dominates, call volume is light** — and a sizing calculator is coming. Still blocks the Ceph OSD size and the BOM | ⏸️ deferred 2026-09-18 |
| **Q13 / Q15** | FIPS posture wording for the SSP. Largely answered by the Q17 measurement; **needs writing up, not deciding** | ⬜ open |
| **Q6** | Offline patch bundle size and cadence | ⬜ open |

**External, nobody here can answer:**

| | Question | Who |
|---|---|---|
| **Q14** | When 24.04 FIPS 140-3 validation completes | NIST / Canonical |
| **Q10** | The 1.36 LTS support window end date | Canonical |
| **Q4** | Unlimited VMs confirmed in writing | Canonical reseller |

## 6. 🔴 MAAS does not work under FIPS

Found 2026-09-17, runbook §9b. **Nothing in the current build path depends on MAAS** — `03-compose-vm.sh` composes from `virsh` directly — so this is not blocking. Three options: pursue Canonical, test a newer version, or remove it from the boundary. **Plan as though removing it is the answer.**

## 7. Never mirrored, never built

- **Landscape** and the **Enterprise Store** — never in a transfer bundle. Blocked on a transfer trip before they are blocked on writing. ⚠️ *State not re-verified since it was recorded.*
- **`svc-log-01`** — the audit-offload collector. `svc-obs-01` can host it instead; the blocker is Q25's three answers, not the missing VM.
- **A Trivy CLI on the machines** — Trivy exists only inside Harbor's container, so nothing can scan the hosts' own filesystems.

## 8. ❓ Unresolved: is the bake-off artifact still the deliverable?

`CLAUDE.md` names the **Canonical Kubernetes vs Spectro Cloud VerteX comparison artifact** as this project's deliverable. `artifact/artifact-source.html` has not been touched since **31 August 2026**. Everything since has gone into building the enclave.

**That may be exactly right — but it should be a decision, not a drift.** If it is still owed, its time-sensitive vendor claims need re-verification before it ships (`CLAUDE.md`, "Re-verify before anything ships"). If the build has replaced it, write that down so the next person does not find a three-week-stale document and assume it is current.

## 9. Recently closed — append only, newest first

**2026-09-18**
- ✅ **Q28** — the third-party package list. The question's premise was wrong: "24–46 per machine" was the `universe` bucket, which **is** covered by `esm-apps`. The genuinely uncovered set is **five installs, four packages** — `contracts-airgapped`, `get-resource-tokens`, `pro-airgapped` (Canonical) and `grafana` (Grafana Labs). Docker is `docker.io` from universe, not `docker-ce`. Generated by `stig-tools.sh coverage`, never transcribed. `ssp-inputs.md` §4.1f
- ✅ **Q27** — Trivy DB refreshed weekly. Alert fires at 10 days, not 7, so a met policy does not alert. §4.1e → **left 3.2 owed**
- ✅ **Q26** — a monitored in-boundary alert satisfies V-270818/V-270819. Does not foreclose email if a path out is ever authorised. §4.1d
- ✅ **Monitoring on host-1/2/3** — they were invisible to Prometheus; the scrape list is hardcoded and building a machine does not add it. Now **15/15 targets up**, node and libvirt
- ✅ **V-270756 closed at the creation point on all four** — the cause was **logrotate**, not `sysstat`. Three stanzas recreated world-readable on purpose; twelve had no `create` line at all
- ✅ **V-270755** — every host had a live WiFi *and* Bluetooth radio. The checklist scored it Not Applicable on a machine with a radio in it
- ✅ **host-4 collected and caught up** — 166/10/11/7 → 169/9/9/7; all four hosts now match exactly on NA and NR, rule for rule
- ✅ **host-1/2/3 made VM-ready** — libvirt, `br0`, 300 GB pool, 200 GB data volume (runbook §6.5, a step that did not exist)
- ✅ **Seven tool bugs fixed**, each of which would have survived a rebuild: `update-initramfs` rebuilding the wrong kernel · `radio status` dying silently on every VM · `set_args` and its pipes · the textfile check reading `/proc/cmdline` · the journal trigger that could not see its own target · the logrotate `create` gap · the coverage marker that reported zero

**2026-09-17** — host-1/2/3 hardened to USG 213/3 and V1R6 171/9/9/5, byte-identical · Q20 (TPM) and Q21 (GRUB) answered.
