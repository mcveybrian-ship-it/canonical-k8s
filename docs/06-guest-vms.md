# Step 06 — compose and harden the guest VMs

> **DESIGN, 2026-09-26 — D1, D2, D3 and the test guest DECIDED (§9); nothing built yet.** It answers backlog **B-06**:
> *nothing drives hardening on a guest* — `05-harden-host.sh` refuses anything but host-1..4, so
> every guest so far was hardened by hand. The numbered decisions **D1–D8** at the end are what
> the review settles; everything above them is the reasoning and the evidence behind each one.

---

## 1. What step 06 is, measured rather than remembered

**Ten guests, not six.** B-06's title says "the 6 cluster VMs"; `scripts/enclave/vm-specs.env`
now places **3 PostgreSQL, 3 Kubernetes control-plane and 4 worker guests** — ten — on top of the
four service VMs, with anti-affinity between the members of each set:

| host | guests the map puts there |
|---|---|
| host-1 | pg-01, k8s-cp-01, k8s-wk-01, **svc-repo-01** |
| host-2 | pg-02, k8s-cp-02, k8s-wk-02, **svc-harbor-01** |
| host-3 | pg-03, k8s-cp-03, k8s-wk-03, **svc-obs-01** |
| host-4 | k8s-wk-04, **svc-mgmt-01** |

That is the **production** map. The **lab** profile keeps all four service VMs on host-4, where
they run today (`vm-specs.env`, `VM_PROFILE=lab`); `03-compose-vm.sh plan` shows the lab layout
and confirms it fits — on 2026-09-26 host-1 needed 26 of its 30 GiB, anti-affinity held.

**The lab cannot run the production spec, and the spec is not shrunk to fit it.** Production asks
for ~200 GB of guest RAM against ~91 GB available, and a single production worker (32 GB) is larger
than any lab host. `VM_PROFILE=lab`, declared by each lab host in `/etc/enclave-profile`, swaps in
lab sizes; the production numbers stay the file's default (runbook §7.2, `HANDOFF.md` §3).

**Hardening the hypervisor does not harden the guest.** Each guest needs its own Pro attach, its
own FIPS kernel and its own STIG pass — runbook §7.4. That is ten more runs of runbook §6.0.

## 2. What exists today — verified 2026-09-26

