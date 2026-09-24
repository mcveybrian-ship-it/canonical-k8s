# Configuration Management Plan — «SYSTEM_NAME» («SYSTEM_ACRONYM»)

| | |
|---|---|
| System | «SYSTEM_NAME» («SYSTEM_ACRONYM») |
| System identifier | «SYSTEM_ID» |
| System owner | «SYSTEM_OWNER» |
| Impact level | IL5 |
| Control baseline | «800-53 Rev 5 High or Moderate» |
| Configuration authority | «CCB name, or the individual who approves changes» |
| Authority cadence | «how often it meets, or "by ticket" if there is no board» |
| Change request mechanism | «Jira or ServiceNow or eMASS or email to the ISSM» |
| Repository of record | «the authoritative repository location and its custodian» |
| Media transfer authority | «who approves a transfer across the gap» |
| ISSM | «ISSM_NAME» |
| ISSO | «ISSO_NAME» |
| System administrator | «SYSADMIN_NAME» |
| Prepared by | «PREPARED_BY» |
| Document version | 0.1 draft |
| Document date | «YYYY-MM-DD» |

---

## 1. Purpose, and why this plan is short

This plan describes how the configuration of «SYSTEM_ACRONYM» is established, recorded,
changed and verified.

**It is deliberately short, because it points at things that already exist rather than
describing things that are intended.** Most configuration management plans are written
aspirationally: they describe a baseline that lives in somebody's head, a change process that
is followed when there is time, and a drift-detection capability that is a plan for a tool.
This enclave inverted that by accident of how it was built. The baseline is an executable
procedure. Every setting that could be a value is a value in a tracked file. The change record
is a commit history. Drift detection is a daemon.

**So the honest form of this document is a map, not a narrative.** Where this plan says "the
procedure is X", X is a file you can open and run, and the citation is given. Where something
is genuinely absent — and two things are — this plan says so rather than describing an
intention as a control.

### 1.1 What is absent, stated first

| Gap | Consequence |
|---|---|
| **There is no configuration control authority.** The technical baseline is governed; the body that approves a change to it is «CCB name, or the individual who approves changes» and does not yet exist as a named function | CM-3 has a mechanism and no authority. A commit is a record of a change, not evidence that the change was approved |
| **The GRUB `--unrestricted` state lives in a package-managed file and can revert silently** | See §7.3. It is the one configuration item in this enclave that can un-configure itself, and it is the reason configuration verification belongs in the **post-patch** procedure and not only the post-hardening one |

---

## 2. The architecture this plan governs

This section is stable across facilities. It changes only if the design changes, and it is
written out in full because every configuration-management claim below depends on it.

### 2.1 Four hosts, ten guests, and no egress

The enclave is **four bare-metal hosts** running KVM/libvirt from distribution packages, with
guests composed by `03-compose-vm.sh` through `virsh` (MAAS was removed 2026-09-18). The operating system is Ubuntu 24.04 LTS on host and
guest, with the Minimal variant on cluster nodes and the standard server image on the hosts
and the service VMs (runbook §1, §2.3, §2.4).

Three hosts carry one Kubernetes control-plane guest and one worker guest each. The fourth
host carries the worker that gives Ceph its fourth failure domain, plus every enclave service
in four separate guests: `svc-mgmt-01` (the Ubuntu Pro
air-gapped contract server), `svc-repo-01` (the apt mirror over nginx, and the Landscape
repository mirror), `svc-harbor-01` (the Harbor registry with its own PostgreSQL and Trivy),
and `svc-obs-01` (Prometheus, Alertmanager and Grafana).

**The services are concentrated on one host deliberately, and the reasoning is a
configuration-management argument.** None of these services is highly available — Harbor is
not clustered, Landscape is not, and and MAAS was removed from the boundary entirely on 2026-09-18.
Spreading them across hosts therefore buys no availability; it only distributes the blast
radius. What matters is *which* failure takes them out. Put Harbor on a cluster host and a
host failure cascades: the host dies, pods reschedule, and the rescheduled pods need image
pulls from a registry that died with the host. On the fourth host, losing any of hosts 1–3
leaves Harbor, DNS and the mirror standing, so the cluster can recover from the failure it
just had. Losing the fourth host is the inverse and far milder — etcd keeps quorum, running
pods keep running on cached images, and Ceph still holds three copies across three surviving
hosts. **You lose the ability to build and patch, not the ability to run** (runbook §1.1).

**The network is fully disconnected with no egress.** Every host is installed with `GATEWAY`
and `DNS` left empty, so the autoinstall template omits the `routes:` and `nameservers:`
blocks entirely; each host reaches everything on the enclave subnet, so administration works
normally, and has no path off the subnet at all. The choice is recorded on the installed host
in `/etc/enclave-build-info` as `gateway=none-airgapped-no-default-route`, so it is visible on
the machine rather than only in a document (runbook §3.0).

**That absent route is a configuration claim, not an architectural one, and this plan does not
pretend otherwise.** It is undone by one `ip route add`. The recommended end state is
structural — the enclave on its own switch or VLAN with no gateway address on that segment at
all — and it is tracked as a POA&M item (`poam.md` ENG-50) rather than described here as
though it were done. Whether the boundary router is in scope is «yes or no - inherited».

Name resolution is `hosts: files dns` on every node, so `/etc/hosts` wins and **`bind9` on `svc-mgmt-01`** is the
fallback. That order is deliberate: `apt`, `containerd` and `pro attach` must not stop working
because a single service VM is rebooting. The domain is `enclave.internal` and **not**
`enclave.local`, because `systemd-resolved` routes any multi-label `.local` name to
MulticastDNS, so such a name would work through `/etc/hosts` and then fail silently the moment
anything relied on DNS (runbook §3.0).

### 2.2 Cryptographic posture

The hosts and guests run with the FIPS provider module active. The precise statement, measured
on `host-4` on 2026-09-17 and reproducible with one command, is that **a FIPS-validated
cryptographic provider module is active inside the distribution's standard OpenSSL 3, together
with a FIPS kernel** — not a wholesale replacement of the platform's cryptographic libraries.
`openssl list -providers` reports the `fips` provider, *Ubuntu 24.04 OpenSSL Cryptographic
Module* `3.0.13-0ubuntu3.15+Fips1`, status active; `/proc/sys/crypto/fips_enabled` is `1`; the
kernel is `6.8.0-138-fips`; and fifteen packages come from the FIPS stream. `openssl` and
`libssl3t64` themselves are the ordinary archive builds from `noble-updates/main`; the FIPS
crypto is `openssl-fips-module-3` from `esm.ubuntu.com/fips-updates` (`ssp-inputs.md` §1.1,
HANDOFF §3).

