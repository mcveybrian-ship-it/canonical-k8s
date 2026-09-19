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
| **3.5** | **V-270747** data-at-rest write-up · ~~V-270719 PPSM~~ → moved to **6a.22** 2026-09-18 (it needs scans and a DISA list, so it is more than paperwork) | Paperwork against mechanisms that already exist | ⬜ open |
| **3.6** | **Make `esm-apps` consistent** across all eight | Enabled inconsistently; `esm-infra` too. It was entitled all along and simply never switched on | ⬜ open |
| **3.7** | **Root CA key custody** | A policy question, not a mechanism | ⬜ open · `ssp-inputs.md` §2.5 |
| **3.8** | **Retire or justify the second USB disk on host-4** | The old WD easystore (`sdb`, 4.5 T, LUKS) is still plugged in and unmounted. Either a free second copy or a USB device on the hypervisor for no reason | ⬜ open |
| **3.9** | **`ufw_rate_limit` now fails on host-1/2/3 — caused by adding monitoring, fixable** | Found 2026-09-19 rescan: USG 213/3 → **212/4** on all three; V1R6 unchanged at 171/9/9/5. Measured cause: **9100 (node-exporter) and 9177 (libvirt exporter) now listen** on the host address, added 2026-09-18, and their ufw rows are `allow`; the rule fails if ANY listening port is not `limit`. **Unlike 443 on the mirror, `limit` should be safe here:** the only permitted source is `svc-obs-01`, scraping every 15 s = ~2 connections per 30 s per port, well under ufw's 6-per-30 s threshold. Change the six host rows in `stig-tailor.sh` to `limit`, re-apply, **confirm all 15 Prometheus targets stay `up`**, rescan. Would take host-1/2/3 back to 213/3 | ⬜ open · small |
| **3.10** | **host-1/2/3 publish NO compliance facts** | Found 2026-09-19 by querying Prometheus: `enclave_facts_source_ok` exists for 10.2.20.158/161/162/163/164 only. host-1/2/3 got node-exporter and the libvirt exporter on 2026-09-18 but never `monitoring.sh facts-timer`, so the dashboard has no STIG tally, patch, cert-expiry, FIPS or AIDE facts for the three newest machines — and nothing said so. Also a prerequisite for 6a.22, which publishes listeners through the same timer | ⬜ open · one command per host |
| **3.11** | 🔴 **Root timers execute scripts `encadmin` can write — a sudo bypass** | Found 2026-09-19 before installing facts on host-1/2/3. Measured on host-4: `enclave-facts.service`, `enclave-vm-backup.service` and `enclave-vm-verify.service` run `/home/encadmin/canonical-k8s/scripts/enclave/{monitoring,vm-backup}.sh` **as root**, and those files are `encadmin:encadmin 770`. Anything able to write as `encadmin` gets root on the next timer tick — no password, no sudo audit record. Cause: `ExecStart=$HERE/...` (monitoring.sh:1706) and `ExecStart=${self}` (vm-backup.sh:1086-1126). Same code on every machine that has the timers. **Fix:** install a root-owned copy (`root:root`, not writable by anyone else) and point the units at it; refreshing it then needs sudo, which is the point. **Do not roll the timers out to more machines until fixed.** 🔄 **Fix written 2026-09-19:** new `scripts/enclave/install-runtime.sh` copies scripts/env/dashboards (never `*-params.env`) to `/usr/local/lib/enclave`, `root:root`, refuses a destination outside `/usr/local/lib`/`/opt` or under a non-root-writable parent, proves nothing in the copy is writable by non-root, and records the source commit in `.source`. `monitoring.sh facts-timer`, `vm-backup.sh schedule` and **`audit-volume.sh install`** (a third instance, found while fixing: hourly on svc-repo/harbor/obs) now call it and point their units at the copy. `harbor.service` checked and is fine (root-owned compose dir; encadmin not in `docker`). **Consequence: after every repo push, re-run the timer installer** — root keeps running the old copy until someone with sudo refreshes it | 🔄 fix written · needs re-install on all 8 |

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

