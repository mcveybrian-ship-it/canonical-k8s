# Information Security Continuous Monitoring Strategy — «SYSTEM_NAME» («SYSTEM_ACRONYM»)

| | |
|---|---|
| System | «SYSTEM_NAME» («SYSTEM_ACRONYM») |
| System identifier | «SYSTEM_ID» |
| System owner | «SYSTEM_OWNER» |
| Impact level | IL5 |
| Control baseline | «800-53 Rev 5 High or Moderate» |
| Reporting | «to whom, how often, in what format» |
| Report recipient | «who receives the monitoring report» |
| Report cadence | «monthly or quarterly» |
| Report format | «the format required - eMASS entry, PDF, dashboard screenshot» |
| Alert review owner | «who reviews Alertmanager, and how often» |
| Alert review cadence | «how often the alert console is actually looked at» |
| Re-scan cadence | «how often each machine is re-scanned» |
| Independent assessor | «who performs the independent assessment - self-assessment is a different artifact» |
| Audit retention, online | «how long audit records stay online» |
| Audit retention, archive | «how long they are archived, and where» |
| Metric retention | «Prometheus retention - 90d/100GB is a placeholder, not a decision» |
| Acceptable vulnerability-data age | «at what age does a scan against carried-in data stop being acceptable» |
| External SIEM | «NONE or the SIEM this must feed, and by what transfer mechanism» |
| STIG Manager | «NONE or the programme runs STIG Manager and expects CKLs fed to it» |
| Notification decision | «the AO answer on whether an in-boundary dashboard alert satisfies notification» |
| ISSM | «ISSM_NAME» |
| ISSO | «ISSO_NAME» |
| Prepared by | «PREPARED_BY» |
| Document version | 0.1 draft |
| Document date | «YYYY-MM-DD» |

---

## 1. Summary, and the one gap that matters

**The monitoring is built and running.** Prometheus, Alertmanager and Grafana on `svc-obs-01`;
node-exporter on every machine and a libvirt exporter on the hypervisor; **34 alert rules in 9
groups**; and compliance, backup, registry and patch-posture facts published **every fifteen
minutes on five machines**. Five provisioned dashboards. Nine scrape targets. Every threshold
is a named parameter rather than a literal. Built 2026-09-14 and extended through 2026-09-16
(runbook §10a, `../dashboards-and-metrics.md`).

**The gap is that there is no notification path, and there cannot be one.** Two STIG controls
require email notification — V-270818, notify the SA and ISSO at 75% of audit storage, and
V-270819, notify on audit processing failure — and **no email can leave an air gap.** `auditd`
is configured `space_left_action = email` with `action_mail_acct = root`, and Postfix is
deliberately `inet_interfaces = loopback-only` **because the STIG requires it**. So the
notification is generated and delivered to a local mailbox nobody watches
(`ssp-inputs.md` §5.1, open-questions Q26).

**Alerts fire into Alertmanager on `svc-obs-01` and go no further.** Until the AO answers, an
alert is something a human has to look at a screen to see. That is §7 of this document, and it
is the single unresolved item in an otherwise strong family.

**Two statements about the maturity of this capability, because both are true and they pull in
opposite directions.** The instrument works: it found a silent nightly-backup failure within
minutes, it found log rotation broken enclave-wide since hardening, and it found nineteen
pending security updates that nothing in the enclave could previously see. And the instrument
has lied: six false passes were produced while building the first two dashboards, three of
which reported success while measuring the wrong thing. §8 is about that, and it is the part of
this strategy that is hardest to write and most worth reading.

---

## 2. Scope and strategy

### 2.1 What is monitored, and from where

**The collector is outside the Kubernetes cluster, deliberately.** If the cluster is what you
are monitoring, monitoring from inside it means being blind exactly when it breaks. It also did
not exist yet when the monitoring was built, and visibility was wanted during the build
(runbook §10a).

| Component | Where | Bound to |
|---|---|---|
| `prometheus` | `svc-obs-01` | **127.0.0.1:9090** |
| `prometheus-alertmanager` | `svc-obs-01` | **127.0.0.1:9093** — the cluster port 9094 is disabled, one node |
| `grafana-server` | `svc-obs-01` | **127.0.0.1:3000**, reached only through nginx on 443 with an enclave certificate |
| `prometheus-node-exporter` | all five in-gap machines | each machine's own enclave address, port 9100 |
| `prometheus-libvirt-exporter` | the hypervisor | the hypervisor's enclave address, port 9177 — **86 metrics** |

