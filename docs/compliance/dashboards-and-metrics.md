# Compliance and OS dashboards — what they measure, and what they do not

**Status:** built and running on `svc-obs-01`, 2026-09-14.
**Generator:** `scripts/enclave/monitoring.sh`. **Dashboards:** `scripts/enclave/dashboards/*.json`.

This document is the reference for the two Grafana dashboards in the enclave and for every
metric behind them. It covers what each number means, where it comes from, how often it
changes, how it can lie, and how to rebuild the whole thing from nothing.

**Current findings are deliberately not in this document.** Counts of open controls are the
client's residual risk posture and live in `docs/runbook.md` §10.1 and `HANDOFF.md`. This
file explains the instrument; the runbook records the readings.

---

## 1. The one thing to understand first

**Half of this is live and half of it is a snapshot of a file.** Reading a snapshot as if it
were live is the only way to be badly misled by these dashboards.

| | Updates | Changes when |
|---|---|---|
| **Live facts** — audit trail, certificates, AIDE, faillock, sudo, USB, FIPS, filesystems, CPU, memory | every 15 min (facts) or every 15 s (node-exporter) | the machine changes |
| **Scanner snapshots** — everything named `enclave_stig_*` and `enclave_usg_*` | only when a scan is re-run | **a human runs a scan** |

`enclave_stig_controls{status="O"}` on a machine will report the same number for weeks while
the machine drifts underneath it. That is not a bug — it is what a checklist is. It is also
why **every scanner panel is paired with a scan-age panel**, and why "Oldest STIG scan" is one
of the six headline stats. A flat green line on a residual panel means nobody has measured
recently, not that nothing has changed.

---

## 2. How the data gets there

```
each machine                         svc-obs-01
------------                         ----------
node-exporter :9100  ──scrape 15s──▶  Prometheus :9090 (loopback)
  ├─ default collectors                 ├─ rules  /etc/prometheus/rules/*.yml
  ├─ systemd collector                  └─ 90d / 100 GB retention
  └─ textfile collector                        │
       reads /var/lib/node_exporter/           ▼
       textfile/*.prom                  Grafana :3000 (loopback)
            ▲                                  │
            │ every 15 min                     ▼
     enclave-facts.timer                nginx :443  (TLS, enclave CA)
       └─ monitoring.sh facts
                                       host-4 also runs
                                       prometheus-libvirt-exporter :9177
```

**Nothing listens on a public port.** Prometheus, Alertmanager and Grafana are all bound to
`127.0.0.1`; nginx terminates TLS with an enclave certificate and proxies to Grafana. The only
enclave-facing listeners are the exporters on 9100 and 9177, and those belong behind a
source-restricted `ufw` rule (see §9).

### The textfile collector is the whole trick

A compliance fact is not something an exporter can invent. `node-exporter` does not know what
a STIG is. The **textfile collector** solves this generically: anything that can write a file
can publish a metric.

- `monitoring.sh facts` writes `/var/lib/node_exporter/textfile/enclave-compliance.prom`
- `node-exporter` serves whatever is in that directory as if it were built in
- `enclave-facts.timer` re-runs it every 15 minutes
- root writes the directory, the `prometheus` user reads it — never the other way round

The file is written to a temporary name and renamed into place, so a scrape never sees half a
file. **If the producer fails, the previous file is left untouched** — a producer that wrote
nothing must not be allowed to turn "the script broke" into "this machine has no findings".

### Labels

Prometheus attaches `machine` and `role` to every series from its scrape config, generated from
`enclave-addresses.env`. Nothing in the fact file carries a hostname; the collector decides who
said it. That is deliberate — a machine cannot mislabel itself.

| role | machine |
|---|---|
| `hypervisor` | `host-4` |
| `maas` | `svc-mgmt-01` |
| `mirror` | `svc-repo-01` |
| `registry` | `svc-harbor-01` |
| `observability` | `svc-obs-01` |

---

## 3. Dashboard: **Enclave OS — host and guests** (`uid: enclave-os`)

Generic operating-system health for the hypervisor and every guest. 21 panels, four rows,
all full width with the legend to the right — at five machines plus four guests a half-width
panel is mostly legend.