## 6a. ⬜ STIG/SRG assessment — opened 2026-09-18

| | Item | Notes | Status |
|---|---|---|---|
| **6a.1** | 🔴 **cyber.mil download list — CAC required, next trip** | See the table below — it is short and two of the items now block real work | ⬜ **needs a CAC trip** |

### 🔴 6a.1 — cyber.mil download list (CAC-only) — verified 2026-09-18

Versions and the nginx/Harbor question were **looked up rather than guessed**; sources at the
bottom.

| # | File | Why | Blocks |
|---|---|---|---|
| ~~1~~ | ✅ **OBTAINED 2026-09-18 — `U_Kubernetes_V2R6_STIG.zip` (Manual, xccdf dated 12 Feb 2026).** ⚠️ **Correction:** this list said *"V2R5 confirmed current"* — wrong; **V2R6 is current.** Measured 2026-09-19: **92 rules (18 CAT I)** vs the SCAP benchmark's 61, which is still **V2R5**. Every SCAP rule is in the manual; **31 are manual-only and need hand review, 12 of them CAT I** — incl. kubelet anonymous auth off (V-242391), explicit kubelet authorisation (V-242392), readOnlyPort off (V-242387), Pod Security Admission (V-254800/254801), **Secrets encrypted at rest (V-274882)**, Secrets not in env vars (V-242415). Applicable-set 800-53 coverage **115 → 116**; **156 with ASD** | K8s build (2.5) — the manual-only CAT Is are design decisions to make **before** the cluster exists, not findings to fix after |
| ~~2~~ | ✅ **OBTAINED 2026-09-18 — `U_BIND_9-x_V3R3_STIG.zip`, 73 rules / 43 CCIs / 3 CAT I.** Adds **26** 800-53 controls to coverage, taking the applicable set from 109 to **115** | 🆕 **New requirement created 2026-09-18** by standing up `bind9` on `svc-mgmt-01`. **Evaluate-STIG ships NOTHING for BIND** — its only DNS content is `U_MS_Windows_Server_DNS_STIG`, which is Microsoft DNS. **A BIND 9.x STIG does exist; the V3 series is current (V3R3, 01 Jul 2026)** — take the latest, the filename pattern is `U_BIND_9-x_V<n>R<n>_STIG.zip` | A DNS server in the boundary with no benchmark is an unassessed component |
| ~~4~~ | ✅ **OBTAINED 2026-09-18 — CAL dated 01 Sep 2026, EXPIRES 15 Nov 2026.** Four files: `CAL_by_Port`/`CAL_by_Service` PDFs, `CAL_Excel_format` xlsx (the one the generator reads — sheets: CAL by Port/Service, Exceptions, **CLSA**, Temporary) and `CAL_Record_of_Changes`. ⚠️ The workbook says **do not distribute the Excel format outside PPSM CCB/TAG membership** — it stays in gitignored `stigs/`, and generated output quotes only rows matching our ports | ⏰ **re-download before 15 Nov 2026** | 6a.22 |
| **3** | ✅ **OBTAINED — `U_ASD_V6R4_STIG.zip`. 🔴 IN SCOPE, not held in reserve** | **286 rules / 225 CCIs / 34 CAT I** — the largest document in the set. **AO 2026-09-18, from prior experience: *"I know 100% I will have to do that one — a lot end up being not applicable but I still have to fill it out."*** So the deliverable is a **completed checklist with a defensible rationale on every row**, not an exclusion argument | ⬜ **286 rows to answer** |

#### How the 286 ASD rows get answered without writing 286 justifications

✅ **139 of 286 rules (49%) carry their own "not applicable" clause in DISA's CheckText.**
For those the rationale is **DISA's own words plus a statement that the condition holds** —
quotable, consistent, and generatable. That is the cheap half, and doing it by hand is how
286 rows end up with 286 slightly different wordings for an assessor to pick at.

