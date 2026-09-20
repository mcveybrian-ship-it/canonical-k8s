# Contingency Plan — «SYSTEM_NAME» («SYSTEM_ACRONYM»)

| | |
|---|---|
| System | «SYSTEM_NAME» («SYSTEM_ACRONYM») |
| System identifier | «SYSTEM_ID» |
| System owner | «SYSTEM_OWNER» |
| Impact level | IL5 |
| Availability categorisation | «A_HIGH_MOD_LOW» |
| Control baseline | «800-53 Rev 5 High or Moderate» |
| **Recovery Time Objective** | **«Recovery Time Objective - NOT YET COMMITTED»** |
| **Recovery Point Objective** | **«Recovery Point Objective - NOT YET COMMITTED»** |
| Maximum Tolerable Downtime | «Maximum Tolerable Downtime» |
| Essential functions | «the mission functions the enclave must restore first» |
| Recovery lead | «recovery lead» |
| Alternate | «alternate, and how they are reached» |
| Notification list | «who is notified of an outage, and by what means - NOT email from inside the gap» |
| Boot-secret custodian | «who holds the LUKS passphrase and the GRUB password, and where» |
| Alternate processing site | **«NONE or the alternate processing site and its agreement reference»** |
| Alternate storage site | **«NONE or the alternate storage site for backup media»** |
| Last contingency test | **2026-09-20 — guest restore from backup, all 4 service guests, all booted (§9.2). No host-failure, failover or Ceph test yet** |
| Test cadence | «how often the plan is exercised» |
| ISSM | «ISSM_NAME» |
| ISSO | «ISSO_NAME» |
| Prepared by | «PREPARED_BY» |
| Document version | 0.1 draft |
| Document date | «YYYY-MM-DD» |

---

## 1. Read this first

**The recovery mechanism in this enclave is built, running and verified. The recovery *plan*
is this document, and two of its most important values are not yet decided.**

Those two are the RTO and the RPO. They are **commitments**, not measurements, and nothing in
this build has committed to them. This plan deliberately does not fill them in from what the
lab happens to achieve, because a recovery objective derived from current behaviour is not an
objective — it is a description with an official-sounding name. Measure, then commit, then
design to the commitment. §4 gives the measured numbers that the commitment should be made
against.

**And CP-4 has no evidence of any kind, because no contingency test has ever been run.** Not a
tabletop, not a restore, not a database failover, not a host-failure rehearsal. That is stated
in §9 in its own section rather than buried, because it is the first thing an assessor will
ask for and the answer is a plain no.

Three architectural limitations are stated in §2 and §3 rather than deferred to a risk
appendix: both recovery paths terminate on one machine, the design does not survive a site
event, and the enclave cannot come back from a power event without a human at the rack.

---

## 2. The architecture that recovery has to work with

This section is stable across facilities. It is written out in full because every recovery
statement in this plan depends on it, and because the shape of the design determines which
failures are survivable and which are not.

### 2.1 Four hosts, and what each failure costs

Four bare-metal hosts running KVM/libvirt. Hosts 1–3 each carry a Kubernetes control-plane
guest, a worker guest and a PostgreSQL guest. Host 4 carries the fourth worker — the one that
gives Ceph a fourth failure domain — plus all four enclave service guests: the Ubuntu
Pro contract server on `svc-mgmt-01`, the apt mirror and Landscape mirror on `svc-repo-01`,
Harbor with its registry, database and Trivy on `svc-harbor-01`, and Prometheus, Alertmanager
and Grafana on `svc-obs-01` (runbook §1, §1.1).

**The asymmetry between the two failure cases is deliberate and it is the design's main
availability decision.**

| Failure | What survives | What is lost |
|---|---|---|
| **Any of hosts 1–3** | etcd keeps quorum on the remaining two control planes; the remaining workers keep running; **Harbor, DNS and the mirror are all standing, so rescheduled pods can pull images**; Ceph rebuilds the lost replica onto the fourth failure domain; the two surviving PostgreSQL guests retain an etcd quorum and a synchronous pair | One control plane, one worker, one database node. Capacity, not function |
| **Host 4** | etcd keeps quorum on hosts 1–3; running pods keep running on locally cached images; Ceph still holds three copies across three surviving hosts | **The ability to build and patch**, not the ability to run — plus, critically for this plan, **the ability to restore anything** (§3.1) |

Putting the registry on a cluster host is what makes a host failure cascade: the host dies,
pods reschedule, and the rescheduled pods need image pulls from a registry that died with the
host. Concentrating the services on host 4 means **losing any of hosts 1–3 leaves the enclave
able to recover from the failure it just had** (runbook §1.1).

Every guest is pinned to its host. Nothing may ever migrate two control planes onto one box.

### 2.2 Storage, and the recovery capacity that has to exist

Ceph on the worker guests' local NVMe, exposed to Kubernetes through ceph-csi, **replica-3
across four OSD nodes**.

**The three-node version of this design could not self-heal at all.** Replica-3 across exactly
three storage nodes has no fourth failure domain to rebuild the third copy onto, so losing a
host meant running degraded until that physical box returned. It also forced steady-state
utilisation to roughly 60% or below and made every patch window a serial, degraded-state
operation. **The fourth OSD node removes all three constraints and was the single
highest-value change in the design revision** (runbook §1.2, HANDOFF §4).

What remains, and belongs in a contingency plan rather than a design document: **self-healing
requires free capacity to heal into.** The lab arithmetic after the 500/500 disk split is 2 TB
raw, **~666 GB usable at replica-3, and ~400 GB working under the utilisation ceiling**
(runbook §9a.2). The production figure cannot be computed because the application's storage
requirement has never been captured — replica-3 makes usable roughly raw ÷ 3, and the
utilisation ceiling means provisioning roughly **five times** the usable figure in raw NVMe, so
a 2 TB application requirement is about 10 TB raw across four hosts (runbook §1.3,
`poam.md` CUST-03).