### Row: Fleet
Five stats. Machines reporting, alerts firing, busiest CPU, tightest filesystem, guests running.

### Row: Operating system — host and guests
CPU used, memory available, **load average per core** (raw load is meaningless across machines
with different core counts), swap used.

### Row: Filesystems
- **Free space now, tightest first** — a table, coloured on the same thresholds the alerts use,
  so the dashboard and the alerting cannot drift into different opinions of "nearly full".
- **Free space over time** — the slope is the useful part, not the level.
- **Audit partition free** — its own panel because auditd's `disk_full_action` can halt a
  machine. Threshold 25% free, tighter than any other mount.
- **Disk I/O**.

`vfat`, `tmpfs`, `squashfs` and `overlay` are excluded everywhere. `overlay` in particular
would report every Docker layer on `svc-harbor-01` as a filesystem.

### Row: Guests, measured from the hypervisor
vCPU, memory, disk and network per domain, from `prometheus-libvirt-exporter` on `host-4`.

**Why this row exists when the guests already run node-exporter:** a guest that is too sick to
report its own metrics still appears here. The hypervisor can see a VM that cannot speak.

---

## 4. Dashboard: **Enclave compliance** (`uid: enclave-compliance`)

30 panels, six rows. Default window 7 days, refresh 1 minute.

### Row 1 — Posture
The six numbers an assessor asks for first.

| Stat | Query | Thresholds |
|---|---|---|
| CAT I open | `sum(enclave_stig_open_by_severity{severity="high"})` | red at 1 |
| Open (all severities) | `sum(enclave_stig_controls{status="O"})` | orange 10, red 25 |
| Not Reviewed | `sum(enclave_stig_controls{status="NR"})` | orange 20, red 50 |
| Machines in FIPS mode | `count(enclave_fips_enabled == 1)` | green only at 5 |
| Oldest STIG scan | `max(time() - enclave_stig_scan_time_seconds)` | orange 7d, red 30d |
| Reboots pending | `sum(enclave_reboot_required)` | orange 1, red 3 |

**Not Reviewed is not a resting state.** Each NR is a control nobody has answered, and five of
them were answerable from evidence already on the box. See runbook §10.1.

### Row 2 — STIG residual
Open per machine, open by severity (stacked), Not Reviewed per machine, USG failures per
machine, and a **scan freshness table** sorted stalest first.

The acceptance criterion for this enclave is that **every machine lands on the same residual
set**. A line that diverges is the interesting result, in either direction — it means one
machine can enforce something the others cannot, or has stopped enforcing something they do.

A **rising** Not Reviewed line is usually a check that hit Evaluate-STIG's 15-minute per-check
timeout, not an Answer File entry that failed to fire. Check the scan log before concluding
anything about the Answer File.

### Row 3 — Audit trail
- **Audit records LOST** — `enclave_auditd_lost`. Anything above zero means the kernel dropped
  audit events and **the trail has holes**. A machine can pass every audit *rule* check while
  doing this, which is exactly why this panel exists.
- **Audit backlog** against `backlog_limit` — the precursor to loss.
- **/var/log/audit free space** at the 25% threshold.
- **auditd running**, from the systemd collector rather than from a fact file. A machine should
  not be the one to tell you its own audit daemon is fine.

### Row 4 — File integrity and access control
- **AIDE time since last check** — `dailyaidecheck.timer`. Above ~36 h means the daily check is
  not running. *Absent* means AIDE is not installed at all, which is a different problem.
- **AIDE exit status** — non-zero means it found changes, or failed.
- **Failed sudo, 24 h rolling** — `pam_faillock` here is `deny=3 unlock_time=0`, so three
  failures is a **permanent** lockout until the tally is cleared by hand. This is the warning.
- **Accounts carrying a faillock tally**.
- **sudo invocations, 24 h rolling** — not a control. An open investigation: MAAS invokes
  `machine-resources` via sudo roughly 1.7 times per second on `svc-mgmt-01`. This panel is
  here to establish whether it is constant or bursty.

### Row 5 — Expiry
- **Certificates, soonest first** — reported as *time remaining*, not as a date, so it cannot
  quietly go stale the way a runbook table does. Orange at 90 days, red at 30.