**The libvirt exporter is the one non-obvious choice and it earns its place: it reports
per-guest CPU, disk and network from the hypervisor, so a guest that is too sick to report its
own metrics still has metrics** (runbook §10a).

**The Kubernetes cluster will be scraped from the collector, not by a Prometheus inside it.**
That needs a network path and credentials from outside the cluster, which is a step-06 design
input rather than a post-deployment addition — and it lands in the same place as the Kubernetes
STIG's Bootstrap guidelines, which also have to be right at cluster creation
(runbook §10a, HANDOFF §3a).

### 2.2 What was declined, and the threshold rather than the conclusion

**Control and metrics are two problems, and conflating them costs you.** Control means seeing a
guest, restarting it, getting a console. Metrics means graphs, trends and alerts. A good
dashboard shows both, which is why they get merged, but they carry very different security
costs here.

Control is `virsh` over SSH, which **adds zero listening surface**, plus the existing rescue
tooling built on it. `cockpit` 314 and `cockpit-machines` 310 **are** in the mirror, and
`cockpit-machines` is a genuinely good libvirt UI. It was declined for three reasons: it is a
listening admin service on every hypervisor; **no DISA STIG exists for Cockpit**, so it would
be a new uncovered product on the machine that runs every guest; and on the hypervisor it means
opening a port on the one machine where the ufw tooling **deliberately refuses** to manage
rules, because it bridges guest traffic.

> **At four hosts the UI is not worth that trade. At forty it would be.** The threshold is
> recorded rather than the conclusion, because the second facility may be bigger (runbook §10a).

### 2.3 The design rule everything here follows

> **A missing source must never render as zero findings.**

A dashboard reading "0 Open" because a scan was never run looks exactly like one reading
"0 Open" because the machine is clean. So **a family with no source emits no samples at all.**
"No data" on a panel is honest. A green zero is a lie
(`../dashboards-and-metrics.md` §6).

This is the rule that makes the rest of this strategy trustworthy, and it is why two of the
34 alert rules are **meta-alerts** that fire on staleness and absence rather than on any
threshold (§5.2).

### 2.4 Retention and sizing, measured

| | Value |
|---|---|
| Audit volume, steady | **2.44 MB/day** on `svc-harbor-01`, **1.71 MB/day** on `svc-repo-01` |
| Audit volume, busiest hour extrapolated to a day | 29.0 MB/day and 14.5 MB/day respectively |
| Method | `audit-volume.sh` sampled **hourly for 55 hours**, 56–57 intervals per machine. Data, not an estimate |
| Projected at twelve machines, audit, steady | ~30 MB/day → **~11 GB for a year** |
| Projected at twelve machines, audit, sustained-burst worst case | ~350 MB/day → ~127 GB/year |
| Prometheus, **estimated** | 150–200 MB/day → ~55–73 GB/year. **An estimate from typical compressed sample sizes, not a measurement of this enclave** |
| Collector disk | **250 GB**, which gives a year of both with real headroom |

**Read the two audit columns differently.** The steady rate is what accumulates. The
busiest-interval figure takes one hour of activity and projects it across a full day, so it is
deliberately conservative — it answers *"what if the machine stayed that busy"*, which it does
not.

**This answers our half of the retention question. Retention length is the AO's half**
(«how long audit records stay online», «how long they are archived, and where»), and
bytes-per-day is now measured rather than guessed — the answer is small, so if a year is asked
for, that is 11 GB of audit records and the conversation should be easy (runbook §10a,
`poam.md` AO-04).

**Prometheus retention was silently 15 days.** `storage.tsdb.retention.time = 0s` and
`retention.size = 0B` mean Prometheus falls back to its built-in 15-day default — on a guest
sized for a year. It is now set explicitly to 90 days and 100 GB. **90 days is a placeholder
until the AO answers; the size cap is the real protection.** Whichever limit hits first wins,
so a noisy month cannot fill 250 GB and take down the machine used to find out why things are
broken (runbook §10a).

### 2.5 One measured fact that changes the audit-retention conversation

**The audit trail as configured does not exist beyond 40 MB.** `num_logs=5` × `max_log_file=8`
MB is 40 MB of rolling history, after which the oldest records are destroyed — and `audit.log`
reached 6.5 MB within forty minutes of a reboot on an idle guest.

**Worse, UBTU-24-100450 passes with `active = yes` in `au-remote.conf` and no remote server in
existence.** That is a hollow pass: the control reports satisfied while offloading nothing
(runbook §6.3d).