Also relevant to recovery expectations on the lab hardware: **consumer M.2 has no power-loss
protection**, so `fsync` latency is roughly 1–5 ms against sub-0.5 ms on enterprise drives.
etcd and Ceph are both `fsync`-bound. Expect etcd `apply entries took too long` warnings and
slow Ceph recovery on this hardware, and **read them as lab-hardware artefacts rather than
design faults** (runbook §1.5).

### 2.3 Databases

PostgreSQL 16 with Patroni on three guests, one per physical host, with their own three-node
etcd that is **deliberately separate from the Kubernetes cluster's**. Sharing the cluster's
etcd would re-couple database failover to cluster health, which is the coupling the design
exists to remove (runbook §9a).

**Synchronous replication is not optional here, and the reason is a recovery reason.** A
previous deployment lost a database, and the mechanism is worth stating precisely because the
same mistake is available on guests: asynchronous streaming replication plus automated
failover. The primary acknowledges a commit to the client, the standby has not received it, a
failover promotes the standby, and those acknowledged transactions are gone. That is
documented as-designed behaviour for asynchronous replication, not a fault, and it was
**almost certainly not a Kubernetes defect** (runbook §9a).

With `synchronous_commit = on` and at least one standby required to have the commit durably on
disk, **a failover cannot lose an acknowledged transaction.** The setting is expressed in
Patroni's configuration — `synchronous_mode: true`, `synchronous_node_count: 1` — because
Patroni rewrites `synchronous_standby_names` itself and a hand-written entry in
`postgresql.conf` is replaced (runbook §9a.1 correction 2).

**`synchronous_mode_strict` is deliberately off, and that decision has one dependency.** With
it off, losing every standby silently degrades the primary to asynchronous — the exact
condition that lost the previous database. With it on, writes block instead. Off plus an alert
is the right answer here **only because the monitoring stack exists**: a rule against Patroni's
metrics catches the degradation inside fifteen minutes, and a blocked write path at 03:00 with
one operator on site is the worse outcome. **That alert rule is owed and does not exist yet**,
which means the decision is not yet defensible (runbook §9a.3, `poam.md` ENG-06).

Applications find the primary with no load balancer at all, using `libpq`'s native multi-host
support with `target_session_attrs=read-write` — which resolves to the Patroni leader by
definition. It is client-side, so it works in an air gap, and it adds nothing to the boundary.
The cost is that applications need connect-time retry logic, because failover is detected at
connect time (runbook §9a).

### 2.4 Rebuild beats restore for most of this enclave, and that is a recovery strategy

**A rebuilt machine is identical to a restored one and arrives with evidence that it was built
correctly.** The build procedure and its parameter files are the primary recovery mechanism for
anything reproducible. Restore is the right answer only for state that nothing can regenerate.

Measured 2026-09-14, allocated bytes rather than qcow2 ceilings, cross-checked against `df`:

| Guest | Irreplaceable state | Size |
|---|---|---|
| `svc-repo-01` | **Nothing** — but re-mirroring costs another transfer trip | **331 GB** |
| `svc-mgmt-01` | The **issuing CA private key**, the Ubuntu Pro contract server, and the enclave DNS zones | 34 GB — ⚠️ **re-measure: MAAS and its database were removed 2026-09-18** |
| `svc-harbor-01` | Images that have been pushed, and Trivy's vulnerability database | 15 GB |
| `svc-obs-01` | Grafana's database and Prometheus history | 7.2 GB |
| | **total** | **386 GB** |

**`svc-repo-01` is 86% of the total and holds nothing that cannot be rebuilt**, so a policy of
"everything except the mirror" costs 55 GB. That is a real recovery-strategy option and it is
recorded here so it can be chosen deliberately rather than discovered during a capacity
argument (runbook §10b).

---

## 3. The three limitations this plan states rather than defers

### 3.1 Both recovery paths terminate on host 4

**They are two recovery mechanisms, not two independent recovery paths.**

| Path | Lands on | Physical host |
|---|---|---|
| Whole-guest backup sets | `/mnt/vmbackup` | **host-4** |
| The proposed PostgreSQL WAL archive | either `svc-repo-01` or host-4's freed M.2 space | **host-4** |

Lose host 4 and you lose the ability to restore **and** the ability to roll forward, while the
databases on hosts 1–3 sit healthy and unrecoverable to any point but their own present state
(runbook §9a.1 correction 1, `ssp-inputs.md` §3.2).

This is a **sharper statement than the site-event caveat below, not the same one**, and it
deserves its own sentence in the SSP. The backup destination is a parameter
(`BACKUP_DEST` in `vm-specs.env`), so moving one path off host 4 is a change of value and a
reattach rather than a change of procedure — but it has not been done, and the target is
«production backup destination - iSCSI/NFS/LUN, NOT a USB disk on the hypervisor»
(`poam.md` ENG-02, ENG-03).

A related detail that makes this worse rather than better: the ~500 GB freed on host 4's 1 TB
M.2 by the disk split is genuinely **the best WAL-archive candidate available** — a dedicated
device, off the database hosts, not mixed into the apt mirror. **It does not fix this
limitation. It is still host 4** (runbook §9a.2).

### 3.2 The design survives a single host failure. It does not survive a site event.

**State which one is being claimed, because an assessor will ask, and the honest answer is the
narrower one.**

Three PostgreSQL guests on three hosts in one room survive a **host** failure. A rack, power or
cooling event takes all three simultaneously — and the backup volume is a disk attached to host
4 in the same room (runbook §9a, `ssp-inputs.md` §3.1).

**This is single-site with no standby of any kind, and it is the largest unaddressed risk in
the design** (HANDOFF §4). It is not a configuration gap and no amount of work inside this
boundary produces a recovery site: a standby is a second enclave and a second ATO boundary.
Either the AO accepts single-site with no disaster recovery as a stated risk, or the programme
funds a second site. There is no third answer (`poam.md` AO-19).

Accordingly, `«NONE or the alternate processing site and its agreement reference»` and
`«NONE or the alternate storage site for backup media»` are answered per engagement, and in the
lab both are NONE. **CP-7 is not satisfied and this plan does not claim it is.**

