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

### 2.2 pbkdf2 was chosen explicitly over the LUKS2 default

> **Key derivation is pbkdf2, not argon2id.**

LUKS2 defaults to `argon2id`, **which is not a FIPS-approved KDF**, and this host runs
`fips_enabled=1`. Formatting a volume with defaults would have produced a weaker-compliance
header than the one it replaced, with nothing to flag it. Caught 2026-09-17 during the backup
drive swap by dumping the old header before creating the new one. Source: runbook §10b.1 ·
suggested control SC-13.

### 2.3 ⬜ TRIM on the backup volume reveals how full it is

> **The backup volume is mounted with `discard`. This reveals which blocks are unused — and
> therefore approximately how full the volume is — to anyone holding the drive. The contents
> remain encrypted; the shape of the usage does not.**

Accepted because it is a backup volume that is already a second copy, and because an SSD
backup target with nightly churn loses sustained write speed without it. Controlled by
`BACKUP_TRIM` in `vm-specs.env`, **default false** so that enabling it is an explicit act.
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
