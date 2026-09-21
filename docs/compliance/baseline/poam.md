# Plan of Action and Milestones — «SYSTEM_NAME» («SYSTEM_ACRONYM»)

| | |
|---|---|
| System | «SYSTEM_NAME» («SYSTEM_ACRONYM») |
| System identifier | «SYSTEM_ID» |
| System owner | «SYSTEM_OWNER» |
| Impact level | IL5 |
| Control baseline | «800-53 Rev 5 High or Moderate» |
| Overlays | «CUI or NSS or Privacy or none» |
| Authorizing Official | «AO_NAME» |
| ISSM | «ISSM_NAME» |
| ISSO | «ISSO_NAME» |
| Prepared by | «PREPARED_BY» |
| Document version | 0.1 draft |
| Document date | «YYYY-MM-DD» |
| Submission system | «eMASS or Xacta or other» |
| Review cadence | «how often the POA&M is reviewed and re-submitted» |
| Risk acceptance authority | «who signs a risk acceptance» |

---

## 1. Purpose

This register lists every known unmet or unverified security requirement in the enclave, with
its source, its risk, what is being done about it, who owns it and when it closes. It is
maintained under CA-5.

Two things make this register unusual, and both are deliberate.

**Every row traces to a file, a command or a dated measurement.** Nothing here is an
impression. Where a row rests on a measurement, the measurement's date is in the row, because
a finding without a date cannot be re-verified and will be restated wrongly six months later.

**Nothing has been left out because it is uncomfortable.** The register names the two
weaknesses most likely to end an authorization conversation — that no contingency test of any
kind has ever been run, and that no CMVP certificate exists for the operating system — in the
same format as everything else. A package loses credibility by omitting what an assessor then
finds on their own.

## 2. How this register is organised, and why the grouping is the point

Rows are grouped by **who can close them**, not by control family and not by severity.

| Group | Meaning | What the programme does with it |
|---|---|---|
| **ENG** | An engineering task inside the boundary | Schedule it. No external input needed |
| **AO** | Blocked on an Authorizing Official decision | Put it in the AO thread. Engineering cannot close it by working harder |
| **CUST** | Blocked on a customer, programme or vendor input | Ask for it. It is a question, not a defect |

Grouping by control family produces a register where an item needing a signature sits beside
an item needing a script, and both look equally actionable. They are not. **An AO row worked
by an engineer is wasted effort, and an engineering row sent to the AO is a delay dressed up
as governance.** The three groups are three different work queues with three different
turnaround times, and separating them is the most useful thing this document does.

Control identifiers below are **suggested NIST 800-53 Rev 5 mappings** offered to help
whoever drafts the SSP find the right section. They are not authoritative; the baseline named
above governs. Where a mapping could not be inferred without guessing, the cell is blank.

## 3. Risk scale

| Rating | Meaning in this register |
|---|---|
| **High** | Could prevent or condition an authorization decision, or could cause unrecoverable data loss |
| **Moderate** | A real control gap with a compensating measure, or a defect that degrades assurance |
| **Low** | Consistency, hygiene or documentation; no plausible path to compromise or loss today |

Risk is stated for the residual condition **as it exists**, not for the condition after the
mitigation. That is what makes the mitigation column meaningful.

---

## 4. Group ENG — engineering tasks owned inside the boundary

### 4.1 Recovery and contingency

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| ENG-01 | `ato-package.md` §1, `nist-800-53-plan.md` CP, `contingency-plan.md` §9.2 | 🔄 **PARTIALLY SATISFIED 2026-09-20 — the guest-restore half has been performed.** All four service guests were rebuilt from a five-set chain and booted, checksums verified, `qemu-img check` passed: svc-obs-01 56 s · svc-harbor-01 1 m 43 s · svc-mgmt-01 3 m 34 s · **svc-repo-01 1 h 11 m** (332 GB). Evidence: `/srv/stig-evidence/restore-test-*.txt` on host-4, mechanism `vm-backup.sh restore-test`. ⚠️ **Two findings came out of it:** the sets held no domain definition (a restore onto a rebuilt host meant hand-writing the XML — now captured in every set), and reassembling an incremental chain was undocumented. ⚠️ **The sets restored predate the definition fix, so the test leaned on the live domain; re-test against a set that contains it.** **STILL OWED: the host-failure rehearsal, database failover and the Ceph degraded exercise.** One passing test is not a tested plan | CP-4 | **High** | Run the host-failure rehearsal (runbook §10) and time it; re-run `restore-test` against a post-fix set. Record what happened, including failures | «OWNER» | «TARGET_DATE» |
| ENG-02 | runbook §9a.1 correction 1 | **Both recovery paths terminate on `host-4`.** Whole-VM backups land on `/mnt/vmbackup` on `host-4`; the proposed WAL archive destination is also on `host-4`. Two mechanisms, not two independent paths | CP-6, CP-9 | **High** | Move one path off `host-4`. Until then state the limitation in the SSP as its own sentence rather than inside the site-event caveat | «OWNER» | «TARGET_DATE» |
| ENG-03 | runbook §10b "Still open" | **The backup destination is an encrypted USB volume attached to the same machine that runs every guest.** A backup written there survives a bad upgrade and not the event backups exist for | CP-6, CP-9 | **High** | The destination is already a parameter (`BACKUP_DEST` in `vm-specs.env`). Production needs storage that survives `host-4` — iSCSI or NFS, which also removes the `usb_storage` / `uas` blocklist exception entirely (runbook §6.3g) | «OWNER» | «TARGET_DATE» |
| ENG-04 | runbook §9a.3 step 4 | **WAL archiving for the PostgreSQL cluster is undecided and unbuilt** — destination and tool both. Without it, restoring a guest from 02:00 loses everything since 02:00 | CP-9, CP-10 | Moderate | `pgbackrest 2.50-1build2` is already in the gap (measured 2026-09-17 against the mirror). Choose a destination that is not a database host, and not `host-4` if ENG-02 is to close | «OWNER» | «TARGET_DATE» |
| ENG-05 | runbook §9a.3 step 6 | **No PostgreSQL failover has ever been exercised.** This design exists because an untested failover already lost a database once | CP-4, CP-10 | **High** | `patronictl switchover` for the planned case, then stop the leader's guest with `vm-power.sh guests-down --only pg-01` and time the promotion | «OWNER» | «TARGET_DATE» |
| ENG-06 | runbook §9a.1 correction 2, §9a.3 | **The synchronous-replication degradation alert is owed.** `synchronous_mode_strict` is deliberately off, so losing every standby silently degrades the primary to asynchronous — the exact condition that lost the previous database. The choice is only defensible because an alert catches it | CP-10, SI-4 | **High** | A Prometheus rule against Patroni's `/metrics`, catching the degradation inside 15 minutes. It is the thing that makes the `strict=off` decision defensible, and it does not exist yet | «OWNER» | «TARGET_DATE» |
| ENG-07 | `ssp-inputs.md` §2.1a, `docs/02-host-install.md` §4c | **There is no remote recovery path of any kind.** `host-1..3` have **no BMC** (confirmed 2026-09-17 — budget test hardware, no management port), and `host-4`'s LUKS root prompts at the console. Either alone is survivable; **together they remove remote recovery entirely** — you cannot unlock the machine and you cannot even watch it fail | CP-10, MA-4 | **High** | Two BOM requirements follow, cheap at purchase and expensive to retrofit — see CUST-14. **State both halves of MA-4 in the SSP:** "no nonlocal maintenance capability" is simultaneously a strong control statement and this risk, and an assessor who reads only the favourable half will find the other | «OWNER» | «TARGET_DATE» |

