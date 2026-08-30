# STAGE-01 — build plan

**Status: PLAN, awaiting approval. Nothing here has been built.**

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

**Not installed:** any desktop environment. See §3.

### 4.5 Credentials and access

| | Status |
|---|---|
| **Paid Ubuntu Pro token** | **BLOCKING.** This is open question 9 — it unlocks the air-gapped tooling entitlement and the Support Portal KB article. Without it STAGE-01 cannot do its main job |
| SSH keypair | Generate on STAGE-01 for reaching the enclave hosts; add the pathfinder's key to it |
| Git access to this repo | STAGE-01 is online, so a normal clone |
| ESM resource tokens | Derived from the paid token via `get-resource-tokens` |

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
  -NetAddress 10.0.20.50 -NetGateway 10.0.20.1 `
  -DryRun
```

Drop `-DryRun` to build. The rendered user-data contains the password hash, so it is written to
a temp file and removed in a `finally` block.

The wrapper refuses an Ed25519 key and a malformed password hash before it touches Hyper-V -
same guards as the enclave seed builder, for the same reason.

## 6. Proposed build sequence

1. ~~Confirm the Hyper-V host and disk budget~~ - done, R7515
2. Clone `schtritoff/hyperv-vm-provisioning` on the host
3. Write a `userdata.yaml` for STAGE-01 — our own user, our SSH keys, no default `admin`/`Passw0rd`
4. Provision the VM - single 1 TB VHDX via -VHDSizeBytes
5. Install the dev toolchain (§4.4), clone this repo, verify the scripts run
6. **Switch development to STAGE-01** — retire the two `.ps1` scripts and the Windows doc blocks
7. Attach the paid Pro token, install the air-gapped tooling
8. First `apt-mirror` run — hours; leave it overnight
9. Prove the mirror locally with nginx before anything crosses the gap

Steps 1–6 need no Pro token and can start immediately. **Steps 7–9 are gated on Q9.**

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

6. **How does media get written once development moves to STAGE-01?** Options: keep the
   PowerShell seed writer on the Hyper-V host (recommended), Hyper-V physical-disk passthrough
   (works, tedious, untested), or a small physical Ubuntu box for media only.



4. **Retire the two `.ps1` scripts** once STAGE-01 is up, or keep both paths in sync?
   Retiring removes `00-fetch-verify-media.ps1` and `02-build-seed.ps1` plus the Windows blocks
   in three docs. Keeping them means every future change lands twice — which I have already got
   wrong twice this week.
5. **Does `airgap-update-lab.md` move here?** It currently sits in `artifact/`, alongside the
   published bake-off document and its build script. A lab runbook is not that.

## 9. Gotchas found building this, 2026-08-29

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
Unblock-File G:	oolsirgapped-setup-machine\*.ps1
Unblock-File G:	ools\hyperv-vm-provisioning\*.ps1
```

**4. Mounting the metadata ISO locks it.** Inspecting the seed with `Mount-DiskImage` holds
the file until it is dismounted, and the next build then fails on
*"cannot access the file ... being used by another process"*. Always pair them:

```powershell
$m = Mount-DiskImage -ImagePath $iso -PassThru
$d = ($m | Get-Volume).DriveLetter
Get-Content "${d}:
etwork-config"
Dismount-DiskImage -ImagePath $iso
```

**How to verify a build before waiting on a boot:** mount the metadata ISO and read
`user-data` and `network-config`. The hash must be intact and the address must carry `/24`.
Thirty seconds, versus a full provision cycle and a login that will not work.

## 8. Sources

- [schtritoff/hyperv-vm-provisioning](https://github.com/schtritoff/hyperv-vm-provisioning) — `New-HyperVCloudImageVM.ps1`, parameters, prerequisites, image versions, default credentials
- [`airgap-update-lab.md`](airgap-update-lab.md) — STAGE-01's mirror role, sizing, licensing model
- [`docs/open-questions.md`](../docs/open-questions.md) — Q6 (bundle size), Q9 (Support Portal access)