**The modules are FIPS 140-3 validated — CMVP #5115 (OpenSSL) and #5215 (Kernel Crypto API) —
and the enclave runs Canonical's security-patched `fips-updates` builds of them**, by the acting
AO's decision of 2026-09-24 (`ssp-inputs.md` §1.2, `poam.md` AO-01). **Configuration consequence:** the
module and kernel versions change with every patch cycle, so the baseline records the stream
(`fips-updates`) and the certificates, and each cycle's `dpkg-query -W openssl-fips-module-3` and
`uname -r` are captured as evidence. *(Until 2026-09-24 this paragraph said no certificates existed —
already out of date when written.)*

Two packaging decisions in this enclave exist **because of** that posture, and they are
configuration-management facts rather than preferences. A snap takes its cryptography from its
base snap and not from the host, so Ceph and MAAS were deployed from **deb packages** rather
(⚠️ MAAS was removed from the boundary 2026-09-18; the reasoning is retained because it still
governs Ceph, and because it is the precedent for any future snap decision)
than from their snaps: `microceph` and `maas` both declare `base: core24`, and `core24` has no
`fips-updates/stable` channel — only candidate, beta and edge. Debs link the host's OpenSSL,
which on a FIPS host is the validated module. The Kubernetes snap is unaffected because it
declares `base: core22`, which does have a FIPS stable channel, and **that base snap is
mandatory** — installing the plain `core22` inside the gap yields a cluster that is not FIPS
despite the host being so (runbook §2.5, HANDOFF §3).

A second consequence worth recording because it constrains every configuration item that
carries a key: with FIPS enabled, OpenSSH refuses Ed25519. **Every SSH key in this build must
be RSA 3072 or larger, or ECDSA** (open-questions, 2026-08-28).

### 2.3 Data at rest

`ENCRYPT_DISKS=true` in `host-params.env` puts `dm_crypt` under **both** volume groups. The
headers are LUKS2, `aes-xts-plain64`, 512-bit, with **pbkdf2** key derivation — chosen
explicitly over the LUKS2 default of `argon2id`, which is not a FIPS-approved KDF. That matters
as a configuration-management point and not only a cryptographic one: formatting a volume with
defaults would have produced a weaker-compliance header than the one it replaced, **with
nothing to flag it**. It was caught during a backup drive swap by dumping the old header before
creating the new one (`ssp-inputs.md` §2.1, §2.2).

Unlock method is a parameter, `LUKS_UNLOCK`, taking `passphrase` or `tpm2`, validated by
`02-build-seed.sh` and recorded in `/etc/enclave-build-info`. **The default is `passphrase`,
the stronger of the two**, so a host built by someone who did not consider this parameter gets
the safer posture rather than the more convenient one, and TPM unlock is an explicit opt-in.
Where TPM unlock is used it seals to **PCR 7 only** — PCR 11 covers the kernel and initrd and
would be stronger, but it changes on every kernel update, and this enclave takes FIPS kernel
updates; sealing to 11 converts "always needs a human" into "needs a human unpredictably,
after a patch, at 02:00" (open-questions, decision recorded 2026-09-16).

Ceph OSDs are created with `--dmcrypt`, so Ceph owns the OSD key and it lives in the monitor
config store rather than in `crypttab`. Two configuration consequences: the OSD unlocks
automatically once the cluster is up and adds no console passphrase, and **it is create-time
only** — converting an existing OSD means destroying and rebuilding it, with data movement
across a four-node cluster that recovers slowly. It is therefore a decision that must be made
before the first OSD exists (runbook §2.5, `ssp-inputs.md` §2.4).

### 2.4 The enclave PKI

A two-tier internal certificate authority, with the **root offline and outside the boundary**
on the staging machine and the issuing CA on `svc-mgmt-01`. Every enclave service serves TLS
from it, and both build paths trust the root before their first `apt` run — the CA-before-apt
ordering that has bitten this build twice in different costumes (runbook §2.9, §2.9a).

The configuration-management properties that matter:

- **Trust anchors are a directory, not a hardcoded certificate.** `trust-anchors/` is a
  directory whose every `.crt` reaches every machine, so a site's own roots can sit beside or
  instead of the enclave root. `ca.sh trust` installs from it, prints each anchor's
  fingerprint, and is idempotent — verified on `host-4` 2026-09-04 reporting `0 added,
  0 removed` on a second run.
- **Certificate names come from the CSR and from nowhere else.** An earlier implementation
  wrote `subjectAltName` into the signing extfile as well, and the measured result was that
  signing one host's CSR with an extfile naming another produced a **valid, correctly-signed
  certificate for the wrong host, with no error and no warning**. Two sources of truth for a
  certificate's name is one too many; the extfile now carries no SAN line (runbook §9a.3).
- **Revocation is dormant rather than absent.** `CA_CRL_URL`, `CA_CRL_DAYS`, `CA_OCSP_URL` and
  `CA_NAME_CONSTRAINTS` are parameters, and leaf extensions are built at sign time with
  `-extfile`, so switching revocation on is a parameter change rather than a CA rebuild. The
  current position is expiry-only and it is defensible at this scale — but **if a CRL is
  required it must be decided before more certificates are issued**, because adding a
  distribution point later means reissuing everything that lacks one (runbook §2.9b,
  `poam.md` AO-12).
- **The Kubernetes PKI is deliberately separate.** Verified against Canonical's documentation
  rather than assumed: the cluster runs three CAs of its own, etcd and the k8sd cluster
  certificate are self-signed regardless, and chaining the cluster under the enclave issuing
  CA would require `pathlen:1` where the issuing certificate is `pathlen:0`. The decision on
  record is that the cluster will not be bootstrapped to an external CA, so
  `CA_ISSUING_PATHLEN` stays 0 (runbook §2.9c).

### 2.5 Storage

Ceph from `noble-updates/main` debs on the worker guests, exposed to Kubernetes through
ceph-csi, **replica-3 across four OSD nodes**. The deb packaging carries Canonical's LTS
commitment — five years standard plus ESM, with 19.2.x backports — where the snap tracks
upstream Ceph's roughly annual calendar. That is a configuration-management argument as much as
a FIPS one: the snap path means **re-platforming Ceph roughly every year inside an accredited
enclave**, each time a media transfer and a baseline change. Checked 2026-08-31: Reef (18) was
already archived and EOL, and Squid (19) was about two months from EOL, while the deb in
`noble-updates/main` is `ceph 19.2.3-0ubuntu0.24.04.3` with all nine components (runbook §2.5).