An in-boundary collector now exists — `svc-obs-01` subsumes the separately planned log
collector — so what is missing is the retention and destination answers, not the machine
(HANDOFF §1, `poam.md` AO-04).

---

## 3. What is monitored, by family

Every metric family below has a named source, a change frequency and a documented way it can
lie. The full reference is `../dashboards-and-metrics.md`; this section states what the
strategy covers.

| Family | What is collected | Source | Cadence |
|---|---|---|---|
| **Availability** | Target up/down, per scrape target | Prometheus itself | 15 s–1 min scrape |
| **Host and guest OS** | CPU, memory, filesystem, read-only mounts, kernel version, interfaces | node-exporter on all five machines | scrape |
| **Guests from the hypervisor** | Per-guest CPU, disk and network | libvirt exporter, 86 metrics | scrape |
| **STIG residual** | Open / Not Reviewed / Not a Finding counts per machine, and checklist age | Evaluate-STIG CKL/CKLB, published as facts | **15 min** |
| **USG results** | Pass / fail per machine | `usg audit` output, published as facts | **15 min** |
| **Audit trail** | `auditd` running, backlog, **lost events**, audit filesystem usage | `auditctl -s` and node-exporter | **15 min** / scrape |
| **File integrity** | AIDE last run, last exit code | AIDE state, published as facts | **15 min** |
| **Access control** | faillock tallies, sudo invocation counts | published as facts | **15 min** |
| **Cryptographic posture** | `fips_enabled`, certificate expiry dates | published as facts | **15 min** |
| **Patch posture** | `pro security-status`, `apt-check`, esm-apps and esm-infra state, apt metadata age, Pro contract expiry | published as facts | **15 min** |
| **Backup** | Per-guest set counts, complete vs incomplete sets, destination mounted, timer state, volume free space | `vm-backup.sh facts` | **15 min** |
| **Registry** | Harbor overall and per-component health, **Trivy database age** | Harbor's unauthenticated `/api/v2.0/health` | **15 min** |
| **Producer health** | Whether each fact producer is actually producing | textfile collector and process inspection | **15 min** |

**The textfile collector is the whole trick.** It lets anything on a machine publish a metric
without writing an exporter, which is what makes the compliance families possible at all — a
15-minute timer runs the collectors and writes files that node-exporter serves
(`../dashboards-and-metrics.md` §2).

The timer is `OnCalendar=*:0/15`, which is absolute: **it cannot lose its place, and a reload
or a reboot does not change when it next runs.**

**Harbor's health endpoint is unauthenticated**, so component health needs no registry
credentials — which is why it could be added without putting a credential in a fact collector
(runbook §10a).

---

## 4. Assessment, and the relationship between the two scanners

Continuous monitoring here is not only telemetry. It includes re-assessment, and the strategy
uses **two scanners in a fixed order** for a measured reason.

**`usg fix` is the only remediation engine; Evaluate-STIG does not remediate at all.** An
unhardened machine shows **118 Open** against DISA V1R6; the same machine after `usg fix` plus
tailoring and fixups shows **20**. Scanning with Evaluate-STIG first would hand an operator 118
findings to work by hand, 98 of which `usg fix` closes for free. Running it second means it
measures the residual (runbook §6.0).

**Neither is redundant, and the evidence package has to state the relationship**, because the
two numbers differ and an unexplained difference reads as a discrepancy. On one machine on one
day: **USG 7 fail, Evaluate-STIG V1R6 20 Open and 14 Not Reviewed** (runbook §10.1f).

Current state, every figure a dated measurement:

| Machine | USG pass / fail | V1R6 Open | Measured |
|---|---|---|---|
| `host-4` | 208 / 8, re-audited with the chrony deviations | 5 | 2026-09-16 |
| `svc-harbor-01` | **210 / 6** | 5 | USG 2026-09-16 |
| `svc-mgmt-01` | **209 / 6** | 6 | USG 2026-09-16 |
| `svc-repo-01` | **212 / 5** | 5 | V1R6 2026-09-16 |
| `svc-obs-01` | **211 / 5** | 4, plus 9 Not Reviewed | 2026-09-14 |

**The residual is the same six on machines with nothing in common**, all policy decisions with
written rationales and none a defect (`airgapped-setup-machine/README.md` §0).

Three points of strategy follow:

- **Re-scan cadence is «how often each machine is re-scanned», and `StigScanStale` enforces
  whatever it turns out to be** — it currently fires on a checklist older than 30 days.
