# SSP inputs — the statements this build has already decided it must make

**Started 2026-09-17, because there is no SSP and twenty-two places in the documents say
"state this in the SSP".** Every one of those was a moment where somebody judged a fact
important enough to survive into the accreditation package, wrote it in an aside, and moved on.
Nothing was collecting them.

## What this document is, and what it is not

**It is not an SSP.** The SSP's *format* is the AO's call — eMASS, a DoD template, or the
programme's own — and writing 60 pages in the wrong template is wasted work. **The content is
ours, and the content is what is at risk of being lost.** So this is the register: every
statement, the evidence that supports it, and where it came from. When the real SSP is written
in whatever template is mandated, this is what gets poured into it.

**Control IDs below are suggested NIST 800-53 mappings to help whoever drafts the SSP find the
right section. They are not authoritative — the AO's control set governs.**

**Rule for this file: no statement without evidence.** If a row cannot name a command, a file or
a dated measurement, it belongs in `docs/open-questions.md` instead.

---

## 1. Cryptography — the posture and its limits

### 1.1 What "FIPS" means on this system — MEASURED

> **The system runs a FIPS-validated cryptographic *provider module* active inside the
> distribution's standard OpenSSL 3, together with a FIPS kernel. It is not a wholesale
> replacement of the platform's cryptographic libraries.**

| | |
|---|---|
| Evidence | `openssl list -providers` → `fips` provider, *Ubuntu 24.04 OpenSSL Cryptographic Module*, `3.0.13-0ubuntu3.15+Fips1`, **status: active**. `cat /proc/sys/crypto/fips_enabled` → `1`. Kernel `6.8.0-138-fips`. |
| Precision that matters | `openssl` and `libssl3t64` are the **ordinary archive builds** from `noble-updates/main`. The FIPS crypto is `openssl-fips-module-3` from `esm.ubuntu.com/fips-updates`. `linux-image-fips` and `libgcrypt20` also come from `fips-updates`. |
| Measured | 2026-09-17 on `host-4` · `HANDOFF.md` §3 |
| Suggested control | SC-13 |

**Say it in those words.** It is accurate, it is reproducible with one command, and it pre-empts
the question an assessor would otherwise ask. Claiming "the system uses FIPS-validated
cryptography" without the mechanism invites exactly the follow-up you cannot answer on the spot.

### 1.2 There are no CMVP certificate numbers for 24.04, and this is what substitutes

> **The modules are submitted to NIST and pending validation. The language is "submitted and
> pending validation" — never "validated".**

Cite Canonical's own framing rather than making a validation claim: `fips-preview` exists for
modules *"submitted to NIST for review but not yet certified"*, and Canonical states *"the
latest FedRAMP guidelines... do allow you to use pre-approved packages that are awaiting NIST
certification."*

**The evidence that stands in for a certificate number is the package version string** —
`openssl-fips-module-3 3.0.13-0ubuntu3.15+Fips1` — plus `dpkg -l | grep -i fips`, which on
`host-4` lists 15 packages from the FIPS stream. Source: runbook §2.3, `docs/open-questions.md`
Q15 · suggested control SC-13.

### 1.3 🔴 The cryptographic-boundary exception has to be won, not assumed

> *"Is every cryptographic module in the boundary validated?"* — the honest answer is no, and
> **this cannot be pre-cleared. It is argued in the SSP.**

This is the single largest accreditation risk in the build and it is not a technical problem —
no amount of engineering changes it while 24.04 has no certificates. Source: runbook §2.2,
`HANDOFF.md`, `docs/open-questions.md` Q13/Q14/Q15 · suggested control SC-13.

---

## 2. Data at rest, and the unlock decision

### 2.1 LUKS is enabled and the unlock method is a stated risk decision

> **Full-disk encryption is in place. The unlock method is a passphrase at the console, chosen
> deliberately over TPM unlock, and the trade is stated rather than implied.**

| | |
|---|---|
| Evidence | `ENCRYPT_DISKS=true` in `host-params.env` puts dm_crypt under **both** volume groups; `LUKS_UNLOCK` takes `passphrase` or `tpm2` and is validated by `02-build-seed.sh`; recorded in `/etc/enclave-build-info`. LUKS2, `aes-xts-plain64`, 512-bit, **pbkdf2** — verified by `cryptsetup luksDump`. |
| The trade, plainly | **Passphrase** defeats both a stolen disk and a stolen machine, and costs unattended recovery. **TPM-sealed** defeats a stolen disk but not a stolen machine, which boots itself. |
| The cost, measured | `host-4`'s reboot on 2026-09-17 stopped at the console until a human typed the passphrase, **and all four service VMs went with it** — the whole enclave was down for the duration. |
| Why it is defensible | The default is `passphrase`, the stronger option, so TPM is opt-in. **Somebody chose it**, which is what makes it a line in an SSP rather than an oversight. |
| Source | runbook §6.3i.1 · `docs/open-questions.md` Q20 (answered) · suggested controls SC-28, CP-10 |

