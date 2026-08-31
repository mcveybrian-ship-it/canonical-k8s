# STAGE-01 — build plan

## 0. WHAT IS LEFT — read this first, do not reconstruct it

**This section is the single home for STAGE-01's remaining work.** The tables in §4–§7 record
*how* things were built and why; they have gone stale more than once. If they disagree with
this section, this section wins and the other one gets fixed.

Last updated **2026-08-31 02:45**.

**Two items left. Everything else on this machine is done.**

| # | What | State |
|---|---|---|
| 1 | **nginx vhost + prove the mirror resolves** | **DONE 2026-08-31.** All 9 suites, all 5 archives, `apt-get update` GPG-verified exit 0, one marker package pulled from each archive. `airgap-update-lab.md` §6.5 |
| 2 | **Generate `airgapped-contracts.yaml`** | **NOT STARTED — now the blocker.** `pro-airgapped` must emit it with `aptURL`s rewritten to MIRROR-01. Without it the enclave can pull packages but has nothing to `pro attach` against |
| 3 | **Build the three transfer scripts** | **PLANNED, not written.** `docs/airgap-media.md` §6. Awaiting two answers: ext4 vs NTFS, and whether a physical BUILD-BOX exists |
| 4 | **Decision 6 — writing physical media from a VM** | **RESOLVED IN PRINCIPLE 2026-08-31.** STAGE-01 never writes media; it produces a bundle and a physical box writes the SSD. Seed sticks stay a Windows job (§7 decision 4). Full plan in `docs/airgap-media.md` §6 |

**THE MIRROR IS COMPLETE — 2026-08-31 02:25. 317 GB, 90,681 packages.**

| Archive | Size | Packages | Note |
|---|---|---|---|
| `archive.ubuntu.com` | 247 G | 85,779 | noble, -updates, -security; main+universe, amd64 |
| `esm/fips-updates` | 68 G | 3,836 | incl. **353 FIPS kernel images** |
| `esm/apps` | 2.4 G | 1,059 | |
| `esm/usg` | 3.3 M | 3 | `usg`, `usg-benchmarks`, `usg-benchmarks-1` |
| `esm/infra` | 408 K | 4 | Thin by design on a young LTS — see §0.4 |

Also done: Pro attached (Infra weekday tier); all three air-gap tools installed
(`contracts-airgapped`, `get-resource-tokens`, `pro-airgapped`); four signing keys staged in
`/srv/apt-mirror/keys/` — `ubuntu-pro-esm-infra.gpg`, `ubuntu-pro-esm-apps.gpg`,
`ubuntu-pro-fips.gpg`, `ubuntu-pro-cis.gpg`.

Everything from earlier still stands: VM provisioned, dev toolchain 10/10, Stage-B tooling,
repo cloned, private material transferred, push access + ssh-agent (§4.6), pre-push guard
fired against the live remote, Windows-only material retired, step 00 media downloaded.

### 0.3 Three `.deb`s the mirror can never serve — carry them separately

`contracts-airgapped` and `pro-airgapped` must be **installed on MIRROR-01, inside the gap**,
but they live in `ppa:yellow/ua-airgapped`, which is not in `mirror.list` and cannot be —
MIRROR-01 has no route to Launchpad. **The contracts server cannot be installed from the
mirror it exists to authenticate.**

```bash
sudo install -d -o apt-mirror -g apt-mirror /srv/apt-mirror/debs
cd /srv/apt-mirror/debs
sudo -u apt-mirror apt download contracts-airgapped pro-airgapped get-resource-tokens
```

### 0.4 Two verification traps found on 2026-08-31 — do not repeat them

**1. Checking `dists/.../Release` does not prove a token works.** Release metadata is served
more permissively than package content. The `esm-infra` token authenticated against Release
(200) and was then **rejected on every pool file** (401). The whole archive looked healthy
and downloaded zero packages. **Always verify against a real `pool/` file taken from that
archive's own `Packages` index**, not against Release.

**2. wget's first 401 is normal — read the second one.** The success and failure paths start
identically:

```
apps :  401 -> Authentication selected: Basic realm="APT mirror" -> 200 OK          OK
infra:  401 -> Authentication selected: Basic realm="APT mirror" -> 401 Unauthorized
        Username/Password Authentication Failed.                                    FAILED
```