**Four failure domains, and what that does and does not fix.** Replica-3 across exactly three
storage nodes cannot self-heal: lose a host and Ceph runs degraded until that physical box
returns, because there is no fourth domain to rebuild the third copy onto. That forced a
steady-state utilisation ceiling of about 60% and made every patch window a serial,
degraded-state operation. **The fourth OSD node removes all three constraints and was the
single highest-value change in the design revision** (runbook §1.2, HANDOFF §4). What remains
is that recovery capacity has to exist to rebuild into: after the lab's 500/500 disk split the
arithmetic is 2 TB raw, **~666 GB usable at replica-3 and ~400 GB working** (runbook §9a.2).

On the lab hardware, the 1 TB M.2 in hosts 1–3 is split into two partitions rather than two
logical volumes inside one LUKS container — **deliberately, because a host LUKS with Ceph's
`--dmcrypt` layered on top encrypts every OSD write twice.** Two partitions give each half
exactly one encryption layer with the right owner. The split is a parameter, `DATA_VG_SIZE`,
and `02-build-seed.sh` validates it before writing a seed, because a storage error appears
about forty seconds into an unattended install on a console these machines do not have
remotely. It accepts `-1` and `500G` and **refuses a bare `500`**, because subiquity reads a
bare number as bytes and the install then fails in a way that never says so (runbook §9a.2).

### 2.6 Application databases

PostgreSQL 16 with Patroni on three dedicated guests, one per physical host, with their **own
three-node etcd** separate from the Kubernetes cluster's. State does not live in the cluster.
The configuration-management reason is the deciding one: on a guest the PostgreSQL STIG applies
cleanly through the same procedure and tooling as every other machine, and in a container the
scanner cannot reach the filesystem and there is no answer to *"show me the PostgreSQL STIG
results"*. Harbor is the worked example — measured 2026-09-16, `svc-harbor-01` has **zero**
PostgreSQL packages visible to `dpkg`, and its bundled 18.3 is covered by no STIG at all
(runbook §9a).

Two configuration settings in that design are not negotiable and are recorded here because
both have a failure mode that looks like success:

- **Synchronous replication is expressed in Patroni's configuration, not PostgreSQL's.**
  Patroni manages `synchronous_standby_names` itself and rewrites it from which nodes are
  actually caught up, so a hand-written entry in `postgresql.conf` is replaced — and the
  failure mode is believing you have synchronous replication because you can still see the
  line you typed. The correct keys are `synchronous_mode: true` and
  `synchronous_node_count: 1` (runbook §9a.1 correction 2).
- **`cache=none` on the guest data disk is correctness, not tuning.** The default write-back
  cache puts a host page cache between PostgreSQL's `fsync` and the platter, so a host power
  loss can lose transactions the database has already acknowledged to the client — the same
  failure class as asynchronous replication with automated failover, one layer down (runbook
  §9a.2).

### 2.7 Backup

Whole-guest backup from the hypervisor with per-set SHA-256 manifests, chain-aware retention,
a nightly verify of changed sets and a weekly deep verify that re-reads every byte. The
mechanism is described in the Contingency Plan; what belongs here is that **every knob is a
parameter in `vm-specs.env`** — destination, retention, LUKS UUID and mapper name, keyfile
path, timezone, verify calendar, and the TRIM posture — so moving from a bench volume to
production storage is a change of values and a reattach rather than a change of procedure
(runbook §10b).

### 2.8 Monitoring

Prometheus, Alertmanager and Grafana on `svc-obs-01`, with node-exporter on every machine and
a libvirt exporter on the hypervisor. **34 alert rules in 9 groups**, and compliance, backup,
registry and patch-posture facts published every fifteen minutes on five machines through
node-exporter's textfile collector. It is described in the ISCM Strategy. Its
configuration-management relevance is that it **publishes live configuration state as
metrics**, so the question "is every machine still configured the way the baseline says" has an
instrument rather than an assertion (runbook §10a,
`../dashboards-and-metrics.md`).

---

## 3. CM-2 — the baseline configuration

**The baseline configuration of this system is an executable procedure with parameters, not a
document describing one.** That is the strongest sentence in this plan and it is literal.

| Baseline element | Where it lives | What it fixes |
|---|---|---|
| The build procedure, step by step | `docs/runbook.md` | Host and guest installation, Pro attach, FIPS enablement, STIG application, service build-out, cluster bootstrap, storage, monitoring, backup |
| Host installation parameters | `scripts/install/02-host-autoinstall/host-params.env` | Disk matching by `id_path`, LV sizes, `DATA_VG_SIZE`, encryption and unlock method, addressing, account name, password hash, NIC name |
| Guest specifications | `scripts/enclave/vm-specs.env` | Per-guest vCPU, RAM, disk and data disk, firmware, Secure Boot, bridge, pools, base image, mirror URL and suites, extra packages, power order and timeouts, every backup parameter |
| Addressing | `scripts/enclave/enclave-addresses.env` | Every enclave address and the domain. **Nothing else in the repository may hardcode an enclave address** |
| PKI parameters | `scripts/enclave/ca-params.env` | CA names, leaf lifetime, path length, CRL and OCSP distribution points, name constraints |
| Transfer parameters | `scripts/transfer/transfer-params.env` | Staging and target hosts, paths, tools directory |
| Assessment tailoring | `scripts/enclave/stig-tailor.sh`, `scripts/enclave/answerfile.sh` | Every STIG deviation, its target value and its written justification |
| Alert thresholds | the `AL_*` values at the top of `scripts/enclave/monitoring.sh` | **21 named thresholds** (counted 2026-09-17). **Nothing is hardcoded** |
| Facility-specific values | `facility-profile.env` in this directory | Every value that changes per engagement, and nothing else |

**The principle behind the parameter files is worth stating because it is what makes the
baseline verifiable:** a value that appears in nine places by hand is a value nobody dares
change, and the two places that get missed are the ones an assessor reads. One source,
referenced everywhere. `apply-addresses.sh` is the worked example — it renders the managed
block of `/etc/hosts` on every node from `enclave-addresses.env` between markers, touching
nothing outside them, so renumbering the enclave is *edit one file, run one command*.

### 3.1 The baseline is reproducible, and that is CM-2's actual test

An assessor asking *"how do you know every host is configured the same way"* gets a script and
a parameter file, not an assurance. Two properties make that true:

**Disks are matched structurally, not by size.** An early template used
`match: {size: smallest}`, and on the pathfinder that resolved to the **120 MB USB seed stick**
rather than the 256 GB SATA disk. Curtin wiped the stick and then failed creating a 1 GB ESP on
a 120 MB device. Subiquity does not exclude removable media from size matching. Both templates
now match on `id_path`, which encodes the physical bus — so `*-ata-*` and `*-nvme-*`
structurally cannot select a USB device and need no per-machine inventory. **Never use
`size: smallest` or `size: largest` in an autoinstall that boots from USB** (open-questions,
2026-08-28).