### 4.2 Assessment coverage

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| ENG-10 | HANDOFF §3a matrix, `backlog.md` 6a.12/6a.13 | **nginx on `svc-repo-01` has no product STIG.** Per the locked 2026-09-13 decision the enclave assesses against the governing **Web Server SRG** rather than recording an absence. 🔄 **OBTAINED — `U_Web_Server_V4R5_SRG.zip` is in `docs/compliance/stigs/`, and three of its rules were read from the XCCDF and remediated 2026-09-21:** SV-206414 (session timeout 1d → 8h, the rule says "eight hours or less"), SV-206411 (directory listings replaced by a default page in every document directory — DISA's fix text, not merely `autoindex off`), SV-206412 **partial** (`server_tokens off` drops the version and OS; nginx cannot drop the product name without the unmirrored `headers-more` module). **STILL OWED: the full assessment** across the three nginx machines in two profiles (mirror vs reverse proxy), loaded through `StigContent/Manual/`, and the write-up | CA-2, CM-6 | Moderate | Assess all three machines against the SRG and record the result; the three rules above are done | «OWNER» | «TARGET_DATE» |
| ENG-11 | HANDOFF §3a matrix | **Docker CE on `svc-harbor-01` has no applicable STIG.** The Docker Enterprise 2.x STIG does not apply to CE; the fallback is the **Container Platform SRG**, not yet obtained | CA-2, CM-6 | Moderate | Same mechanism as ENG-10 | «OWNER» | «TARGET_DATE» |
| ENG-12 | HANDOFF §3a matrix | **PostgreSQL 18.3 inside `goharbor/harbor-db:v2.15.2` is covered by no STIG.** Measured 2026-09-16: `svc-harbor-01` has **zero** PostgreSQL packages visible to `dpkg`, so the database is invisible to the scanner and outside the evidence chain entirely | CA-2, SA-22 | Moderate | Decision plus write-up: accept 18.3 against the **Database SRG** with a written rationale, or pin Harbor to an image whose bundled Postgres is in STIG range — which is a Harbor upgrade decision, not a configuration change | «OWNER» | «TARGET_DATE» |
| ENG-13 | HANDOFF §3a matrix | **The Kubernetes cluster is not built and its STIG work is not started.** Canonical publishes a mapping of **91 guidelines** — 62 Default, 13 Bootstrap, 10 Post-Deployment, 6 N/A. The audit is **manual**, and the 13 Bootstrap guidelines must be correct **at cluster creation**; getting them wrong means rebuilding the cluster | CA-2, CM-6 | **High** | Read Canonical's mapping **before** step 06, not after. Plan the 13 Bootstrap guidelines into the bootstrap configuration | «OWNER» | «TARGET_DATE» |
| ENG-14 | `airgapped-setup-machine/README.md` §0a item 2 | **One Evaluate-STIG re-scan is owed on `host-4`.** Its last V1R6 scan (2026-09-16, NF=168 / Open=5 / NR=11) predates three changes: the `/mnt/vmbackup` AIDE exclusion, the new V-270817 answer, and confirmation that V-270682 stays closed | CA-2, CA-7 | Low | One 9–15 minute scan. Until it runs, four of 2026-09-16's changes are claims rather than results | «OWNER» | «TARGET_DATE» |
| ENG-15 | `airgapped-setup-machine/README.md` §0a E3c | **`svc-harbor-01` has never had a full Evaluate-STIG V1R6 scan retrofitted** after the tooling landed. The tooling is in place and V-270675 was verified `NF` there, but the full run has not been done | CA-2 | Low | One scan. It is also the second data point on whether the residual converges to the same set across dissimilar machines | «OWNER» | «TARGET_DATE» |
| ENG-16 | `airgapped-setup-machine/README.md` §0a item 4 | **Four Not Reviewed controls are engineering work, not policy:** V-270651 AIDE configuration integrity (needs the pristine `aide-common` .deb), V-270747 data-at-rest write-up, V-270719 PPSM, V-270754 the ufw 443 rate-limit decision | CA-2, CM-6 | Moderate | Each is a discrete task. **V-270754 is classified inconsistently in the source documents** — see §8 note 3 | «OWNER» | «TARGET_DATE» |
| ENG-17 | runbook §10.1d, README §0a E3b | **Reboot verification is owed for V-270757** (journal directory permissions, closed by a `tmpfiles` drop-in) and **V-274870** (an audit rule that needs a reboot to take effect) | CA-2, AU-12 | Low | Batch both into the next planned `host-4` reboot; verify after, not before | «OWNER» | «TARGET_DATE» |

### 4.3 Configuration and integrity

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| ENG-20 | HANDOFF §3, `ssp-inputs.md` §4.4 | **The GRUB `--unrestricted` state is a state, not a property, and can revert silently.** It lives in `/etc/grub.d/10_linux`, a package-managed file. A `grub-common` update or a `usg fix` re-run can replace it, after which the generated `grub.cfg` demands a password to **boot** — on hosts whose LUKS root already stops at a console | CM-6 | Moderate | `stig-tailor.sh grubpw status` belongs in **post-patch** verification, not only post-hardening. Measured safe on `host-4` 2026-09-17: `--unrestricted` at `10_linux:34`, 1 `superusers`, 1 `password_pbkdf2`, `unrestricted=5` in the generated config | «OWNER» | «TARGET_DATE» |
| ENG-21 | HANDOFF §3, `ssp-inputs.md` §4.3 | **`esm-infra` is enabled inconsistently.** `host-4` has `esm-apps` enabled and `esm-infra` **disabled**; `svc-mgmt-01` has both (measured 2026-09-17). Harmless today because `main` carries standard security updates until 2029, and real at the support boundary or sooner if a package moves pockets | SI-2 | Low | Enable `esm-infra` on `host-4` and audit the remaining machines for consistency. Fix for consistency, not urgency | «OWNER» | «TARGET_DATE» |
| ENG-22 | `ssp-inputs.md` §4.1, runbook §6.3g | **Two USB `DISABLE` events are logged `INCOMPLETE - module still loaded`**, so `kernel_module_usb-storage_disabled` fails on `host-4` until the next reboot. The block file is restored and the control's own CheckText passes; the module stays resident because a mounted filesystem holds a reference | MP-7, AC-19 | Low | Accepted as designed behaviour of a time-boxed window. Permanently removed by a non-USB backup target (ENG-03), which is worth more to the package than the throughput is | «OWNER» | «TARGET_DATE» |
| ENG-23 | `open-questions.md` backlog | **Parameter files do not travel and nothing detects the drift.** `push-repo-to-host.sh` sends only files tracked at HEAD, so every machine keeps its own copy of every `*-params.env` and they diverge silently. Observed 2026-09-04: `build-01`'s `transfer-params.env` kept a stale `STAGE_HOST` and nothing reported it for two days | CM-2, CM-6 | Moderate | The real fix is deriving addresses from `enclave-addresses.env` at run time so they cannot disagree, not a `--check` mode that relies on somebody running it | «OWNER» | «TARGET_DATE» |
| ENG-24 | `open-questions.md` backlog | **`docs/airgap-media.md` §6.1a is wrong for `host-4`.** It says to verify the transfer disk by serial; the USB enclosure reports `SERIAL 0000000000000000` there and the check silently finds nothing. `host-4`'s own OS disk is the **same model** (WD SN550), so a destructive command keyed on model would hit the wrong disk | CM-6, MP-6 | Moderate | Rewrite §6.1a to key on `LABEL=enclave-xfer` and to state that a serial check can return nothing rather than failing loudly | «OWNER» | «TARGET_DATE» |
| ENG-25 | `ssp-inputs.md` §6 | **`runbook.md` §2.3 still instructs `sudo pro enable fips-preview`** and calls it "the stream the decision rests on". That was superseded: `fips-preview` is unavailable on 24.04 (Q11) and the stream is `fips-updates`. Following the instruction as written enables the wrong stream | CM-6, SC-13 | Moderate | Correct the runbook text. It is exactly the class of error the SSP-inputs register exists to surface — a claim repeated in a document long after the fact changed | «OWNER» | «TARGET_DATE» |
| ENG-26 | `open-questions.md` backlog | **Secure Boot is disabled on the enclave VMs** (`VM_SECURE_BOOT='false'`). Under the Microsoft-keys firmware, `svc-mgmt-01` reached GRUB and stopped with `error: prohibited by secure boot policy`, then booted to a login prompt with cloud-init never having run — a silent half-boot | CM-6, SI-7 | Moderate | Recorded as a **deferral, not a decision**. Revisit at step 05: identify which component the policy rejects, and whether the shipped signed shim/GRUB chain works under different settings. **It is no longer only a hardening nicety:** per runbook §6.3i.1 and `ssp-inputs.md` §2.1a, Secure Boot is a **prerequisite** for TPM-sealed unattended unlock, so it has to be settled before production hardware is specified rather than deferred past it | «OWNER» | «TARGET_DATE» |
| ENG-27 | `open-questions.md` backlog | **Guest SSH access depends on the compose host's incidental state.** `03-compose-vm.sh` defaults `VM_SSH_KEYS` to the invoking user's `authorized_keys`, so a guest trusts whatever the *host* happened to trust at compose time. Found 2026-09-03 when an operator's own key was silently absent from every VM | AC-3, CM-6 | Low | Make `VM_SSH_KEYS` an explicit list in `vm-specs.env`, and have the composer report **which** keys it installs, not how many | «OWNER» | «TARGET_DATE» |
| ~~ENG-28~~ | `ssp-inputs.md` §4.1h | ✅ **CLOSED 2026-09-18 — resolved by removing the cause, not by root-causing it.** MAAS invoked `machine-resources` ~1.7 times per second on `svc-mgmt-01` — 231,159 invocations in 38 hours, each a sudo session and an audit record, producing 5 GB/day of syslog and driving V-270816 to fail there. The invocation rate was never explained; all three MAAS services were `active` with zero restarts. **MAAS was removed from the boundary entirely by AO decision** (it does not run under FIPS, and its only documented purpose here was unreachable), which eliminates the finding at source. Open listeners on that machine went **76 → 21** | AU-4, SI-4 | Moderate | ✅ Closed by elimination. ⚠️ **If MAAS ever returns to the boundary, this finding returns with it and the root cause is still unknown** | — | 2026-09-18 |

### 4.4 PKI and cryptographic key management

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| ENG-30 | runbook §2.9b, backlog item 9 | **No Certificate Policy / Certification Practice Statement exists.** "Internal PKI with documented key management" is what makes a two-tier private CA defensible rather than self-signed with extra steps, and the document is the *documented* part | SC-12, SC-17 | Moderate | Most of the content is already written in runbook §2.9b and needs assembling rather than inventing: key generation and custody, issuance authority, lifetimes, revocation position, recovery procedure | «OWNER» | «TARGET_DATE» |
| ENG-31 | runbook §2.9b, backlog item 6 | **The issuing CA carries `pathlen:0` but no `nameConstraints`** — it can sign a certificate for any name in the world, not only `*.enclave.internal`. A stolen issuing key is therefore unbounded in scope | SC-12 | Moderate | `CA_NAME_CONSTRAINTS` is already a parameter and the mechanism is built but untested, because it needs the issuing CA re-signed. **Cheap now, expensive once more leaves exist** — fold it into the single re-issuance event with `CA_CRL_URL` | «OWNER» | «TARGET_DATE» |
| ENG-32 | runbook §2.9b, backlog item 5 | **`CA_LEAF_DAYS=365` is a default nobody chose.** 365 with a calendar reminder is a decision; 365 by default is not | SC-12 | Low | Decide it, and record the reasoning. Note where practice is heading: CA/Browser Forum SC-081v3 takes public TLS lifetimes to 200 days (2026-03-15), 100 (2027-03-15) and 47 (2029-03-15). A private CA is not bound by the Baseline Requirements, but tooling and assessor expectation follow them | «OWNER» | «TARGET_DATE» |
| ENG-33 | runbook §9a.3 | **The `--peer` EKU fix has only been proven against a scratch CA, not the real issuing CA.** etcd peer TLS is mutual and needs `serverAuth` **and** `clientAuth` in one certificate; `ca.sh` previously hardcoded `serverAuth` in all three places it set an EKU | SC-12, SC-8 | Moderate | Re-prove on the real issuing CA before etcd is built: `openssl x509 -noout -ext extendedKeyUsage,subjectAltName`. Related hazard already closed: an extfile carrying `subjectAltName` silently overrode the CSR's, producing a valid correctly-signed certificate **for the wrong host** with no error | «OWNER» | «TARGET_DATE» |
| ENG-34 | runbook §2.9, backlog item 1 | **The external PKI round trip has never been run.** `ca.sh request --profile dod-pki` emits a conformant CSR and prints the external-authority path, and the local half works. A CSR going out to a real Registration Authority and a certificate coming back has not been tested | SC-12, SC-17 | Moderate | Test it once against whatever RA the site uses, before a site depends on it | «OWNER» | «TARGET_DATE» |
| ENG-35 | runbook §2.9, backlog item 8 | **How container runtimes trust Harbor is undesigned.** `containerd` on every node needs the enclave root before it can pull from a TLS registry, and it does not read the system trust store the way `curl` does. This is the CA-before-apt ordering problem in a different costume, and it has already bitten twice | SC-8, CM-6 | Moderate | Settle before step 06. It is a cluster-bootstrap input, not a post-deployment fix | «OWNER» | «TARGET_DATE» |

### 4.5 Vulnerability management

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| ENG-40 | `open-questions.md` Q27, `dashboards-and-metrics.md` §4c | **Trivy's vulnerability database is expired and cannot be updated from inside the gap.** Measured 2026-09-15: built upstream **2026-09-08 07:08Z**, downloaded **2026-09-08 18:49Z**, Trivy's own `NextUpdate` was **2026-09-09 07:08Z**. It gets one day staler per day, and Harbor keeps reporting images clean — so a stale database and a clean image are indistinguishable from the portal | RA-5, SI-2 | **High** | `trivy-db` is an OCI artifact and can be mirrored into Harbor itself, the same pattern as the apt mirror, which turns this into a transfer-bundle item with a measurable age. **The adapter knob is unverified on this Harbor version.** Until then, quote every Harbor result with the database date beside it. The three scanners that do **not** use this database — secret detection, misconfiguration, SBOM/licence inventory — are unaffected and work offline indefinitely. Depends on AO-10 for the acceptable age | «OWNER» | «TARGET_DATE» |
| ENG-41 | `open-questions.md` Q27, `dashboards-and-metrics.md` §11 | **Nothing can scan the machines' own filesystems for known vulnerabilities.** Trivy exists only inside Harbor's container; there is no Trivy CLI anywhere in the enclave. The patch-posture metrics measure how far behind the mirror a machine is, which is a different question from whether an installed package has a known CVE | RA-5 | Moderate | Two routes: run it from the Harbor image against a bind-mounted host filesystem, or carry a binary in on the next transfer trip. Either result is bounded by the same dated database as ENG-40 | «OWNER» | «TARGET_DATE» |
| ENG-42 | `ssp-inputs.md` §4.2, Q28 | **The named list of packages no subscription covers is owed.** Between **24 and 46 third-party packages per machine** — Docker, the Harbor components, anything carried in as a `.deb` — are covered by no Ubuntu subscription at any tier. Two known entries with a design consequence: `patroni` and `etcd-server` are both from `universe`, so the database cluster's consensus layer is not in `main` | SI-2, SR-3 | Moderate | Ours to produce, and scriptable. The count is not the artifact — the **named list** is, because the count is a number nobody has read. Pairs with AO-11, which decides who patches them | «OWNER» | «TARGET_DATE» |
| ENG-43 | `dashboards-and-metrics.md` §11, `open-questions.md` Q28 | **`apt-check`'s security count excludes ESM, and it silently reported zero.** Measured 2026-09-16 on five machines out of five: `apt-check` reported `N;0` — zero security updates — while `pro security-status` reported **19** esm-apps security updates. The alert fired on apt-check's number alone and would have missed every one | SI-2, SI-4 | Low | **Already fixed** — `SecurityUpdatesPending` is now a disjunction across apt-check, esm-apps and esm-infra, each term keeping its own `machine` label. Retained in this register because ESM is where `universe` packages get their only coverage, so it is precisely the stream that must not become invisible again | «OWNER» | «TARGET_DATE» |

### 4.6 Boundary and isolation

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| ENG-50 | runbook §3.0, backlog | **The isolation claim rests on an absent default route, not on architecture.** The enclave hosts have `GATEWAY` and `DNS` empty so no `routes:` block is emitted, and `/etc/enclave-build-info` records `gateway=none-airgapped-no-default-route`. That is a configuration claim undone by one `ip route add`, and hard to defend to an AO while the hosts share a wire with `stage-01` | SC-7, CA-3 | **High** | The recommended end state is structural: the enclave on its own switch or VLAN with **no gateway address on that segment at all**, so isolation is an absent path rather than an unwritten rule. Note the sequencing trap — renumber **after** `svc-repo-01` serves packages, or `host-4` is left with no package source including the tools to fix it | «OWNER» | «TARGET_DATE» |
| ENG-51 | runbook §10a "Still owed" | **Port 9100 is reachable from the enclave on three of five machines.** `ufw` genuinely enforces on `svc-repo-01` and `svc-obs-01` only; `host-4` and `svc-mgmt-01` have no rule table by design, and `svc-harbor-01`'s is written but not enabled. The exporter exposes every mount, interface, process count and kernel version | SC-7, CM-7 | Moderate | The rule belongs in `stig-tailor.sh`'s ufw table source-restricted to the collector, not poked in by hand. **Proof that the source-restricted rule works, measured against a live listener:** from `svc-obs-01` the scrape target reads `up`; from `stage-01` `curl` times out at 7.0 s, dropped. Timing is what distinguishes a DROP from a closed port | «OWNER» | «TARGET_DATE» |
| ENG-52 | runbook §10a "Still owed" | **`host-4`'s libvirt exporter on 9177 has no firewall rule** because `host-4` has no rule table — `stig-tailor.sh ufw` deliberately refuses to manage rules on the machine that bridges guest traffic | SC-7 | Low | Bounded by closing the physical gap. Revisit with ENG-51 | «OWNER» | «TARGET_DATE» |
| ENG-53 | `ato-package.md` §1 | **PPSM registration does not exist.** The inputs do: `stig-tailor.sh ufw` holds the rule set and every listening port has a justification in the runbook. Runbook §9a.3 adds `:8008`, `:2379` and `:2380` | CM-7, SC-7 | Moderate | Generate it from the rule tables rather than transcribing it, per the baseline's own rule that anything derivable from a parameter file is generated | «OWNER» | «TARGET_DATE» |
| ENG-54 | runbook §10a | **The only route to the enclave web UIs is an SSH tunnel through `stage-01`**, the one machine with a foot in both networks — and it dies at cutover, correctly. Importing the enclave root CA into a workstation that also browses the internet is a real trust decision that should be recorded rather than happening quietly | AC-17, SC-8 | Moderate | Every service reached that way must be reachable from inside the boundary before cutover. Nothing in the build may depend on that path. Remove the CA from any machine that leaves the project | «OWNER» | «TARGET_DATE» |

### 4.7 Documentation and package artifacts

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| ENG-60 | `ato-package.md` §1 | **No System Security Plan exists.** `ssp-inputs.md` holds 22 decided statements with their evidence; the template is the AO's call | PL-2 | **High** | Ask for the template (CUST-01), then pour the register into it. Do not draft 60 pages in the wrong template | «OWNER» | «TARGET_DATE» |
| ENG-61 | `ato-package.md` §1 | **No authorization boundary diagram exists.** The text does — runbook §1.2 has the four-host topology and §3.1 the addressing, and the boundary is unusually clean because `stage-01` and `build-01` are deliberately outside it | CA-3, PL-2 | Moderate | Cheap, and it is the first thing an assessor opens | «OWNER» | «TARGET_DATE» |
| ENG-62 | `ato-package.md` §1 | **No Risk Assessment Report exists.** The raw material is unusually good: the recovery-path analysis, the TPM/passphrase trade, replica-3 self-healing behaviour | RA-3 | Moderate | Write it from the analysis already in the runbook rather than starting from a threat catalogue | «OWNER» | «TARGET_DATE» |
| ENG-63 | `ato-package.md` §1, `README.md` | **The hardware/software inventory has not been extracted into a deliverable format.** The authoritative sources exist — `enclave-addresses.env`, `vm-specs.env`, and live `enclave_*` facts — and every package's origin is known because everything entered through one audited mirror | CM-8 | Low | **Generate it, do not write it.** A hand-written inventory drifts from the day it is written | «OWNER» | «TARGET_DATE» |
| ENG-64 | `nist-800-53-plan.md` Phase 2 | **The CCI-to-control harvest has not been built.** Every CKL and CKLB Evaluate-STIG has produced already carries `CCI_REF` per finding, so five machines of assessed, dated, per-rule evidence is *already* 800-53 traceability — it needs the CCI List translation table | CA-2, PL-2 | Moderate | **A script, not a document**, so it regenerates every time a scan runs. Described as the single highest-leverage unbuilt piece of work in the 800-53 plan | «OWNER» | «TARGET_DATE» |
| ENG-65 | `ato-package.md` §1 | **No Security Assessment Plan exists.** Runbook §6.0 is the procedure and §10.1 the tooling; missing are the assessor independence statement and a schedule | CA-2 | Moderate | Depends on CUST-05 for who assesses | «OWNER» | «TARGET_DATE» |
| ENG-66 | `open-questions.md` backlog | **Runbook sections are undrafted** — day-2 patching in particular (blocked on CUST-08), plus the remaining Harbor, MAAS air-gap, Landscape and backup/restore write-ups (§11.3) | MA-2, CM-9 | Moderate | MA-4 nonlocal maintenance is trivially satisfied — there is no remote access — but MA-2 needs the procedure written | «OWNER» | «TARGET_DATE» |
| ENG-67 | HANDOFF §4, `open-questions.md` | **The published platform comparison artifact still costs the enclave at three hosts**, and the design moved to four on 2026-08-31. A dated callout was added; the figures were deliberately not rewritten | SA-4 | Low | Not an accreditation artifact, but it is the SA-4 selection evidence and it should not be internally inconsistent when an assessor reads it | «OWNER» | «TARGET_DATE» |

---

## 5. Group AO — blocked on an Authorizing Official decision

**None of these can be closed by engineering.** Each is a policy answer about what this
enclave is permitted to do without, or a judgement about evidence that has no technical
remedy. Send them as **one thread**, not as ten tickets.

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| AO-01 | `ssp-inputs.md` §1.3, Q13/Q14/Q15 | **No CMVP certificates exist for Ubuntu 24.04, so the cryptographic-boundary exception must be argued rather than evidenced.** This is the single largest accreditation risk in the build and it is not a technical problem — no amount of engineering changes it while 24.04 has no certificates | SC-13 | **High** | The posture is as strong as it can be made and it is **measured, not inferred** (2026-09-17, `host-4`): `openssl list -providers` shows the `fips` provider **active**, *Ubuntu 24.04 OpenSSL Cryptographic Module* `3.0.13-0ubuntu3.15+Fips1`; `fips_enabled=1`; kernel `6.8.0-138-fips`; 15 packages from the FIPS stream. **That version string is the evidence that substitutes for a certificate number.** State the mechanism precisely: a FIPS-validated *provider module* active inside the distribution's standard OpenSSL 3, plus a FIPS kernel — not a wholesale replacement of the crypto libraries | «OWNER» | «TARGET_DATE» |
| AO-02 | `ssp-inputs.md` §5.1, Q26 | **Two controls require email notification and no email can leave an air gap.** V-270818 (notify the SA and ISSO at 75% of audit storage) and V-270819 (notify on audit processing failure). `auditd` is configured `space_left_action = email` with `action_mail_acct = root`, and Postfix is deliberately `inet_interfaces = loopback-only` **because the STIG requires it** — so the notification is generated and delivered to a local mailbox nobody watches | AU-4, AU-5 | **High** | The honest compensating control is the monitoring stack: Prometheus and Alertmanager on `svc-obs-01` alert on audit filesystem usage and on `auditd` failure and surface it on a dashboard. **That is a different mechanism from the one the control names.** Strengthening evidence: the stack publishes `enclave_auditd_lost`, and on the first scrape **four of five machines had lost 446–500 audit events** — V-270819 territory measured directly rather than inferred. If the AO says no, the control stays open on every machine permanently | «OWNER» | «TARGET_DATE» |
| AO-03 | Q25, README §0a | **Five Not Reviewed controls need a signature, not more engineering.** Triaged 2026-09-14; the set is identical on every machine. **V-270658** and **V-270817** audit offload; **V-270722** and **V-270745** the CAC family; **V-270754** the ufw rate-limit decision on 443 | CA-2 | Moderate | Nothing further can be done technically. Each is a policy answer about what this enclave is permitted to do without | «OWNER» | «TARGET_DATE» |
| AO-04 | Q26 / backlog, runbook §6.3d | **The audit trail as configured does not exist beyond 40 MB.** `num_logs=5` × `max_log_file=8` MB is **40 MB of rolling history**, then the oldest records are destroyed; `audit.log` reached 6.5 MB within 40 minutes of a reboot on an idle VM. Worse, **UBTU-24-100450 passes with `active = yes` in `au-remote.conf` and no remote server in existence** — a hollow pass | AU-4, AU-11 | **High** | Three AO answers are needed before the collector can be sized or built: (1) retention, online and archived — **this single answer drives the disk size**; (2) whether the programme already has a SIEM this must feed, because the only routes out are sneakernet or a one-way device; (3) whether an **in-boundary** collector satisfies offload, given there is no egress by design and the STIG's own standalone answer (UBTU-24-900950) is a weekly cron. Our half is measured: 2.44 MB/day on Harbor, 1.71 on the repo, ~30 MB/day across twelve machines, **~11 GB for a year** | «OWNER» | «TARGET_DATE» |
| AO-05 | `ssp-inputs.md` §4.1, runbook §6.3d | **`disk_full_action = SUSPEND` leaves a machine running unaudited**, and `space_left_action = email` with no MTA sends the 25% warning nowhere. Both are package defaults nobody chose | AU-5 | Moderate | Make them stated decisions rather than defaults. Depends on AO-02's answer for the notification half | «OWNER» | «TARGET_DATE» |
| AO-06 | Q25, runbook §10.1d, backlog | **The smart-card / CAC family is five controls and one missing subsystem, and it is the largest single block of findings on every machine.** V-270663 (SSSD for multifactor), V-270735 (SSSD certificate path validation), **V-270736 (HIGH — SSSD mapping certificates to users via `ldap_user_certificate`, i.e. an LDAP directory holding user certificates)**, V-270722 (smart card logins), V-270745 (DoD PKI-established CAs). Plus the same family from USG: `service_sssd_enabled`, `sssd_enable_user_cert`, `install_smartcard_packages`, the `smartcard_configure_*` rules and `package_opensc_installed` | IA-2 | **High** | **None of the required infrastructure exists in this enclave:** no LDAP or AD directory, no CAC/PIV readers or cards, and no DoD PKI trust path inside the gap. The last is a direct conflict — the enclave authenticates TLS against its internal two-tier CA. `libpam-pkcs11` **is** installed, which is what produces `no suitable token available` on every `sudo`, but there is no card, no reader and nothing to map against. **This is not deferrable one rule at a time.** Ask: (a) is CAC/PIV in scope at all for an air-gapped enclave with no directory; (b) if yes, who provides the directory and the DoD PKI material, and how does revocation work with no egress; (c) if no, will one documented risk acceptance cover the whole family rather than five deviations | «OWNER» | «TARGET_DATE» |
| AO-07 | README §0, runbook §6.3e | **`ufw` cannot enforce on three of five machines, and the residual finding is accepted rather than fixed.** `check_ufw_active` fails on `svc-harbor-01` (docker-proxy DNATs past ufw's INPUT chain), `svc-mgmt-01` (no rule table — MAAS opens ~30 ports and getting it wrong breaks PXE, which is how `host-1..3` get built) and `host-4` (bridges guest traffic). `ufw_rate_limit` fails on all five | SC-7, SC-5 | Moderate | Each has a written rationale and none is a defect. The enclave-wide mandatory guard is `ufw allow 22/tcp` **before** `ufw enable`, every time, verified from another machine — on `svc-repo-01` a wrong rule set means nothing in the enclave can install the fix | «OWNER» | «TARGET_DATE» |
| AO-08 | README §0, `ssp-inputs.md` | **`encrypt_partitions` fails inside every guest and passes on `host-4`.** The guest's virtual disk is not LUKS; the `host-4` NVMe underneath it is | SC-28 | Moderate | **This is a compensating control, not a deviation, and the rule must not be deselected** — write it up properly so the scanner keeps reporting it and the rationale travels with the finding | «OWNER» | «TARGET_DATE» |
| AO-09 | HANDOFF §3a, backlog | **Which PostgreSQL benchmark applies to a community PostgreSQL 16 build.** Evaluate-STIG ships only `U_PGS_SQL_9-x_STIG_V2R5` and routes community Postgres to it explicitly; on `svc-mgmt-01` it reported **`DISAStatus : Sunset`** and logged *"Unable to process PgSQL9x - skipping"*, refusing to score against retired guidance without `--AllowDeprecated`. So the 9.x option is not really available — it produces a score against withdrawn guidance | CA-2 | Moderate | **The Crunchy Data Postgres 16 STIG V1R1 (benchmark 13 Jun 2024, covering PostgreSQL 13–16) is a dependency, not a preference.** The narrowed question: does the AO accept a vendor-named STIG for a community build, or require the **Database SRG**? Crunchy states the functionality it reflects is "100% open source Postgres". Blocks CUST-06, which is the CAC download | «OWNER» | «TARGET_DATE» |
| AO-10 | Q27 | **At what age does scanning against carried-in vulnerability data stop being acceptable?** The answer sets the transfer cadence and the `AL_TRIVY_DB_STALE` threshold, currently 30 days, so the alert first fires **2026-10-08** | RA-5 | Moderate | Engineering half is ENG-40. Until answered, every Harbor result is quoted with its database date | «OWNER» | «TARGET_DATE» |
| AO-11 | Q28 | **Who patches the 24–46 third-party packages per machine that no Ubuntu subscription covers at any tier**, on what cadence, and if the answer is nobody, that has to be stated | SI-2, SR-3 | **High** | The `esm-apps` half turned out to be engineering and is closed: the entitlement was present on every in-gap machine all along, the archive was already mirrored (2.4 GB, 1,059 debs, signed `InRelease`), and enabling it revealed **19 pending security updates across five machines that nothing in the enclave could previously see**. So the `universe` packages were uncovered **by omission, not by entitlement**. What still needs a signature is the third-party half. If the answer is nobody, those packages belong in the SSP as a **named list** with that stated | «OWNER» | «TARGET_DATE» |
| AO-12 | runbook §2.9b, backlog items 1–3 | **Three PKI policy questions, none of them mechanisms.** (1) Is an internal CA acceptable at all, or is DoD PKI issuance required inside the boundary? (2) Revocation: the current position is expiry-only — no CRL, no OCSP, no `crlDistributionPoints` in any certificate. (3) **Root key custody** — HSM, hardware token, or encrypted media in a safe; who holds the passphrase, and is there two-person control? | SC-12, SC-17 | **High** | Mechanisms are already built and dormant so the answers do not block work: `trust-anchors/` accepts a site's roots beside or instead of the enclave root, `ca.sh request --profile` emits a CSR matching an RA's DN policy, and `CA_CRL_URL` / `CA_OCSP_URL` / `CA_CRL_DAYS` are parameters with leaf extensions built at sign time. **But if the AO wants a CRL it must be decided before more certificates are issued** — adding a distribution point later means reissuing everything that lacks one. `ca.sh backup-root` provides the custody mechanism and **cannot provide the policy, which is what the SSP will ask for** | «OWNER» | «TARGET_DATE» |
| AO-13 | runbook §2.10, backlog | **The enclave free-runs as a set with no traceable time source.** `host-4` serves stratum 10 from a `local` reference and every VM follows it reporting `synchronized: yes`. That suits etcd, Ceph and TLS; it does not suit audit correlation or a STIG demanding an authoritative source, and the chrony rules fail on `host-4` precisely because it is the master | AU-8 | Moderate | Some IL5 environments require a **traceable** source — GPS or PTP — which is hardware that has to be in the BOM and inside the boundary. `time-sync.sh master --upstream <addr>` adopts an appliance **without touching a single client**, so the answer costs one parameter, not a redesign | «OWNER» | «TARGET_DATE» |
| AO-14 | runbook §10b "Still open" | **Backup media leaves the room, and that carries the same requirements as the enclave itself** | MP-5, MP-6, CP-9 | Moderate | An AO question, grouped with AO-03 and AO-02. It also constrains ENG-03: a non-removable destination removes the question | «OWNER» | «TARGET_DATE» |
| AO-15 | `ssp-inputs.md` §2.3, `vm-specs.env` | **TRIM is enabled on the backup volume, which reveals how full it is.** `discard` reveals which blocks are unused — and therefore approximately how full the volume is — to anyone holding the drive. The contents stay encrypted; the shape of the usage does not | SC-28 | Low | Accepted because it is a second copy and an SSD backup target with nightly churn loses sustained write speed without it. `BACKUP_TRIM` **defaults to false** so enabling it is an explicit act; it is currently `true` in the lab with the SSD, with the rationale recorded in `vm-specs.env`. **It belongs in the SSP as a stated choice rather than being found in a config file later** | «OWNER» | «TARGET_DATE» |
| AO-16 | `open-questions.md` backlog | **Is Secure Boot on the guests required or only expected?** It changes whether ENG-26 is a blocker or a hardening nicety | CM-6, SI-7 | Moderate | Ask alongside AO-06 and AO-12 | «OWNER» | «TARGET_DATE» |
| AO-17 | Q18, README §0a E6 | **Which STIG revision will the assessor test against, and are Answer-File justifications accepted?** Measured 2026-09-10 on one machine on one day: **USG (V1R1) = 7 fail; Evaluate-STIG (V1R6) = 20 Open + 14 Not Reviewed.** Unhardened was 118 Open, so `usg fix` closes 83% — but the residual against the revision DISA will actually assess is **20, not 7** | CA-2 | Moderate | Both scanners run per machine either way, so this does not block work. Two contradictions worth surfacing to the assessor directly: **UBTU-24-600160** is Open despite a USG tailoring, because **a USG deviation does not travel to DISA's tool** — every justification needs an Answer File too; and **UBTU-24-100010** counts `systemd-timesyncd` as installed at `deinstall ok config-files`, a real finding USG hid. Also ask whether the programme runs **STIG Manager** — if it does, feed it rather than building a correlator (ENG-64) | «OWNER» | «TARGET_DATE» |
| AO-18 | `nist-800-53-plan.md` IR | **Is the Incident Response Plan inherited or system-specific?** | IR-8 | Moderate | An independent IR plan for a one-operator air-gapped enclave may be inappropriate. Write for the inherited case by default and ask before drafting | «OWNER» | «TARGET_DATE» |
| AO-19 | `nist-800-53-plan.md` PE, HANDOFF §4 | **The enclave is single-site with no standby of any kind, and that is the largest unaddressed risk in the design.** It is not a configuration gap; a recovery site is a second enclave and a second boundary | CP-7, CP-2 | **High** | Either the AO accepts single-site with no DR as a stated risk, or the programme funds a second site. There is no third answer, and no amount of work inside this boundary produces one | «OWNER» | «TARGET_DATE» |

---

## 6. Group CUST — blocked on a customer, programme or vendor input

| ID | Source | Weakness | Control | Risk | Mitigation / milestone | Owner | Target |
|---|---|---|---|---|---|---|---|
| CUST-01 | `ato-package.md` §2, `nist-800-53-plan.md` | **The control baseline and overlay set are not in writing.** IL5 commonly corresponds to a High-equivalent baseline plus DoD overlays for CUI, but "commonly" is not something to build a package on — **it changes the control count by hundreds**, and therefore how much of the SSP exists at all | PL-2, RA-2 | **High** | It is a determination, not a deduction. Everything downstream depends on it. Where the engagement will not answer, write for High and record the alternative as a tailoring note rather than leaving it blank | «OWNER» | «TARGET_DATE» |
| CUST-02 | `ato-package.md` §2 | **The required artifact list has not been provided.** RMF packages vary by Service, by programme and by eMASS configuration | CA-6 | **High** | Ask for it in writing before drafting anything long, and record the answer in `ARTIFACTS_REQUESTED` so the next engagement can see what differed. Nobody should start an Incident Response Plan the programme was going to inherit | «OWNER» | «TARGET_DATE» |
| CUST-03 | Q22, runbook §1.3 | **No capacity requirement has ever been captured.** Without it the Ceph OSD device size per host is unspecifiable, and OSD capacity is the largest line in the hardware BOM. **Not derivable from the lab** | CP-2, SA-2 | **High** | Mind the multiplier: replica-3 makes usable ≈ raw ÷ 3, and the steady-state utilisation ceiling means provisioning roughly **5× the usable figure in raw NVMe** — a 2 TB application requirement is ~10 TB raw across four hosts. Surfaces late and forces a hardware re-order if guessed | «OWNER» | «TARGET_DATE» |
| CUST-04 | runbook §9a "Still open" | **How many databases, and is this one application's state or a shared platform service?** Three synchronous nodes for a single application's database is generous; for a shared service it is the floor. **This is the one input that would change the sizing** | CP-2, SA-2 | Moderate | Ask with CUST-03 — same audience, same conversation | «OWNER» | «TARGET_DATE» |
| CUST-05 | `ato-package.md` §1, `nist-800-53-plan.md` CA | **CA-2 needs an independent assessor statement.** Every assessment to date is self-assessment, which is a different artifact | CA-2 | Moderate | Identify the assessor and the independence basis. Blocks ENG-65 | «OWNER» | «TARGET_DATE» |
| CUST-06 | HANDOFF §3a, runbook §10.1 | **The Crunchy Data Postgres 16 STIG XCCDF is a CAC-only download.** `public.cyber.mil` redirects to SAML and the downloads index is a JavaScript portal with no scrapable links (checked 2026-09-13). The same applies to the Web Server SRG, the Container Platform SRG, the Database SRG and the CCI List | CA-2 | **High** | Somebody with a CAC downloads them and they travel on the transfer media. The mechanism is already built: `StigContent/Manual/` takes any XCCDF and `answerfile.sh` writes portable `ValidationCode` that runs the real check at scan time. Blocks ENG-10, ENG-11, ENG-12, ENG-64 and AO-09 | «OWNER» | «TARGET_DATE» |
| CUST-07 | `nist-800-53-plan.md` PT, Q22 | **Whether a privacy threshold analysis or impact assessment is required depends entirely on what the applications will hold**, which nobody has stated | PT-2, PT-3 | Moderate | Ask. It is one question and it determines whether a whole artifact exists | «OWNER» | «TARGET_DATE» |
| CUST-08 | Q6, runbook §11 | **Offline patch bundle size and cadence are unanswered**, which blocks the day-2 patching procedure and the sizing of the service VMs. Partially measured 2026-09-08: Harbor's own images **697 MB**, Trivy databases **1.03 GB**. **Still unmeasured: the Kubernetes and workload images Harbor will serve** — and that is the number that sizes `svc-harbor-01`'s disk. The 500 GB in `vm-specs.env` remains a documented guess | MA-2, SI-2 | Moderate | Vendor and programme input. Note Trivy's database needs refreshing on **every** trip — an ongoing sustainment cost, not a one-off, and it belongs in whatever is told to the programme office about day-2 operations | «OWNER» | «TARGET_DATE» |
| CUST-09 | Q14 | **When 24.04 FIPS 140-3 validation is expected to complete** sizes the window the enclave runs on pending-validation modules | SC-13 | Moderate | Vendor question. Feeds the risk narrative and any condition attached to AO-01 | «OWNER» | «TARGET_DATE» |
| CUST-10 | Q10, HANDOFF §3 | **The Kubernetes 1.36 LTS support window has not been confirmed against the ATO's expected lifetime.** Related and sharper: the version decision (`k8s` v1.36.4, snap revision 5526) **rests on `1.36-classic/candidate` because `1.36-classic/stable` was unpublished as of 2026-08-31.** 1.36 is the LTS line and 1.35 is not, so 1.35 buys a support-window problem; the 1.36.4 build declares `grade: stable`; and the channel stops mattering once the snap is side-loaded by revision | SA-22 | Moderate | **Re-check `snap info k8s` before the platform bundle is built** — do not restate the channel from any document in this repository. If 1.36 has promoted to stable at the same revision, the SSP wording gets simpler for free. Both 1.35.7 and 1.36.4 are in the bundle, so it is reversible without another media trip | «OWNER» | «TARGET_DATE» |
| CUST-11 | runbook §1.3, `open-questions.md` backlog | **No production hardware specification exists** — no CPU, RAM, disk or NIC figure for any host, and VM sizing is estimates only. **Quote no hardware until it does** | SA-2, CM-8 | Moderate | Written **after** the lab is tested, from measured numbers. Note which lab measurements transfer and which do not: `host-4` (24 threads / 128 GB) lands on its estimate and **is** production-representative; hosts 1–3 are deliberately undersized at 4c/8t and 32 GB and prove the procedure runs, not what it needs. Depends on CUST-03 and CUST-08 | «OWNER» | «TARGET_DATE» |
| CUST-12 | Q4 | **"Unlimited VMs at every support tier" has not been confirmed on a quote.** Public pricing says yes; this is the biggest cost variable on the Canonical side | SA-4 | Low | Get it in writing. Re-verify list pricing rather than restating it from any document in this repository — vendor posture in this space changes quarterly | «OWNER» | «TARGET_DATE» |
| CUST-13 | `facility-profile.env`, `nist-800-53-plan.md` PE | **Which existing facility ATO the PE controls are inherited from has not been named.** "The facility is secure" is not an inheritance statement | PE-1 | Moderate | Name the ATO. It is one line and it removes a whole family from the writing queue | «OWNER» | «TARGET_DATE» |
| CUST-14 | `ssp-inputs.md` §2.1a, runbook §6.3i.1 | **Production hosts need a BMC with IPMI/Redfish and serial-over-LAN, and unattended unlock must be settled before the hardware is specified.** Neither is in any BOM because no BOM exists (CUST-11) | CP-10, MA-4, SA-2 | **High** | Both are cheap at purchase and expensive to retrofit. The BMC is also what lets MAAS deliver the redeploy-after-failure capability that justifies its place in the boundary. Unattended unlock being settled first matters because Secure Boot is a prerequisite for TPM-sealed unlock, which makes ENG-26 a hardware-schedule dependency and not a nicety | «OWNER» | «TARGET_DATE» |

---

## 7. Closed with evidence

Kept in the register because a POA&M that only ever grows reads as a system nobody is
working on. Each of these was open, was closed by measurement or by decision, and the
evidence is named.

| ID | Item | Closed | Evidence |
|---|---|---|---|
| CLOSED-01 | Can a FIPS stream be enabled on 24.04? | 2026-08-28 | Yes, but only `fips-updates`; `fips` and `fips-preview` both report `n/a` — entitled but unavailable on this release |
| CLOSED-02 | Does USG carry a DISA STIG profile for 24.04? | 2026-08-28 | Yes — the profile is `stig-v1r1`, not `disa_stig`. `disa_stig` is a floating alias and will move |
| CLOSED-03 | What does "FIPS" actually mean on this system? | 2026-09-17 | The strong posture, measured on `host-4`: FIPS provider **active** inside standard OpenSSL 3, `fips_enabled=1`, kernel `6.8.0-138-fips`, 15 packages from the FIPS stream |
| CLOSED-04 | Does the GRUB password break unattended reboot? | 2026-09-17 | No. `stig-tailor.sh grubpw status` on `host-4`: password set **and** `--unrestricted` present, so GRUB demands it to edit an entry and not to boot one. V-270675 met. Residual risk carried as ENG-20 |
| CLOSED-05 | Is data-at-rest encryption required? | 2026-08-29 | Yes at IL5. Implemented as `ENCRYPT_DISKS` in `host-params.env`, LUKS under both volume groups, default `true` |
| CLOSED-06 | How do hosts unlock without a human at every boot? | 2026-09-16 | TPM 2.0 measured-boot unlock recommended for production, passphrase retained and default, both parameterised as `LUKS_UNLOCK`. **Zero of 194 V1R6 controls mention TPM** and V-270747 checks only that every persistent partition has a `crypttab` entry — so this was never a compliance trade, only a risk decision. PCR 7 only, deliberately: PCR 11 changes on every kernel update and this enclave takes FIPS kernel updates |
| CLOSED-07 | Is there a FIPS channel for the Kubernetes snap? | 2026-08-31 | No — none exists, and the snap auto-detects FIPS mode. The requirement lands on the **base** snap: `core22` from `fips-updates/stable` (`20260125+fips`, rev 2383), which must be in the bundle. `core24`'s `fips-updates/stable` is **empty** |
| CLOSED-08 | Do MicroCeph and MAAS run non-FIPS crypto? | 2026-08-31 | Closed by decision — both moved to deb packaging, so **there is no exception to defend**. A snap takes its crypto from its base snap and `core24` has no FIPS stable channel; debs link the host's OpenSSL, which on a FIPS host is the validated module |
| CLOSED-09 | Does replica-3 across three storage nodes self-heal? | 2026-08-31 | It does not, and the fix was structural: a **fourth** OSD node gives Ceph a fourth failure domain so it can rebuild the lost copy. Residual risk carried in §8 note 2 |
| CLOSED-10 | `prune` deleted every full backup in the enclave | 2026-09-16 | The worst defect found in this project. The parameter is named `BACKUP_KEEP_CHAINS` and the code counted **directories**, so "keep 2" deleted the base and kept two diffs against something that no longer existed; the volume went from 402 GB to 11 GB. Fixed to group sets into chains by `mode=` and retire a whole chain at once, with three guards — the first **refuses to prune a domain with no full at all**. `prune --dry-run` now exists |
| CLOSED-11 | The first scheduled backup failed silently | 2026-09-15 | A latent defect the first unattended run exposed: `vdb` on every guest is a **raw** cloud-init seed ISO, and a raw file cannot hold a persistent dirty bitmap. `domain_disks()` now selects qcow2 only and names what it excluded on every run. **The monitoring found it within minutes**, which is the argument for having built it |
| CLOSED-12 | Log rotation was broken enclave-wide since hardening | 2026-09-14 | Fixup 3 sets `/var/log` to group `syslog`, and logrotate refuses every file in a stanza without an `su` directive. `/var/log/messages` on `svc-mgmt-01` had reached **7.9 GB, never rotated**. Fixed on all five with `su root syslog` and `maxsize 100M`; forced rotation reclaimed 5 GB. **The control passed throughout while the disk filled** |
| CLOSED-13 | Evidence was never collected off the machines | 2026-09-14 | §6.0 step 14 had been skipped on every machine: all five held their own checklist and `stage-01` held none, and four are VMs that can be rebuilt. First real run took 103 files / 337 MB off five machines. **Evidence you cannot collect is evidence you do not have** |
| CLOSED-14 | Answer File deviations did not travel between machines | 2026-09-11 | The hand-built file carried `ResultHash` on 7 of 8 entries with empty `ValidationCode`, so it answered only on the machine it was built on. `answerfile.sh` now generates portable entries — **17 entries, 0 hashes** — each running DISA's CheckText verbatim at scan time and re-opening the control if the condition changes. **Portability proven on a second dissimilar machine 2026-09-14** |
| CLOSED-15 | Credential exposed in a session transcript | 2026-09-02 | Rotated on both affected machines, seed rebuilt, `host-4` reinstalled and verified. Separate finding scrubbed in the same pass: two `pscp.exe -pw` lines held a different plaintext credential |

---

## 8. Five things this register states plainly rather than leaving for an assessor to find

**1. No contingency test has ever been run.** Not a tabletop, not a restore, not a failover.
CP-4 has evidence for ONE of five test types as of 2026-09-20 — the guest restore (ENG-01, `contingency-plan.md` §9.2). The host-failure, failover, Ceph and tabletop exercises remain unperformed (ENG-01, ENG-05). It is the only item in this register that
cannot be written instead of performed, and it is also the item most likely to change the
design — which is a reason to do it early rather than late.

**2. Ceph replica-3 on four OSD nodes has a utilisation ceiling, and every patch window
touches it.** The three-host design could not self-heal at all: lose a host and the cluster
ran degraded until the physical box returned. The fourth OSD node fixed that, and it is the
single highest-value change in the revision. What remains is that recovery capacity has to
exist to rebuild into — the lab arithmetic after the 500/500 disk split is 2 TB raw,
**~666 GB usable at replica-3, ~400 GB working**. Plan the steady-state ceiling, and treat a
patch window on a four-node cluster as a degraded-state operation even though it is no longer
a serial one.

**3. `V-270754` is classified inconsistently in the source documents.** Q25 lists it as one
of five Not Reviewed controls that *"cannot be closed from inside the boundary"* and need an
AO signature; `airgapped-setup-machine/README.md` §0a item 4 lists it as one of *"the four
engineering Not Reviewed"*. It appears here in both **ENG-16** and **AO-03**, deliberately,
because the discrepancy is real and unresolved in the source material. **Resolve it before
submission** — an item in two groups with two owners is an item with none.

**4. LUKS unlock is a console passphrase, so the enclave cannot recover from a power event
without a human at the rack.** Measured, not predicted: `host-4`'s reboot on 2026-09-17
stopped at the console until somebody typed the passphrase, and **all four service VMs went
with it** — the whole enclave was down for the duration. `/etc/crypttab` carries
`crypt-os UUID=... none luks` with no keyfile, by design: putting a keyfile on the same disk
would defeat the encryption the AO required. The data volume is fine (`nofail`, keyfile on
the encrypted root); it is the OS volume that blocks. Acceptable for a lab with one operator
on site. **A materially different proposition for production hardware in a facility somebody
has to be escorted into** (AO-19, CLOSED-06).

**5. Two mechanisms are not two paths, and one alert is the only thing making one design
decision defensible.** ENG-02 and ENG-06 are the two rows most likely to be read as minor
and are not. Both recovery paths terminating on `host-4` means a healthy, unrecoverable
database cluster on the surviving hosts. `synchronous_mode_strict` off with no degradation
alert means silent asynchronous operation — the exact condition that lost a database once
already.

---

## 9. Maintaining this register

**A row closes with evidence or it does not close.** A row marked complete without a command,
a file or a dated measurement is a row that will be reopened by the next assessor, at a worse
moment.

**A commit that changes security-relevant behaviour touches `../ssp-inputs.md` in the same
commit, or says in its message why it does not.** That rule exists because twenty-two such
statements accumulated as scattered asides precisely because nothing collected them, and the
runbook carried a superseded `fips-preview` instruction for weeks after the fact changed
(ENG-25). Good intentions produced both.

**Re-verify time-sensitive claims rather than restating them.** Vendor posture, STIG
revisions, snap channels and package versions change quarterly. `CLAUDE.md` names the
re-verification list; the correct action is to re-fetch the source, not to quote this
document. The one worked example of skipping it in this project is the datastore reversal:
a document sat in front of readers asserting dqlite was the default long after Canonical had
made etcd the default and deprecated dqlite outright.

**Every row's group is a claim about who can close it.** When a row moves between ENG, AO and
CUST, that is a real change worth noting in the review, because it changes who is waiting on
whom.

---

## 10. Sources

Every row above cites its source inline. The documents those citations refer to:

| Reference | What it is |
|---|---|
| `docs/compliance/ssp-inputs.md` | The 22 decided statements with their evidence |
| `docs/compliance/nist-800-53-plan.md` | Family-by-family status and the CCI mapping approach |
| `docs/compliance/ato-package.md` | The artifact container list, and what already exists under another name |
| `docs/compliance/dashboards-and-metrics.md` | Every metric, alert rule and dashboard, and how each can lie |
| `docs/runbook.md` | The build procedure. §1 topology · §2.5 Ceph · §2.9 PKI · §6.0 hardening · §9a PostgreSQL · §10a monitoring · §10b backup · §10c host reboot · §10.1 the two scanners |
| `docs/open-questions.md` | The live tracker: open questions by who answers them, the re-verification list, and the backlog |
| `HANDOFF.md` | The settled record. §3 verified findings · §3a the locked SRG coverage decision |
| `airgapped-setup-machine/README.md` | §0/§0a: per-machine scan tallies, the residual set, and the Evaluate-STIG stream |
| `scripts/enclave/*.env`, `scripts/install/02-host-autoinstall/host-params.env` | Authoritative parameter values — inventory, addressing, VM and backup configuration |
| CKL / CKLB files, per machine | Assessed, dated, per-rule findings carrying `CCI_REF` |