Grepping for `401` finds both. Grep for **`Authentication Failed`** instead.

**Cause:** the contract exposes twelve resource names (`cc-eal`, `esm-apps`, `esm-infra`,
`fips`, `fips-preview`, `fips-updates`, `landscape`, `livepatch`, `realtime-kernel`, `ros`,
`ros-updates`, `usg`) and the wrong one was pasted onto the infra lines. Fixed by
re-substituting the value printed under `esm-infra:`; all four packages then downloaded.

**Also note the naming traps:** the token for `usg` is printed under **`cis`** — `usg` is an
alias of the `cis` entitlement. And the STIG package is **`usg`**, not `ubuntu-security-guide`
(that is the 20.04-era name, which is why `apt-cache madison ubuntu-security-guide` kept
returning nothing).

**Done and verified**, so nobody re-opens them:

- VM provisioned; dev toolchain 10/10; Stage-B tooling (`regctl`, `regsync`, `store-admin`,
  `snapd`, `qemu-utils`); repo cloned; private material transferred
- Push access to `origin` + ssh-agent (§4.6); **pre-push guard fired against the live remote**,
  4 tests — see `docs/open-questions.md`
- Windows-only material retired (§6 step 6); step 00 media downloaded
- **Ubuntu Pro attached 2026-08-31** — *Ubuntu Pro + Infra Support (weekday)*, account
  "Mcvey Consulting", valid to 2027-08-30. `esm-apps`, `esm-infra`, `livepatch` enabled;
  `fips-updates`, `usg`, `landscape` entitled and deliberately left disabled (§0.2)
- **Archive mirror COMPLETE 2026-08-31 00:19** — 21:25:45 → 00:19:18, 2 h 53 m. **247 GB,
  85,779 `.deb` files — exactly the count apt-mirror predicted.** Zero-byte files: 0. No wget
  failures. Suites `noble`, `noble-security`, `noble-updates`. 738 GB free

### 0.2 Do not enable `fips-updates` or `usg` on STAGE-01

Both are entitled and both must stay **disabled here**. STAGE-01 is the staging box, not an
enclave host. Enabling `fips-updates` moves it onto the FIPS kernel (the pathfinder went
`7.0.0-30-generic` HWE → `6.8.0-138-fips`) for no benefit, and would put a FIPS-mode SSH
restriction on the machine that holds the git deploy key.

**The packages still reach the enclave** — they are *mirrored*, not installed. Mirroring
requires only the bearer token in `mirror.list`, never enabling the service locally.

### 0.1 What the paid Pro token actually unblocks

Worth being precise, because "blocked on Q9" was previously applied far too broadly and cost
a day on the mirror.

| Needs the paid token | Does **not** need it |
|---|---|
| `pro attach` on STAGE-01 | The 245 GiB archive mirror — anonymous |
| `get-resource-tokens` → the esm-infra / esm-apps bearer tokens | nginx serving that mirror |
| The four ESM lines in `mirror.list` (single-digit GB) | Everything in items 2 and 3 above |
| `pro-airgapped` → the airgapped contracts-server config | |
| The Support Portal KB article describing the air-gapped Pro procedure | |

**What to buy for the mirror: ONE paid Ubuntu Pro subscription, on STAGE-01, at the Infra
tier or above.** One machine — not three.

`airgap-update-lab.md` §2 is the authority on which machine holds what, and it has been
settled since the lab was designed:

| Machine | Where | Role | Subscription |
|---|---|---|---|
| **STAGE-01** | Online, **outside** the gap | Builds and syncs the mirror; holds the token | **PAID full Pro** |
| MIRROR-01 | **Inside** the gap | nginx :80 (repo) + `contracts-airgapped` :8484 | Free tier |
| CLIENT-01/02 | Inside the gap | Patch from MIRROR-01 | Free tier |

**STAGE-01 is not the mirror.** It is the staging box that *fetches the packages the mirror is
made of*, then hands them across the gap on removable media. The serving mirror is MIRROR-01,
inside the enclave, and it needs no paid token — clients attach to its local contracts server,
which serves entitlements derived from STAGE-01's paid token.

**Which tier — established 2026-08-30 from Canonical's own pages.**