**The install is unattended and leaves its own record.** Booting with the seed and no
`autoinstall` kernel keyword gives one confirmation prompt and then an unattended install, so
no ISO remastering is needed. Note the limitation honestly: **the prompt shows network
configuration only — no disk or partition summary** — so there is no checkpoint at which the
partition plan can be reviewed before it is written. Verify after the install with `lsblk`
(open-questions, 2026-08-28).

### 3.2 What is deliberately not in the baseline repository

Five paths are excluded from version control because they are client-private engagement
material, and two more classes because they are credentials.

| Excluded | Why | How it is handled instead |
|---|---|---|
| `HANDOFF.md`, `docs/open-questions.md`, `docs/runbook.md`, `artifact/`, `archive/` | Client-private engagement material; `origin` is a public remote | `scripts/private-sync.sh pack`/`unpack`/`backup`, which verifies the checksum of the file that actually landed and opens the archive on the far end |
| `host-params.env`, `services-params.env`, `ca-params.env`, `transfer-params.env`, `airgapped-contracts.yaml`, `.pro-contract-token`, `seed-*.iso`, keys and tokens | Each holds a plaintext credential by design | Tracked `.example` files carry the structure; live values are per-machine |

**Two consequences, and both are real CM weaknesses rather than footnotes.**

First, **excluded from git means no change history for those files**, so a change to the
runbook or the open-questions tracker never appears in `git status` and nothing will remind
anybody to preserve it. The mitigation is a discipline and a script, not a control.

Second, **parameter files do not travel and nothing detects the drift.**
`push-repo-to-host.sh` sends only files tracked at HEAD — which is precisely what stops a LUKS
passphrase reaching every host — with the cost that every machine keeps its own copy of every
`*-params.env` and they diverge silently. Observed 2026-09-04: after the lab renumbered, one
machine's `transfer-params.env` kept a stale staging address and nothing reported it until the
next transfer two days later, which sat for two minutes and returned to a prompt. **The real
fix is deriving addresses from `enclave-addresses.env` at run time so they cannot disagree**;
a `--check` mode that compares them still relies on somebody running it. Tracked as `poam.md`
ENG-23.

### 3.3 File encoding is a configuration item, enforced by the repository

`.gitattributes` enforces it, and the reasons are failure modes that were paid for.

| Class | Requirement | What breaks otherwise |
|---|---|---|
| `*.ps1` | ASCII-only content, UTF-8 **with BOM**, **CRLF** | Windows PowerShell 5.1 reads `.ps1` as the system ANSI codepage unless a BOM is present, so a UTF-8 em-dash becomes three garbage bytes and the file fails to parse |
| `*.sh`, `user-data`, `meta-data` | **LF** | CRLF breaks the shebang and breaks cloud-init parsing — **including on removable media**, because files pick up CRLF in transit and must be re-verified after copying to a thumb drive |
| `*.zip`, `*.iso`, `*.img` | binary | Normalisation would corrupt them |

Validation before commit: `bash -n` for shell, the PowerShell parser for `.ps1`, and
`yaml.safe_load` for autoinstall configurations. PowerShell targets **5.1**, not 7 — no
ternary, no null-coalescing, no `-AsHashtable`, and TLS 1.2 forced before any download.

---

## 4. CM-3 — configuration change control

### 4.1 The mechanism

**Git history is the change record.** Every change to the build procedure, every parameter
value, every script and every assessment tailoring is a commit with a message. As of
2026-09-17 the repository carries 350 commits.

The change process for a technical change is therefore:

| Step | Action |
|---|---|
| 1 | Raise the change through «Jira or ServiceNow or eMASS or email to the ISSM» |
| 2 | **Change the parameter or the procedure, not the machine.** A setting typed at a prompt is a setting the next rebuild will not have |
| 3 | Validate: `bash -n` / the PowerShell parser / `yaml.safe_load`, and `shellcheck` where it applies |
| 4 | Commit, with a message that says what changed and why |
| 5 | **If the change is security-relevant, touch `../ssp-inputs.md` in the same commit, or say in the message why it does not** (§4.3) |
| 6 | Apply to the target machines through the documented path, which for scripts is `push-repo-to-host.sh` |
| 7 | Verify on the machine, and re-run the affected assessment |
| 8 | «CCB name, or the individual who approves changes» records approval |

### 4.2 The authority gap, stated plainly

Steps 1 and 8 are the two in that table that do not yet exist. **A commit records that a change
was made; it does not record that it was approved.** Naming the approval authority is a
tailoring action, not an engineering one, and until it is named CM-3 is satisfied
mechanically and not procedurally.

### 4.3 The rule that keeps the documentation from rotting

**A commit that changes security-relevant behaviour touches `../ssp-inputs.md` in the same
commit, or says in its message why it does not.** Not "later."

That rule exists because of two measured failures. Twenty-two statements important enough to
survive into an accreditation package accumulated as scattered asides across three weeks of
build work, precisely because nothing was collecting them. And the runbook carried an
instruction to enable the wrong Ubuntu Pro FIPS stream for **weeks** after the fact had
changed, because nothing forced a re-read — the stream `fips-preview` is unavailable on 24.04
and the correct stream is `fips-updates`, yet §2.3 still names the former as *"the stream the
decision rests on"* (`ssp-inputs.md` §6, `poam.md` ENG-25). Good intentions produced both.

### 4.4 Two change-control hazards found the hard way

**Do not push the repository to a host while a script from it is running.**
`push-repo-to-host.sh` replaced `vm-backup.sh` twenty-five minutes into a seventy-eight-minute
verify. Bash re-read the file from a changed offset, so the run executed the old per-set loop
and printed the **new** summary. The result claimed clean and could not be trusted — not
because the backups were bad, they were fine, but because it was no longer knowable which code
had run. Fifty-eight minutes and 402 GB spent producing an answer nobody could stand behind
(runbook §10b).

**The transfer bundle records no provenance, and nothing detects that a carried script is older
than the repository.** A stale `restore-mirror.sh` was found on the transfer media by reading
the file, not by any check. The fix is for `build-transfer-bundle.sh` to stamp the git commit
into the manifest and for `restore-mirror.sh` to print it on startup, so the version being run
is visible rather than assumed (open-questions backlog).

### 4.5 A guard, not a policy, keeps private material off the public remote

`origin` is public. `.githooks/pre-push` refuses a push **by branch name and by content**, so
the pre-squash history branch is blocked even if pushed under a different name. It is tracked,
so it travels with the repository — but **git does not track `.git/hooks`**, so every clone
must opt in with `git config core.hooksPath .githooks`. There is a deliberately awkward
override for a genuine false positive.