**And state the consequence, because it is operational reality:** this enclave cannot recover
from a power event, a kernel update or a hardware fault without a human physically at the rack.
Acceptable for a lab with one operator on site. A materially different proposition for
production hardware in a facility somebody has to be escorted into.

### 2.1a 🔴 There is no remote recovery path of any kind

> **A console LUKS passphrase combined with no out-of-band management means a power event,
> kernel panic or failed reboot requires a human physically at the machine — with no way to see
> why from anywhere else.**

| | |
|---|---|
| Evidence | `host-1..3` have **no BMC** (confirmed 2026-09-17 — budget test hardware, no management port). `host-4`'s LUKS root prompted at the console on 2026-09-17 and the enclave stayed down until somebody typed it |
| Why it is one finding and not two | Either alone is survivable. **Together they remove remote recovery entirely** — you cannot unlock it and you cannot even watch it fail |
| Lab vs production | Acceptable on a bench with the operator in the room. In a facility requiring an escort it is the difference between a ten-minute fix and a scheduled visit |
| Source | `docs/02-host-install.md` §4c · runbook §6.3i.1 · suggested controls CP-10, MA-4 |

**Two BOM requirements follow, cheap at purchase and expensive to retrofit:** production hosts
need a **BMC with IPMI/Redfish and serial-over-LAN** — it is also what lets MAAS deliver the
redeploy-after-failure capability that justifies its place in the boundary — and **unattended
unlock must be settled before the hardware is specified**, which per §6.3i.1 means Secure Boot
is a prerequisite rather than a deferrable nicety.

*(MA-4 note: "no nonlocal maintenance capability" is simultaneously a strong control statement
and this risk. State both — an assessor who reads only the favourable half will find the other.)*

### 2.2 pbkdf2 was chosen explicitly over the LUKS2 default

> **Key derivation is pbkdf2, not argon2id.**

LUKS2 defaults to `argon2id`, **which is not a FIPS-approved KDF**, and this host runs
`fips_enabled=1`. Formatting a volume with defaults would have produced a weaker-compliance
header than the one it replaced, with nothing to flag it. Caught 2026-09-17 during the backup
drive swap by dumping the old header before creating the new one. Source: runbook §10b.1 ·
suggested control SC-13.

### 2.3 ✅ TRIM on the backup volume reveals how full it is — DECIDED 2026-09-17

> **The backup volume is mounted with `discard`. This reveals which blocks are unused — and
> therefore approximately how full the volume is — to anyone holding the drive. The contents
> remain encrypted; the shape of the usage does not.**

Accepted because it is a backup volume that is already a second copy, and because an SSD
backup target with nightly churn loses sustained write speed without it. Controlled by `BACKUP_TRIM` in `vm-specs.env`, **default false so that enabling it is an explicit
act — and it WAS explicitly enabled** for the Crucial SSD on 2026-09-17, after `reattach` measured
`discard granularity 4K` and confirmed the bridge actually passes TRIM. So this is a decision taken,
not a decision pending; the ⬜ here previously made it read as undecided.
Source: runbook §10b.1 · suggested control SC-28.

### 2.4 Ceph OSD encryption moves key management into the cluster

> **OSDs are created with `--dmcrypt`, so Ceph owns the key and it lives in the mon config
> store rather than `crypttab`. The monitors are therefore holding key material.**

An assessor will ask about that. Two further consequences: it unlocks automatically once the
cluster is up and adds no console passphrase; and **it is create-time only** — converting an
existing OSD means destroying and rebuilding it. Source: runbook §2.5 · suggested controls
SC-28, SC-12.

### 2.5 ⬜ Root CA key custody is a policy question, not a mechanism

> **`ca.sh backup-root` provides the mechanism for offline root key custody. It does not
> provide the policy, and the SSP will be asked for the policy.**

Who holds the passphrase, where the two copies live, and whether there is two-person control.
Unanswered. Source: runbook §2.9 · `docs/open-questions.md` · suggested control SC-12.