- **Evidence collection is part of monitoring.** `stig-tools.sh collect` walks the address table
  and pulls both scanners' output to the staging host. **It was skipped on every machine until
  2026-09-14**: all five held their own checklist, the staging host held none, and four of the
  five are rebuildable guests. The first real run took **103 files and 337 MB off five
  machines**. *Evidence you cannot collect is evidence you do not have* (runbook §6.0 step 14).
- **Deviations must be expressed to both scanners.** A USG tailoring **does not travel** to the
  tool DISA uses. `answerfile.sh` writes **17 portable Answer File entries with zero
  `ResultHash` values** (counted 2026-09-17), each re-running DISA's own check text at scan time so the control
  re-opens if the condition changes — and portability was proven on a second dissimilar machine
  rather than assumed (runbook §10.1, `airgapped-setup-machine/README.md` §0a).

**CA-2 needs an independent assessor.** Every assessment to date is self-assessment, which is a
different artifact: «who performs the independent assessment - self-assessment is a different artifact» (`poam.md` CUST-05).

---

## 5. Alerting

### 5.1 The rule set

**34 rules in 9 groups**, generated by `monitoring.sh rules` into `/etc/prometheus/rules/`.
**Every rule carries an `action` annotation saying what to do about it — an alert that does not
say what to do is a pager that trains people to ignore it.** Thresholds are the `AL_*`
parameters at the top of the script; nothing is hardcoded — **21 of them**, counted 2026-09-17.

| Group | Rules |
|---|---|
| availability | `InstanceDown` |
| cpu / memory | `HighCPU`, `MemoryPressure` |
| filesystems | `FilesystemFillingWarning`, `FilesystemFillingCritical`, `AuditFilesystemFilling`, `FilesystemWillFillSoon` (`predict_linear` over 6 h says full within 4 h), `FilesystemReadOnly` |
| audit trail | `AuditRecordsLost`, `AuditRecordsLostAtBoot`, `AuditdNotRunning`, `AuditBacklogNearLimit` |
| compliance drift | `StigOpenControlsIncreased`, `StigScanStale`, `FipsModeDisabled`, `CertificateExpiringSoon`, `AideCheckStale`, `AideDetectedChanges`, `AccountLockoutRisk`, `ComplianceFactsStale` |
| backups | `BackupMissed`, `BackupNeverCompleted`, `BackupInterrupted`, `BackupDestinationDetached`, `BackupTimerDisabled`, `BackupVolumeFilling`, `BackupFactsMissing` |
| registry | `HarborUnhealthy`, `HarborComponentUnhealthy`, `TrivyDatabaseStale`, `TrivyDatabaseMissing` |
| patch posture | `SecurityUpdatesPending`, `AptMetadataStale`, `ProContractExpiring`, `FipsUpdatesDisabled` |

**Rules live in Prometheus, not in Grafana.** Grafana's alerting lives in its database, which is
not versioned, does not travel on transfer media and dies with the guest. **A rule file is a
file in the repository** (`../dashboards-and-metrics.md` §7).

### 5.2 Five rules shaped by a lesson rather than a threshold

These are the ones worth understanding, because each encodes a measured failure.

**`SecurityUpdatesPending` is a disjunction because `apt-check` cannot see ESM.** Measured
2026-09-16, minutes after `esm-apps` was enabled: `apt-check` reported zero security updates on
**five machines out of five**, while `pro security-status` reported **19** esm-apps security
updates. The rule fired on apt-check's number alone and **would have missed every one.** ESM is
where `universe` packages get their only coverage, so it is precisely the stream that must not
be invisible. Each term keeps its own machine label, which is why it is a disjunction and not a
sum.

**`AccountLockoutRisk` has no hold time, deliberately.** `pam_faillock` is `deny=3` with
`unlock_time=0`, so the **third** failure locks the account permanently until a tally file is
truncated by hand. A five-minute hold put the warning after the window in which it was useful —
on 2026-09-16 the operator hit one failure on the hypervisor and found out from `sudo`, not
from here. It now fires on the first failure, which is the only warning that arrives in time.

**`AuditRecordsLost` uses `delta`, not a bare threshold.** `auditd`'s lost counter is cumulative
since boot, so `> 0` would fire forever on a machine that dropped records once weeks ago — and
an alert that is always firing trains people to close it without reading. `delta` over an hour
asks the actionable question: *is it losing records now*. What it cannot see is loss **at boot**
— the counter resets to what the boot dropped, not to zero, and stays flat — so
**`AuditRecordsLostAtBoot`** alerts on any loss within `AL_BOOT_LOSS_WINDOW` of a boot and then
clears by itself (backlog 3.33; the rationale is in `dashboards-and-metrics.md`).

