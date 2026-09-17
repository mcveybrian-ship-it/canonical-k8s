# Baseline accreditation artifacts — written once, tailored per engagement

**Purpose: there is no single AO.** This enclave is a design taken to different facilities
(`HANDOFF.md` §3a — *"a template for other facilities, not a one-off"*), so the deliverable is a
**baseline artifact set that gets tailored**, not a package for one accreditation. Waiting on an
AO's template is waiting on something that never arrives in the singular.

## The three layers, and why they are separated

Every document here is written so that a new engagement touches **only the third layer**.

| Layer | Changes | Lives in |
|---|---|---|
| **1. Generic** | Never. RMF process language, artifact purpose, control descriptions | The document prose |
| **2. Architecture** | Only if the design changes. Four hosts, air gap, FIPS posture, LUKS, enclave PKI, Ceph replica-3, the backup model | The document prose — reusable for anybody buying this design |
| **3. Facility** | **Every engagement.** Names, addresses, POCs, location, the AO's baseline and overlays | **[`facility-profile.env`](facility-profile.env)** only |

**Placeholders are `«GUILLEMETS»`** — visually obvious in prose, and nobody types them by
accident. So the tailoring checklist is one command:

```bash
grep -rn '«' docs/compliance/baseline/
```

**A document still showing a guillemet has not been tailored.** That is the design: a visible
blank is safer than this lab's value silently standing in, because a wrong-but-plausible value
carried into a second engagement is worse than an obvious gap.

## Where the content comes from

These documents are not written from nothing. Three weeks of build work already produced the
substance:

| Source | What it supplies |
|---|---|
| [`../ssp-inputs.md`](../ssp-inputs.md) | Every statement already decided, with its evidence. The SSP's raw material |
| [`../nist-800-53-plan.md`](../nist-800-53-plan.md) | Family-by-family status, and the CCI mapping approach |
| [`../ato-package.md`](../ato-package.md) | Which artifacts exist under another name already |
| [`../../runbook.md`](../../runbook.md) | The build procedure — this **is** the CM baseline |
| `../../../scripts/enclave/*.env` | Authoritative inventory and addressing values |
| CKL / CKLB files | Assessed, dated, per-rule findings with `CCI_REF` — 800-53 traceability already |

## The set, and its state

| Artifact | File | State |
|---|---|---|
| **System Security Plan** | `ssp.md` | ⬜ Not started. Content is in `../ssp-inputs.md`; needs the control baseline to know its own size |
| **POA&M** | `poam.md` | ⬜ **Next.** Inputs complete; highest value per hour in the set |
| Security Assessment Plan | `sap.md` | ⬜ Procedure exists (runbook §6.0, §10.1); needs assessor independence and a schedule |
| Security Assessment Report | `sar.md` | ⬜ Should be **generated** from the CKLs, not written |
| Contingency Plan | `contingency-plan.md` | ⬜ Mechanism exists and is verified; the plan and the RTO/RPO commitment do not |
| Configuration Management Plan | `cm-plan.md` | ⬜ Unusually strong — mostly points at the runbook and the parameter files |
| Incident Response Plan | `ir-plan.md` | ⬜ Write for the inherited case by default; a system-specific IR plan for a one-operator air-gapped enclave is often inappropriate |
| Risk Assessment Report | `rar.md` | ⬜ Raw material is good: recovery-path analysis, the TPM trade, replica-3 self-healing |
| ISCM Strategy | `iscm-strategy.md` | ⬜ Already running (step 09a). One real gap: no notification path (Q26) |
| Hardware / Software Inventory | — | ⬜ **Generate, do not write.** A hand-written inventory drifts from the day it is written |
| Boundary description + diagram | `boundary.md` | ⬜ Text exists in runbook §1.2/§3.1. The diagram is not mine to draw |

## Two rules that keep this from rotting

**1. A commit that changes security-relevant behaviour touches
[`../ssp-inputs.md`](../ssp-inputs.md) in the same commit, or says in its message why it does
not.** Not "later." Twenty-two such statements accumulated as scattered asides precisely because
nothing collected them, and the runbook carried a `pro enable fips-preview` instruction for weeks
after Q11 made it wrong — because nothing forced a re-read. Good intentions produced both.

**2. Anything derivable from a parameter file is generated, never transcribed.** The inventory,
the addressing, the port list, the assessment results. This project has already proved the
pattern twice: `apply-addresses.sh` renders `/etc/hosts` from one source, and the facts timer
publishes live state rather than a snapshot. **Generated documentation cannot drift; written
documentation always does.**

## Tailoring a new engagement

1. Copy this directory.
2. Fill in `facility-profile.env` — every value, including the control baseline and overlay set.
3. `grep -rn '«' .` and resolve everything it finds.
4. Re-verify every time-sensitive claim rather than restating it. `CLAUDE.md` names them under
   *"Re-verify before anything ships"* — vendor posture in this space changes quarterly, and the
   reader is making a decision.
5. Record what the AO actually asked for in `ARTIFACTS_REQUESTED`, so the next engagement can
   see what differed instead of re-deriving it.