- **USB storage blocked (V-270718)** — 1 means blocked in `modprobe.d`, which is the only place
  the control looks; it never runs `lsmod`. Expected to read 0 on `host-4` while the backup
  window is open.

### Row 6 — Can this dashboard be believed
- **Age of the facts on each machine** — if this climbs, every compliance number above it is
  frozen at whatever it was when the producer last succeeded.
- **Fact sources, per machine** — `1` readable, `0` present but unreadable, **absent entirely**
  means that source does not exist on that machine. Telling those three apart is the entire
  reason the row exists.

---

## 4a. Dashboard: **Enclave hypervisor — host-4 and VM backups** (`uid: enclave-hypervisor`)

24 panels, two rows. Backup state comes from `vm-backup.sh facts`; guest state comes from
`prometheus-libvirt-exporter` on the hypervisor.

### Row: Backup — did last night's backup actually land on the disk

Six stats — **domains with no complete backup**, oldest successful backup, destination mounted,
free space, **interrupted sets**, nightly timer — then a per-domain table and five graphs.

Three of those deserve explanation:

- **`MANIFEST.sha256` is the completion marker.** It is written only after every disk in a set
  has been copied. A set directory *without* one is an interrupted run — which is exactly what
  the `TMOUT`-killed full backup left behind. **Counting directories would have called that a
  success**, so complete and incomplete sets are counted separately and interrupted sets get
  their own stat, red at one.
- **"Backup job running" should be a narrow block after 02:00, not a plateau.** A job that never
  clears is the `cannot acquire state change lock` state.
- **"Time since last successful backup" should draw a sawtooth** — climbing all day, dropping to
  near zero at 02:00. A line that climbs straight through 26 hours is a job that stopped.

**An unmounted destination publishes nothing per-domain.** `$DEST` still exists as an empty
directory when the USB volume is not attached, so counting sets there would report "0 complete
sets" for every domain — indistinguishable from a machine never backed up, and from one whose
backups were deleted. Instead `enclave_backup_dest_mounted` goes to 0, `source_ok` goes to 0,
and the per-domain families vanish. After a reboot that is the normal state, for three separate
reasons: `usb-storage` is STIG-blocked, LUKS is locked, and nothing types the passphrase.
`vm-backup.sh reattach` is the fix.

### Row: Hypervisor — host-4 and the guests it runs

`libvirt_up`, guests running, host-4 CPU and memory, then per-guest state, vCPU, memory, block
I/O, network, and **network errors and drops** — which should be flat zero, and where drops on a
bridged guest network usually mean the host is the bottleneck rather than the guest.

All nineteen `libvirt_*` metric names were read from the running Prometheus rather than assumed.

---

## 5. Metric reference

Every metric published by `monitoring.sh facts`. All are gauges. All carry `machine` and `role`
from the scrape config.

### Scanner snapshots — change only when a scan is re-run

| Metric | Labels | Source | Meaning |
|---|---|---|---|
| `enclave_stig_controls` | `status` = `NF`/`O`/`NR`/`NA` | newest `*_COMBINED_*.csv` under `/srv/stig-evidence/<MACHINE>/Checklist/` | DISA **V1R6** controls by status |
| `enclave_stig_open_by_severity` | `severity` = `high`/`medium`/`low` | same CSV | Open controls by severity; `high` is CAT I |
| `enclave_stig_controls_total` | — | same CSV | controls assessed |
| `enclave_stig_scan_time_seconds` | — | mtime of that CSV | when that checklist was written |
| `enclave_usg_rules` | `result` = `pass`/`fail`/`notselected`/… | newest `/var/lib/usg/usg-results-*.xml` | XCCDF rule-results, Canonical **V1R1** |
| `enclave_usg_scan_time_seconds` | — | mtime of that XML | when USG last audited |

**Two scanners, two revisions, two different numbers, both correct.** USG/OpenSCAP assesses
Canonical's V1R1 and is the only one that *remediates*. Evaluate-STIG assesses DISA V1R6, which
is what an assessor will actually use, and only measures. Do not reconcile them into one figure.