### 3.3 The enclave cannot come back from a power event without a human at the rack

Measured, not predicted. On 2026-09-17 host 4 was rebooted for a package upgrade. Its LUKS root
volume **stopped at the console until somebody typed the passphrase**, and all four service
guests went down with it — the whole enclave was unavailable for the duration
(`ssp-inputs.md` §2.1, open-questions Q20).

`/etc/crypttab` carries `crypt-os UUID=... none luks` — **no keyfile, by design**. Putting a
keyfile on the same disk would defeat the encryption the AO required. The data volume is fine:
it has a keyfile on the encrypted root and is mounted `nofail`. **It is the OS volume that
blocks.**

**And there is no way to watch it fail, either.** Hosts 1–3 have **no BMC** (confirmed
2026-09-17 — budget test hardware with no management port). A console passphrase plus no
out-of-band management means a power event, a kernel panic or a failed reboot requires a human
**physically at the machine, with no way to see why from anywhere else.** Either limitation
alone is survivable; together they remove remote recovery entirely
(`ssp-inputs.md` §2.1a, `docs/02-host-install.md` §4c).

**Acceptable for a lab with one operator on site. A materially different proposition for
production hardware in a facility somebody has to be escorted into**, where it is the
difference between a ten-minute fix and a scheduled visit.

Two mitigations exist and neither is in place in the lab. TPM 2.0 measured-boot unlock is the
mechanism that removes the console passphrase; it is built and parameterised as
`LUKS_UNLOCK=tpm2`, it seals to **PCR 7 only** (PCR 11 changes on every kernel update and this
enclave takes FIPS kernel updates), and enrolment **keeps the passphrase slot** so a bad seal
degrades to today's behaviour rather than bricking the host. It requires Secure Boot, which is
currently disabled on the guests and undecided on the hosts. And a BMC with IPMI or Redfish and
serial-over-LAN is a production BOM requirement — cheap at purchase, expensive to retrofit
(open-questions decision 2026-09-16, `docs/02-host-install.md` §4c, `poam.md` CUST-14).

**Consequence for the recovery objectives in this plan: any RTO commitment must include the
time for a person holding «who holds the LUKS passphrase and the GRUB password, and where» to
reach the rack.** That is not a technical delay and it cannot be engineered away while the
unlock is a console passphrase.

---

## 4. The backup mechanism, as built and verified

This is the part of the plan that is real. Everything in this section is running.

### 4.1 What it does

`vm-backup.sh` performs whole-guest backup from the hypervisor using libvirt's incremental
backup with checkpoints. **It refuses to run anywhere else, and the assertion is inside the
script rather than in a comment above a pasted command block.**

| Verb | Behaviour |
|---|---|
| `status` | Changes nothing. Destination checks, every guest with what it actually occupies, whether a full fits, and which checkpoints an incremental could build on |
| `full [guest]` | Full backup, starting a new chain. No name means all guests |
| `incr [guest]` | Incremental since the last checkpoint. **Falls back to a full if there is no checkpoint**, so it is safe as the only scheduled verb |
| `verify` | `qemu-img info` on every image plus the checksum manifest written at the destination. **Prints a count**, so "verified" cannot mean it checked nothing |
| `prune` | Retires chains beyond `BACKUP_KEEP_CHAINS`, with three guards (§6.1) |
| `progress` | Asks libvirt, not the filesystem. `df` knows what has landed; only `domjobinfo` knows the total, and a sparse qcow2 makes on-disk bytes a poor proxy |
| `keyfile` | Enrols a LUKS keyfile so a scheduled run needs no human |
| `reattach` | After a reboot: opens the USB window, unlocks, mounts, re-blocks USB |
| `schedule` / `unschedule` | Installs or removes **both** timers (§4.3) |
| `restore-plan <guest>` | Prints the restore steps and runs none of them (§5) |

### 4.2 Integrity, and the blind spot in it

**Every backup set carries a SHA-256 manifest**, and the manifest is the integrity statement
because it hashes the bytes that actually arrived on the volume.

Verification runs at two cadences, and the difference between them is a control rather than a
convenience:

| Run | Scope | Duration | What only it can detect |
|---|---|---|---|
| Nightly | **Changed sets only**, skipped by a per-set `VERIFIED` stamp recording the newest mtime that passed | seconds | That the set written twenty minutes ago arrived intact |
| Weekly | **`verify --all`** — re-reads every byte | ~80 min for 400 GB | **Silent decay** |

> **An mtime cannot detect bit-rot.** Silent corruption does not touch a timestamp, so a
> skipped set is taken on the word of a previous run rather than re-checked. That is the right
> trade for the nightly question and the wrong trade for the only check that ever runs — which
> is why the weekly deep verify exists and why `unschedule` removes both timers together.
> Removing one would leave a weekly hour-long read against a volume nothing backs up any more,
> reporting success on data going stale (runbook §10b, `ssp-inputs.md` §3.3).

**Incrementals are not `qemu-img check`ed, deliberately, and the reason is worth knowing
because the wrong version of this check reported every healthy incremental as corrupt.** A
push-mode incremental qcow2 carries a backing-file reference to the **live guest disk**;
`qemu-img check` opens the whole chain, the running guest holds a lock on that disk, and the
open fails for a reason that has nothing to do with the backup. Two healthy incrementals failed
identically while both manifests verified clean. **An alert that fires on every healthy run is
worse than no alert**, because the run where something *is* wrong is the one that gets ignored.
So: `qemu-img info` on everything, which parses the header without opening the chain, and
`qemu-img check` only where there is no backing file — which means fulls (runbook §10b).

### 4.3 The schedule

`vm-backup.sh schedule 02:00` installs **two** timers:

| Unit | When | What it does |
|---|---|---|
| `enclave-vm-backup.timer` | Daily at 02:00 in `BACKUP_TZ` | `incr`, then `verify` on changed sets only, then `prune` |
| `enclave-vm-verify.timer` | `BACKUP_VERIFY_ONCALENDAR`, default Sunday 04:00 in `BACKUP_TZ` | `verify --all`, re-reading every byte |

