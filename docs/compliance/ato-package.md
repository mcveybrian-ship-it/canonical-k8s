# The AO submission package — what it contains, and what we already have

**Started 2026-09-17.** Companion to [`ssp-inputs.md`](ssp-inputs.md), which collects the
*statements*; this document is the *container list*.

> 🔴 **The AO's artifact list governs, not this one.** RMF packages vary by Service, by
> programme and by eMASS configuration. **Ask for the required artifact list in writing before
> drafting anything long.** Below is the standard set, offered so the request is informed and so
> nobody starts writing an Incident Response Plan the programme was going to inherit.

**The useful half of this document is the third column.** This build has been generating
accreditation evidence for three weeks without calling it that. Most of what follows already
exists in some form; knowing which is the difference between a two-week package and a
three-month one.

---

## 1. The artifact set

### Core — the package does not exist without these

| Artifact | What it is | What we already have |
|---|---|---|
| **System Security Plan (SSP)** | The system description, boundary, and a control-by-control implementation statement | ⚠️ **Not started.** [`ssp-inputs.md`](ssp-inputs.md) holds 22 decided statements with evidence. The template is the AO's call |
| **Authorization Boundary diagram** | What is in, what is out, every crossing | ⚠️ Text exists — runbook §1.2 has the four-host topology, §3.1 the addressing, and the boundary is unusually clean: **`stage-01` and `build-01` are deliberately outside it**. Needs drawing |
| **Hardware / Software / Firmware inventory** | Every component, version, and where it came from | ✅ **Strong.** `enclave-addresses.env` and `vm-specs.env` are authoritative; `enclave_*` facts publish live versions; the mirror means every package's origin is known. Needs extracting into the AO's format |
| **Security Assessment Plan (SAP)** | How the controls will be tested, by whom, with what tools | ⚠️ Partial. Runbook §6.0 is the procedure and §10.1 the tooling (Evaluate-STIG V1R6, USG, `stig-tools.sh`). Missing: the assessor's independence statement and a schedule |
| **Security Assessment Report (SAR)** | The results | ✅ **Strong.** CKL/CKLB per machine, dated, with the progression preserved (`51/68 → 210/7` on `svc-harbor-01`). Five machines assessed, residual set of six, every one a policy decision |
| **POA&M** | Every unmet control, with a remediation date and owner | ⚠️ **Not assembled, but the inputs are complete.** The six residual findings, `docs/open-questions.md`, and the ⬜ rows in §3a coverage matrix. **This is the single highest-value thing to assemble next** |
| **Risk Assessment Report (RAR)** | Threat, likelihood, impact, residual risk | ⚠️ Not started. The raw material is unusually good: §9a.1's recovery-path analysis, the TPM/passphrase trade, replica-3 self-healing |

### Operational plans — often where packages stall

| Artifact | What we already have |
|---|---|
| **Configuration Management Plan** | ✅ **Very strong, and unusual.** `docs/runbook.md` is a reproducible build procedure; every setting is a parameter in a tracked file; git history is the change record; AIDE detects drift; `apply-addresses.sh` enforces one source of truth for addressing. Most programmes write this document aspirationally — here it already governs |
| **Contingency Plan (CP)** | ⚠️ Mechanism ✅, plan ⬜. `vm-backup.sh` gives verified whole-VM recovery with manifests, nightly changed-set verify and a weekly deep verify. **What is missing is the written plan and the RTO/RPO commitment** — and §9a.1 says plainly that both recovery paths terminate on `host-4` |
| **Contingency Plan Test Results** | 🔴 **Nothing, and this is a real gap.** The host-failure rehearsal in runbook §10 has never been run, and a Patroni failover has never been exercised. **An untested recovery plan is an assumption**, and this design exists because an untested failover already lost a database once |
| **Incident Response Plan** | ⬜ Nothing. Ask whether it is inherited from the enclosing programme — in an air-gapped enclave with one operator, an independent IR plan may be inappropriate |
| **Continuous Monitoring (ISCM) strategy** | ✅ **Strong and already running.** Step 09a: Prometheus, Alertmanager, Grafana; 34 alert rules in 9 groups; compliance, backup, registry and patch-posture facts on a 15-minute timer across five machines. 🔴 **One gap: no notification path** — Q26, because no email can leave an air gap |
| **Patch / flaw remediation procedure** | ⚠️ Step 10 unwritten, blocked on Q6. But `esm-apps`/`esm-infra` posture is measured and the patch-posture metrics exist |

### Registrations and agreements

| Artifact | Status |
|---|---|
| **PPSM registration** (ports, protocols, services) | ⬜ Not started. Inputs exist: `stig-tailor.sh ufw` holds the rule set, and every listening port has a justification in the runbook. §9a.3 adds `:8008`, `:2379`, `:2380` |
| **Interconnection Security Agreements (ISA/MOU)** | ✅ **Almost certainly none — and say so affirmatively.** The enclave has no external connections; `stage-01` is outside the boundary and physically unplugged at cutover. *"No interconnections"* is a strong statement, not an omission |
| **Privacy (PTA / PIA)** | ⬜ **A PIA is required — settled 2026-09-22.** `DATA_TYPES` records PII of staff and operators, **PII of members of the public**, **PHI** and recorded human call records, so the screening outcome is not in doubt. Backlog **D-7**; ⚠️ whether a health-information regime applies on top of 800-53 is still open (**Q-PHI**) |
| **Cybersecurity Strategy** | ⬜ Acquisition-programme artifact. Ask whether it applies |

---

## 2. What to do first, and why in this order

**1. Ask the AO for the required artifact list and the control baseline.** Both are decisions,
not deductions, and everything downstream depends on them. Include the three boundary questions
from `00-downloads.md` (the router, the Traditional Security Checklist, App Sec & Dev).

**2. Assemble the POA&M.** It is the highest value per hour on this list: the inputs are already
complete and written, it is the artifact that most directly shows control of the system, and
assembling it forces every ⬜ in this repository to acquire an owner and a date.

**3. Run the contingency test.** It is the only item on this list that **cannot be written** —
it has to be performed. Pull a host, restore a guest, fail over a database, and record what
happened. It is also the item most likely to change the design, which is a reason to do it early
rather than late.

**4. Draw the boundary diagram.** Cheap, and it is the first thing an assessor opens.

**5. Then the SSP**, once the template is known and the POA&M has already forced the honest
answers out into the open.

---

## 3. The three things this package will be strongest on

Worth knowing, because these are where a programme office normally struggles:

- **Reproducibility.** The build is a procedure, not a memory. An assessor asking *"how do you
  know every host is configured the same way"* gets a script and a parameter file, not an
  assurance.
- **Evidence with dates and provenance.** Measured findings, the commands that produced them,
  and preserved progressions — including the failures. The record shows a system under control,
  not a system presented at its best moment.
- **Honest limitations already written down.** Both recovery paths on one host. Single site, no
  DR. Replica-3 that cannot self-heal. A passphrase that needs a human at the rack. **Packages
  lose credibility by omitting things an assessor then finds.** These are already in
  [`ssp-inputs.md`](ssp-inputs.md) in the programme's own words.

## 4. And the three it will be weakest on — say them first

- **No contingency test has ever been run.**
- **No notification path exists** for the two controls that require one (Q26).
- **No CMVP certificate numbers exist for 24.04**, so the cryptographic-boundary exception has to
  be argued rather than evidenced (Q13/Q14/Q15). [`ssp-inputs.md`](ssp-inputs.md) §1 has the
  measured posture that makes the argument as strong as it can be.