The checklist is selected **newest by mtime, never from `Previous/`, and scoped to this
machine's own directory**. Evaluate-STIG archives each prior run under `<MACHINE>/Previous/`,
and a path sort puts the archive last — which once made a report describe a scan twenty minutes
older than the one that had just finished.

### Live facts — change on their own

| Metric | Labels | Source | Notes |
|---|---|---|---|
| `enclave_fips_enabled` | — | `/proc/sys/crypto/fips_enabled` | 1 = FIPS kernel mode |
| `enclave_reboot_required` | — | `/var/run/reboot-required` | an update not yet live |
| `enclave_auditd_enabled` | — | `auditctl -s` | |
| `enclave_auditd_lost` | — | `auditctl -s` | **events dropped since boot.** Above 0 = holes in the trail |
| `enclave_auditd_backlog` | — | `auditctl -s` | current queue depth |
| `enclave_auditd_backlog_limit` | — | `auditctl -s` | the ceiling backlog is heading for |
| `enclave_auditd_failure` | — | `auditctl -s` | kernel failure mode |
| `enclave_cert_expiry_seconds` | `file`, `cn` | `openssl x509` over `/etc/ssl/enclave/*.crt` and `/usr/local/share/ca-certificates/*.crt` | unix time of expiry |
| `enclave_aide_last_run_seconds` | — | `systemctl show dailyaidecheck.service` | start of the last run |
| `enclave_aide_last_exit_code` | — | same | 0 = clean |
| `enclave_aide_db_age_seconds` | `db` | mtime of `/var/lib/aide/aide.db*` | baseline age |
| `enclave_faillock_users_with_failures` | — | non-empty files in `/run/faillock` | at 3 they are locked out |
| `enclave_failed_sudo_24h` | — | journal, `-t sudo` | authentication failures |
| `enclave_sudo_invocations_24h` | — | journal, `-t sudo` | total `COMMAND=` lines |
| `enclave_usb_storage_blocked` | — | `/etc/modprobe.d/*.conf` | where V-270718 looks |

### Backup facts — hypervisors only, from `vm-backup.sh facts`

Written to `enclave-backup.prom` by `vm-backup.sh`, which is called by `monitoring.sh facts`.
`vm-backup.sh` owns the on-disk layout, so it is the thing that reads it — teaching
`monitoring.sh` where a backup set lives would put that knowledge in two files that would drift.

| Metric | Labels | Meaning |
|---|---|---|
| `enclave_backup_dest_mounted` | — | 1 = the LUKS volume is unlocked and mounted |
| `enclave_backup_source_ok` | — | 0 when the destination could not be read |
| `enclave_backup_timer_enabled` | — | `enclave-vm-backup.timer` active |
| `enclave_backup_dest_avail_bytes` / `_size_bytes` | — | free and total at the destination |
| `enclave_backup_last_success_seconds` | `domain` | mtime of the newest `MANIFEST.sha256` |
| `enclave_backup_last_attempt_seconds` | `domain` | newest set directory of any kind |
| `enclave_backup_sets_complete` | `domain` | sets carrying a manifest |
| `enclave_backup_sets_incomplete` | `domain` | set directories with **no** manifest |
| `enclave_backup_last_set_bytes` | `domain` | size of the newest complete set |
| `enclave_backup_checkpoints` | `domain` | libvirt checkpoints an incremental can build on |
| `enclave_backup_job_active` | `domain` | 1 while libvirt reports a job |
| `enclave_backup_domains_defined` / `_protected` | — | defined, and holding ≥1 complete set |
| `enclave_backup_total_bytes` | — | newest complete set summed across domains |

Sizes are summed with `stat` over the files in a set, **not** `du` over the tree. A set holds a
handful of qcow2 files; `du` would walk and stat every block on a USB disk every 15 minutes, on
a volume holding hundreds of gigabytes, for the same answer.

`virsh domjobinfo` **pads its fields**, and matching the line exactly once printed idle domains
as in progress. The value is stripped of whitespace before comparison.

### Producer health — read these before trusting anything above

| Metric | Labels | Meaning |
|---|---|---|
| `enclave_facts_generated_seconds` | — | when the file was written. If it stops moving, everything is frozen |
| `enclave_facts_source_ok` | `source` | `1` read, `0` present but unreadable, **absent** = not on this machine |