Five properties of the units are deliberate:

- **`RequiresMountsFor`** — the unit **fails** rather than writing to the wrong filesystem. An
  unmounted mountpoint is an ordinary empty directory on the root disk; without this the backup
  runs, reports success, and fills the system disk instead.
- **`Persistent=true`** — a missed run happens at the next opportunity instead of being skipped
  in silence. ⚠️ **It also fires a catch-up immediately when the calendar changes**, which was
  observed and is harmless here but would be a genuine surprise on a job with side effects.
- **`IOSchedulingClass=idle` and `Nice=10`** — a 300 GB copy should not starve the guests it is
  copying.
- **`TimeoutStartSec=6h`**, sized from measurement, not guessed.
- **`RandomizedDelaySec`** on the weekly, so it never lands exactly on the hour.

**The timezone is inside the calendar specification, not converted by hand.** Every enclave
machine runs UTC on purpose — audit and documentation timestamps are UTC and labelled — so
`OnCalendar=*-*-* 02:00:00` ran the job at 21:00 Central, in the middle of the working evening
while the guests were busiest. Converting by hand is wrong twice a year: 02:00 Central is 07:00
UTC under daylight time and 08:00 under standard, so a hardcoded offset moves the job by an
hour every spring and autumn and nobody notices. systemd 252 and later accept the zone inside
the specification and do the arithmetic. `schedule` **validates both specifications with
`systemd-analyze` before writing any unit** and prints the next elapse in UTC, because an
unparseable specification produces a timer that never fires and reports nothing at install
time (runbook §10b).

### 4.4 Refusals, because a backup that reports success wrongly is worse than none

| Refusal | Why |
|---|---|
| **Destination is not a mountpoint** | See `RequiresMountsFor` above. Nothing distinguishes that failure from a good run until the machine falls over |
| **Destination is not encrypted** | Data at rest is required at IL5, and these images contain everything the guests contain — **including the issuing CA private key**. `--accept-unencrypted` exists for bench work and does not carry to production |
| **Not enough room** | Compared against **actual allocated bytes**, not the nominal qcow2 ceiling, and both numbers printed |

One operational constraint that has to be in the procedure rather than learned: **a multi-hour
backup cannot live in an interactive shell on these machines.** `TMOUT=600` is set readonly on
every hardened machine "per security requirements" — the STIG idle-timeout control — and any
dropped session `SIGHUP`s the foreground job. The first full backup died at roughly 125 GB of
331 GB for exactly that reason. **Use `--detach` for anything large**; it runs under
`systemd-run`, survives logout and a closed lid, and writes to the journal (runbook §10b).

### 4.5 Measured cost — size any window from these numbers, not from an estimate

> **A full backup costs 2× the data in I/O.** It writes every byte, then reads every byte back
> to compute the manifest. Size maintenance windows from that, never from the copy alone
> (runbook §10b.1).

| Measurement | Value |
|---|---|
| One full set, all four guests | **401 GB** — measured, not estimated |
| Sustained read on the bench volume | **107 MB/s** |
| `svc-repo-01` alone (331 GB) | ~55 min to copy, **~52 min to hash** |
| The full recovery run, four guests | 21:17 → 23:21 UTC, **just over 2 hours** |
| Typical incrementals after the first full | `svc-mgmt-01` 7.0 GB · `svc-obs-01` 802 MB · `svc-repo-01` 248 MB · `svc-harbor-01` 258 MB |

**107 MB/s was the drive, not the bus** — a 2.5-inch platter sustains 100–130 MB/s while USB 3
carries 400 or more. The decision recorded 2026-09-17 was to replace it with an SSD, which is a
**speed swap and not a capacity swap**: the platter volume was 4.6 TB at 9% used, and the
replacement has about 3.6 TiB usable. `BACKUP_KEEP_CHAINS` was never forced by capacity and can
be raised now that `prune` is chain-aware — **but do the arithmetic against 3.6 TiB and the
measured 401 GB per chain**, not against the old 4.6 TB (runbook §10b.1).

Four things are easy to get wrong when the destination moves, and all four are recorded because
each is a silent failure:

| | |
|---|---|
| The enclosure decides the gain | A SATA SSD behind a USB 3.0 bridge lands ~400 MB/s; NVMe behind USB 3.2 Gen 2 lands ~1 GB/s. **Confirm UASP is in play** — `lsusb -t` must show `uas`, not `usb-storage`. A bridge falling back to BOT caps throughput, destroys queue depth, and presents as a slow *drive* |
| `BACKUP_LUKS_UUID` is the step most likely to be missed | The volume is addressed by LUKS UUID deliberately — never `/dev/sdX`, because this drive has already moved from `sdb` to `sda` once, and never the USB `by-id` string, because it changes in a different enclosure. The UUID is inside the header and follows the data |
| The new header must match the old one | **Match cipher and key size** (`cryptsetup luksDump`) or the data-at-rest posture changes silently on a FIPS-relevant control. This is how the `argon2id` default was caught — argon2id is not a FIPS-approved KDF, so formatting with defaults would have produced a weaker header than the one it replaced with nothing to flag it |
| The keyfile must be re-enrolled | `BACKUP_KEYFILE` stays on the hypervisor's **own encrypted root**, so it is readable only once that machine is already unlocked and running. **A stolen backup drive does not come with its key** |

> **🔴 Sequencing, because it has already gone wrong once in this enclave: the old drive is the
> only copy until the new one is verified.** Format the new drive, `rsync` the tree across —
> which preserves the per-set `VERIFIED` stamps and the manifests, so the first nightly stays
> at seconds — run `verify --all` on the **new** volume, and only then wipe the old one. Keep
> the old drive on a shelf as a second copy; it costs nothing (runbook §10b.1).

### 4.6 The removable-media collision, and what actually breaks