**Nothing alerts on the residual set being non-zero.** It is non-zero by design and every
finding in it has a written rationale. `StigOpenControlsIncreased` alerts on it **changing**,
which is the drift question and the one worth waking somebody for.

**`ComplianceFactsStale` and `BackupFactsMissing` are the meta-alerts, and they carry their
groups.** Every other compliance and backup rule needs its metric to exist before it can fire,
so a producer that silently stops takes the whole group quiet — **and quiet is
indistinguishable from healthy.** Those two fire on frozen and on absent respectively
(`../dashboards-and-metrics.md` §7).

### 5.3 Honest note on the rule set's provenance

**Every expression was evaluated against live data before shipping, and all were quiet at the
time — which for the backup group meant the metrics did not exist yet, not that the backups
were fine.** That is exactly the distinction `BackupFactsMissing` exists to make
(`../dashboards-and-metrics.md` §7).

---

## 6. What the instrument has actually found

This section exists because it is the argument for having built any of this, and because a
monitoring strategy that lists capabilities without results is a procurement document.

### 6.1 Within minutes of the first scrape

| Finding | Detail |
|---|---|
| **`auditd` had lost 446–500 events on four of five machines** | The kernel dropped audit records — the trail has holes. One machine alone was at zero. This is V-270819 territory **measured directly rather than inferred**, and it is the strongest evidence in the package that a monitored signal is the only notification this enclave can deliver |
| **USB storage unblocked on the hypervisor** | Expected while the backup window was open — but the control was failing on that machine at that moment and **nothing else said so** |
| **144,840 sudo invocations in 24 hours on `svc-mgmt-01`** | 1.68 per second. The MAAS `machine-resources` storm, measured rather than estimated. ✅ **CLOSED 2026-09-18 by removing MAAS from the boundary** — the root cause was never found and no longer needs to be (`poam.md` ENG-28) |
| **Two machines' checklists were 3.1 days stale** | A re-scan that was owed, now visible as a number instead of a memory |

### 6.2 Findings that nothing else in the enclave could have produced

| Finding | Why only monitoring found it |
|---|---|
| **The first scheduled backup failed silently** | The timer was enabled, the volume mounted and healthy with 4.2 TB free, and every other signal green. Before the backup facts existed, **this would have been found during a restore** (Contingency Plan §6.2) |
| **Log rotation was broken enclave-wide since hardening** | A hardening fixup set `/var/log` to group `syslog`, and logrotate then refuses every file in a stanza without an `su` directive. One machine's `/var/log/messages` had reached **7.9 GB, never rotated.** **The control passed throughout while the disk filled.** Fixed on all five; forced rotation reclaimed 5 GB immediately |
| **Nineteen pending security updates nothing could see** | `esm-apps` was **entitled all along** on every in-gap machine and had simply never been switched on; the archive was already mirrored and serving. So the `universe` packages were uncovered **by omission, not by entitlement** |
| **apt metadata was 15 days old everywhere** | A mirror snapshot from a fixed date, so every "0 security updates" was only true as of that date. `AptMetadataStale` fires at 30 days |
| **Trivy's vulnerability database is expired** | Present, so scan results are real — but built upstream **2026-09-08** with a `NextUpdate` of **2026-09-09**, and one day staler per day. **Harbor keeps accepting pushes and keeps reporting images clean, so a stale database and a clean image are indistinguishable from the portal** (`poam.md` ENG-40, AO-10) |
| **Nothing was watching the watcher** | Prometheus scraped itself from the start; Alertmanager and Grafana never were, though both serve metrics on loopback. **Nothing could answer whether an alert had been delivered** — the one question the alerting stack exists for. Nine targets now, not seven |

### 6.3 One reproducibility gap the monitoring work closed

**Grafana's `.deb` was carried into the enclave before it was ever written down.** A rebuild
from a fresh download run would have reached the collector step with nothing to install. It is
now recorded in the downloads list with the SHA-256 that the build script enforces, verified
against the staged copy (runbook §10a).

That is a monitoring finding about the monitoring itself, and it is the same class of problem
as the evidence-collection gap in §4: **a capability that exists only because somebody did
something by hand once is not a capability.**

---

## 7. The notification gap

**This is the one unresolved item in this strategy, and it is not solvable inside the
boundary.**