`source` is one of `usg`, `estig`, `certs`, `auditd`, `aide`, `accounts`, `fips`.

### From node-exporter's systemd collector

`node_systemd_unit_state{name,state}` and restart counters, narrowed by `SYSTEMD_UNITS` to the
units a machine exists to run. Unrestricted it emits several series for every unit on the box.

---

## 6. The design rule everything here follows

> **A missing source must never render as zero findings.**

A dashboard reading "0 Open" because a scan was never run looks exactly like one reading
"0 Open" because the machine is clean. So a family with no source **emits no samples at all**.
"No data" on a panel is honest. A green zero is a lie.

This is not theoretical. Writing these two dashboards produced six false passes, every one of
which reported success while measuring the wrong thing:

| What reported success | What was actually true |
|---|---|
| `promtool check config` | passes happily for a config with **no rule files at all** |
| "grafana has 5 dashboards loaded" | `/api/search` returns **401** unauthenticated; `len()` of the error object's five keys |
| every panel rendering "No data" | the provisioned datasource had **no `uid`**, so Grafana invented one and nothing matched |
| `enclave_aide_last_exit_code 0` | `systemctl show` on a **nonexistent unit** exits 0 and prints defaults |
| a machine reporting another machine's checklist | the evidence glob was not scoped to the hostname |
| `collector 'systemd' IS NOT REPORTING SUCCESS` | `grep -q` under `set -o pipefail` — see §10 |

Verification therefore always asks the running thing, never the file just written:
`cmd_rules` counts rules in the live Prometheus process, `cmd_dashboards` reads Grafana's own
sqlite database, and `cmd_exporter` asks the exporter which collectors it loaded.

---

## 7. Alert rules

Eight rules in `/etc/prometheus/rules/`, generated by `monitoring.sh rules`. Every one carries
an `action` annotation saying what to do about it — an alert that does not say what to do is a
pager that trains people to ignore it.

| Alert | Fires when | For | Severity |
|---|---|---|---|
| **availability** | | | |
| `InstanceDown` | `up == 0` | 2m | critical |
| **cpu / memory / filesystems** | | | |
| `HighCPU` | CPU > 85% | 10m | warning |
| `MemoryPressure` | MemAvailable < 10% | 10m | warning |
| `FilesystemFillingWarning` | free < 20% | 15m | warning |
| `FilesystemFillingCritical` | free < 10% | 5m | critical |
| `AuditFilesystemFilling` | `/var/log/audit` free < 25% | 5m | critical |
| `FilesystemWillFillSoon` | `predict_linear` over 6h says full within 4h | 30m | warning |
| `FilesystemReadOnly` | `node_filesystem_readonly == 1` | 1m | critical |
| **audit trail** | | | |
| `AuditRecordsLost` | `delta(enclave_auditd_lost[1h]) > 0` | 5m | critical |
| `AuditdNotRunning` | the unit is not active | 5m | critical |
| `AuditBacklogNearLimit` | backlog over half `backlog_limit` | 10m | warning |
| **compliance drift** | | | |
| `StigOpenControlsIncreased` | more Open than 1 day ago | 15m | warning |
| `StigScanStale` | checklist older than 30 days | 1h | warning |
| `FipsModeDisabled` | `enclave_fips_enabled == 0` | 10m | critical |
| `CertificateExpiringSoon` | inside 30 days | 1h | warning |
| `AideCheckStale` | no AIDE run in 36h | 1h | warning |
| `AideDetectedChanges` | last exit non-zero | 10m | warning |
| `AccountLockoutRisk` | any faillock tally | 5m | warning |
| `ComplianceFactsStale` | facts older than 1h | 15m | critical |
| **backups** | | | |
| `BackupMissed` | no complete set in 26h | 30m | critical |
| `BackupNeverCompleted` | a domain with no manifest-carrying set | 1h | critical |
| `BackupInterrupted` | a set with no manifest | 30m | warning |
| `BackupDestinationDetached` | volume not mounted | 2h | critical |
| `BackupTimerDisabled` | nightly timer inactive | 1h | warning |
| `BackupVolumeFilling` | free below 200 GB | 30m | warning |
| `BackupFactsMissing` | `absent(enclave_backup_dest_mounted)` | 1h | critical |