The remaining 147 need judgement, but they **group**. Measured theme counts (rules can match
more than one — this is for grouping, not arithmetic): database/SQL **28**, no-locally-developed-
code/COTS **17**, source code and SDLC **17**, DoD PKI/certificates **14**, web service/API/SOAP
**8**, mobile code **2**.

**The plan: answer ~12 themes once each, then apply. Not 286 individual write-ups.**

⚠️ **Two themes will NOT be N/A and should be expected to bite:**
- **database/SQL (28)** — PostgreSQL 16 is real, and `pg-01..03` are being built. These
  overlap the Postgres 16 STIG and need reconciling, not waiving.
- **DoD PKI / certificates (14)** — same private-CA problem as everywhere else in this
  enclave. AO acceptance, not a technical answer.

❌ **A DNS SRG is NOT needed.** The only DISA "DNS STIG" is **V4R1.20 from 2017** and is
superseded by the BIND 9.x series. **A product STIG exists for our DNS server**, so the SRG
fallback does not apply — this is the opposite of the nginx situation.

✅ **CONFIRMED: no DISA STIG exists for nginx, Harbor, Grafana or Prometheus.** That is now a
checked fact rather than an assumption, which materially strengthens the applicability
determination — "we searched and there is none" is a far better sentence for an assessor than
"we assumed there wasn't". It validates assigning nginx to the **Web Server SRG** and
Harbor to the **Container Platform SRG** under each SRG's own "products for which STIGs do not
exist" clause.

✅ **Not needed:** Ubuntu 24.04 V1R6 ships with Evaluate-STIG. Ubuntu 22.04 V2R9 was downloaded
but is **not applicable** — this enclave runs 24.04.