It has been tested against the live remote: a normal push passes, the protected branch is
refused by name, and a local branch cut from it under another name is refused on content,
naming the offending commit and every private path. **A correction to an earlier record is
worth carrying, because it is the class of test that looks valid and is not:** an earlier
"renamed branch" test used a push *refspec*, which does not exercise the content rule at all —
git reports the local ref under its original name regardless of the remote name, so the
branch-name rule catches it first. Only a genuine local branch reaches the content rule
(open-questions).

---

## 5. CM-4 — impact analysis

Some configuration changes in this enclave are cheap and some cannot be undone. The plan's
contribution is to name the second kind, because the cost is not obvious from the change.

| Change | Why it is not reversible in place |
|---|---|
| **Pod CIDR, service CIDR, cluster DNS domain** | Changing one after bootstrap means rebuilding the cluster (runbook §3.0) |
| **The 13 Kubernetes STIG Bootstrap guidelines** | They must be correct at cluster creation; getting them wrong means rebuilding the cluster (HANDOFF §3a) |
| **Ceph OSD encryption** | `--dmcrypt` is create-time only; converting an existing OSD means destroying and rebuilding it with data movement across a slow four-node cluster (runbook §2.5) |
| **OSD device sizing** | Uneven OSD sizes skew placement noticeably at four nodes, and replica-3 across four nodes is gated by the three smallest OSDs. `k8s-wk-04`'s OSD must be trimmed to match (runbook §9a.2) |
| **Issuing CA `nameConstraints` and `pathlen`** | Both require re-signing the issuing certificate, which is cheap now and expensive once more leaves exist. They fold into a single re-issuance event (runbook §2.9b) |
| **A CRL distribution point** | Adding one later means reissuing every certificate that lacks one (runbook §2.9b) |
| **Enabling Secure Boot after TPM enrolment** | PCR 7 measures the Secure Boot policy, so enabling it later **changes PCR 7 and breaks every existing TPM seal** (`docs/02-host-install.md` §4c) |
| **Clearing the TPM** | Cannot be done remotely afterwards, and these are ex-Windows machines where BitLocker may still own the TPM (`docs/02-host-install.md` §4c) |
| **`usg fix`** | Removes packages and stops services as well as tightening settings. Run `stig-tailor.sh preflight` first — on one machine `isc-dhcp-server`, `python3-txtftp` and `squid` were all live and all were MAAS (runbook §6.3f) |
| **The AIDE database** | `usg fix` **builds** it as part of remediation, so whatever is in scope at that moment gets hashed inside the fix run with no progress output. On the mirror machine that was 321 GB at ~26 MB/s — about three and a half hours; on the hypervisor it would be ~1.9 TB. The exclusion must exist **before** the fix, not after (runbook §6.3h) |
| **Renumbering the enclave before the mirror serves packages** | Leaves the hypervisor with no package source at all, including the tools needed to fix it (runbook §3.0) |

**One impact-analysis lesson is worth generalising beyond configuration.** A retention policy
that counts objects cannot be correct unless every object is independent. The moment one object
is a delta against another, counting is the wrong operation and only the dependency graph will
do. This enclave learned it by deleting every full backup it had (Contingency Plan §6.1). **Any
`KEEP=N` parameter in this repository deserves the question: N of what, and what depends on
what.**

---

## 6. CM-5 — access restrictions for change

| | |
|---|---|
| **No remote access path exists.** MA-4 nonlocal maintenance is trivially satisfied: there is no remote maintenance capability at all | `nist-800-53-plan.md` |
| **Local accounts only**, with no directory service. `usg fix` removes blanket `NOPASSWD`, so anything privileged must be typed by a human — scripts that ran `ssh host sudo ...` stop working after hardening | runbook §6.0 |
| Per-command sudo exceptions are scoped and justified, not blanket | `nist-800-53-plan.md` AC |
| The DoD consent banner precedes all SSH output. **Anything parsing that output must tolerate several hundred bytes before the command's own output** | runbook §6.0 |
| Boot-time secrets — the LUKS passphrase and the GRUB superuser password — come from a controlled document and are **never in this repository** | runbook §6.0 step 12c |
| Guest SSH trust is currently inherited from the compose host's own `authorized_keys`, which is a defect: access to a machine should be a stated decision, not a side effect of which box the composer ran on | `poam.md` ENG-27 |

**One access-control hazard belongs in this plan because it is triggered by making a change.**
`pam_faillock` is configured `deny=3` with `unlock_time=0`, `sudo` allows three tries per
invocation, and `silent` makes the lock look like a typo. **One fumbled password prompt locks
the only administrative account, permanently, until a tally file is truncated by hand** — on a
headless machine reached over SSH. The procedure is to open a second SSH session and leave it
open before starting any hardening work, because public-key authentication bypasses PAM's auth
stack and an existing session survives a broken `sudo` (runbook §6.0 steps 1–2, §6.3m).

---

## 7. CM-6 — configuration settings

### 7.1 The two scanners, and the relationship between them

This enclave assesses every machine with **both** the Ubuntu Security Guide and DISA's
Evaluate-STIG, in that order, and the order is evidence-based rather than a preference.

**`usg fix` is the only remediation engine here; Evaluate-STIG does not remediate at all.**
Measured on this enclave: an unhardened machine shows **118 Open** against DISA V1R6, and the
same machine after `usg fix` plus tailoring and fixups shows **20**. Scanning with
Evaluate-STIG first would hand an operator 118 findings to work by hand, 98 of which `usg fix`
closes for free. Running it second means it measures the residual — a roughly twenty-item list
on a machine already 83% of the way there (runbook §6.0).

**Neither scanner is redundant.** USG hardens and scores against Canonical's V1R1;
Evaluate-STIG assesses against the revision DISA will actually use and emits the CKL/CKLB an
assessor consumes. The relationship has to appear in the evidence package, because the two
numbers differ and an unexplained difference reads as a discrepancy: on one machine on one day,
**USG reported 7 fail while Evaluate-STIG V1R6 reported 20 Open and 14 Not Reviewed**
(runbook §10.1f, `poam.md` AO-17).

The profile name is pinned in its versioned form, `stig-v1r1`, and **not** taken from the
floating alias `disa_stig`, which will move (runbook §6.0 step 6).

### 7.2 Current settings state, per machine

Every figure below is a measurement with a date, not a target.

| Machine | USG pass / fail | Evaluate-STIG V1R6 Open | Measured |
|---|---|---|---|
| `host-4` | 208 / 8, re-audited with the chrony deviations | 5 | 2026-09-16 |
| `svc-harbor-01` | **210 / 6** | 5 | USG 2026-09-16 |
| `svc-mgmt-01` | **209 / 6** | 6 | USG 2026-09-16 |
| `svc-repo-01` | **212 / 5** | 5 | V1R6 2026-09-16 |
| `svc-obs-01` | **211 / 5** | 4, plus 9 Not Reviewed | 2026-09-14 |