### 2.6 The ingress wildcard is one key protecting every application

> **A wildcard certificate is one private key fronting every application under that label.
> Compromise of it is compromise of all of them, and revocation means reissuing and
> redeploying every service at once.**

Normal for ingress, and chosen deliberately. Two specifics: the key lives in the cluster as a
TLS secret readable by anything that can read secrets in that namespace; and a wildcard matches
exactly one label. Source: runbook §2.9b · suggested controls SC-12, SC-8.

---

## 3. Availability and recovery — what is and is not claimed

### 3.1 🔴 The design survives a single host failure. It does not survive a site event.

> **State which one is being claimed, because an assessor will ask, and the honest answer is
> the narrower one.**

Three PostgreSQL guests on three hosts in one room survive a **host** failure. A rack, power or
cooling event takes all three simultaneously. Source: runbook §9a · suggested control CP-10.

### 3.2 🔴 Both recovery paths terminate on host-4

> **The whole-VM backup volume and the WAL archive both land on `host-4`. They are two recovery
> mechanisms, not two independent recovery paths.**

Lose `host-4` and you lose the ability to restore *and* the ability to roll forward, while the
databases on `host-1..3` sit healthy and unrecoverable to any point but their own present state.
A sharper statement than the site-event caveat above, and it deserves its own sentence. Source:
runbook §9a.1 correction 1 · suggested control CP-9.

### 3.3 Backups are verified, and the verification has a known blind spot

> **Every backup set carries a SHA-256 manifest. Changed sets are verified nightly; the whole
> volume is re-read weekly, and the weekly run is the only thing that can detect silent decay.**

Because a set that passes and is never modified keeps its mtime, and **silent decay does not
change an mtime** — so the nightly's skip logic cannot see it. Stated so the weekly run is
understood as a control rather than a convenience. Also: incrementals are not `qemu-img
check`ed, because a push-mode incremental references the live guest disk, which is locked — the
manifest is the integrity statement. Source: runbook §10b · suggested control CP-9.

### 3.4 A full backup costs twice the data in I/O

> Write every byte, then read every byte back to hash it.

Measured: one full set of four guests is **401 GB**; at 107 MB/s that was ~62 min to write and
~62 min to hash. Relevant to any maintenance-window commitment in the SSP. Source: runbook
§10b.1 · suggested control CP-9.

---

## 4. Boundary, media and services

### 4.1 Removable media is blocked, and the exception is logged

> **`usb_storage` and `uas` are both blocklisted. Backup operations open a time-boxed window,
> and every open and close is recorded with who, when and which modules.**

`uas` matters: blocking only `usb_storage` leaves a UAS enclosure working and the control looks
applied while it is not. ⚠️ **Known gap as of 2026-09-17:** two `DISABLE` events are logged as
`INCOMPLETE - module still loaded`, so `kernel_module_usb-storage_disabled` fails until the next
reboot. **A non-USB backup target — iSCSI or NFS — removes this exception entirely, which is
worth more to the SSP than the throughput is.** Source: runbook §6.3g · suggested controls MP-7,
AC-19.

### 4.1a ⚠️ Every host has a WiFi and a Bluetooth radio, and the checklist does not prove it

> **All four hosts ship with an 802.11 adapter and a USB Bluetooth radio. The radios are
> disabled at the kernel — `install <module> /bin/true` plus `blacklist`, applied to the
> initramfs as well as `/etc` — not merely left unconfigured.**

This is the one boundary statement an assessor cannot take from the checklist, because **V-270755
scores Not Applicable on a machine that has a radio.** DISA's check lists wireless *interfaces*;
where no driver happens to be bound there is no interface, so the scanner applies the rule's own
"no physical wireless network radios" note. Measured 2026-09-17: host-4 scored `not_applicable`
while carrying a MediaTek MT7922. host-1/2/3 scored Not Reviewed with a live `wlp2s0` on a
Realtek RTL8821CE.

**Bluetooth is not in the Ubuntu 24.04 V1R6 benchmark at all** — no rule, at any severity. A
machine can hold a live Bluetooth radio and score a clean checklist, so the control here is a
deliberate addition rather than an implementation of a requirement.

The claim is evidenced rather than asserted: the answer-file entry for V-270755 re-runs the
hardware test at every scan and returns **Open** if the block is ever removed or a radio appears
that nothing is blocking — so this statement self-invalidates rather than going stale. Source:
runbook §6.3g.1 · `scripts/enclave/stig-tailor.sh radio` · suggested controls **AC-18**
(wireless access), SC-40, CM-7.