USB storage is blocklisted on the hypervisor by the STIG, and the backup destination is a USB
volume. The interaction is understood and measured rather than assumed.

**V-270718 / UBTU-24-300039 checks only the `modprobe.d` configuration files.** Its check text
greps `/etc/modprobe.d/*` for the block directives; it does **not** look at `lsmod`. So after
the time-boxed window auto-closes: the block file is restored and the control passes again, the
module is still loaded so the drive keeps working, and `modprobe -r` fails as expected because
a mounted filesystem holds a reference (runbook §10b, §6.3g).

**A reboot is what actually breaks it, not the timer.** The drive will not appear, the LUKS
volume will not be unlocked, and nothing will mount it. The timer carries
`RequiresMountsFor`, so **systemd fails the unit outright rather than backing up into an empty
directory on the root disk: a failed unit, not a silent gap.** Recovery is one command,
`vm-backup.sh reattach`, which opens the window, unlocks with the keyfile, mounts, and
re-blocks USB **from a trap** so the window closes even when the unlock or the mount fails.

> **No amount of scripting makes a STIG-blocked USB drive a good production backup target.**
> For a bench it is fine and documented. In production the destination wants storage that
> survives a reboot — which is exactly why the destination is a parameter. **A non-USB target
> also removes the blocklist exception entirely, which is worth more to the accreditation
> package than the throughput is** (runbook §10b.1, §6.3g).

One further stated posture: the backup volume is currently mounted with `discard`, which
reveals which blocks are unused and therefore approximately how full the volume is to anyone
holding the drive. The contents remain encrypted; the shape of the usage does not. It is
accepted because the volume is already a second copy and an SSD target with nightly churn loses
sustained write speed without it. **`BACKUP_TRIM` defaults to false so that enabling it is an
explicit act**, and it belongs in the SSP as a stated choice rather than being found in a
configuration file later (`ssp-inputs.md` §2.3, `poam.md` AO-15).

---

## 5. Restore

### 5.1 Restore is deliberately not automatic

`restore-plan <guest>` prints the steps and runs none of them. Restoring overwrites a running
system's disk, it is done under pressure, and that is where an unattended script does the most
damage.

Two properties of the printed plan are deliberate:

- **It renames the current disk rather than deleting it.** *"I deleted it first"* has no undo.
- **It ends by clearing libvirt's checkpoints**, because restoring an older image while newer
  checkpoints exist leaves the two disagreeing about what has changed.

A crash-consistent restore is acceptable for the database guests specifically because
PostgreSQL is crash-safe and comes up by replaying its own WAL. That is also why the guest data
disks are qcow2 rather than raw logical volumes, which would be faster: **`vm-backup.sh` backs
up qcow2 disks only, so a raw data disk means the OS disk is backed up and the database is
not** (runbook §9a.2).

### 5.2 Planned host-4 outage, and coming back

Rebooting host 4 is an enclave outage. The procedure is `vm-power.sh`, which exists because the
ordering, the waiting and the refusals are not things to retype at a rack at 01:00. Order,
per-guest timeout and boot timeout are parameters in `vm-specs.env`.

**The shutdown order, and why it is that order:**

| | Guest | Reason |
|---|---|---|
| 1 | `svc-obs-01` | It scrapes the other four and runs the alert rules. Stopping it first keeps a *planned* outage out of Prometheus as a fake incident |
| 2 | `svc-harbor-01` | Containerised PostgreSQL under docker-compose; the service must stop eleven containers and give the database a clean close. The slowest and most delicate stop — give it the most room |
| 3 | `svc-mgmt-01` | The Pro contract server and enclave DNS. ⚠️ MAAS's PostgreSQL was removed 2026-09-18; `postgresql@16-main` may still be installed — confirm before assuming a database needs a clean stop |
| 4 | `svc-repo-01` | nginx over static files. Nothing to lose, and it is what everything else installs from, so it stays up longest |

**But the order is the small half.** `virsh shutdown` is **asynchronous** — it sends ACPI and
returns immediately. What corrupts a database is not the wrong order, it is the host rebooting
while a guest is still flushing. So **every guest must read `shut off` before the host is
touched**, and `host-reboot` re-checks for running domains immediately before the reboot,
because a guest that came back between the two checks is exactly the case that corrupts a
database. **Never `virsh destroy`** — on a live database that is pulling the power cord, and it
is how a reboot becomes a restore. If a guest is still running after seven or eight minutes,
**do not reboot**; find out what is ignoring SIGTERM first.

> **🔴 `libvirt-guests` is not a safety net on this host, and this was measured.** On the
> 2026-09-17 reboot it logged `Can't connect to default. Skipping.` and then
> `Deactivated successfully` — libvirtd had already stopped when it ran, so it had nothing to
> connect to. **It shut down nothing and reported success.**
>
> The guests nevertheless closed cleanly: Harbor's PostgreSQL logged
> `database system was shut down at 00:24:44 UTC` on the way back up — a clean shutdown record
> rather than crash recovery, timestamped four minutes *before* `libvirt-guests` ran. All ten
> Harbor containers came back healthy and nothing was damaged.
>
> **So the finding is not "the guests were killed". It is that nothing in the shutdown path is
> accountable for them.** The unit whose job this is explicitly skipped, something else stopped
> them gracefully, and we cannot say with confidence what. It worked; it is not a procedure and
> it is not repeatable knowledge. **The old way's success cannot be explained, so it cannot be
> relied on** — and the first time it does not work, the evidence will be in a database rather
> than on a console (runbook §10c).

Also check what a bare reboot would do before doing one: Ubuntu's default `ON_SHUTDOWN=suspend`
makes a host reboot `managedsave` tens of gigabytes of guest RAM onto the LUKS volume — slow,
and not the intent — and if it hits `SHUTDOWN_TIMEOUT` the guests are killed anyway.

**Coming back up, three things in order:**

1. **The OS volume prompts for a LUKS passphrase at the console.** Nothing proceeds until
   somebody types it, and that somebody has to be at the machine (§3.3).
