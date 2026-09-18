# Applying NIST 800-53 to this enclave — the plan

**Started 2026-09-17.** Sits between [`ssp-inputs.md`](ssp-inputs.md) (the statements) and
[`ato-package.md`](ato-package.md) (the containers). This is the engineering plan: which
controls, how they get satisfied, and what is actually left to do.

> 🔴 **The control baseline is the AO's determination, not ours.** IL5 generally corresponds to
> a High-equivalent baseline plus DoD overlays for CUI, but *"generally"* is not something to
> build a package on. **Get the baseline and the overlay set in writing** — it changes the
> control count by hundreds and it is the first question in
> [`ato-package.md`](ato-package.md) §2.

---

## The insight that makes this tractable

**Do not approach this as "implement several hundred controls."** The STIG has already done the
technical work, and **the mapping from STIG results to 800-53 controls is mechanical, not
judgemental**:

```
STIG rule  →  CCI (Control Correlation Identifier)  →  800-53 control
```

**Every CKL and CKLB file Evaluate-STIG has produced already carries `CCI_REF` fields per
finding.** So five machines' worth of assessed, dated, per-rule evidence is *already* 800-53
traceability — it just needs the CCI-to-control translation table, which DISA publishes as the
**CCI List** (added to the cyber.mil list in [`00-downloads.md`](../00-downloads.md)).

> **Consequence, and it reframes the whole effort: the technical control families are largely
> already evidenced. What is genuinely unwritten is the POLICY families and the handful of
> controls an air gap makes impossible.** Plan the work accordingly instead of starting at AC-1
> and grinding forward.

---

## Family-by-family: what exists, what is owed

Status is honest, not aspirational. **✅** implemented with evidence · **⚠️** partial ·
**⬜** not started · **↗** belongs to the enclosing programme, not this system.

### Technical families — mostly satisfied, needs mapping not building

| Family | Status | What exists, and where |
|---|---|---|
| **AC** Access Control | ✅⚠️ | Local accounts only; `usg fix` removed blanket `NOPASSWD`; per-command sudo exceptions scoped and justified (⚠️ the `svc-mgmt-01` exception existed for MAAS, removed 2026-09-18 — re-check whether it is still needed); DoD banner before all SSH output; ufw via `stig-tailor.sh ufw`. ⚠️ **SSSD decisions still open** — two of the five hardening decisions |
| **AU** Audit and Accountability | ✅⚠️ | auditd per the STIG; `/var/log/audit` on its own LV; volume measured (2.44 MB/day on Harbor, 1.71 on repo); offload to `svc-obs-01`. 🔴 **AU-4/AU-5 blocked on Q26 — two controls require email notification and no email can leave an air gap.** Also found by monitoring: **audit records were being dropped on four machines** |
| **CM** Configuration Management | ✅ **Strongest family** | The runbook is a reproducible procedure; every setting is a parameter in a tracked file; git is the change record; AIDE detects drift; `apply-addresses.sh` enforces one source of truth. ⚠️ CM-6 caveat: the GRUB `--unrestricted` state is package-managed and can revert silently |
| **IA** Identification and Authentication | ⚠️ | SSH keys; password complexity via STIG; FIPS-mode crypto. **`pam_pkcs11` is present and looking for a smart card** (observed 2026-09-17: `no suitable token available`) — **is CAC/PIV authentication intended here? That is an IA-2 multifactor answer and nobody has decided it.** ⬜ New question |
| **SC** System and Communications Protection | ✅⚠️ | FIPS provider **active** (measured); LUKS on both VGs with pbkdf2; enclave PKI with an offline root; TLS everywhere internally; no external connections at all. 🔴 **SC-13's boundary exception must be argued — no CMVP numbers exist for 24.04** |
| **SI** System and Information Integrity | ✅⚠️ | AIDE; `esm-apps` + `esm-updates`; patch-posture metrics; 34 alert rules. ⚠️ **SI-2 gaps: `esm-infra` inconsistent across machines, and Trivy cannot scan host filesystems** (Q27) |
| **CP** Contingency Planning | ⚠️ | `vm-backup.sh` with manifests, nightly changed-set verify, weekly deep verify, chain-aware retention. 🔴 **CP-4 has NEVER been tested** — no host-failure rehearsal, no failover exercise. **Both recovery paths terminate on `host-4`** |
| **MP** Media Protection | ✅ | `usb_storage` **and `uas`** blocklisted with a logged, time-boxed exception window; media transfer procedure in `airgap-media.md`. ⚠️ Known gap: two `DISABLE` events logged `INCOMPLETE - module still loaded` |
| **RA** Risk Assessment | ⚠️ | Trivy in Harbor scans images; the residual-findings register is effectively a risk log. ⬜ **No RAR document; no host-level vulnerability scanning** (Q27) |
| **SR** Supply Chain Risk Management | ⚠️ | Every package's origin is known because everything comes from one audited mirror; snaps served as verified files; Harbor is the only image source. 🔴 **Q28's named list of packages no subscription covers is owed** — and `patroni`/`etcd-server` are both `universe` |
| **CA** Assessment, Authorization, Monitoring | ✅⚠️ | Five machines assessed with Evaluate-STIG against DISA V1R6, dated CKLs, progressions preserved. ⬜ CA-2 needs an **independent** assessor statement — self-assessment is not the same artifact |