### 4.1b ⚠️ The account lockout is not a lockout for the account holder

> **`deny = 3` with `unlock_time = 0` is implemented as DISA requires. Its effectiveness against
> an adversary who already has a shell is limited by design, and that limit should be stated
> rather than discovered.**

Measured on `host-2` 2026-09-18 during a real lockout: the tally file
`/var/run/faillock/encadmin` is owned by the locked-out user and mode `rw-rw----`.
`pam_faillock` creates it as that user because it must write the tally during that user's own
authentication. So the account holder clears their own lockout with one unprivileged command
(`faillock --user "$(id -un)" --reset`) and may then resume guessing three passwords at a time,
indefinitely.

**This is `pam_faillock`'s default behaviour, not a misconfiguration**, and `usg fix` wrote the
configuration — so changing it would be a deviation from DISA's own remediation. The control is
real against a remote attacker with no session; it is close to no control against one who has
one. Key-based SSH also never reaches `pam_faillock`, so a lockout removes privilege, not access.

The operational consequence is documented separately and matters more day to day: the previous
recovery procedure said to reboot, which on `host-1..4` means a passphrase at the physical
console. Source: runbook §6.3m · suggested controls **AC-7**, IA-5.

### 4.1c ⚠️ Ceph OSDs share a device with guest storage on this hardware

> **The design requires one whole device per Ceph OSD. The lab gives each OSD a partition on
> the same NVMe that already carries guest OS disks and the database data volume.**

Measured 2026-09-18. Each cluster host has exactly one NVMe; 500 GB of it is `crypt-data`
serving `/var/lib/libvirt/images` and `/var/lib/libvirt/images-data`, and an OSD would take the
unpartitioned remainder — ~454 GB on `host-1`, ~431 GB on `host-2`, ~1.3 TB on `host-3`.

Two consequences, both of which belong in the SSP rather than in a footnote:

- **Availability.** An OSD contending with guest I/O on one queue is not the isolation the
  design assumes, and a device failure takes the OSD *and* every guest on that host together —
  which is also the failure mode §3.1 already declines to claim protection against.
- **Evidence.** No Ceph performance or recovery timing measured on this hardware transfers to
  production. Anything asserted from lab measurement must say so.

⚠️ **Ceph has never been executed** — runbook §9 states this in its own text. No claim about
the storage tier is currently evidenced by anything. Source: runbook §9, §7.2 · suggested
controls SC-5, CP-2, SA-4.

### 4.1d ✅ Notification is a monitored alert, not email — AO DECISION 2026-09-18

> **V-270818 and V-270819 are satisfied by an in-boundary alert on the monitoring stack. Email
> cannot leave the air gap, and the STIG itself is why.**

`auditd` is configured with `space_left_action = email` and `action_mail_acct = root`, and
Postfix is `inet_interfaces = loopback-only` **because the STIG requires it**. The notification
is therefore generated and delivered to a local mailbox nobody reads. The compensating control
is Prometheus and Alertmanager on `svc-obs-01`, alerting on audit filesystem usage and on
`auditd` failure, surfaced on a dashboard an operator uses.

**This is a different mechanism from the one the control names, and that is stated rather than
glossed.** It is also demonstrably more effective here: on its first scrape the stack published
`enclave_auditd_lost` and found **four of five machines had lost 446–500 audit events** —
V-270819's condition, detected directly rather than inferred, by a mechanism that actually
reaches a human.

ℹ️ **The AO's decision carries a forward condition:** if a mail path out of the boundary is
ever authorised, `auditd`'s existing email configuration is already correct and needs only a
relay — the control would then be met by the named mechanism as well. Nothing in this decision
forecloses that. Source: `docs/open-questions.md` Q26 · suggested controls **AU-5(1)**, AU-5,
SI-4.

### 4.1e ✅ Vulnerability data has an agreed maximum age — AO DECISION 2026-09-18

> **Trivy's vulnerability database is refreshed WEEKLY by transfer media. Scan results are
> quoted with the database date beside them.**

Nothing in the enclave can reach Trivy's update endpoint. Measured 2026-09-15: the database was
built 2026-09-08 and expired by Trivy's own `NextUpdate` on 2026-09-09 — **and Harbor kept
reporting images clean, because a stale database and a genuinely clean image are
indistinguishable from the portal.**