| | |
|---|---|
| What two controls require | Email notification: V-270818 at 75% of audit storage, V-270819 on audit processing failure |
| What the system does | Generates the notification and delivers it to a local mailbox nobody watches. `auditd` is `space_left_action = email`, `action_mail_acct = root`, and Postfix is `inet_interfaces = loopback-only` **because the STIG requires it** |
| Why it cannot be fixed | **No email can leave an air gap.** There is no egress by design, and adding one would trade a boundary control for a notification |
| The honest compensating control | Prometheus and Alertmanager alert on audit filesystem usage and on `auditd` failure, and surface both on a dashboard. **That is a different mechanism from the one the control names**, and saying so is the point |
| The strongest supporting evidence | The stack publishes `enclave_auditd_lost` from `auditctl -s`, and on the first scrape **four of five machines had lost 446–500 audit events** — V-270819 measured directly rather than inferred |
| The question for the AO | **Does an in-boundary alert on a monitored dashboard satisfy "notify the SA and ISSO", given that email cannot cross the gap?** If yes, the rules are already written. If no, the control stays open on every machine in the enclave, permanently |
| Recorded as | `poam.md` AO-02, open-questions Q26 |

**Two consequences of the gap have to be stated plainly rather than softened.**

First, **an alert is only as good as the frequency with which somebody looks at the screen.**
`«how often the alert console is actually looked at»` is a facility answer and it is the whole
control: 34 rules firing at a display nobody watches at 03:00 is not a notification path, and
this strategy does not claim otherwise.

Second, `«who reviews Alertmanager, and how often»` has to be a named role with a stated
cadence, not "the operator sees it". In a one-operator enclave that is the same person who is
being notified, which is a real weakness and is the reason the alternate in the Contingency Plan
matters.

---

## 8. How the monitoring can lie, and what was done about it

**This is the most important section of this strategy for an assessor, because it is the
difference between an instrument and a decoration.**

Writing the first two dashboards produced **six false passes**, every one of which reported
success while measuring the wrong thing:

| What reported success | What was actually true |
|---|---|
| `promtool check config` | Passes happily for a configuration with **no rule files at all** — which is how the first "rules loaded" verification succeeded with zero rules loaded |
| "Grafana has 5 dashboards loaded" | The search endpoint returns **401** unauthenticated, and the check was counting the five keys of the error object |
| Every panel rendering "No data" | The provisioned datasource had **no uid**, so Grafana invented one and nothing matched |
| `enclave_aide_last_exit_code 0` | `systemctl show` on a **nonexistent unit** exits 0 and prints defaults |
| A machine reporting another machine's checklist | The evidence glob was not scoped to the hostname |
| A collector reported broken while working | `grep -q` under `set -o pipefail`: grep exits on first match, the producer dies of SIGPIPE with status 141, and the pipeline reports failure **even though grep matched.** Whether it bites depends on how far into the output the match is, which is why the same working configuration reported broken on three machines and fine on two |

### 8.1 The rule that came out of it

> **Verification asks the running thing, never the file just written.**

`monitoring.sh` now counts rules in the live Prometheus process, reads Grafana's own database
for the dashboard count, and asks the exporter which collectors it loaded — rather than
inspecting the configuration it wrote a moment earlier
(`../dashboards-and-metrics.md` §6).

### 8.2 Three more that are worth carrying between facilities

**`node_scrape_collector_success{collector="textfile"} 1` does not mean it read anything.** With
no directory configured there is nothing to fail at, so success means *"read nothing"* — and
the same run reported the systemd collector succeeding with **970 series** instead of the eleven
its unit filter allows. The check now reads the running process's own command line for the
textfile directory argument before trusting either collector's success flag.

**Two subcommands must not write the same setting differently.** One subcommand set
node-exporter's arguments to the listen address alone, silently undoing what another had
configured on the same machine. On 2026-09-15 that removed the textfile directory and the
systemd unit filter from `svc-obs-01` — the only machine where it had been re-run — so **that
machine alone stopped publishing every compliance fact while continuing to look healthy.** Both
subcommands now call one builder function.

**A Grafana datasource uid is a contract, and getting it wrong takes Grafana down.** Grafana
updates a provisioned datasource **by uid**; pinning one on a datasource first created without
one makes that update look up a uid its database has never seen. Provisioning fails, and
provisioning is a hard dependency of the HTTP server, so **Grafana exits 1 in a loop** — which
from the outside is an nginx 502 with a clean nginx log. Deleting the datasource by name first
is the documented migration, and the dashboard step now waits on Grafana's health endpoint and
dies with Grafana's own error rather than reporting success over a dead service.

### 8.3 And the general lesson, stated as a strategy principle

**Suspect the check before the fix.** Seven checks in this build were found wrong in one night,
three of them producing false passes. **A green result proves nothing until the check itself is
trusted.**