**Three of these are shaped by a lesson rather than by a threshold.**

**`AuditRecordsLost` uses `delta`, not `> 0`.** auditd's `lost` counter is cumulative since
boot, so a bare threshold would fire forever on a machine that dropped records once weeks ago —
and an alert that is always firing trains people to close it without reading. `delta` over an
hour asks the actionable question: *is it losing records now*. On a reboot the counter resets,
delta goes negative, and nothing fires, which is correct.

**Nothing alerts on the residual set being non-zero.** It is non-zero by design and every
finding in it has a written rationale. `StigOpenControlsIncreased` alerts on it *changing*.

**`ComplianceFactsStale` and `BackupFactsMissing` are the meta-alerts, and they carry the
group.** Every other compliance rule needs its metric to exist before it can fire, so a
producer that silently stops takes the whole group quiet — and **quiet is indistinguishable
from healthy**. Those two fire on frozen and on absent respectively.

**Every expression was evaluated against live data before shipping**, and all 26 were quiet —
which for the six backup rules meant *the metrics did not exist yet*, not that the backups were
fine. That is the distinction `BackupFactsMissing` exists to make.

Thresholds are the `AL_*` parameters at the top of `monitoring.sh` — nothing is hardcoded.

**Rules live in Prometheus, not in Grafana.** Grafana's alerting lives in its database, which
is not versioned, does not travel on media, and dies with the VM. A rule file is a file in this
repository.

**These fire into Alertmanager on `svc-obs-01` and go no further.** There is still no
notification path — see §11. Until there is, an alert is something someone has to look at a
screen to see, which is the whole of Q26.

---

## 8. Rebuilding this from nothing

Assumes the enclave exists and `svc-obs-01` is composed and hardened (runbook §10a).

```
# 1. the collector, on svc-obs-01
sudo ./scripts/enclave/monitoring.sh collector

# 2. an exporter on EVERY in-gap machine, including svc-obs-01 itself
sudo ./scripts/enclave/monitoring.sh exporter

# 3. per-guest metrics, HYPERVISORS ONLY
sudo ./scripts/enclave/monitoring.sh libvirt

# 4. compliance facts, on every in-gap machine
sudo ./scripts/enclave/monitoring.sh facts-timer

# 5. alert rules and dashboards, on svc-obs-01
sudo ./scripts/enclave/monitoring.sh rules
sudo ./scripts/enclave/monitoring.sh dashboards
```

Steps 2 and 4 combine safely into one privileged call:

```
sudo bash -c './scripts/enclave/monitoring.sh exporter && ./scripts/enclave/monitoring.sh facts-timer'
```

### What must already be on the mirror

| Thing | Where it comes from |
|---|---|
| `prometheus`, `prometheus-alertmanager`, `prometheus-node-exporter`, `prometheus-libvirt-exporter`, `nginx` | the apt mirror, `universe` |
| `grafana_13.2.1_33191028959_linux_amd64.deb` | carried as a file into `/srv/repo/debs/`, **checksum-verified before install** — see `docs/00-downloads.md` §7 |

Grafana is carried as a verified `.deb` rather than installed from a repository **so that no
third-party signing key enters the trust store**. The SHA-256 in `monitoring.sh` is the control.

### The timer runs out of the repository checkout

`enclave-facts.service` has `ExecStart=/home/encadmin/canonical-k8s/scripts/enclave/monitoring.sh facts`
— it runs the script **where the repo lives on that machine**, the same convention
`vm-backup.sh schedule` uses. Verified on `host-4`, 2026-09-14.

**So moving or renaming the checkout breaks the timer silently.** Nothing alerts on it directly;
the symptom is `enclave_facts_generated_seconds` freezing, which is exactly what the "Age of the
facts" panel in row 6 is for. If the repo path ever changes, re-run `facts-timer` on every
machine — it rewrites the unit.

### Everything is generated, nothing is clicked

- the scrape config is generated from `enclave-addresses.env` — adding a machine means adding
  it there and re-running `collector`, never editing `prometheus.yml`