2. **Reattach the backup volume** — `vm-backup.sh reattach`. It does not come back on its own.
3. 🔴 **Confirm the guests actually autostarted. Do not assume.** All four have `virsh
   autostart` set, **but the image pool lives on the LUKS data volume mounted `nofail`.** If
   `libvirtd` starts before that volume mounts, autostart fails and you get four `shut off`
   domains **with no error anywhere** — `nofail` is what makes it silent. Check `virsh list
   --all` and `findmnt` on the pool path.

And know that a timer may fire on its own: `Persistent=true` means a nightly missed during the
outage starts shortly after boot, which is correct and worth knowing before it surprises
somebody mid-maintenance (runbook §10c).

---

## 6. Two failures of this mechanism, recorded because they are the evidence it is trustworthy

A contingency plan that reports only successes is a plan nobody has tested. Both of these were
found and fixed, and both were found by the monitoring rather than during a restore.

### 6.1 `prune` deleted every full backup in the enclave

**2026-09-16. The worst defect found in this project, and it was in code that had been running
nightly.**

A nightly run fired and its `prune` step removed, among others, `svc-obs-01`'s 7.2 GB full and
`svc-repo-01`'s 331 GB full. **The volume went from 402 GB to 11 GB. No guest in the enclave
had a restorable backup.** The guests were all running and healthy — nothing was lost from the
machines. **What was lost was the ability to put them back.**

**The cause in one sentence: the parameter is named `BACKUP_KEEP_CHAINS` and the code counted
directories.** It sorted set directories by name, kept the newest N and deleted the rest. The
oldest directory is always the full, so *"keep 2"* deleted the base and kept two diffs against
something that no longer existed. **An incremental without its full is not a backup.** It had
been in the nightly chain since the schedule was created, so it would have fired again the next
morning regardless of anything done by hand.

**The fix keeps chains, which is what the parameter always claimed.** A chain is a full plus
every incremental after it up to the next full. `prune` now reads the mode from each set's
metadata, groups sets into chains, keeps the newest N chains, and **retires a whole chain at
once** — the full and its incrementals go together, because an incremental is worthless the
moment its base goes.

Three guards, and the first is the one that matters:

| Guard | Behaviour |
|---|---|
| **No full at all in a guest's sets** | **Refuses to prune anything for that guest**, and says why. Had this existed the loss was impossible — and it is exactly the state the old code left behind, so it also stops a second prune compounding the first |
| Fewer chains than the retention count | Keeps everything, and says so |
| **After acting, prove a full survived** | Counts retained fulls per guest and shouts if the answer is zero. Turns *"I believe this is correct"* into *"this guest can still be restored"* |

`prune --dry-run` now exists. **Use it after any change to retention.** The fix was tested
against three cases including the exact failure state above, and recovery was fresh fulls for
all four guests — about 390 GB, with both timers disabled until the new `prune` was in place.

> **The general lesson, and it is not about backups.** A retention policy that counts objects
> cannot be correct unless every object is independent. The moment one object is a delta
> against another, counting is the wrong operation and only the dependency graph will do.
> **Any `KEEP=N` parameter in this system deserves the question: N of what, and what depends on
> what** (runbook §10b).

### 6.2 The first scheduled run failed, and the cause was designed in from the start

**2026-09-15 at 02:00.** The timer fired, ran for seven seconds and exited 1. All four guests
failed identically with `checkpoint inconsistent: missing or broken bitmap`.

The second disk on every guest is its cloud-init seed ISO, format **raw**. **A raw file cannot
hold a persistent dirty bitmap** — qcow2 stores one in the image, raw has nowhere to put it, so
qemu keeps it in memory and it dies with the process. libvirt still wrote a checkpoint naming
that bitmap, so the moment a guest restarted the chain referred to something that no longer
existed. **The first incremental after any guest restart was always going to fail**; the manual
fulls the day before succeeded only because nothing had restarted yet.

Nothing was damaged and no data was lost. But it is worth being precise: **not a fault that
appeared, a latent defect that the first unattended run exposed.**

The seed ISO should never have been in the backup set. It is read-only, a few hundred
kilobytes, regenerated whenever a guest is composed — and **it contains the password hash and
the SSH keys**, so copying it onto the backup volume spread a credential for no benefit
whatsoever.

The fixes: guest disk selection now takes **qcow2 only**, parsed from the domain XML rather
than from a command that does not print the format, and names what it excluded and why on every
run — *a disk silently dropped from a backup is the kind of thing discovered during a restore*.
A guest with no qcow2 disk is skipped outright rather than producing an empty,
successful-looking set. A broken chain self-heals into a full once, and only for this specific
error, dropping the stale checkpoint metadata without touching the guest disk or any set
already on the volume. And a failed attempt removes the empty set directory it created with
`rmdir` — never `rm -rf` — so it can only ever delete a directory that holds nothing.

> **This is the case the monitoring was built for, and it is worth recording that it worked.**
> The failure was silent: the timer was enabled, the volume was mounted and healthy with 4.2 TB
> free, and every other signal on the machine was green. `BackupInterrupted` fires on a set
> directory with no manifest, and `BackupMissed` would have fired at the 26-hour mark. **Before
> the backup facts existed, this would have been found during a restore** (runbook §10b).

---

## 7. Detection — how an outage becomes known

There is no notification path out of this enclave and there cannot be one; that gap is the
subject of the ISCM Strategy and of `poam.md` AO-02. What exists is a monitored signal on a
dashboard inside the boundary.

Seven of the 34 alert rules exist specifically for recovery capability:

| Alert | Fires when |
|---|---|
| `BackupMissed` | No complete set in 26 hours |
| `BackupNeverCompleted` | A guest with no manifest-carrying set at all |
| `BackupInterrupted` | A set with no manifest |
| `BackupDestinationDetached` | The volume is not mounted |
| `BackupTimerDisabled` | The nightly timer is inactive |
| `BackupVolumeFilling` | Free space below the threshold |
| `BackupFactsMissing` | The backup facts are **absent** — the meta-alert |