| fact | evidence |
|---|---|
| host-1..3 are already hypervisors | libvirt active, `br0`, `vg-data`, ~29–30 GB free on each |
| A new guest gets, from cloud-init: hostname, admin account (hash + keys), mirror apt sources, `/etc/hosts`, the enclave resolver, CA trust, extra packages | `03-compose-vm.sh` user-data |
| A new guest gets **no** repo, **no** Pro, **no** hardening | same |
| The guest's serial console is logged on its host, to `<pool>/console/<vm>-console.log` (0644, a pty with a log, so `virsh console` still works) | `03-compose-vm.sh` `--serial pty,log.file=...` |
| **The cloud-init seed stays attached for the guest's whole life** — and it carries the admin hash and the authorized keys | nothing detaches it; `03-compose-vm.sh` only warns that the data disk would move `vdc`→`vdb` if it ever were |
| `05-harden-host.sh` has 18 steps, stops at 3 reboots for a human, and still needs a person in 4 places: the Pro token (`scp -3` from stage-01), passwords (now from the credentials file, 3.32), **`step_tailor`'s `confirmed reachable from off-box? [y/N]`**, and **`step_prechecks`'s `proceed to usg fix? [y/N]`** — the fourth was missed here and found by the slice-2 live run (2026-09-27), which halted on it | the script |
| ufw rule tables exist for the eight current machines only; `stig-tailor.sh ufw` **refuses** on any other | `stig-tailor.sh` `ufw_rules()` |
| **Neither STIG turns off what Kubernetes needs.** usg's `stig` profile (226 rules) and DISA's Ubuntu 24.04 V1R6 benchmark select **nothing** on `ip_forward`, forwarding, `br_netfilter`, BPF or `noexec` (usg's only "forwarding" rule is SSH X11) | queried both benchmark files, with known rules as the positive control |

## 3. The one choice everything else follows from — who runs the hardening (D1)

**A. The operator, inside each guest, as on the hosts today.** Ten guests × eighteen steps ×
three reboots, each in its own SecureCRT session. It works; it is also exactly the
"forty commands and a dozen judgement calls, done five different ways" that 05 was written to end,
and it is not unattended — the from-scratch build (2.6) is defined as unattended.

**B. A host-side orchestrator, over SSH.** Not viable: hardened guests have no `NOPASSWD`, so every
privileged command needs a typed password; host-4 has no key into the guests; and stage-01 cannot
reach inside the gap after cutover.

**C. The guest hardens itself from its first boot — recommended.** The reason 05 stops at every
reboot on a host is the LUKS passphrase at a console. **A guest has no such prompt** — its disk is
an image on the host's already-unlocked, LUKS-encrypted storage — so a guest can reboot itself and
carry on. Run from a systemd unit it runs as root, so no sudo password is needed either. It runs
05's own step list, resumes after each reboot from 05's existing state file, and reports progress on
its serial console, which the host already logs.

## 4. How C works, end to end

### 4.1 Inputs travel on a per-guest provisioning disk — not in the cloud-init seed

`03-compose-vm.sh` builds a small read-only disk, label `ENCLAVE-PROV`, next to the seed (same
`0711` pool directory, file mode `0600`), holding exactly:

- **the repo** — exactly the files `push-repo-to-host.sh` delivered to the host, listed in the
  `.pushed-files` it now writes beside `.pushed-from` (a host has no git). Never the whole
  directory: it can hold anything put there since, and files deleted from git that an
  extract-over-the-top leaves behind. Compose refuses without the list;
- **this guest's credentials file** — `credentials.<vm>.env` read from the `enclave-cred` stick,
  mounted read-only on the host (`airgap-media.md` §9). The guest gets its own file and no other;
- **the Pro token** — see D3;
- **the Evaluate-STIG Answer File** — today pushed from stage-01, which will not be reachable;
- **the operator** (`provision.env`, `ENCLAVE_OPERATOR=` the VM admin user) — the account the
  hardening unit acts for (4.3); parsed on the guest, never sourced.

**As built (2026-09-27):** `sudo ./03-compose-vm.sh <vm> --harden [--cred-dir DIR]`. Every input
is gathered and checked **before anything is created** (the 3.38 rule): the guest's file must be
root 600, in the reader's format, and carry *that guest's* break-glass key; the token, the answer
file and a ufw table for the guest must exist. Staged on `/run` (tmpfs), imaged with `genisoimage
-R` (Rock Ridge keeps the 0600), the stage shredded on any exit. The disk goes after the data disk,
so a PG guest's data disk stays `vdc`. The profile was dropped from the list: nothing on the guest
reads it.

Why not the seed: the seed has to exist for cloud-init and is small and public-shaped; putting the
token and the credentials in it would make the thing that currently never gets detached into the
thing that holds secrets. A separate disk has one job and a clear end of life (4.5).

### 4.2 First boot

cloud-init's `runcmd` mounts `LABEL=ENCLAVE-PROV` read-only and:

1. installs the repo to a **root-owned** directory (`/opt/enclave-build`) — the same reason as
   `install-runtime.sh`: root is going to execute it, so only root may be able to change it;
2. installs the credentials file as `/etc/enclave/credentials.env`, root 600, and the token
   root 600;
3. installs and **enables** `enclave-harden.service` — and does not start it. cloud-init's
   `power_state` reboots the guest once after cloud-final (only if `first-boot` finished), and the
   unit starts at that boot, exactly as it resumed three times in slice 2.

**Why not start it straight away (found designing slice 3):** the unit is `WantedBy=
multi-user.target`, so it is ordered *before* `multi-user.target`, and cloud-final runs *after* it.
Starting the run from inside cloud-final races cloud-final's tail; ordering it `After=cloud-final`
is a dependency cycle. One extra reboot (~20 s) buys the proven path. As built, the runcmd is
`05-harden-host.sh first-boot /mnt/enclave-prov`, run from the read-only disk; a failure prints
`provision FAIL` / `HALTED` on the console and suppresses the reboot.

### 4.3 `enclave-harden.service`

A `oneshot` unit that runs `05-harden-host.sh run` in guest mode. Where 05 on a host says
"reboot, then run me again", on a guest it **reboots itself**; the unit is enabled, so it runs
again at the next boot and 05 resumes from its state file. Every step writes one line to the
serial console:

```
ENCLAVE-HARDEN pg-01 fips START
ENCLAVE-HARDEN pg-01 fips OK
```

— which lands in the host's `<pool>/console/<vm>-console.log`. **That log is the progress feed**;
nobody has to log in to watch it. It is 0644 on the host, so the runner prints step names and
results only — never a value from the credentials file or the token.

**The unit carries a `sudo` run's environment, because it continues one** (found 2026-09-27, live
run 2 on pg-01). systemd gives a root service no `HOME` and no `SUDO_USER`; the run got through
every hardening step and died at `evalstig` on `HOME: unbound variable`. `SUDO_USER` matters as
much: it is what hands the Evaluate-STIG evidence to the operator, so `collect` can pull it
unprivileged. The unit therefore sets `HOME=/root USER=root LOGNAME=root` and the operator who
handed the run over (`SUDO_USER/UID/GID`, captured from `sudo 05 run` or `resume`; every reboot
rewrites the unit from the unit's own environment, so it stays put). At first boot no `sudo` run
hands anything over, so the operator comes from `provision.env` on the provisioning disk — the VM
admin user compose created (slice 3).

### 4.4 Completion, and step 16a done by the machine itself

The last step deletes the credentials file and the token (runbook §6.0 step 16a — on a guest it
stops being a manual, forgettable step), writes `/etc/enclave/hardening-complete` with the USG and
Evaluate-STIG tallies, disables the unit, and prints:

```
ENCLAVE-HARDEN pg-01 DONE usg=<pass>/<fail>
```

`CredentialsFileLeftBehind` (3.35) still watches, for the case where something stopped first.

### 4.5 The host finishes the job — a new `03-compose-vm.sh finish <vm>`

On the host, once `DONE` appears in the serial log:

1. **detach and shred the provisioning disk and the cloud-init seed** — the seed has done its job;
   today it stays forever with the admin hash and keys on it. *(PG guests: the data disk moves
   `vdc`→`vdb` when the seed goes. `finish` refuses unless it is mounted by UUID or LABEL.)*
2. **the checks a machine cannot run on itself** — replaces 05's `[y/N]` prompt: SSH answers
   through ufw from outside the guest, time is synchronised to host-4, the guest resolves and is
   resolved by the enclave DNS;
3. prints the register line for its credentials file (placed / deleted, with times) — §9's
   custody record, filled by the machine.

**As built (2026-09-27): `sudo ./03-compose-vm.sh <vm> --finish [--no-reboot]`** (a flag like
`--destroy`, not a subcommand). It refuses unless the guest's **last** `ENCLAVE-HARDEN` line — read
from every rotated console log, oldest first — is `DONE`, and says whether that line reports the
credentials deleted. Checks from outside: ssh answers (`ssh-keyscan`); a port nothing opens to the
host is **dropped**, not refused (ufw default-deny, `FINISH_PROBE_PORT`); the enclave DNS answers
forward and reverse when asked directly with `dig`. **Time is not checked from outside** — no
guest is scraped and no clock-offset alert exists; every run says so (backlog 3.39). Then the seed
and provisioning disk are detached from the persistent config (verified gone from it before
anything is shredded) and shredded; failed checks do not stop this. By default a **cold** restart
(shutdown + start, so qemu drops the disks) proves the guest boots: ssh must answer again, no unit
may fail beyond `FINISH_EXPECTED_FAILED` (`vm-specs.env`: `sssd.service`, the CAC family), and
cloud-init must not fall back to no datasource. `-n` does the read and the checks only. Exit 1 if
any check failed. Progress lines now end ` @<UTC>` so the register can carry the deletion time.

### 4.6 When something fails

The unit stops, prints `ENCLAVE-HARDEN <vm> <step> FAIL` on the serial console, and leaves its
state. **Nothing retries forever.** A human then reaches the guest by SSH with a key, or by
`virsh console` and the break-glass account — the recovery path the build already provides.

## 5. What changes in `05-harden-host.sh` — extend it, do not fork it (D2)

One step list for hosts and guests, so a fix to a step reaches both. Host or guest is **derived**
from which address-file key the machine owns (`HOST_*` → host; `SVC_*`, `PG_*`, `K8S_*` → guest),
never typed.

| step | on a host (unchanged) | on a guest |
|---|---|---|
| preflight | count login sessions — a second session is the way back in | skip the session count; check the serial console is being logged — that is a guest's way back in |
| hostprep, patch, usg, baseline, usgfix, v1r6, verify, auditvolume, final_audit | as now | as now (hostprep verifies cloud-init's work instead of doing it — slice 1) |
| prechecks | preflight, then `proceed to usg fix? [y/N]` | **with a terminal:** the same prompt. **Unattended:** proceed only if preflight flagged nothing beyond `GUEST_PRECHECK_EXPECTED` (`vm-specs.env`; measured on pg-01: `package_timesyncd_removed`, decided by V-270645 + chrony) and every account losing NOPASSWD has a password (6.3a). A service-account NOPASSWD, an incomplete preflight or anything new **halts** for a person. Decided on preflight's machine-readable report (`PREFLIGHT_REPORT`), not its printed text |
| pro | token from `~/.pro-contract-token` | also accepts the root-600 token from 4.2 |
| fips, usgfix, v1r6 reboots | stop and tell the human | **reboot itself** and resume |
| tailor | ufw, time client, `[y/N]` off-box prompt | ufw **needs a rule table for this guest** (D5); time client as now; **no prompt** — `finish` checks from outside (4.5) |
| radio | disable what exists | run it — a VM should report none; that result is the evidence |
| grub | prep + set (hash from the credentials file) | same — and it matters more: the serial console is exactly where a password without `--unrestricted` would stop the boot |
| accounts | from the credentials file | same |
| evalstig | Answer File pushed from stage-01 | Answer File from the provisioning disk |
| done | — | delete credentials + token; write `hardening-complete`; disable the unit |

## 6. The Kubernetes nodes (D4)

Checked, not assumed: neither STIG disables forwarding, bridge netfilter or BPF (§2). What does
conflict:

1. **ufw.** The nodes need the API server, kubelet and CNI ports open between them. **Those numbers
   come from Canonical's Kubernetes documentation for the snap we pin (3.26) — fetched when B-07 is
   written, not guessed here.** A default-deny firewall hardened in before they are known would
   block the bootstrap.
2. **AIDE scope.** containerd and kubelet state churn constantly; like the apt mirror, they must be
   outside the AIDE database or every check reports thousands of changes.
3. **Audit volume.** Container churn raises audit traffic; `audit-volume.sh` sizes it before the
   collector disk is fixed.

**Recommendation:** harden the K8S guests completely in step 06 with a **minimal** rule table
(SSH and node-exporter — what every machine has), and let B-07 add the Kubernetes ports from the
verified list before it bootstraps. The firewall is never off; it is widened once, on evidence.

## 7. The PostgreSQL guests (06a)

The data disk must be mounted by UUID or LABEL before `finish` removes the seed (4.5) — the composer
already warns; `finish` enforces it. The WAL archive and the at-rest evidence (`lsblk -s` shows
`crypt` under both disks) stay as backlog B-06a and 6a.9 describe.

## 8. Built and tested in four slices — one new thing at a time

Testing all of this at once would be miserable, and a failure would not say which part broke. So
it is built in four slices, **each tested on the same throwaway guest (lab profile), each with a
pass/fail you can see, each useful on its own** — stopping after any slice leaves the enclave
better than before it.

| slice | what gets built | what you test | pass looks like | needs |
|---|---|---|---|---|
| **1** | 05 learns **"I am on a guest"**: the guard accepts `SVC_*`/`PG_*`/`K8S_*` (role derived, never typed), preflight skips the session count, the token and passwords are read the guest way | Compose one throwaway guest; SSH in; run `sudo 05-harden-host.sh run` **by hand**, exactly as on host-3 | It reaches the end; USG lands where the other guests did (209–212 pass) | D2, D3 |
| **2** | On a guest, 05 **reboots itself** at the three reboot points and **resumes** from its state file | Rebuild the guest; start 05 once | All three reboots pass with nobody touching it; the state file shows every step once | D7 |
| **3** | The **provisioning disk** and **`enclave-harden.service`** — the guest hardens itself from first boot | Compose the guest and do not log in | The serial log shows every `ENCLAVE-HARDEN ... OK` and a `DONE` line; the credentials file is gone from the guest | D1, D5 (a table for the test guest) |
| **4** | **`03-compose-vm.sh finish`** — shred seed + provisioning disk, the outside checks, the register line | Run `finish` on the host | Both disks gone; SSH still answers through ufw; time and DNS checked from outside | D6 |

**Slice 1 alone closes B-06's actual gap** — *nothing can harden a guest* — and costs you the
least, because it is the procedure you already use on the hosts. Slices 2–4 are what make it
unattended for the from-scratch build (2.6); they wait until slice 1 has shown the steps behave on
a guest.

**After the four slices:** pg-01..03 (06a, with their ufw tables), then the K8S guests once B-07
has its verified port list (D4), then in 2.6 the four service VMs through the same path onto their
mapped hosts (D8).

## 9. Decisions for review

**Decided 2026-09-26 by the acting AO:** **D1** — the guest hardens itself (all four slices are built);
**D2** — extend 05; **D3** — the host's own token copy; **slice-1 test guest: pg-01 on host-1**
(in the address file and the map, lab-sized; destroyed and recomposed for real after the slices).
D4–D8 are asked when their slice comes up.

**Decided 2026-09-27 for slice 3:** hardening is triggered by **`--harden`** (a plain compose is
unchanged; the 2.6 build passes the flag) · **D5 built now**, for every machine, not only guests
(`stig-tailor.sh ufw` refuses a table port missing from `ppsm-services.tsv`; all 36 existing rows
pass) · the slice-3 test uses a **throwaway credentials file copied to host-1**, not the stick (the
stick path is exercised in 2.6).

**Decided 2026-09-27 for slice 4:** **D6** — `finish` shreds **both** the seed and the provisioning
disk · it **cold-restarts the guest by default** to prove it boots without them (`--no-reboot`
skips it) · time sync is **not** faked from inside: `finish` says it is unchecked, and backlog 3.39
builds the real check (guests scraped + a clock-offset alert for every machine).

| # | Decision | Recommendation | Why |
|---|---|---|---|
| **D1** | Who runs guest hardening | **C — the guest hardens itself from first boot** | Only option that is unattended; a guest reboot needs no console |
| **D2** | Extend `05-harden-host.sh` or write a separate guest script | **Extend 05**, role derived from the address file | One step list: a fix reaches hosts and guests at once |
| **D3** | How the Pro token reaches a guest | **The host's own token** (it already holds one for its own attach) is copied onto the guest's provisioning disk | No new copy on removable media; the alternative is a per-machine token file on the credentials stick |
| **D4** | K8S firewall ports | **Minimal table in 06; B-07 adds the verified Kubernetes ports** | Ports are facts to fetch for the pinned snap, not to guess now |
| **D5** | Where guest ufw tables come from | **Written in `stig-tailor.sh`'s existing table format** (as the other eight are), **plus a check that every port a table opens is registered in `ppsm-services.tsv`** | The PPSM file describes *what each port is*, not which machine runs it (machines appear only in free-text descriptions), so it cannot generate the tables. The check keeps the firewall and the CLSA (6a.22) from disagreeing silently |
| **D6** | Retire the seed and provisioning disk after hardening | **Yes — `finish` detaches and shreds both** | Today the seed holds the admin hash and keys for the guest's whole life |
| **D7** | Failure policy | **Stop, report on the serial console, leave state; no automatic retry** | A retry loop on a half-hardened machine hides the failure that matters |
| **D8** | The four service VMs in 2.6 | **Rebuilt through this same path, onto their mapped hosts** | Otherwise the from-scratch build proves ten guests and hand-builds four |

## 10. Risks, stated plainly

- **The first unattended `usg fix`.** Runbook §6.3a: `usg fix` once locked every composed VM's
  console. The cloud-init admin hash (built in since) is what prevents that — but no one will be
  watching this run, which is why the first one is on a disposable guest.
- **The serial log becomes load-bearing.** It is the progress channel and the evidence that a guest
  finished; its location and permissions on the host become part of the design, not a debugging aid.
  **Found in slice 3's first live run (2026-09-27):** `virtlogd` rotates a console log at 2 MB
  (`max_size`, 3 backups) and creates the new file **0600 root** — the 0644 compose sets survives
  only until the first rotation. With `log.append=on` a guest's log grows across every recompose,
  so pg-01's rotated 16 s after `provision START` and the run straddled two files. A reader
  therefore needs root **and** `<vm>-console.log*`, oldest first (compose's hint now says so);
  slice 4's `finish` runs as root and must read the rotated files too, never the live one alone.
- **A hardening boot finishes late** (observed slice 3): the unit is ordered before
  `multi-user.target`, so a boot that runs verify → evalstig reaches it ~7 minutes in, and
  cloud-final waits with it (`ready after 413.79 seconds`). ssh and the serial getty are not
  ordered behind it, so the way in is unaffected; anything that waits for "boot finished" is.
- **Capacity.** The lab profile has to fit ten guests plus the service VMs within ~29–30 GB per
  host; that is 2.7's planner's job to confirm before anything is composed.
- **The token on the hosts.** D3 uses the token each host already keeps from its own hardening. That
  standing copy exists today regardless; D3 does not create it, but it does start depending on it.