**Sources:** [DoD STIG index](https://cyber.trackr.live/stig) ·
[BIND 9.x STIG](https://www.stigviewer.com/stigs/bind_9x) ·
[Kubernetes STIG V2R5 checklist](https://ncp.nist.gov/checklist/996) ·
[Cyber Exchange downloads](https://www.cyber.mil/stigs/downloads)
| **6a.2** | **The control baseline and overlay set** | The gap count is meaningless without it — the tool's 1,014 denominator is the whole 800-53 catalogue, not an IL5 baseline. **AO input; Brian is the AO for now.** Also what `ssp.md` is blocked on | 🔴 **blocks the gap number AND `ssp.md`** |
| **6a.3** | **Assess Container Platform SRG against `svc-harbor-01` NOW** | Not a future item. By the SRG's own definition (engine + registry + key-value store) **Harbor-under-Docker is already a container platform**, missing only the keystore. No Harbor STIG and no registry SRG exist, so this SRG **is** the instrument. ~140 rules after tailoring | ⬜ open |
| **6a.4** | **V-233201 — local cache of PKI revocation data** | ⚠️ **The air gap makes this MANDATORY and the hardest PKI rule in the set, not N/A.** With no OCSP reachability, CRLs must be couriered in on a defined cadence or every certificate validates against stale revocation state | ⬜ open · needs a cadence decision |
| **6a.5** | **V-233233 — registry images patched within 30 days** | Demands a **≤30-day sneakernet cadence, permanently**. Operationally the hardest requirement in the document for this enclave. Not waivable on air-gap grounds | ⬜ open · pairs with the weekly Trivy decision (§3.2) |
| **6a.6** | **V-278968 — is `docker.io` from Ubuntu universe "vendor supported"?** | CAT I. Whether Ubuntu Pro `esm-apps` coverage of `universe` satisfies "a version supported by the vendor" for a container runtime is a question for **Canonical and the AO**. Do not assert either way without a Canonical source | ⬜ open |

| **6a.7** | **pg-01..03 build must start from §9a.2a, not §9a.3** | Four traps found 2026-09-18 *before* the build: Patroni's default `md5` replication user is an **instant CAT I on all three nodes** (V-261892); V-261967 contradicts 25 other rules over `log_destination`; ~60 fixtexts tell you to edit files Patroni regenerates; and 13 filesystem checks point at **RHEL paths that do not exist on Ubuntu** | ⬜ **read before building** |
| ~~6a.8~~ | ✅ **RESOLVED 2026-09-18 by inspection.** `patroni` 3.2.2-2 and `python3-etcd` 0.4.5-4 downloaded from the mirror and read: **zero `hashlib` imports and zero `.md5()` calls outside test code.** The MD5-under-FIPS failure mode is not present. Also corrected a wrong CAT I claim — Patroni generates **`scram-sha-256`** for PG≥10, not `md5`. ⚠️ A real failover under FIPS is still owed as proof; static analysis lowered the risk, it did not test it | ✅ risk resolved · failover test still owed |
| **6a.9** | **Decide pgcrypto vs LUKS for Postgres at-rest, in writing** | V-261901/930/931 (two CAT I) name pgcrypto. **pgcrypto is not inside any FIPS validation boundary** and its `crypt()`/`gen_salt()` fail at runtime under FIPS OpenSSL. LUKS at the VM disk layer is the defensible answer — but the substitution has to be *stated*, not implied | ⬜ open |
| **6a.10** | **Author the Postgres org-defined baseline** | 27 of 111 rules compare against a site baseline — approved extensions, superusers, object owners, port, pinned package version, per-role connection limits. **This baseline is the real deliverable** and is the tailorable artifact that survives to the next engagement. Missing baseline MUST yield Not Reviewed, never NotAFinding — 27 chances for a hollow pass | ⬜ open |
| **6a.11** | **Record the Crunchy-vs-PGDG tailoring statement** | This is the **Crunchy Data** Postgres 16 STIG. If pg-01..03 run Ubuntu/PGDG Postgres, applicability is a tailoring decision and V-283674's "vendor supported" reads differently. Defensible either way — but it must be written down, not assumed | ⬜ open |

| **6a.12** | **Web Server SRG — ASSESS, against 3 machines in 2 profiles** | System nginx runs on **`svc-repo-01`, `svc-obs-01`, `svc-mgmt-01`**. ⚠️ `HANDOFF.md:377` lists only `svc-repo-01` — **wrong, understates scope by two machines**. `svc-harbor-01` has **no system nginx** (measured); Harbor serves TLS from bundled containers — appliance-internal, scope it in writing. Two profiles: *static file server* (`svc-repo-01`) vs *reverse proxy* (other two) — the cookie/proxy/HTTP2 rules are N/A on the first | ⬜ open |
| **6a.13** | **Three verified nginx findings** | Measured 2026-09-18, not inferred: **`server_tokens` off is commented out** — confirmed leaking `server: nginx/1.24.0 (Ubuntu)` (V-206412); **`ssl_session_timeout 1d`** where the rule requires ≤8h (V-206414); **`autoindex on`** on the mirror (V-206411) — a real trade-off, apt does not need it, human browsing does | ⬜ open · all trivial fixes |
| **6a.14** | **Two nginx items that are hygiene, NOT vulnerabilities** | ⚠️ Recorded so nobody re-raises them as urgent. `nginx.conf` ships `ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3` at `http{}` — but **TLS 1.0/1.1 do not negotiate**: every 443 block carries a `TLSv1.2 TLSv1.3` override AND the FIPS provider refuses them at the library level (both measured). Likewise **no `ssl_ciphers` is set**, yet the negotiated suite is `TLS_AES_256_GCM_SHA384` over TLS 1.3. Fix both as defence in depth — a future server block without the override would inherit the weak default — but they are not live exposure | ⬜ low priority |
| **6a.15** | **🔴 V-264363 has NO technical remedy** | HTTP/2 is required end to end, but **nginx cannot speak HTTP/2 to an upstream** — `proxy_pass` is HTTP/1.1 at best, `grpc_pass` is the only h2 path and does not apply. So the proxy machines **are** doing the downgrade the rule prohibits. The rule's own text opens the only door: CAT III if the rewritten request is validated against the HTTP/1.x spec. **Needs probe evidence, not assertion** — nginx 1.24's rejection of CL+TE and malformed request lines is unverified | ⬜ open · needs a documented mitigation |
| **6a.16** | **⚠️ V-206430 becomes unfixable the day mTLS is enabled** | The rule demands client certs from **DoD PKI**. The enclave CA is private. As written it **admits no compensating control** — it needs AO risk acceptance, not a config change. N/A today only because nginx authenticates nobody. **Flag to the AO before anyone turns on client-cert auth, not after** | ⬜ open · AO decision |
| **6a.17** | **Database SRG — EXCLUDE, carry a 34-rule delta** | 108 of its 142 requirements have a Postgres 16 STIG child — pure double-count. **34 have no child**, incl. 2 CAT I (V-206555 password complexity, V-206561 obscure auth feedback) and 21 Rev-5 additions (V-263602–263622). Assess the product STIG **plus the named delta**, which is the fallback rule applied exactly as written. Ready-to-use exclusion rationale drafted | ⬜ ready to write up |
| **6a.18** | **Application Server SRG — EXCLUDE outright** | Nothing in the enclave meets the SRG's definition (a runtime environment hosting organisationally developed code). Harbor → Container Platform SRG; Grafana → Web Server SRG; nginx → Web Server SRG. ⚠️ **But see 6a.19 — do not let the exclusion drop an orphan control** | ⬜ ready to write up |
| **6a.19** | **🔴 CCI-000174 / AU-12(1) is covered by NOTHING else** | Time-correlated, system-wide audit aggregation appears **only** in the Application Server SRG (V-204716) — in no other guide we hold. It lands squarely on the open audit-offload thread. **Assess AU-12(1) as an RMF control at system level** in the SSP rather than importing 137 rules to catch one. Same treatment for CCI-002363 (AC-12(1)) and CCI-002169 (AC-3(7)) | ⬜ **do not lose this in the exclusion** |
| ~~6a.20~~ | ✅ **DECIDED BY THE AO 2026-09-18 — community PostgreSQL, tailored Crunchy STIG.** Condition verified: `postgresql-16` is in Ubuntu **main** (no licensing, Canonical-supported to 2036 under ESM) and depends on `libssl3t64`, so it inherits the FIPS provider structurally. pgaudit and patroni available from the mirror under `esm-apps`. Assess 111 tailored rules + the 34-rule Database SRG delta. Tailoring written up front in `ssp-inputs.md` §4.1g | ✅ done |
| **6a.21** | **ASD target is a COTS application — re-weigh the answers before filling them** | ⏸️ **Parked 2026-09-18 by Brian to finish later.** Read from DISA's own `U_ASD_V6R4_Overview.pdf` §1.1, not assumed: **COTS does NOT exempt** — *"This guide is to be used for in-house application development and to assist in the evaluation of the security of COTS/GOTS/OSS products and any other third-party applications."* What it changes is **who answers**: *"Answers to some questions will need to be gathered through discussions with vendor representatives or from public information about the company."* Measured in the XCCDF: **15 rules name COTS/vendor/third-party; 37 are about the development process** (code review, SDLC, scanning) — those become a **vendor questionnaire**, not N/A. Only **2** rules give COTS a carve-out: APSC-DV-003236 (N/A if the dev team is not accessible) and 001995 (N/A if the vendor will not provide code-review results). ⚠️ **Two CAT I rules get harder, not easier:** APSC-DV-003240/003250 need proof every component is vendor-supported. ⚠️ **APSC-DV-003080 is a likely finding** — backup copy of the software stored offsite or fire-rated; every copy is in one room (§1.3). ⚠️ **The example at the top of `asd-answers.md` (*"no locally developed application; vendor products only"*) is the wrong framing** — the ASD target is the COTS mission application, not "nothing"; platform components stay under their product STIGs/SRGs per Overview §1.1. **To do:** name the application and vendor, add an *answered-by* (system owner / vendor) split to `asd-triage.py`, fix the header example, draft the vendor questionnaire. 🆕 **Prior JITC checklist found 2026-09-18** — `docs/compliance/stigs/CAD MAP App Sec Dev STIG.cklb` (gitignored; **OMNI CAD/MAP**, ASD **V6R3**; same 286 rule IDs as V6R4, 6 check texts changed: 000110/120/130, 002330, 002900, 003120). JITC result: NaF 73 · NA 109 · Open 33 · NR 71. **Reusable as evidence: only 47 rows** have text about the application itself. **19 NaF/NA rationales rest on JITC's platform** (RKE2/Rancher, Active Directory, Ubuntu 20.04 CAC, FIPS 140-2 cert numbers, Bitnami Postgres, RAE-Syslog) and must be rewritten for ours — ⚠️ several may **flip to Open** here, because this enclave has no AD and no CAC yet. 211 rows are status-only with no rationale; 9 are drafts ("?????"). **The 33 Opens are mostly application behaviour** (8 CAT I: password length/storage, session destroy, command/SQL/input injection, overflow, default passwords) — controlling the host does not close those; they go to the vendor. Of the Opens, the ones the host/organisation *can* own: 003320 DoS, 000950 destination-IP logging, 001430 unsigned patches, 001480 program execution, 003130/003160 test procedures, 003260/003340 notifications. ⚠️ Confirm the application **version** matches what JITC assessed before reusing any application-side row. 🆕 **ON THE DoDIN APL (read 2026-09-19 from `DoDIN APL Report_18-Sep-2026.pdf`): MicroAutomation, Inc. — Omni911 4.1 — TN 2404602 — effective 15-Oct-2025, expires 15-Oct-2028 — sponsor OSD — Customer Premises Equipment.** That changes the ASD posture: the vendor has been through DISA APL testing, the JITC V6R3 checklist (May 2025) is Brian's own work — he did the JITC assessment **together with the vendor** (he is not MicroAutomation), five months before the listing, and APSC-DV-003240/003250 "vendor supported" has a DoD record behind it. **Deploy 4.1 or the listing does not cover us.** The platform products (Ubuntu, Canonical K8s, Postgres, Harbor) are not on the APL — it lists 169 network/UC/security devices, not general-purpose software, so absence there is not a finding | ⏸️ parked · Brian |
| **6a.22** | **PPSM — ports, protocols and services: scan, then generate the CLSA** | Requested 2026-09-18 as part of the security-posture paperwork. **The artifact has a name:** V-270719 asks for the *"PPSM Components Local Services Assessment (CLSA)"* and fails anything *"prohibited by the PPSM CAL"*. DoDI 8551.01 (31 May 2023) requires PPS used *"internal or external to the enclave"* to be declared; PPS confined to the enclave get a CLSA instead of a DISN vulnerability assessment. **Method, all from what exists:** (1) `ss -tulpnH` on every machine is the authoritative listener list, TCP **and UDP**, including bind address and owning process; (2) `nmap` from `svc-obs-01` proves what is actually reachable. **nmap 7.94 is already in the mirror** (universe, so `esm-apps`); (3) join both with the `stig-tailor.sh` ufw table, where **every allowed port already carries a justification** (tab-separated: machine · port/proto · action · source · reason); (4) join with the CAL to mark each row *on the CAL* / *not on the CAL, needs approval*. **Output is generated, never typed**, per baseline README rule 2: `docs/compliance/baseline/ppsm-clsa.md`. ⚠️ **The CAL is a CAC download from cyber.mil**. Listed as 6a.1 #4; its file format is unknown until you have it. ⚠️ Listening-but-unjustified and justified-but-not-listening are both findings to report, not tidy away. Also feeds ASD APSC-DV-001510/002990 and closes POA&M ENG-53 🆕 **CAL read 2026-09-19. The answer for an enclave-internal system:** at boundaries 09–16 (enclave-side) **every CAL and CLSA entry reads `AO`** — approval is the AO's, not DISA's; the YELLOW/GREEN/RED colours apply only at DISN boundaries 07/08, which the air gap never crosses. **Match by SERVICE, not port** — wide-range entries (e.g. ORACLE-OCR) cover thousands of ports and give false hits. By name: SSH, DNS, NTP, HTTPS, `PGDG-POSTGRESQL-DB` 5432 and `KUBERNETES-KUBELET-API` 10250 are **on the CAL**; Prometheus, node-exporter, Alertmanager, Grafana :3000, etcd, Patroni, Harbor, libvirt, Ceph are **NOT** — they appear only as *other organisations' CLSA entries* (e.g. DLA-GRAFANA 3000/tcp), which is the precedent: **we write our own CLSA rows and the AO approves them.** ⚠️ **DESIGN CONSTRAINT (Brian, 2026-09-19: *"how will we run onsite"*):** it must run **entirely inside the gap** — scan, collect and generate from an in-gap machine (`svc-obs-01` is the natural home: collector and nmap vantage), CAL carried in with the transfer bundle. **`stage-01` may be a lab convenience, never a dependency** — it is outside the boundary and unplugged at cutover. A first design that rode on `stig-tools.sh collect` was stopped for exactly this reason | ⏸️ **waiting by decision 2026-09-19 — build to the constraint** |
| **6a.23** | **CAC/PIV access — plan drawn up 2026-09-18** | **In scope per Brian 2026-09-18** (*"at DISA we had to make CAC access work"*). That answers open-questions CAC item (a). Closes the five-control smart-card family (V-270663/735/736/722/745, incl. the **only HIGH left**), and turns 6a.16 from risk acceptance into a fix. Everything is in the mirror: `sssd` 2.9.4, `libpam-sss`, `sssd-ldap`, `opensc`/`opensc-pkcs11`, `pcscd`, `libccid`, `slapd` 2.6.10, `389-ds-base`. USB lockdown blocks **storage only** (`usb-storage`/`uas`), so CCID readers work. **Open decisions: D1** identity source: local users + SSSD certmap (Canonical-documented, but V-270736's check literally greps `ldap_user_certificate`, so it becomes a documented deviation) **vs** an in-enclave LDAP directory (closes the HIGH as written, adds a component to assess). **D2** trust anchors are a *facility parameter*: DoD roots for CAC, Federal PKI for PIV. **D3** CRL carry-in cadence, shared with 6a.4. **D4** an in-gap admin workstation with a reader. None exists today (POA&M ENG-54). ⚠️ **`docs/compliance/stigs/UbuntuRootCertInstaller.docx` checked 2026-09-18: DO NOT USE.** Measured against the real v5.14 bundle: its `*.pem` glob selects only `DoD_PKE_CA_chain.pem` (Root CA 6 + DOD EMAIL CA-73, the code-signing chain), skipping all 49 certs in the `.p7b` files, so Root CA 3/4/5 and every issuing CA are missing; `openssl rehash` skips that file (*"does not contain exactly one certificate"*); it downloads inside the gap; it skips the bundle signature check the README requires; it still prints Success and would **hollow-pass V-270745**. **Brian is modifying it himself (2026-09-19)**. Do not build a competing `ca.sh` subcommand; review his version against these points when he brings it back. Phases and detail: see the plan when written into runbook §10.1d | ⬜ **4 decisions, then build** |

| **6a.24** | **STIG evidence collection depends on `stage-01` — it has no onsite home** | Found 2026-09-19 while designing 6a.22. `stig-tools.sh collect` pulls every machine's results to `stage-01` using the `build01` key; it only *warns* when run elsewhere. Onsite there is no `stage-01`, so scan evidence would stay scattered on the machines that produced it — the 2026-09-14 problem again. Needs an in-gap evidence home (likely `svc-obs-01`), a key that exists inside the gap, and the same design shared with 6a.22 | ⬜ open · decide with 6a.22 |

⚠️ **Do not over-claim air-gap N/A.** Of 188 Container Platform SRG rules, only **8** are genuinely not applicable. The air gap changes *how* the rest are satisfied, not *whether* they apply — and 6a.4 is the clearest case of a rule that gets **harder**, not waived.

## 6b. ✅ MAAS removed 2026-09-18 — what it cost and what it left

**Open listeners on `svc-mgmt-01`: 76 → 21.** Remaining ports are `22 25 53 80 123 323 443 5432
8484 9100` — ssh, postfix (loopback), DNS, nginx redirect, time, TLS, postgres, the Pro contract
server, node-exporter. 13 packages and 10 services gone.

✅ **Ubuntu Pro survived**, which was the gate: `pro refresh` succeeded with MAAS fully down, and
`esm-apps`, `fips-updates` and `usg` stayed enabled. The contract server is independent of MAAS.

| | Item | Status |
|---|---|---|
| **6b.1** | ⚠️ **`autoremove` took `bind9` with MAAS** — its only reverse-deps were MAAS packages. `named.service` reported `Loaded: not-found`, which reads like a broken config and is a missing package. Zone files in `/etc/bind/enclave/` survived; reinstall + `zone-install` is the recovery. **`apt-mark manual bind9` before the purge on a rebuild** | ✅ recorded in runbook §9a.4 |
| **6b.1a** | ✅ **Enclave DNS is up on `svc-mgmt-01`, verified from host-4.** Forward, reverse and the `*.apps` wildcard all answer; out-of-zone names return **NXDOMAIN in 147 ms**. Zones render from the same `MAP` in `apply-addresses.sh` that writes `/etc/hosts` — one table, two renderers | ✅ done |
| **6b.1b** | ⚠️ **NOTHING points at it yet, and that is deliberate.** No `DNS=` on any machine; resolution is still `/etc/hosts` only. Pointing resolvers at `10.2.20.161` is a separate reversible step and is what makes `*.apps` and CoreDNS forwarding actually work | ⬜ **next DNS step** |
| ~~6b.1c~~ | ✅ **ALREADY FIXED 2026-09-03 — the note was stale, not the file.** `airgapped-contracts.yaml` carries 4 `.internal` references and zero `.local` in both staged copies, verified without printing it (it is a credential). Decisive evidence: the config's `aptURL` entries are what `pro` writes into client sources, and host-4's sources read `svc-repo-01.enclave.internal`. Runbook §9a.4 corrected | ✅ done |
| **6b.1d** | ✅ **Resolvers pointed at the enclave DNS — all 8 machines.** `DNS=10.2.20.161`, hosts-file names still resolve, the `*.apps` wildcard now resolves **via DNS**, outside names return nothing. ⚠️ **`svc-repo-01` carries its own FQDN on the `127.0.1.1` line**, so its own name resolves to loopback there — the only machine of eight. Benign (TLS validates on the NAME, not the address; apt works) and **not auto-fixed**: that line is outside the managed block. `apply-addresses.sh apply` now warns when it sees it | ✅ done · one cosmetic outlier |
| **6b.2** | **`postgresql@16-main` still installed on `svc-mgmt-01`** — it was MAAS's database. Confirm nothing else uses it, then remove. Until then it is an unassessed database in the boundary | ⬜ open |
| **6b.3** | **Two pre-existing failed units on `svc-mgmt-01`** — `openipmi` (no `/dev/ipmi0` on a VM) and `sssd` (no configured domains). Not MAAS's doing. `stig-tailor.sh fixups --apply` clears both via item 0b | ⬜ open |
| **6b.4** | **None of the four service VMs has today's `fixups`** — including item 2c, the logrotate `create` fix. They will re-open V-270756 on their next rotation exactly as the hosts would have | ⬜ open |
| **6b.5** | **`esm-infra` is disabled on host-4** — visible in the `pro status` from the gate check. Known inconsistency, see §3.6 | ⬜ open |

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