**`BackupFactsMissing` is the one that carries the group**, and the reason is a design rule this
enclave follows everywhere: *a missing source must never render as zero findings*. Every other
backup rule needs its metric to exist before it can fire, so a producer that silently stops
takes the whole group quiet — **and quiet is indistinguishable from healthy**
(`../dashboards-and-metrics.md` §6, §7).

Honest note on those rules' provenance: **all of them were quiet when first shipped, and for
the backup group that meant the metrics did not exist yet rather than that the backups were
fine.** That is exactly the distinction `BackupFactsMissing` exists to make
(`../dashboards-and-metrics.md` §7).

---

## 8. Recovery objectives, and why they are blank

| | |
|---|---|
| RTO | **«Recovery Time Objective - NOT YET COMMITTED»** |
| RPO | **«Recovery Point Objective - NOT YET COMMITTED»** |
| MTD | «Maximum Tolerable Downtime» |
| Essential functions | «the mission functions the enclave must restore first» |

**These are commitments and no commitment has been made.** Leaving them blank is deliberate:
a recovery objective back-filled from measured behaviour is a description wearing an
objective's name, and an objective the design was never held to is worse than an acknowledged
gap.

**What is known, and what any commitment has to be made against:**

| Input to the commitment | Value |
|---|---|
| Nightly backup cadence | Daily, 02:00 in `BACKUP_TZ`, incremental. **So the unmitigated RPO floor today is ~24 hours for anything not covered by database replication** |
| PostgreSQL synchronous replication | Reduces the RPO to zero **for acknowledged transactions on the database layer**, and only there |
| WAL archiving | **Not built** (`poam.md` ENG-04). Without it, restoring a guest from 02:00 loses everything since 02:00 |
| Full-set restore volume | 401 GB for all four service guests |
| Sustained throughput | 107 MB/s on the bench platter; 4–5× faster on the SSD it was replaced with |
| **Human latency at the rack** | **Non-zero and non-negotiable** while LUKS unlock is a console passphrase and three hosts have no BMC (§3.3) |
| Guest rebuild time | For most of the enclave, rebuild is faster and better-evidenced than restore (§2.4) |
| Measured guest restore | **2026-09-20 (§9.2): 56 s for a 13 GB guest, 3 m 34 s for 35 GB, from a five-set chain — rebuild plus boot, on a healthy host.** A per-guest figure, not a recovery of the enclave |
| Prerequisite | **No test has yet measured recovery from a HOST loss** (§9.1), so every figure above is still an input, not a commitment |

Do not commit to an RTO or RPO before ENG-01 in the POA&M has been run. The numbers above are
what the test should confirm or refute.

---

## 9. CP-4 — testing. One test has been run; four have not.

**Until 2026-09-20 no contingency test of any kind had ever been performed. The guest-restore
test has now been run and is recorded in §9.2. Everything else below is still untested, and
one passing test is not a tested plan.**

| Test | State |
|---|---|
| Host-failure rehearsal (runbook §10) | **Never run** |
| Guest restore from a backup set | ✅ **Run 2026-09-20** — all 4 service guests rebuilt from a 5-set chain and booted (§9.2). Slowest: `svc-repo-01`, 1 h 11 m |
| PostgreSQL / Patroni failover | **Never run**, planned or unplanned |
| Ceph degraded-state and recovery behaviour | **Never exercised** on four nodes |
| Tabletop walkthrough | **Never held** |
| Full site failover | Not applicable — there is no alternate site (§3.2) |

**An untested recovery plan is an assumption**, and this design exists in its current shape
precisely because an untested failover already lost a database once (`ato-package.md` §1).

One thing has been *proved* incidentally and should not be mistaken for a test: host 4 has been
rebooted once with all four guests returning. That is not a recovery exercise, and its own
write-up says plainly that its success **cannot be explained** (§5.2).

### 9.2 Test record — guest restore from backup, 2026-09-20

**Method.** `vm-backup.sh restore-test <guest>`, run on `host-4` against the live nightly sets
on the encrypted backup volume. For each guest it walks the chain back to the full it was built
on, verifies every set against its `sha256` manifest, rebuilds the disk **into its own
directory**, runs `qemu-img check`, defines a separate domain `restore-test-<guest>` **with no
network interface**, boots it, and watches a captured serial console for a login prompt. The
live guest is never stopped and never written to; the copy cannot take its address.

**Chain restored:** one full (2026-09-16) plus four nightly incrementals — five sets per guest.

| Guest | Disk | Checksums | `qemu-img check` | Booted | Rebuild | Boot | Total |
|---|---|---|---|---|---|---|---|
| `svc-obs-01` | 13 GB | verified | passed | **yes** | 39 s | 17 s | **56 s** |
| `svc-harbor-01` | 15 GB | verified | passed | **yes** | 65 s | 38 s | **1 m 43 s** |
| `svc-mgmt-01` | 35 GB | verified | passed | **yes** | 192 s | 22 s | **3 m 34 s** |
| `svc-repo-01` | 332 GB | verified | passed | **yes** | 4261 s | 27 s | **1 h 11 m** |

**Data age at test time: 14 hours** — the newest set was 07:00 UTC, the test ran at 21:30 UTC.
That is a measured recovery point for a single guest, and it is consistent with the ~24 hour
unmitigated floor in §8 rather than a replacement for it.

Evidence: `/srv/stig-evidence/restore-test-<guest>-<stamp>.txt` on `host-4`, one file per run.

**What the test found, which is the part worth keeping:**

1. **The backup sets did not contain the domain definition.** Only the disks were stored. A
   restore onto a rebuilt host would have meant writing the VM's XML — CPU, memory, machine
   type, firmware, disk and network layout — by hand, under pressure, from memory. Every set
   now stores `virsh dumpxml --inactive` and checksums it. **The sets that this test restored
   predate that fix**, so the test used the live definition and said so; that is weaker
   evidence than it appears and the next set is the one that closes it.