| Tier | List | Buys the air-gapped procedure? |
|---|---|---|
| Ubuntu Pro, self-support | $500/yr | **No.** Entitlement only. *"No enterprise support included"*, no Knowledge Base |
| **Pro + 24/7 Infra** | **$1,775/yr** | **Yes — the minimum that works** |
| Pro + 24/7 Full | $3,400/yr | Yes, plus break-fix on ~36,000 Universe packages |
| Weekday variants | 50% of the 24/7 rate | Infra weekday ≈ **$887.50/yr** |

The tier matters for a reason unrelated to the token — every paid tier carries the
entitlement. It is that the procedure is **KB-only**: Canonical's airgapped page says
*"Customers with a paid subscription to Ubuntu Pro can set up the included services in
environments with limited or no network connectivity"*, then points at a Knowledge Base
article, *Get Started with Ubuntu Pro in an Airgapped Environment*, and states Support Portal
/ Knowledge Base access is required to follow it. At $500 you own the entitlement and cannot
read the instructions for using it.

**So the mirror costs $887.50–$1,775/yr, one subscription.**

> **Do not confuse this with the production cluster's licensing.** The three enclave hosts
> need their own Pro coverage — that is a BOM/TCO line item, driven by
> `HANDOFF.md` §3, and it is **not** what makes the mirror work. `airgap-update-lab.md` §1
> also warns that one paid sub feeding otherwise-unlicensed production servers through a
> mirror violates Canonical's service description: the free-tier rows above are lab and
> evaluation only.

Sources: <https://ubuntu.com/pro/docs/airgapped-setup/> · <https://ubuntu.com/pricing/pro>
(both re-fetched 2026-08-30; pricing unchanged from 2026-08-27) · `airgap-update-lab.md` §1–3.

**The consequence if Q9 never lands:** the enclave gets `noble`, `-updates` and `-security`
from the mirror above, which on a young LTS is where nearly all patches come from today. What
it does **not** get is ESM/Pro content, FIPS packages or USG STIG tooling — and those are the
OS decision. So Q9 is not optional; it just is not blocking the work in flight.

---

**Status as of 2026-08-30: BUILT AND USABLE. Everything not gated on Q9 is done.**

| | |
|---|---|
| VM provisioned | **Done** 2026-08-29 — `10.0.20.160`, 8 vCPU / 16 GB, 989 G free |
| SSH key auth from Windows | **Done** 2026-08-30 — was broken, see §4.5 |
| Dev toolchain (§4.4) | **Done** — all ten present |
| Mirror + Stage-B tooling | **Done** — `nginx`, `snapd`, `qemu-utils`, `apt-mirror`, `regctl`, `regsync`, `store-admin` |
| This repo cloned on it | **Done** 2026-08-30 |
| Push access to `origin` | **Done** 2026-08-30 — deploy key registered, agent set up (§4.6) |
| Pre-push guard fired against the live remote | **Done** 2026-08-30 — four tests, `docs/open-questions.md` |
| Client-private material | **Done** — transferred with `scripts/private-sync.sh`, verified gitignored |
| **Repo ownership** | **STAGE-01 is authoritative from 2026-08-30.** See §7 decision 7 |
| Retire the Windows-only scripts and doc blocks | **Not started** — §6 step 6 |
| **Archive mirror (200-250 GB, no token needed)** | **NOT STARTED** — §6 step 8a. `mirror.list` was still the stock 2022 `kinetic` default until 2026-08-30. **This is the long pole and nothing blocks it** |
| Pro token, ESM pockets, contracts server | **Blocked on Q9** — §6 steps 7, 8b |
| nginx mirror vhost | **NOT STARTED** — §6 step 9. nginx runs, but serves only the stock default site |

§6 carries per-step status and the audit command that produced this table. §8 records the four
gotchas found building it - do not re-derive them.

STAGE-01 is the online staging machine from
[`airgap-update-lab.md`](airgap-update-lab.md). This plan gives it a second job:
**it also becomes the sole development workstation for this project.**

That consolidation is the point. Every problem in the 2026-08-29 session came from the
Windows/Ubuntu boundary — UTF-8 BOM breaking PowerShell, TLS 1.0 defaults, no `gpg`, no
`mkpasswd`, WSL and Windows holding separate `~/.ssh` directories. Doing the work on Ubuntu
removes that entire class of failure, and STAGE-01 has to exist anyway.