- the Grafana datasource is provisioned with a **pinned uid**, `enclave-prometheus`
- dashboards are provisioned from files with `allowUiUpdates: false`

**Edits made in the Grafana UI cannot be saved back over a provisioned dashboard.** Change the
JSON in `scripts/enclave/dashboards/` and re-run `monitoring.sh dashboards`. A change that
lives only in Grafana's database is lost with the VM and does not travel on media.

---

## 9. Security posture of the monitoring itself

- Prometheus, Alertmanager and Grafana bind `127.0.0.1` only. Grafana is reachable solely
  through nginx on 443 with an enclave certificate.
- `monitoring.sh` **proves the bind with `ss`** after every restart. A wildcard bind is the
  same finding as the Postfix one in runbook §6.3e, and it would be repeated five times.
- **Port 9100 is not firewalled by `monitoring.sh`, deliberately.** It exposes every mount,
  interface, process count and kernel version. The rule belongs in `stig-tailor.sh`'s ufw table,
  source-restricted to the collector. `ufw` is only enabled on machines with a rule table.
- Reaching Grafana from a desk is an ssh tunnel through `stage-01`, which is temporary and dies
  at cutover. See runbook §10a.

---

## 10. Traps worth knowing before you change any of this

**`grep -q` under `set -o pipefail` is a false-negative generator.** `grep -q` exits the instant
it matches; the producer on the left is then killed by SIGPIPE with status 141; `pipefail`
reports the pipeline as failed *even though grep matched*. Whether it bites depends on how far
into the output the match is — the same working configuration reported `systemd` broken and
`textfile` fine on one machine, both broken on three others, and both fine on a fifth. Match in
bash with `case`, or read the whole stream.

**`sed` cannot carry a value containing its own delimiter.** The systemd unit-include regex is
full of `|`, and `s|^ARGS=.*|ARGS="..."|` died at character 180. There is no delimiter a future
value cannot contain. Replace the line by filtering and appending instead.

**Grafana updates a provisioned datasource by uid.** Pinning a uid on a datasource that was
first created without one makes that update look up a uid its database has never seen;
provisioning fails, and provisioning is a hard dependency of Grafana's HTTP server — so Grafana
exits 1 in a loop. From the outside that is an **nginx 502 with a clean nginx log**.
`deleteDatasources:` by name first is the documented migration and is safe to leave in place.

**`systemctl show` on a unit that does not exist exits 0 and prints defaults.** Gate on
`LoadState=loaded`.

**`/srv/stig-evidence` is also where `stage-01` collects every machine's evidence.** An unscoped
glob will happily report another machine's checklist as this one's.

---

## 11. What this does not cover yet

- **No notification path.** V-270818/V-270819 require email notification and **no email can
  leave an air gap**; Postfix is deliberately `inet_interfaces = loopback-only` because the
  STIG requires it. Alertmanager on a dashboard is a different mechanism from the one the
  control names and needs an AO answer — `docs/open-questions.md` **Q26**.
- **No role dashboards for the mirror, the registry, MAAS or the collector.** The collector's
  own is the cheapest of the four — every series it needs is already scraped.

---

## See also

**This document travels on transfer media; the runbook does not.** `build-transfer-bundle.sh`
carries the repository with `git archive HEAD`, which takes **tracked files only** — and
`docs/runbook.md`, `docs/open-questions.md` and `HANDOFF.md` are gitignored client-private
material. That is deliberate, but it means the rebuild sequence in §8 has to be *here*, in the
public half, or it does not reach the enclave at all. It also means **an uncommitted change to
this file does not travel** — commit before building a bundle.

| Document | For |
|---|---|
| `docs/runbook.md` §10a | how the monitoring stack was built, in order, and why |
| `docs/runbook.md` §10.1 | the two scanners, the residual set, and the current findings |
| `docs/runbook.md` §6.3 | the STIG deviations these metrics measure the effect of |
| `docs/open-questions.md` Q25/Q26 | the AO decisions that block the remaining controls |
| `docs/00-downloads.md` §7 | acquiring the Grafana `.deb` for a clean build |
| `scripts/enclave/monitoring.sh` | the generator — the comments carry the reasoning |