**The residual set is six, and it is the same six on machines with nothing in common.** Five
apply everywhere — `encrypt_partitions`, `ufw_rate_limit`, `service_sssd_enabled`,
`sssd_enable_user_cert`, `auditd_offload_logs` — and `check_ufw_active` is added on the three
machines where ufw cannot enforce. **All are policy decisions with written rationales. None is
a defect** (`airgapped-setup-machine/README.md` §0).

**One correction in that record is worth carrying, because the arithmetic caught a wrong
assumption.** The residual was believed to be seven, with the seventh assumed to be the GRUB
password rule dropping after the GRUB work. It was not: fail fell by one, `notselected` rose by
one, and pass never moved — so a rule went `fail → notselected`, which is a journal-permissions
deviation being applied. GRUB was already closed. **The seventh finding was the journal rule**
(`airgapped-setup-machine/README.md` §0).

### 7.3 The one configuration item that can un-configure itself

**`--unrestricted` on the GRUB boot classes lives in `/etc/grub.d/10_linux`, which is a
package-managed file.**

The configured state is the safe one and it is measured: on `host-4`, 2026-09-17,
`stig-tailor.sh grubpw status` reports `--unrestricted` present at `10_linux:34`, one
`superusers` line, one `password_pbkdf2` line, and `unrestricted=5` in the generated config.
So GRUB demands the password to **edit** a boot entry and not to **boot** one. V-270675 is met
and hardened hosts still reboot unattended.

**But it is a state, not a property.** A `grub-common` update or a re-run of `usg fix` can
replace that file and re-arm the trap, and nothing announces it. The generated `grub.cfg` would
then demand a password to boot — on a host whose LUKS root already stops at a console, and in
this enclave's case on hosts with no BMC to watch it fail from.

> **Therefore: `stig-tailor.sh grubpw status` belongs in the post-patch verification
> procedure, not only the post-hardening one.**

This is the clearest example in the enclave of why configuration verification has to be
periodic rather than a one-time gate, and it is the single caveat that keeps CM-6 from being
unqualified here (HANDOFF §3, `ssp-inputs.md` §4.4, `poam.md` ENG-20).

### 7.4 Deviations are tailored, not deselected, and they must be expressed twice

Two mechanisms, and they are not interchangeable:

- **`stig-tailor.sh`** expresses USG deviations as `set-value` retargeting rather than as
  exceptions wherever possible, so the rule still runs and still reports.
- **`answerfile.sh`** writes Evaluate-STIG Answer File entries — **17 entries, zero
  `ResultHash` values** (counted in `answerfile.sh`, 2026-09-17) — each carrying `ValidationCode` that re-runs DISA's own CheckText at
  scan time, so the control re-opens if the underlying condition changes.

**A USG deviation does not travel to the tool DISA uses.** UBTU-24-600160 was Open in
Evaluate-STIG despite being tailored in USG, which is how this was found: every justification
needs an Answer File entry as well as a USG tailoring
(`airgapped-setup-machine/README.md` §0a E3a).

Three traps in that mechanism, all paid for:

| Trap | Effect |
|---|---|
| `ResultHash` on an entry | Ties the answer to one machine. The hand-built file answered only on the machine it was built on; three controls came back Open on every other machine |
| `ExpectedStatus` hardcoded to `O` | An answer for a Not Reviewed control generates cleanly, validates cleanly and **never fires**. `verify` now fails if a hash reappears |
| A deviation applied without checking the OVAL definition | One rule failed pre-fix and passed post-fix while `usg fix` wrote **nothing** to `/etc/modprobe.d/`, which suggests it tests whether a module is *loaded* rather than *blocked* |

And one deselection that is correct and should be understood as such:
`file_groupowner_system_journal` is deselected enclave-wide because it conflicts with another
rule in the same profile and its result depends on when the scan runs relative to the last
`systemd-tmpfiles` run (runbook §10.1).

**One rule must specifically not be deselected.** `encrypt_partitions` fails inside every guest
because the guest's virtual disk is not LUKS while the hypervisor's NVMe underneath it is.
**That is a compensating control, not a deviation** — write it up and leave the rule selected so
the finding and its rationale travel together (`poam.md` AO-08).

### 7.5 The assessment scope is full SRG coverage, by decision

Where DISA publishes no product STIG, this enclave assesses against the governing **SRG**
rather than recording an absence of coverage. The decision was taken 2026-09-13 and the reason
is a configuration-management one: **this build is a template for other facilities, and being
over-covered is cheaper than discovering a gap at the second site** (HANDOFF §3a).

| Target | Benchmark | State |
|---|---|---|
| Ubuntu 24.04, all machines | **Ubuntu 24.04 STIG V1R6** — 194 controls, DISA status Active, benchmark dated 01 Jul 2026 | Done. Four to six Open per machine, all AO decisions |
| KVM, libvirt, QEMU on the hypervisor | **No STIG or SRG exists.** Governed by the General Purpose Operating System SRG through the host OS STIG | **Already covered. Cite the absence of hypervisor guidance; do not report a gap** — the OS STIG *is* the published guidance for a KVM host, and that is a citation, not an excuse |
| PostgreSQL 16 | **Crunchy Data Postgres 16 STIG V1R1** (covers 13–16) | Open — the XCCDF is a CAC-only download (`poam.md` CUST-06), and Evaluate-STIG's shipped 9.x benchmark is **Sunset** and the tool refuses to score against it |
| PostgreSQL 18.3 inside the Harbor appliance | **No STIG covers 18.** Database SRG fallback; the CIS PostgreSQL Benchmark tracks versions faster | Open — decision plus write-up. **The version is not ours to choose** (`poam.md` ENG-12) |
| nginx | **No STIG exists.** Web Server SRG | Open (`poam.md` ENG-10) |
| Docker CE | The Docker Enterprise 2.x STIG **does not apply to CE.** Container Platform SRG | Open (`poam.md` ENG-11) |
| Kubernetes | **Kubernetes STIG** (2024-06-10). Canonical publishes a mapping: 91 guidelines — 62 Default, 13 Bootstrap, 10 Post-Deployment, 6 N/A | Open. **The audit is manual, and the 13 Bootstrap guidelines must be right at cluster creation** (`poam.md` ENG-13) |

The mechanism for all of it is already built: `StigContent/Manual/` takes any XCCDF, and
`answerfile.sh` writes portable validation code that runs the real check at scan time
(runbook §10.1).

### 7.6 The verification lesson that governs how settings are checked

**Suspect the check before the fix.** Seven checks in this build were found to be wrong in one
night, three of them producing **false passes** — a green result that proves nothing because
the check was not trustworthy. Worked examples, all measured:

- `promtool check config` passes happily for a configuration with **no rule files at all**, so
  the first "rules loaded" verification succeeded with zero rules loaded.
- `systemctl show` on a unit that **does not exist** exits 0 and prints defaults, so a
  nonexistent AIDE timer reported exit code 0.
- `node_scrape_collector_success{collector="textfile"}` reads 1 when **no directory is
  configured**, because with nothing to read there is nothing to fail at.
- `grep -q` under `set -o pipefail` is a false-negative generator: grep exits on first match,
  the producer dies of SIGPIPE with status 141, and the pipeline reports failure **even though
  grep matched**. Whether it bites depends on how far into the output the match is, which is why
  the same working configuration reported broken on three machines and fine on two.
- One machine's compliance facts were reported as another's, because the evidence glob was not
  scoped to the hostname.
- A measurement taken on a machine **whose `/srv` is empty** was used to conclude that AIDE
  does not index bulk data. It does. **Measure where the control can actually fail.**

> **The rule this produced: verification asks the running thing, never the file just written.**
> Count rules in the live Prometheus process, read Grafana's own database, ask the exporter
> which collectors it loaded, read the running process's command line.

---

## 8. CM-7 — least functionality

| Control point | Implementation | Evidence |
|---|---|---|
| No egress | No default route on any enclave host; no external connections at all | runbook §3.0 |
| Host firewall | `stig-tailor.sh ufw` holds the rule table with a justification per row. **Genuinely enforcing on two of five machines** — `host-4` bridges guest traffic and `svc-mgmt-01` opens ~30 MAAS ports where a wrong rule set breaks PXE, which is how hosts 1–3 get built | runbook §6.3e, `poam.md` AO-07 |
| Removable media | `usb_storage` **and `uas`** blocklisted. `uas` matters: blocking only `usb_storage` leaves a UAS enclosure working while the control looks applied | runbook §6.3g |
| Media exception | A **time-boxed, logged window** rather than a standing exception. `stig-tailor.sh usb enable [--minutes N]` auto-closes on a timer, and every open and close records who, when and which modules | runbook §6.3g |
| Admin web UIs | **Refused deliberately.** `cockpit` and `cockpit-machines` are both in the mirror and `cockpit-machines` is a good libvirt UI — but it is a listening admin service on every hypervisor, **no DISA STIG exists for Cockpit**, and on the hypervisor it means opening a port on the one machine where ufw deliberately refuses to manage rules. Control is `virsh` over SSH, which adds **zero** listening surface | runbook §10a |
| Removed surface | MAAS's `3128` squid proxy was pointless surface in an air gap with a local mirror. ✅ **MAAS was removed entirely 2026-09-18** — open listeners on `svc-mgmt-01` went **76 → 21** | runbook §6.3e |
| Service binds | Prometheus, Alertmanager and Grafana bind loopback only; Grafana is reachable solely through nginx on 443 with an enclave certificate. **All five components bind all interfaces out of the box**, so `monitoring.sh` proves the bind with `ss` after every restart rather than trusting the configuration it just wrote | `../dashboards-and-metrics.md` §9 |
| Hardware-dependent timers | `prometheus-node-exporter-collectors` installs five systemd timers. Each is kept **only if the hardware it reads exists**, checked per machine — the hypervisor keeps `nvme` and `smartmon`, the guests do not. Same command, different correct answer; a hardcoded list would be wrong on one of them | runbook §10a |

**Recording the threshold rather than the conclusion, on the admin UI decision:** at four hosts
the UI is not worth that trade. At forty it would be. The second facility may be bigger
(runbook §10a).

---

## 9. CM-8 — component inventory

**Generate it. Do not write it.** A hand-written inventory drifts from the day it is written,
and this repository has already proved the generated pattern twice — `apply-addresses.sh`
renders `/etc/hosts` from one source, and the facts timer publishes live state rather than a
snapshot.

| Inventory element | Authoritative source |
|---|---|
| Machines, addresses, domain | `scripts/enclave/enclave-addresses.env` |
| Guest sizing and configuration | `scripts/enclave/vm-specs.env` |
| Host hardware and disk identity | `scripts/install/02-host-autoinstall/host-params.env`, and `01-hw-inventory.sh` output per host |
| Live software versions | `enclave_*` facts published every 15 minutes by the monitoring stack |
| Package provenance | **Every package's origin is known, because everything entered through one audited mirror.** Snaps are served as verified files; Harbor is the only image source |
| Per-machine assessment state | CKL / CKLB files collected to the staging machine by `stig-tools.sh collect` |
| Ports, protocols and services | `enclave_listen_socket` and `enclave_ufw_rule` facts, joined with `scripts/enclave/ppsm-services.tsv` and the DISA CAL by `scripts/enclave/ppsm.py` — the PPSM CLSA is generated, never typed (backlog 6a.22) |
| Guest placement | `PLACE_*` in `scripts/enclave/vm-specs.env`; `03-compose-vm.sh plan` verifies it against measured hardware and **refuses** to compose a guest away from its declared host (backlog 2.7) |

**Two tools entered the boundary for assessment and are components in their own right:**

| Tool | Where | Why it is here, and what it can do |
|---|---|---|
| `nmap` 7.94 | `svc-obs-01`, from the enclave mirror (`universe`, so `esm-apps` covers it) | The reachability half of the PPSM assessment: listening is not the same as reachable, and a `systemd` address filter is invisible to `ss`. **It is an active scanner inside the boundary** — it trips `ufw`'s rate limiting, which is why scan results and monitoring results must be read together rather than one overriding the other |
| Root-owned runtime copy | `/usr/local/lib/enclave` on every machine, installed by `scripts/enclave/install-runtime.sh` | systemd timers must execute only code root can change. The repository checkout is writable by `encadmin`, so timers running from it were a privilege-escalation path (backlog 3.11). **The copy goes stale deliberately** — refreshing what root runs on a schedule requires `sudo` and leaves the same record as any other privileged act |

**The inventory has not yet been extracted into a deliverable format** (`poam.md` ENG-63).

Two honest limitations on provenance, both already tracked. Between **24 and 46 third-party
packages per machine** are covered by no Ubuntu subscription at any tier, and two of them are
structurally interesting: `patroni` and `etcd-server` are both from `universe`, so the database
cluster's consensus layer is not in `main` (`poam.md` ENG-42, AO-11). And Grafana crosses the
gap as a single checksum-verified `.deb` rather than as a mirrored repository, **deliberately**
— mirroring the vendor repository would mean adding a new signing key to the trust store on
every machine that installs from it, and in an IL5 build every trusted key is a supply-chain
question somebody has to answer (runbook §10a).

---

## 10. CM-9 and CM-11 — this plan, and software installed by users