---

## 1. What STAGE-01 does

| Role | Why it lands here |
|---|---|
| **Ubuntu Pro mirror builder** | Holds the paid Pro token, runs `apt-mirror`, generates the air-gapped contracts config. Per `airgap-update-lab.md` §5–6 |
| **Stage B bundle staging** | Snaps, container images, Harbor installer, MAAS boot images — everything that crosses into the enclave |
| **Sole dev workstation** | Native `gpg`, `mkpasswd`, `mkfs.vfat`, `dd`, LF line endings, one SSH key store |
| **Seed-stick writer** | Runs `02-build-seed.sh` directly — no PowerShell path needed |

## 2. How it gets built

**[`schtritoff/hyperv-vm-provisioning`](https://github.com/schtritoff/hyperv-vm-provisioning)**
— `New-HyperVCloudImageVM.ps1`. Provisions an Ubuntu cloud image as a Hyper-V VM and seeds it
with cloud-init, which is the same NoCloud mechanism step 02 already uses.

The exact command, sized for this host, is in section 4.2.

**Use `24.04`, not `24.04-azure`.** The Azure images default to `DataSourceAzure`, which the
script has to convert to NoCloud — that path needs WSL and Windows 11 build 22000+. The plain
image avoids the whole detour.

Known from the project's README: default credentials are `admin` / `Passw0rd` unless a custom
`userdata.yaml` is supplied, and a VHD under 40 GB is not recommended for recent Ubuntu. We
supply our own userdata, so the defaults never apply.

### Prerequisites on the Hyper-V host

**Windows Server 2022 — this host.** Hyper-V is a *Role*, installed with
`Install-WindowsFeature`. The `Enable-WindowsOptionalFeature` commands in schtritoff's README
are the Windows 10/11 *client* names and fail on Server with
`Feature name Microsoft-Hyper-V-Tools-All is unknown`.

```powershell
Get-WindowsFeature -Name Hyper-V*                                   # check first
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart
```

If Hyper-V Manager already runs, the role is installed and there is nothing to do.

**Windows 10/11 client**, for reference:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

## 3. GUI — recommendation: none

**VS Code does not need a GUI on the server.** VS Code runs on your Windows box and connects
over SSH with the **Remote-SSH** extension: the editor, terminal, extensions and debugger all
execute on STAGE-01, the window renders on Windows. It installs its own server component on
first connect. Nothing to configure on the Ubuntu side beyond sshd, which we already have.

Reasons to keep it headless:

- A desktop adds ~1.5 GB and a large monthly patch surface to a machine whose job is patching
- Every GUI package is another thing in the mirror and another CVE stream
- On the production analogue, a desktop on a server is a STIG finding

**If you want a local GUI anyway**, the lightest thing that works well is XFCE over RDP:

```bash
sudo apt install xubuntu-desktop-minimal xrdp
```

XFCE over GNOME because GNOME's compositing is miserable over RDP. Recommend deciding this
*after* trying Remote-SSH — in practice it removes the need.

## 4. Inventory

### 4.1 Hyper-V host — CONFIRMED 2026-08-29

| | |
|---|---|
| Machine | Dell PowerEdge R7515 |
| OS | Windows Server 2022 Datacenter, Hyper-V Manager 10.0.20348.1 |
| CPU | AMD EPYC 7282 |
| RAM | 127.6 GB |
| Disk | 12,888 GB total |

Comfortably over-specified for this job. Two consequences:

**The `-azure` images are off the table, and that is fine.** Converting an Azure-branded image
to NoCloud needs Windows 11 build 22000 or later. **Server 2022 is build 20348**, so that path
does not exist here. Use `-ImageVersion "24.04"` — which was the recommendation anyway, since
the plain image needs no conversion and no WSL.

**Resources are effectively free.** The VM spec below is sized against this host, not against a
laptop.

### 4.2 VM spec — revised for this host

| | Value | Why |
|---|---|---|
| vCPU | **8** | `apt-mirror` runs 20 threads; container-image work is parallel. The host has an EPYC 7282 — 4 was a laptop-sized guess |
| RAM | **16 GB** | Out of 127.6 GB. Costs nothing and keeps mirroring plus a VS Code server comfortable |
| Disk | **1 TB, single VHDX** | Out of 12.9 TB. See §4.3 — 500 GB works, 1 TB means never revisiting it |
| Generation | 2 | UEFI, matches the production hosts |
| Network | Static IP or reserved DHCP | It becomes a fixed dev target |

**Single disk, specified at provisioning time** via `-VHDSizeBytes`. The script takes one disk;
a separate data VHDX would have to be added afterwards in Hyper-V. On a host with 12.9 TB the
separation buys nothing, so keep it simple.

```powershell
.\New-HyperVCloudImageVM.ps1 `
  -VMName "STAGE-01" `
  -ImageVersion "24.04" `
  -VMGeneration 2 `
  -VMProcessorCount 8 `
  -VMMemoryStartupBytes 16GB `
  -VHDSizeBytes 1TB `
  -ShowSerialConsoleWindow `
  -KeyboardLayout en
```

### 4.3 Storage budget

| | Size | Source |
|---|---|---|
| OS and tooling | ~20 GB | |
| apt mirror — noble main+universe, amd64, binaries only | 200-250 GB | `airgap-update-lab.md` §4 |
| ESM pockets | single-digit GB today | same |
| Container images for Harbor | **TBD** | **Q6 — unanswered** |
| Snaps, ISOs, cloud images | ~7 GB | |
| **Realistic total today** | **~300 GB** | |
| **Recommended allocation** | **1 TB** | Absorbs whatever Q6 turns out to be, without a resize |

500 GB is genuinely sufficient for what is known today. 1 TB is 8% of this host's disk and
removes the question permanently — the unknown is container images, and that number could be
large.

### 4.4 Software

**Mirror role** — per `airgap-update-lab.md` §5:
```
apt-mirror  nginx  contracts-airgapped  get-resource-tokens   (ppa:yellow/ua-airgapped)
```

**Dev role** — what this repo's scripts actually need:
```
git  python3  python3-yaml  shellcheck  gnupg  whois  dosfstools  rsync  curl  jq
```
- `gnupg` — closes the deferred GPG signature check from step 00
- `whois` — provides `mkpasswd` for the password hash
- `dosfstools` — `mkfs.vfat` for seed sticks
- `python3-yaml` — the autoinstall validation
- `shellcheck` — lint the `.sh` scripts

**Stage B bundle role** — for steps 04–08:
```
snapd  store-admin(snap)  regclient (regctl/regsync)  qemu-utils
```

`store-admin` and `regclient` are not `apt` packages. Both installed 2026-08-30; commands
verified against the vendor docs cited in §9 that day, not from memory:

```bash
# Enterprise Store admin tooling - Canonical snap
sudo snap install store-admin

# regclient - static binaries. Do NOT use the "go install" line in runbook 4.3:
# it needs a Go toolchain, which is deliberately not on this machine.
sudo curl -L -o /usr/local/bin/regctl  https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64
sudo curl -L -o /usr/local/bin/regsync https://github.com/regclient/regclient/releases/latest/download/regsync-linux-amd64
sudo chmod 755 /usr/local/bin/regctl /usr/local/bin/regsync
```

**Naming:** the product formerly called *Snap Store Proxy* is now the **Enterprise Store**.
The snap is still `store-admin`. `runbook.md` §4.4 uses the current name;
`airgap-update-lab.md` still says Snap Store Proxy in one place and needs updating.

**Not installed:** any desktop environment. See §3. No Go toolchain either - the two binaries
above are fetched, not built.

### 4.5 Credentials and access

| | Status |
|---|---|
| **Paid Ubuntu Pro token** | **BLOCKING.** This is open question 9 — it unlocks the air-gapped tooling entitlement and the Support Portal KB article. Without it STAGE-01 cannot do its main job |
| **SSH key auth from Windows** | **FIXED 2026-08-30.** Two different keys both named `enclave_admin` had existed - Windows `%USERPROFILE%\.ssh` and WSL `~/.ssh` held different keys and STAGE-01 accepted neither. `~/.ssh/authorized_keys` now holds `SHA256:4Z7+69CE5dAX6YZIs4G5ivEzLDm3dAwB51rGAxum/Rc` (`enclave-admin`, RSA 4096) - the Windows one. Remote-SSH works |
| SSH keypair | Generate on STAGE-01 for reaching the enclave hosts; add the pathfinder's key to it |
| **Git push access to origin** | **WORKING 2026-08-30.** Deploy key `~/.ssh/github_stage01` (`SHA256:yiOpB1BJ2AbWd49ckl7UdbQwUzfbOjcHJ8x+Sr9cGWE`, RSA 4096, read/write) registered on the repo. The key is **passphrase-protected**, so it needs an agent - see §4.6. Repo cloned 2026-08-30 |
| ESM resource tokens | Derived from the paid token via `get-resource-tokens` |

### 4.6 SSH agent for the git deploy key - set up 2026-08-30

The deploy key is passphrase-protected (`aes256-ctr`/`bcrypt`), so `git` cannot sign with it
unless an agent holds it unlocked. Headless, there is no desktop session to start one.

**The failure mode is misleading.** With no agent, `ssh -T git@github.com` reports
`Permission denied (publickey)` - which reads as "the key is not registered". It is not that.
`ssh -vv` shows the truth:

```
debug1: Server accepts key: ... RSA SHA256:yiOpB1BJ2AbWd49ckl7UdbQwUzfbOjcHJ8x+Sr9cGWE
git@github.com: Permission denied (publickey).
```

GitHub **accepted** the public key and asked for a signature; ssh could not produce one
because the private key was locked and nothing could prompt. Check `ssh-add -l` before
re-issuing a key.

Ubuntu ships `/usr/lib/systemd/user/ssh-agent.service` but it carries
`ConditionPathExists=/etc/X11/Xsession.options` and orders itself before
`graphical-session-pre.target` - it will not start on a headless box. A local unit replaces it:

```ini
# ~/.config/systemd/user/ssh-agent.service
[Unit]
Description=SSH agent for STAGE-01 development (git deploy key)

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a %t/ssh-agent.socket

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now ssh-agent.service
# and in ~/.bashrc:
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"
```

**Lingering is deliberately off** (`loginctl show-user encadmin -p Linger` -> `Linger=no`), so
the agent dies at logout and the key must be re-added after a reboot:

```bash
ssh-add ~/.ssh/github_stage01
```

That is the intended trade: this box will hold the paid Pro token, and an unlocked
write-capable key surviving logout indefinitely is not the posture we want on it.

## 5. Files in this folder

| File | What |
|---|---|
| `README.md` | This plan |
| `airgap-update-lab.md` | The four-machine lab runbook that defines STAGE-01's mirror role |
| `stage-01-userdata.yaml` | cloud-init template. The SSH key and password hash are substituted at build time |
| `Build-Stage01.ps1` | Wrapper around schtritoff's script. Runs on the Hyper-V host, not on STAGE-01 |

```powershell
.\Build-Stage01.ps1 `
  -ProvisioningScript C:\src\hyperv-vm-provisioning\New-HyperVCloudImageVM.ps1 `
  -SshPubKeyFile $env:USERPROFILE\.ssh\enclave_admin.pub `
  -PasswordHash '<the $6$ hash>' `
  -NetAddress 10.0.20.160 -NetGateway 10.0.20.1 `
  -DryRun
```

Drop `-DryRun` to build. The rendered user-data contains the password hash, so it is written to
a temp file and removed in a `finally` block.

The wrapper refuses an Ed25519 key and a malformed password hash before it touches Hyper-V -
same guards as the enclave seed builder, for the same reason.

## 6. Build sequence — status 2026-08-30

1. ~~Confirm the Hyper-V host and disk budget~~ — **done**, R7515
2. ~~Clone `schtritoff/hyperv-vm-provisioning` on the host~~ — **done**
3. ~~Write a `userdata.yaml` for STAGE-01~~ — **done**, own user and keys, no default `admin`/`Passw0rd`
4. ~~Provision the VM~~ — **done 2026-08-29.** `10.0.20.160`, single 1 TB VHDX, 989 G free
5. ~~Install the dev toolchain (§4.4), clone this repo, verify the scripts run~~ — **done
   2026-08-30.** All ten dev packages; `nginx`, `snapd`, `qemu-utils`, `apt-mirror`, `regctl`,
   `regsync`, `store-admin`; repo cloned; private material restored via
   `scripts/private-sync.sh`
6. ~~**Switch development to STAGE-01**~~ — **done 2026-08-30.** See §7 decision 7.
   `00-fetch-verify-media.ps1` deleted; `docs/00-downloads.md` now routes step 00 to STAGE-01
   and keeps the Windows procedure as a clearly-marked manual fallback with no script behind
   it. `02-build-seed.ps1` stays, and its PowerShell blocks in `01-pathfinder.md` /
   `02-host-install.md` stay with it (§7 decision 4)
7. Attach the paid Pro token, install `contracts-airgapped` / `get-resource-tokens` from
   `ppa:yellow/ua-airgapped` — **blocked, Q9.** The PPA is not added and neither package is
   installed
8. First `apt-mirror` run. **Splits in two — see `airgap-update-lab.md` §6:**
   - **8a. archive.ubuntu.com, 200-250 GB — NOT blocked.** Anonymous and free, no token.
     Hours; leave it overnight. **This is the long pole of the whole build**
   - **8b. ESM pockets, single-digit GB — blocked, Q9.** Needs resource tokens. Appended to
     the same `mirror.list` later; the archive content already on disk is not re-fetched
9. Prove the mirror locally with nginx before anything crosses the gap — **not blocked for
   8a.** nginx is running but has only the stock default site; the mirror vhost is unwritten

**Corrected 2026-08-30.** Steps 8 and 9 were previously marked "blocked, Q9" wholesale. That
was wrong and it cost time — the free archive half is the multi-hour item and could have been
running all along. **Only step 7 and step 8b are gated on Q9.**

### Audit STAGE-01's state

Run this on the box rather than trusting this table; it is what produced the status above.

```bash
printf '\n=== identity ===\n'; hostnamectl --static; ip -4 -br addr show scope global
printf '\n=== disk ===\n'; df -h / | tail -1

printf '\n=== dev toolchain (4.4) ===\n'
for p in git python3 python3-yaml shellcheck gnupg whois dosfstools rsync curl jq; do
  dpkg -s "$p" >/dev/null 2>&1 && echo "  ok       $p" || echo "  MISSING  $p"
done

printf '\n=== mirror role ===\n'
for p in apt-mirror nginx contracts-airgapped get-resource-tokens; do
  dpkg -s "$p" >/dev/null 2>&1 && echo "  ok       $p" || echo "  MISSING  $p"
done

printf '\n=== stage-B bundle role ===\n'
for p in snapd qemu-utils; do
  dpkg -s "$p" >/dev/null 2>&1 && echo "  ok       $p" || echo "  MISSING  $p"
done
command -v regctl >/dev/null && echo "  ok       regctl" || echo "  MISSING  regctl"
snap list store-admin >/dev/null 2>&1 && echo "  ok       store-admin" || echo "  MISSING  store-admin"

printf '\n=== repo clone ===\n'; ls -d ~/canonical-k8s 2>/dev/null || echo "  NOT CLONED"
printf '\n=== ubuntu pro ===\n'; pro status 2>&1 | head -6
printf '\n=== keys that can log in ===\n'; ssh-keygen -lf ~/.ssh/authorized_keys 2>/dev/null
```

## 7. Decisions

**Answered 2026-08-29:**

1. ~~Which Hyper-V host~~ — Dell R7515, Server 2022, 127.6 GB RAM, 12.9 TB disk. Ample.
2. ~~GUI~~ — **headless confirmed.** VS Code Remote-SSH from Windows.
3. ~~Data disk size~~ — specified at provisioning via `-VHDSizeBytes`. **Recommend 1 TB** over
   the 500 GB originally planned; see §4.3.

**Answered 2026-08-29, with a caveat:**

4. **Retire the PowerShell scripts — yes, but not all of them.** `00-fetch-verify-media.ps1`
   goes; STAGE-01 downloads and verifies natively with `gpg` and `sha256sum`.
   **`02-build-seed.ps1` should stay.** STAGE-01 is a VM, and Hyper-V has no casual USB
   passthrough — writing a physical seed stick from a Linux guest means offlining the disk on
   the host and attaching it as a physical disk, per stick. Writing USB media is inherently a
   physical-host job. Keeping one dual-platform script is cheaper than the alternative.
5. **`airgap-update-lab.md` moved here** from `artifact/`, which now holds only the published
   bake-off document and its build script.

**Still open:**

6. ~~**How does media get written once development moves to STAGE-01?**~~ **RESOLVED IN
   PRINCIPLE 2026-08-31.** Neither of the two awkward options was needed. **STAGE-01 never
   writes physical media** — it produces a transfer bundle, and a separate physical box writes
   the disk. That removes the Hyper-V USB-passthrough problem entirely instead of working
   around it, and it splits the question into two unrelated ones: a 320 GB ext4 SSD for the
   mirror (written from Ubuntu) and ~120 MB FAT32 seed sticks (still Windows, per decision 4).
   Full plan, measured numbers and the three scripts: `docs/airgap-media.md` §6.
   **Still to answer:** ext4 vs NTFS on the SSD, and whether a physical BUILD-BOX exists.

**Answered 2026-08-30:**

7. **Which machine owns the repo and the client-private material — STAGE-01.** The five private
   paths are gitignored, so git cannot sync them and two copies diverge silently. STAGE-01 is
   authoritative from 2026-08-30; the Windows working copy is a backup and a seed-stick writer
   only. Everything that pushed this way is a Windows-boundary artifact: CRLF breaking a
   shebang, the UTF-8 BOM rule for `.ps1`, TLS 1.2 defaults, no native `gpg` or `mkpasswd`, and
   WSL and Windows holding separate `~/.ssh` - which is what broke key auth to this very box.
   Transfer between them is `scripts/private-sync.sh`, never git.

## 8. Gotchas found building this, 2026-08-29

Four things cost an evening. All are now handled by `Build-Stage01.ps1`, but they are the
reason it exists rather than typing the provisioning script's parameters directly.

**1. `ExpandString()` destroys your password hash.** The provisioning script runs your
user-data through PowerShell variable expansion:

```powershell
$userdata = $ExecutionContext.InvokeCommand.ExpandString( Get-Content $CustomUserDataYamlFile -Raw )
```

A SHA-512 hash `$6$salt$hash` is read as the variables `$6`, `$salt`, `$hash` and expands to
nothing. Observed: `$6$XLerqFqY9bun.IVK$rtiub...` arrived as `.IVK`. The account is created
with a garbage password and no error is raised anywhere. Cloud-init tokens like `$UPTIME` go
the same way. The wrapper escapes backticks then dollars before writing the temp file.

**2. `-NetAddress` must be CIDR; `-NetNetmask` is ignored for netplan.** The script drops
`$NetAddress` verbatim into the netplan v2 `addresses:` list and never uses `$NetNetmask` for
v2 - that parameter only applies to the older v1 format. A bare `10.0.20.160` produces invalid
netplan, the interface never comes up, and the VM boots with no network. The wrapper derives
the prefix from the netmask when one is missing.

**3. Copying scripts between machines blocks them.** Files that arrive over the network carry
a Mark-of-the-Web, and under `RemoteSigned` they refuse to run: *"is not digitally signed"*.
Fix on the target, not by weakening the policy:

```powershell
Unblock-File G:\tools\airgapped-setup-machine\*.ps1
Unblock-File G:\tools\hyperv-vm-provisioning\*.ps1
```

**4. Mounting the metadata ISO locks it.** Inspecting the seed with `Mount-DiskImage` holds
the file until it is dismounted, and the next build then fails on
*"cannot access the file ... being used by another process"*. Always pair them:

```powershell
$m = Mount-DiskImage -ImagePath $iso -PassThru
$d = ($m | Get-Volume).DriveLetter
Get-Content "${d}:\network-config"
Dismount-DiskImage -ImagePath $iso
```

**How to verify a build before waiting on a boot:** mount the metadata ISO and read
`user-data` and `network-config`. The hash must be intact and the address must carry `/24`.
Thirty seconds, versus a full provision cycle and a login that will not work.

## 9. Sources

- [schtritoff/hyperv-vm-provisioning](https://github.com/schtritoff/hyperv-vm-provisioning) — `New-HyperVCloudImageVM.ps1`, parameters, prerequisites, image versions, default credentials
- [`airgap-update-lab.md`](airgap-update-lab.md) — STAGE-01's mirror role, sizing, licensing model
- [`docs/open-questions.md`](../docs/open-questions.md) — Q6 (bundle size), Q9 (Support Portal access)