2. **Reassembling an incremental chain was the undocumented step.** `restore-plan` says "apply
   incrementals in order" and stops there. A libvirt push-mode incremental holds only changed
   clusters and carries no reference to what it was built on, so on its own it is unreadable.
   The procedure is now executed rather than described.
3. **The mirror is the recovery-time problem, and by a wide margin.** `svc-repo-01` took
   **1 h 11 m** against 3 m 34 s for the next largest — 332 GB versus 35 GB. The rebuild reads
   the whole chain off the backup volume and then flattens it, so ~332 GB of guest costs
   roughly double that in I/O, on a USB-attached source. **Restoring all four guests
   sequentially is ~1 h 20 m**, and that figure is dominated by one machine whose contents are
   an apt mirror — rebuildable from the transfer bundle, which §2.4 already argues is better
   evidence than a restore. The decision this measurement forces: **is the mirror worth
   restoring at all, or is it rebuilt while the guests that hold irreplaceable state are
   restored first?**
4. **Chain depth grows by one every night** — five on the day of the test. Restore time and the
   number of links that must all be intact grow with it. The full-backup cadence is a decision
   this measurement now informs.

**What it does NOT prove.** One guest at a time, onto a healthy host, from a volume attached to
that same host. It does not test losing `host-4` (§3.2), a site event (§3.1), database failover,
or Ceph. Those remain untested, and the §8 objectives stay uncommitted until the host-failure
rehearsal in §9.1 has been run.

### 9.1 The test that should be run first, and why early

`poam.md` ENG-01 owns this. Three reasons to schedule it before more documentation is written:

1. **It is the only item in the package that cannot be written instead of performed.**
2. **It is the item most likely to change the design**, which is a reason to do it early rather
   than late.
3. **The plan's two blank values depend on it.** RTO and RPO should be committed from a
   measured recovery, not from an estimate.

Scope for the first pass, with a stopwatch: pull a host and record what Ceph, etcd and the
cluster actually do; restore one guest from a backup set onto a renamed disk and time it; run
`patronictl switchover` and then a real leader loss by stopping the leader's guest, and time the
promotion; and reboot the hypervisor through `vm-power.sh` end to end including the LUKS
passphrase and the autostart verification. **Record what happened, including the failures** —
this project's evidence is credible because it preserves the failures, and a test write-up with
no surprises in it is a test nobody learned from.

---

## 10. Roles

| Role | Assignment |
|---|---|
| Recovery lead | «recovery lead» |
| Alternate | «alternate, and how they are reached» |
| Boot-secret custodian | «who holds the LUKS passphrase and the GRUB password, and where» |
| Backup media custodian | «who handles backup media leaving the room, under what procedure» |
| Notification | «who is notified of an outage, and by what means - NOT email from inside the gap» |
| ISSM | «ISSM_NAME» |
| ISSO | «ISSO_NAME» |
| System administrator | «SYSADMIN_NAME» |

**One structural risk in this table deserves naming rather than filling in.** This enclave is
operated by one person on site, and recovery from the most likely failure — a power event —
requires a human holding a passphrase to be physically at the rack. **A one-operator enclave
has a single point of human failure, and an assessor will ask who the second person is.** The
alternate is not a formality here; it is the control.

---

## 11. Control coverage summary

Stated honestly, because this is the family where the gap between mechanism and plan is widest.

| Control | State | Basis |
|---|---|---|
| **CP-2** Contingency plan | ⚠️ Partial — this document, with RTO, RPO and the roles unfilled | §8, §10 |
| **CP-3** Training | ⬜ None | — |
| **CP-4** Testing | 🔴 **No evidence of any kind** | §9 |
| **CP-6** Alternate storage site | 🔴 **None.** Both recovery paths terminate on the same machine that runs every guest | §3.1, §3.2 |
| **CP-7** Alternate processing site | 🔴 **None.** Single site, no standby | §3.2 |
| **CP-9** Information system backup | ✅ **Strong.** Whole-guest backup with per-set SHA-256 manifests, chain-aware retention with three guards, nightly changed-set verify and weekly deep verify, refusals on unmounted/unencrypted/insufficient destinations, and measured cost | §4 |
| **CP-10** Recovery and reconstitution | ⚠️ Partial. The mechanism is built and the procedure is written; **it has never been executed**, WAL archiving does not exist, and there is no remote recovery path at all | §5, §3.3, §9 |

---

## 12. Sources

| Reference | What it supplies |
|---|---|
| `docs/runbook.md` §10b | The backup mechanism as built, its parameters, its refusals, and both failures in §6 |
| `docs/runbook.md` §10b.1 | Measured cost of a full backup, and the four traps in moving the destination |
| `docs/runbook.md` §10c | The ordered shutdown and startup, and the `libvirt-guests` finding |
| `docs/runbook.md` §9a, §9a.1, §9a.2, §9a.3 | The database design, the recovery-path correction, the disk split, and the build procedure |
| `docs/runbook.md` §1, §1.1, §1.2, §1.5 | Topology, why the services sit on one host, the fourth failure domain, and the lab-hardware caveats |
| `docs/runbook.md` §2.5, §6.3g | Ceph packaging and OSD encryption; the USB window |
| `docs/02-host-install.md` §4c | The no-BMC finding and the two BOM requirements that follow |
| `docs/compliance/ssp-inputs.md` §2.1, §2.1a, §2.3, §3.1–3.4 | The decided statements on unlock, remote recovery, TRIM and the recovery limitations |
| `docs/compliance/dashboards-and-metrics.md` §6, §7 | The backup alert rules and the missing-source design rule |
| `docs/compliance/ato-package.md` | Contingency plan and test-results status in the package |
| `docs/open-questions.md` Q19, Q20 | Encryption required; the unlock decision and its measured cost |
| `HANDOFF.md` §4 | The availability model, and single-site with no standby |
| `scripts/enclave/vm-specs.env` | Every backup and power parameter |
| `scripts/enclave/vm-backup.sh`, `vm-power.sh` | The mechanisms themselves |