This plan is maintained by «ISSM_NAME» and reviewed at «how often it meets, or "by ticket" if there is no board». It is stored with the rest of the package in «the authoritative repository location and its custodian».

**There is no user-installed-software problem in the ordinary sense, because there is no
`apt install` path to the internet.** Every package comes from the enclave mirror on
`svc-repo-01` over TLS with a signed `InRelease`, every snap is side-loaded as a verified file
with its assertion, and every container image comes from Harbor. **A mirrored PPA is not
automatically installable** — it needs an explicit source stanza and its key — which is a
deliberate friction point rather than a defect (runbook §4.4a).

One consequence worth stating, because it shapes the diagnostic toolset: there is no
`apt install` inside the boundary for anything that was not mirrored, so the Minimal image's
package list is a design decision made in advance and not a runtime one. `VM_EXTRA_PACKAGES`
in `vm-specs.env` is where it lives (runbook §2.4).

---

## 11. Configuration verification, and the transfer process as a CM control

### 11.1 Drift detection

| Mechanism | What it detects | Cadence |
|---|---|---|
| **AIDE** | File-integrity drift on the configured paths | Periodic, by cron/timer. `AideCheckStale` alerts if no run in 36 hours; `AideDetectedChanges` alerts on a non-zero exit |
| **Compliance facts** | STIG residual, USG results, `auditd` loss, certificate expiry, AIDE state, faillock and sudo counts | Every **15 minutes** on all five machines |
| **`StigScanStale`** | A checklist older than 30 days | Hourly evaluation |
| **`StigOpenControlsIncreased`** | More Open controls than one day ago — **drift, not the residual itself** | 15 minutes |
| **`FipsModeDisabled`** | `fips_enabled` gone to 0 | 10 minutes |
| **`apply-addresses.sh verify`** | Every node resolving every name | On demand |
| **`stig-tailor.sh grubpw status`** | The GRUB `--unrestricted` state (§7.3) | **Post-patch, per the caveat** |

**AIDE's scope is itself a configuration item, and getting it wrong is expensive.** The
exclusion fragment `/etc/aide/aide.conf.d/90_aide_enclave_exclude` is numbered 90 so it sorts
ahead of the `/ 0 Full` catch-all, and it works before AIDE is even installed — which it has to,
because `usg fix` builds the database as part of remediation (§5).

**Nothing alerts on the residual set being non-zero, deliberately.** It is non-zero by design
and every finding in it has a written rationale. The alert is on it *changing*
(`../dashboards-and-metrics.md` §7).

### 11.2 Media transfer is a configuration-management process

Everything entering the boundary crosses on media, and the path is scripted rather than
manual: `build-transfer-bundle.sh` stages and hashes the bundle, `write-transfer-media.sh`
writes the volume, and `restore-mirror.sh` unpacks it inside the gap. Transfer authority is
«who approves a transfer across the gap».

Four properties and one defect:

- **The clean step is inside the script with its guards, not typed at a prompt** — and the
  guard fires *first*. An early version checked the target path only **after** a writability
  test, so `/etc` was rejected merely because the caller was unprivileged and would have
  proceeded as root. **A safety check that depends on the caller being unprivileged is not a
  safety check.**
- **LF endings must be re-verified after copying to removable media**, because files pick up
  CRLF in transit (§3.3).
- **A destructive command keyed on a disk model would hit the wrong disk on the hypervisor**,
  because the USB enclosure reports an all-zero serial there and the machine's own OS disk is
  the same model. Key on the filesystem label, and understand that a serial check can return
  **nothing** rather than failing loudly (`poam.md` ENG-24).
- **Scope the whole enclave's needs before a cutover, not after.** The first cutover happened
  with the apt mirror complete and three other services' software never mirrored, because
  nobody asked what the later build steps would need while the cable was still in. The cutover
  itself was still right — it proved a transfer path that had only ever been read, and found
  six defects in the restore script including one that made the contracts server unreachable
  over HTTP. The cost was one extra trip.
- **The defect: the bundle records no provenance** (§4.4).

### 11.3 Evidence collection is part of configuration management, not separate from it

`stig-tools.sh collect` walks the address table and pulls USG and Evaluate-STIG output from
every machine to the staging host with one privileged call per machine.

**This step was skipped on every machine until 2026-09-14.** All five machines held their own
checklist, the staging host held none, and four of the five are guests that can be rebuilt.
The first real run took **103 files and 337 MB off five machines**. It is recorded here because
it is the case the step exists for: **evidence you cannot collect is evidence you do not have**
(runbook §6.0 step 14).

---

## 12. Four controls this configuration satisfies unusually well

Worth stating explicitly, because an air gap is normally described in terms of what it costs.

- **CM-2 baseline configuration** — the baseline is an executable procedure with parameters,
  not a document describing one.
- **CM-7 least functionality** — the admin UI was declined on a recorded threshold, the squid
  proxy was removed rather than firewalled, and every service bind is proven with `ss` rather
  than assumed.
- **SR supply-chain provenance** — every package, snap and image entered through one audited
  path and its origin is recorded.
- **MA-4 nonlocal maintenance** — no remote maintenance path exists. **State both halves of
  this**: it is simultaneously a strong control statement and, combined with a console LUKS
  passphrase and no BMC on three of four hosts, the reason the enclave has no remote recovery
  path at all (`poam.md` ENG-07, CUST-14). An assessor who reads only the favourable half will
  find the other.

---

## 13. Sources

| Reference | What it supplies |
|---|---|
| `docs/runbook.md` | The build procedure and the baseline itself. §1 topology · §2.3–2.6 platform decisions · §2.9 PKI · §3.0 addressing · §4.4a mirrored PPAs · §6.0 hardening sequence · §6.3 the deviations and what they cost · §9a databases · §10a monitoring · §10b backup · §10.1 the two scanners |
| `docs/02-host-install.md` | §4c the firmware pass, the no-BMC finding, and the Secure Boot recommendation |
| `docs/airgap-media.md` | Media handling, and the serial-check defect in §6.1a |
| `docs/compliance/ssp-inputs.md` | The decided statements with their evidence |
| `docs/compliance/nist-800-53-plan.md` | Family-by-family status |
| `docs/compliance/dashboards-and-metrics.md` | Every metric and alert rule, and §10's list of ways a check lies |
| `docs/open-questions.md` | The live tracker and the backlog |
| `HANDOFF.md` | §3 verified findings · §3a the locked SRG coverage decision |
| `airgapped-setup-machine/README.md` | §0/§0a per-machine tallies and the residual set |
| `.gitattributes`, `.gitignore`, `.githooks/pre-push` | The repository's own enforced configuration controls |
| `scripts/` | `install/` the numbered build scripts · `enclave/` the operational scripts and parameter files · `transfer/` the media path |