### Policy and programme families — this is where the real writing is

| Family | Status | Note |
|---|---|---|
| **PL** Planning | ⬜ | The SSP itself. [`ssp-inputs.md`](ssp-inputs.md) is the content |
| **IR** Incident Response | ⬜ | Nothing. **Ask whether it is inherited** — an independent IR plan for a one-operator air-gapped enclave may be inappropriate |
| **MA** Maintenance | ⬜⚠️ | Step 10 (day-2 patching) is unwritten, blocked on Q6. MA-4 nonlocal maintenance is trivially satisfied: **there is no remote access** |
| **AT** Awareness and Training | ↗ | Programme |
| **PS** Personnel Security | ↗ | Programme |
| **PE** Physical and Environmental | ↗ | Facility's existing ATO, presumably. Confirm — and note the enclave's **single-site, no-DR** posture is a PE-adjacent risk statement |
| **PM** Program Management | ↗ | Programme |
| **PT** PII Processing | ⬜ | Depends on the application data — same unknown as Q22 |
| **SA** System and Services Acquisition | ⚠️ | The platform bake-off is genuine SA-4 evidence: a documented, sourced comparison behind the Canonical selection |

---

## The plan, in the order that wastes least effort

**Phase 1 — get the inputs that change everything (days, mostly waiting)**
1. **The control baseline and overlay set**, in writing.
2. **The required artifact list.**
3. **The CCI List** from cyber.mil, with the rest of the STIG collection.
4. The three boundary questions: the router, the Traditional Security Checklist, App Sec & Dev.

**Phase 2 — mechanically harvest what is already evidenced (worth automating)**

Parse the existing CKL/CKLB files, join `CCI_REF` to the CCI List, and emit a control-by-control
table showing which 800-53 controls are already satisfied, by which STIG rules, on which
machines, on what date. ⬜ **A script, not a document** — five machines' evidence and it
regenerates every time a scan runs. This is the single highest-leverage piece of work on this
page and it does not exist yet.

**Phase 3 — close the technical gaps that are actually ours** (each already tracked)

`esm-infra` consistency · Q28's package list · host-level vulnerability scanning (Q27) · the
SSSD decisions · PPSM registration from the ufw rules · the Patroni synchronous-degradation
alert · **and the contingency test, which is the only one that cannot be written instead of
performed.**

**Phase 4 — write the policy families**, with the AO's template in hand and Phase 2's table
already answering the technical questions.

---

## Four controls this enclave satisfies unusually well — say so explicitly

An air gap is normally described in terms of what it costs. It buys these outright:

- **CA-3 / SC-7 boundary protection** — there are no external connections. Not "restricted": none.
- **MA-4 nonlocal maintenance** — no remote maintenance path exists.
- **CM-2 baseline configuration** — the baseline is an executable procedure with parameters, not a document describing one.
- **SR supply chain provenance** — every package, snap and image entered through one audited path and its origin is recorded.

## And three it cannot satisfy without an AO decision

- **AU-4 / AU-5** — notification at 75% audit capacity, with no path for a notification to leave (Q26).
- **SC-13** — no CMVP certificates exist for 24.04; the posture is measured and strong, but the exception is argued, not evidenced (Q13/Q14/Q15).
- **CP-4** — until the contingency test is actually run, this control has no evidence of any kind.