The AO's answer sets two things:

| | |
|---|---|
| **Refresh cadence** | Weekly — the DB is an OCI artifact and rides the same transfer route as everything else |
| **Alert threshold** | **10 days, not 7.** A weekly refresh means the DB is legitimately almost 7 days old just before each transfer, so alerting at 7 would fire every week while the policy was being MET. The alert must catch a MISSED cycle. Both are parameters: `AL_TRIVY_DB_POLICY_DAYS` and `AL_TRIVY_DB_GRACE_DAYS` |

ℹ️ Trivy's secret detection, misconfiguration checks and SBOM/licence inventory **do not use
this database** and are unaffected offline. Only CVE matching is age-bound. Source:
`docs/open-questions.md` Q27 · `docs/compliance/dashboards-and-metrics.md` §4c · suggested
controls **RA-5**, SI-2, SI-5.

### 4.1f ✅ Third-party packages — a named list and a defined route — AO DECISION 2026-09-18

> **24–46 packages per machine are covered by no Ubuntu subscription at any tier. They are
> patched on demand via the same transfer media that carries OS patches, and where no patching
> exists for one it is named in this SSP rather than counted.**

The `esm-apps` half of this closed by measurement — the entitlement was present all along and
had simply never been enabled; switching it on revealed three pending security updates nothing
in the enclave could previously see. What remained was the genuinely uncovered third-party set:
Docker, the Harbor components, and anything carried in as a `.deb`.

The AO's answer has two parts, and both matter:

1. **There IS a route.** A technician carrying the OS patch bundle can carry third-party
   packages in the same trip, so "no subscription covers it" does not mean "it can never be
   patched." The cadence is the patch cadence, not a separate process.
2. **The "nobody" case is handled explicitly.** Where a component has no upstream patching the
   package is **named in the SSP with that stated** — an unpatched named list is defensible, an
   uncounted one is not.

#### ✅ THE LIST, MEASURED 2026-09-18 — and the question's premise was wrong

Q28 assumed **"24–46 third-party packages per machine, no subscription covers them at any
tier."** Measured across all eight machines, that figure was counting the **`universe`** bucket,
which **is** covered — by `esm-apps`, entitled all along and now enabled. The genuinely
uncovered set is **five package installs in the entire enclave**, four distinct packages:

| Package | Version | Origin | On | Patching route |
|---|---|---|---|---|
| `contracts-airgapped` | 1.8.1 | Canonical Ltd | `svc-mgmt-01`, `svc-repo-01` | Canonical Support Portal / KB article — requires Infra tier or above. Carried in on the patch trip |
| `get-resource-tokens` | 1.8.1 | Canonical Ltd | `svc-repo-01` | as above |
| `pro-airgapped` | 1.8.1 | Canonical Ltd | `svc-repo-01` | as above |
| `grafana` | 13.2.1 | Grafana Labs | `svc-obs-01` | grafana.com releases. Carried in on the patch trip. Verified: its only apt source is `/var/lib/dpkg/status` — no archive behind it |

**Per-machine totals** (installed / main+restricted / universe / no archive):

| | host-1 | host-2 | host-3 | host-4 | svc-mgmt-01 | svc-repo-01 | svc-harbor-01 | svc-obs-01 |
|---|---|---|---|---|---|---|---|---|
| installed | 855 | 855 | 854 | 969 | 722 | 552 | 538 | 544 |
| universe (esm-apps) | 30 | 30 | 30 | 64 | 60 | 21 | 24 | 34 |
| **no archive** | 0 | 0 | 0 | 0 | **1** | **3** | 0 | **1** |

✅ **Docker is NOT an exception here.** Q28 named it specifically. Measured on `svc-harbor-01`:
the installed package is **`docker.io` from Ubuntu `universe`**, not `docker-ce` from Docker's
own repository — so `esm-apps` covers it. **There are no third-party apt sources anywhere in the
enclave**; every source is `svc-repo-01` mirroring Ubuntu's own archives (archive, esm-apps,
esm-infra, fips-updates, usg).

⚠️ **The remaining exposure is container images, not packages.** Harbor's own components and
anything pushed into it are outside apt entirely, so no subscription tier is even relevant to
them — and their currency is governed by §4.1e's Trivy database question, not by this one. That
is a different control surface and should not be folded into this list.

**REGENERATE RATHER THAN TRANSCRIBE.** This table is a snapshot; the command is the evidence:

```bash
### MACHINE: any enclave machine ###
./scripts/enclave/stig-tools.sh coverage
```

It reads the **component** from the apt list filenames rather than trusting
`apt list --installed`'s `[installed,local]` marker — which returned **zero** on `host-4` while
64 packages were in fact universe-only, because that marker catches debs with no apt entry at
all, not packages whose archive gives them weaker support. It needs no privilege and changes
nothing.

⚠️ **A measurement trap found alongside this, and it is still live:** `apt-check`'s security
count **excludes ESM**. On `host-4` it reported `3;0` — three updates, zero security — while
`pro` reported three esm-apps *security* updates. Any alert keyed on `apt-check` alone would
have missed all three; the rule is now a disjunction across `apt-check`, `esm-apps` and
`esm-infra`. Source: `docs/open-questions.md` Q28 · suggested controls **SI-2**, CM-8, SA-22.

### 4.1g ✅ PostgreSQL is community, assessed against a tailored vendor STIG — AO DECISION 2026-09-18

> **The database tier is community PostgreSQL 16 from Ubuntu `main`, not a commercial
> distribution. It is assessed against the DISA Crunchy Data Postgres 16 STIG V1R3 with
> documented tailoring, plus the 34 Database SRG requirements that STIG has no child rule for.**

**The AO's reasoning, recorded because it is the rationale an assessor will test:** *"I do not
want to be dependent on a provider for a product I can get and set up ourselves and have to pay
licensing on — as long as the Postgres we are using is compatible with FIPS-enabled Ubuntu and
can be hardened."*

**The condition was verified, not assumed.** Measured 2026-09-18 against the enclave mirror:

| Package | Version | Component | Support |
|---|---|---|---|
| `postgresql-16` | 16.15-0ubuntu0.24.04.1 | **main** | Canonical standard security to 2029, ESM to 2036 |
| `postgresql-16-pgaudit` | 16.0-1 | universe | `esm-apps` — entitled and now enabled |
| `patroni` | 3.2.2-2 | universe | `esm-apps` |
| `etcd-server` | 3.4.30-1ubuntu0.24.04.3+esm2 | main | already receiving ESM updates |

**FIPS capability is structural, not claimed:** `postgresql-16` depends on **`libssl3t64`**, the
system OpenSSL. On these hosts that library loads the FIPS provider (§1.1), so the database
inherits the validated module by the same mechanism as every other service. No separate crypto
path, nothing to certify independently.

**Why a vendor STIG for a non-vendor product.** There is no community-PostgreSQL STIG at any
version — DISA's only other PostgreSQL benchmark is `PGS_SQL_9-x`, which is **Sunset**. The
Database SRG's own fallback rule is to use the SRG *"when a product-specific STIG is not
available"*; one **is** available for PostgreSQL 16, written for a different distribution of the
same upstream source. **Tailoring a close product STIG produces materially better security than
generic SRG checks** — 111 specific rules naming real settings and queries, against 142 generic
ones — and the 34-rule delta covers what it misses, including two CAT I the product STIG never
inherited (V-206555 password complexity, V-206561 obscured authentication feedback).

**The tailoring, stated up front rather than defended later** — this is the part an assessor
challenges, so it is written before the assessment, not after:

| The STIG assumes | This enclave | Effect |
|---|---|---|
| Crunchy Data distribution (**334** mentions) | community PostgreSQL 16, Ubuntu `main` | same upstream source, different packaging |
| `/usr/pgsql-16/{bin,lib,share}` | `/usr/lib/postgresql/16/`, `/usr/share/postgresql/16/` | 13 filesystem checks retargeted |
| config inside `PGDATA` | `/etc/postgresql/16/main` | ownership/mode checks retargeted |
| `rpm -qa` / `dnf` | `dpkg` / `apt-cache` | 4 package checks retargeted |
| pgaudit shipped by the vendor | `postgresql-16-pgaudit` from the mirror | **available — verified**; 15 rules depend on it |
| **no HA awareness at all** (0 mentions of Patroni) | Patroni 3.2.2 | ⚠️ see runbook §9a.2a |

⚠️ **Two things this decision does NOT settle, and neither may be assumed:**