The companion principle is **measure where the control can actually fail.** A conclusion that
AIDE does not index bulk data was drawn from a machine **whose `/srv` was empty** — zero entries
proves nothing about scope there. It was wrong, and the correct measurement showed AIDE walking
the mirror at about 26 MB/s, which on 321 GB is roughly three and a half hours inside a
remediation run that prints nothing (runbook §6.3h, open-questions).

---

## 9. Security posture of the monitoring itself

A monitoring stack is new attack surface, and in this enclave it is new **finding** surface as
well. What was done about that:

| | |
|---|---|
| Binds | Prometheus, Alertmanager and Grafana on loopback only. Grafana reachable solely through nginx on 443 with an enclave certificate, and `:3000` refused in 0.5 ms from off-box |
| Proven, not asserted | `monitoring.sh` proves every bind with `ss` after each restart. **All five components bind all interfaces out of the box** — that is one earlier finding repeated five times, which is why it is checked rather than configured and forgotten |
| TLS before the password | Grafana was moved behind TLS **before the admin password was ever set**, which is the only order that helps. Verified from off-box with the enclave root CA and no `-k`: HTTP 200 by IP and by name, `ssl_verify_result=0` both ways, `:80` returning 301 |
| The step people skip | `GF_SERVER_ROOT_URL` must move with the port, or every login redirect points back at plain HTTP and drops the browser out of TLS on the first redirect — the padlock appears, then quietly goes away |
| Exporter exposure | **Port 9100 exposes every mount, interface, process count and kernel version.** The rule belongs in the ufw table source-restricted to the collector, not poked in by hand — and ufw only enforces on the machines that have a rule table (`poam.md` ENG-51) |
| Proof the source restriction works | Measured against a live listener at the same moment: from the collector the scrape target reads `up`; from a non-collector machine `curl` times out at **7.0 s, dropped**. **Timing is what distinguishes a ufw DROP from a closed port** — a closed port refuses instantly. Before the exporter existed both looked identical, which is why the first "proof" of that rule proved nothing |
| Hardening order | **Prove the stack before hardening it, not after.** Build, verify, harden, verify again — any breakage is then attributable. `svc-obs-01` landed on 211 pass / 5 fail and the stack was re-verified afterwards |
| Desk access | An SSH tunnel through the one machine with a foot in both networks, **temporary and dying at cutover by design.** Nothing in the build may depend on it (`poam.md` ENG-54) |

---

## 10. What this strategy does not yet cover

Stated as gaps rather than omitted.

| Gap | Detail |
|---|---|
| **No notification path** | §7. The single unresolved item |
| **No CVE-level scanning of the machines themselves** | The patch-posture family measures how far behind the mirror each machine is, which is a **different question** from whether an installed package has a known CVE. Closing it needs Trivy pointed at a filesystem, and **there is no Trivy CLI anywhere in the enclave** — it exists only inside Harbor's container. Either route is bounded by the same dated database, so it would report CVE exposure as of the database's date, not today (`poam.md` ENG-41) |
| **No role dashboard for the mirror** (the MAAS half is moot — removed 2026-09-18) | The mirror needs Release-file age, repository growth and a **pool** URL probe — `Release` returning 200 while `pool` returns 401 reads as success, and that trap has already been hit in this project. MAAS needs DHCP pool utilisation |
| **No alerts on the collector itself** | Rule-evaluation failures, a growing notification queue and the time-series database nearing its retention ceiling are all visible on the collector dashboard and none of them page. **There is a limit to how far this can go: a Prometheus that cannot evaluate rules cannot evaluate the rule that says so.** Genuinely closing it needs something outside the collector watching the collector |
| **No Kubernetes monitoring** | The cluster does not exist yet. Scraping it from the collector is a step-06 design input (§2.1) |
| **No database monitoring** | The PostgreSQL guests do not exist yet, and the **synchronous-degradation alert is owed** — it is the rule that makes the `synchronous_mode_strict=off` decision defensible (`poam.md` ENG-06) |
| **Metric retention is a placeholder** | 90 days and 100 GB, pending «Prometheus retention - 90d/100GB is a placeholder, not a decision» |

---

## 11. Reporting

| | |
|---|---|
| To whom | «who receives the monitoring report» |
| How often | «monthly or quarterly» |
| In what format | «the format required - eMASS entry, PDF, dashboard screenshot» |
| Overall reporting requirement | «to whom, how often, in what format» |
| External SIEM | «NONE or the SIEM this must feed, and by what transfer mechanism» |
| STIG Manager | «NONE or the programme runs STIG Manager and expects CKLs fed to it» |