1. ✅ **RESOLVED BY INSPECTION 2026-09-18 — Patroni contains no runtime MD5.** The concern was
   that Patroni is Python and `hashlib.md5()` raises on FIPS-enforcing builds. The packages were
   downloaded from the enclave mirror and read: **`patroni` 3.2.2-2 and `python3-etcd` 0.4.5-4
   contain ZERO `hashlib` imports and zero `.md5()` calls outside test code.** The only hits are
   in `etcd/tests/integration/helpers.py`, which generates certificate serials for integration
   tests and never executes at runtime. Runtime crypto is `ssl` (both, → OpenSSL → the FIPS
   provider) and `hmac` in `patroni/api.py` for REST API authentication. **The MD5-under-FIPS
   failure mode is not present in this version.**
   ⚠️ Still worth one check at build time: HMAC is FIPS-approved *with an approved digest*, so
   confirm the digest `patroni/api.py` uses if the REST API is exposed. It is not on the
   bootstrap or failover path. And a real failover under FIPS remains the proof — static
   analysis lowers the risk, it does not replace the test.
2. **`V-283674` asks for a "vendor supported" version.** With community packaging the vendor is
   **Canonical**, and `postgresql-16` being in `main` is the evidence. That reading should be
   stated in the assessment rather than left for an assessor to infer.

Source: `docs/open-questions.md` · runbook §9a.2a · `HANDOFF.md` §3 · suggested controls
**CM-6**, SA-4, SA-22, SI-2.

### 4.1h ✅ MAAS is removed from the boundary — AO DECISION 2026-09-18

> **MAAS is removed entirely. `svc-mgmt-01` remains, because it also hosts the Ubuntu Pro
> air-gapped contract server, which every machine's FIPS, ESM and USG entitlement depends on.**

The AO: *"I recommend dumping and removing MAAS totally — no value to me, just a headache."*
Concurred, on evidence:

| | |
|---|---|
| **It does not work** | MAAS does not run under FIPS. It was broken for **7 days while `systemctl is-active` reported healthy** — the unit was up, the job was dead |
| **Its purpose is unreachable** | Its documented role here was *redeploy the physical hosts over PXE after failure* (runbook §4840). It cannot, and cannot while FIPS is on |
| **It is the largest attack surface in the enclave** | ~30 open ports (`5239-5284`, `3128`, `8000`, `53`, `67/udp`, `69/udp`, `5353`) for zero delivered function |
| **It pollutes the audit trail** | **144,840 sudo invocations in 24 hours** — 1.68/second — from `machine-resources`. 5 GB/day of syslog, and a direct driver of V-270816 |
| **It carries an unassessed database** | MAAS runs its own PostgreSQL 16, never assessed against any benchmark (runbook §8727). Removing MAAS removes that surface with it |
| **It blocks other work** | `svc-mgmt-01` has **no ufw rule table** precisely because MAAS's port list was never confirmed. Removing MAAS unblocks the firewall |
| **13 packages** | `maas`, `maas-agent`, `maas-cli`, `maas-common`, `maas-dhcp`, `maas-netmon`, `maas-proxy`, `maas-rack-controller`, `maas-region-api`, `maas-region-controller`, `python3-django-maas`, `python3-maas-client`, `python3-maas-provisioningserver` |

✅ **Verified before agreeing — nothing depends on MAAS's DNS.** All machines resolve via
`127.0.0.53` (systemd-resolved) against `/etc/hosts`, which carries 16–19 enclave entries rendered
by `apply-addresses.sh`. MAAS's `named` serves nothing.

🔴 **WHAT MUST SURVIVE: `contracts-airgapped.service`**, enabled and active on `:8484`. That is the
Ubuntu Pro air-gapped contract server. Without it there is **no FIPS stream, no `esm-apps`, no
`esm-infra`, no USG** on any of the eight machines. **Removing MAAS must not remove
`svc-mgmt-01`**, and Pro attachment must be re-verified on every machine afterwards.

**The cost, stated honestly:** rebuilding a *physical* host now requires a seed USB and somebody
at the rack, rather than a network redeploy. On machines with **no BMC** and a **LUKS passphrase
at the console**, that is the same exposure as §2.1a wearing another hat — it is not created by
this decision, it is made permanent by it. TPM unlock (§2.1a) is the mitigation that matters.

Source: `docs/runbook.md` §9b, §4840, §7607 · suggested controls **CM-7** (least functionality),
SA-22, RA-5.

### 4.1i ✅ Log retention is 90 days, aligned with metrics — AO DECISION 2026-09-18

> **Audit and syslog are retained 90 days on the collector — the same window as Prometheus —
> unless the programme provides an external air-gapped system, in which case logs ship to it from
> `svc-obs-01` alone.**

The AO's first answer was 30 days; raised to 90 on the observation that **Prometheus already
retains metrics for 90 days**, and mismatched windows mean that for days 31–90 you have a metric
spike with no log to explain it. Aligning them is a one-line change now and a migration later.

**Egress is from ONE machine, not eight.** That is the part that matters for AU-9(2): on four
physical hosts with everything virtualised, **no placement of the collector satisfies AU-9(2) —
it fails for exactly four machines wherever it sits** (verified by arithmetic, not assumed).
Only shipping records out of the boundary closes it. Until that external system exists, AU-9(2)
is a documented partial with a stated exception.

Source: `docs/open-questions.md` Q25 · suggested controls **AU-11**, AU-4, AU-9(2), AU-12(1).

### 4.2 ⬜ Third-party packages no subscription tier covers

> **Between 24 and 46 packages per machine are covered by no subscription at any tier.**

Half-answered: `esm-apps` was entitled all along and enabling it revealed 19 pending security
updates nothing in the enclave could previously see. **The remaining half is the named list**,
and it is owed. Two known entries: `patroni` and `etcd-server` are both from `universe`, so the
database cluster's consensus layer is not in `main`. Source: `docs/open-questions.md` Q28 ·
suggested control SI-2.

### 4.3 ⚠️ `esm-infra` is enabled inconsistently

`host-4` has `esm-apps` enabled and **`esm-infra` disabled**; `svc-mgmt-01` has both. Harmless
today — on 24.04, `main` is covered by standard security updates until 2029, so `esm-infra`
supplies nothing additional — but it becomes real at the support boundary, or sooner if a package
moves pockets. Source: `HANDOFF.md` §3, measured 2026-09-17 · suggested control SI-2.

### 4.4 The GRUB password permits unattended boot, and that is a state not a property

> **A GRUB superuser password is set, and `--unrestricted` is present on the boot classes, so
> the password is required to EDIT a boot entry and not to BOOT one.**

V-270675 met without breaking unattended reboots. Evidence: `stig-tailor.sh grubpw status` on
`host-4`, 2026-09-17 — `--unrestricted` at `/etc/grub.d/10_linux:34`, one `superusers`, one
`password_pbkdf2`, `unrestricted=5` in the generated config.

⚠️ **`10_linux` is package-managed.** A `grub-common` update or a `usg fix` re-run can revert it
silently and re-arm the trap, on a host whose LUKS root already stops at a console. **`grubpw
status` belongs in post-patch verification, not only post-hardening.** Source:
`docs/open-questions.md` Q21 (answered) · suggested control CM-6.

---

## 5. Audit

### 5.1 ⬜ Two controls require email notification and no email can leave an air gap

V-270818 (notify SA and ISSO at 75% of audit storage) and V-270819. Unresolved — needs an AO
answer on an acceptable compensating mechanism. Source: `docs/open-questions.md` Q26 ·
suggested controls AU-4, AU-5.

### 5.2 ⬜ Five Not Reviewed controls need a signature, not more engineering

Triaged 2026-09-14; the set is identical on every machine. Nothing further can be done
technically. Source: `docs/open-questions.md` Q25.

---

## 6. 🔴 A stale instruction found while building this register

**`docs/runbook.md` §2.3 (around line 3603) still says `fips-preview` is "the stream the
decision rests on" and instructs `sudo pro enable fips-preview`.** That is wrong and was
superseded: **Q11 established that `fips-preview` is unavailable on 24.04**, the stream is
`fips-updates`, and 2026-09-17's measurement confirms `fips-updates` enabled with the FIPS
provider active (§1.1 above). Following that instruction would enable the wrong stream.

⬜ **Fix the runbook text.** Recorded here because it was found while collecting SSP inputs and
is exactly the class of error this register exists to surface — a claim repeated in a document
long after the fact changed.

---

## What is owed before any of this ships

| | |
|---|---|
| The SSP's template | **The AO's decision.** Ask before drafting prose. |
| Q13, Q14, Q15 | AO judgement on the crypto posture. §1.1 and §1.2 are the inputs; the decision is not ours. |
| Q25, Q26 | A signature and a compensating control. No engineering left. |
| Q28's named list | Ours to produce. Scriptable. |
| Root CA custody policy | §2.5. Ours to propose, AO's to accept. |
| Re-verify every time-sensitive claim | Per `CLAUDE.md`: re-fetch the sources under *"Re-verify before anything ships"* rather than restating from this file. |