**Two reporting constraints are structural rather than administrative.**

**Anything leaving this boundary leaves on media or through a one-way transfer device.** If the
programme has a SIEM this enclave must feed, those are the only two routes and the answer
changes the design rather than the report format — which is why it is an AO question and not an
assumption (runbook §6.3d, `poam.md` AO-04).

**Ask about STIG Manager before building a correlator.** A USG-to-Evaluate-STIG correlator is
on the backlog, with the join key being the STIG ID and the map already existing in the
tailoring file. **If the programme runs STIG Manager, feed it rather than building one**
(`airgapped-setup-machine/README.md` §0a E6, `poam.md` ENG-64).

**What should be reported, given that the raw material is already generated:** the per-machine
USG and V1R6 tallies with their dates, the residual set and the fact that it is identical across
dissimilar machines, checklist age, patch posture including the ESM streams, backup completeness
and the date of the last deep verify, certificate expiry, `auditd` loss, Trivy database age
beside every scan result, and the POA&M's own movement. All of it is already published as
metrics on a 15-minute cadence, so the report should be **generated from the instrument rather
than transcribed from it** — this baseline's own rule, and the reason the dashboards were built
before the document describing them.

---

## 12. Control coverage summary

| Control | State | Basis |
|---|---|---|
| **CA-7** Continuous monitoring | ✅ **Strong and running**, with a named notification gap | §3, §5, §7 |
| **CA-7(4)** Risk monitoring | ⚠️ Partial — compliance drift, patch posture and backup capability are all instrumented; **CVE-level exposure is not** | §3, §10 |
| **AU-6** Audit review and analysis | ⚠️ Partial — `auditd` loss, backlog and filesystem usage are alerted; **record-level review depends on the offload answer** | §2.5, §7 |
| **AU-4 / AU-5** Audit capacity and response | 🔴 **Blocked on the AO.** The condition is measured and alerted; the notification the control names cannot be delivered | §7 |
| **SI-4** System monitoring | ✅ 34 rules in 9 groups, every one with an action annotation, every threshold a parameter | §5 |
| **SI-2** Flaw remediation monitoring | ✅⚠️ Patch posture measured across apt, esm-apps and esm-infra; **third-party packages have no stream** | §6.2, `poam.md` AO-11 |
| **RA-5** Vulnerability monitoring | ⚠️ Images scanned in the registry, **against data of a known and growing age**; hosts not scanned at all | §6.2, §10 |
| **CM-6** Configuration settings monitoring | ✅ Compliance facts every 15 minutes; drift alerts on change rather than on the designed residual | §3, §5.2 |
| **CA-2** Assessment | ⚠️ Two scanners, dated evidence, preserved progressions — **but self-assessment only** | §4 |

---

## 13. Sources

| Reference | What it supplies |
|---|---|
| `docs/compliance/dashboards-and-metrics.md` | The authoritative metric reference: every series, where it comes from, how often it changes, **how it can lie**, the alert rules, the security posture of the stack, the traps, and the rebuild sequence |
| `docs/runbook.md` §10a | How the stack was built, in what order, and why — including what was declined and the measured sizing |
| `docs/runbook.md` §6.0 | The hardening sequence, and why USG runs before Evaluate-STIG |
| `docs/runbook.md` §6.3d | Audit offload, the 40 MB trail, and the hollow pass |
| `docs/runbook.md` §6.3e, §6.3h | The ufw rule the enclave cannot satisfy as written; AIDE scope and the empty-`/srv` measurement error |
| `docs/runbook.md` §10.1, §10.1f | The two scanners, the residual set, and the relationship the evidence package must state |
| `docs/compliance/ssp-inputs.md` §4, §5 | The decided statements on media, patching and audit |
| `docs/compliance/nist-800-53-plan.md` | Family-by-family status, and the CCI harvest that is not yet built |
| `docs/open-questions.md` Q25, Q26, Q27, Q28 | The AO decisions this strategy is waiting on |
| `airgapped-setup-machine/README.md` §0/§0a | Per-machine tallies, the residual set, and the Evaluate-STIG work stream |
| `scripts/enclave/monitoring.sh` | The stack itself: exporters, rules, facts, the 15-minute timer, dashboards, and 21 named alert thresholds |
| `scripts/enclave/audit-volume.sh` | The hourly audit-growth sampler that produced the sizing measurements |
| `scripts/enclave/stig-tools.sh`, `answerfile.sh` | Scanner distribution, evidence collection, and portable deviation entries |
