# Host OS install — bare metal, Ubuntu Server 24.04.4 LTS

Builds the three physical hosts to an identical, reproducible, STIG-partitioned base.
Hardening is **not** done here — see §8 for why.

Config: [`scripts/install/02-host-autoinstall/user-data`](../scripts/install/02-host-autoinstall/user-data)
Seed builder: [`scripts/install/02-build-seed.sh`](../scripts/install/02-build-seed.sh)

Verified against Canonical's autoinstall reference 2026-08-27. Sources in §11. Anything not
verified this session is marked **[VERIFY]** and must be settled on the **pathfinder machine**
(START-HERE step 01, pass 2) before this goes to three production hosts.

---

## 1. Two corrections to the runbook, found while writing this

**The runbook's Phase 3 is circular.** Runbook §6 says MAAS commissions and deploys the
three hosts. MAAS runs on `svc-01`, which is a VM, which runs on a host — so MAAS cannot
install the host it depends on. Something has to come first.

**Resolution: autoinstall all three hosts from removable media.** MAAS then manages only the
VMs, not the host OS. For three machines this is simpler than a PXE bootstrap, gives you a
version-controlled config that produces three identical hosts, and removes the dependency
loop entirely. MAAS is still the VM host manager and composer (runbook §7) — it just never
touches the metal.

**The STIG "fresh install" rule collides with the bootstrap order.** Canonical is explicit
that STIG hardening runs on a fresh installation. But host-1 has to carry `svc-01` — and
therefore MAAS, Landscape and the Pro contract server — before *any* host can attach to Pro
and enable FIPS or USG. So host-1 is not fresh by the time hardening is possible.

Options, in order of preference:

| | Approach | Cost |
|---|---|---|
| **A** | Autoinstall all 3 → build `svc-01` on host-1 → harden hosts 2 and 3 (still fresh) → migrate `svc-01` to host-2 → **rebuild host-1** and harden it fresh | One extra host rebuild. Genuinely fresh STIG baseline on all three. |
| B | Accept host-1 as "fresh enough" — only LXD and one VM were added before hardening | No rebuild, but you are arguing the point with an assessor rather than avoiding it |
| C | Stand up the Pro/Landscape infrastructure on a separate temporary machine inside the boundary first | Cleanest, but needs a fourth machine and an accreditation story for it |

**Recommend A.** One rebuild is cheap; a contested STIG baseline is not. Decide before you
start, because it determines which host you build first and where `svc-01` lands.

## 1a. Not yet satisfied — decide before building production hosts

This template does **not** configure disk encryption or a GRUB password. Both are STIG items
and both are install-time decisions that cannot be retrofitted without a rebuild.

| | Status |
|---|---|
| **GRUB password** — `UBTU-24-102000` (V-270675) | Confirmed requirement. Not in the template |
| **Data-at-rest encryption** — LUKS | Requirement is conditional on the data's protection level; exact 24.04 rule ID must be pulled from <https://public.cyber.mil/stigs/downloads/>. No `dm_crypt` in the template |

Applied naively, both stop three headless racked hosts from rebooting unattended — which
breaks every patch window. The GRUB password needs `--unrestricted` on normal boot entries;
LUKS needs TPM 2.0 or Tang/Clevis rather than a console passphrase.

**Open questions 19, 20 and 21 cover this.** Settle them before step 02 runs on real hardware.

## 2. What this produces

An Ubuntu Server 24.04.4 host that is: identically configured across all three machines,
partitioned to satisfy the STIG's separate-filesystem rules, has a console password set (so
STIG remediation cannot lock you out), SSH key-only, no swap, and **nothing else** — no LXD,
no Pro attachment, no hardening.

## 3. Prerequisites

- `ubuntu-24.04.4-live-server-amd64.iso`, verified — see [`00-downloads.md`](00-downloads.md) and
  [`00-fetch-verify-media.sh`](../scripts/install/00-fetch-verify-media.sh)
- A second USB stick for the autoinstall seed, FAT32, labelled `CIDATA`. The HTTP seed method
  does not apply inside the enclave — see [`airgap-media.md`](airgap-media.md)
- BMC/IPMI reachable, with serial-over-LAN configured — see §7a for why this is the
  recommended console path and what it implies for the accreditation boundary
- Hosts set to UEFI boot, Secure Boot decision made **[VERIFY]** — confirm whether your STIG
  baseline requires Secure Boot enabled; it affects the ESP layout and signed-kernel choice
- An SSH keypair for the admin account

## 4. One-time setup

Done once. Reused for all three hosts. If you already did this during the pathfinder pass
(step 01, Part A), it is done — `host-params.env` persists.

### 4.1 Password hash

**Linux or WSL:**

```bash
sudo apt install -y whois
mkpasswd --method=SHA-512 --rounds=4096
```

**Windows**, using the OpenSSL that ships with Git Bash:

```bash
openssl passwd -6
```

Starts `$6$`. **Not optional** — the DISA profile requires a password on the administrative
account and will lock you out of the host without one. MAAS-style key-only builds routinely
have none; that is the trap this avoids. Record the plaintext in the programme credential
store, never in this repo.

### 4.2 SSH key — on your workstation

**Generate on the machine you will SSH *from*. Never on a host you are about to install.**

Every install wipes the target. A key generated there dies with it — so if `ALLOW_PW` is
`false` and that was your only key, you are down to console access on a racked machine.
`ALLOW_PW=true` during the build is the guard against exactly that; step 03 turns it off.

**RSA or ECDSA, never Ed25519.** With FIPS enabled OpenSSH refuses it outright — *"ED25519 keys
are not allowed in FIPS mode"*, confirmed on the pathfinder 2026-08-28. Every host here runs
FIPS, including the guest VMs.

**From a Windows workstation**

```powershell
ssh-keygen -t rsa -b 4096 -C "enclave-admin" -f $env:USERPROFILE\.ssh\enclave_admin
type $env:USERPROFILE\.ssh\enclave_admin.pub
```

**From an Ubuntu / Linux workstation**

```bash
ssh-keygen -t rsa -b 4096 -C "enclave-admin" -f ~/.ssh/enclave_admin
cat ~/.ssh/enclave_admin.pub
```

Either way you get two files. Only the `.pub` goes into `host-params.env`:

| File | What it is | Where it lives |
|---|---|---|
| `enclave_admin` | **private key** — the secret | Stays on your workstation. Never on a host, never in this repo |
| `enclave_admin.pub` | public key — one line, starts `ssh-rsa` | Pasted into `host-params.env`, installed on every host |

Then connect with it explicitly:

```powershell
ssh -i $env:USERPROFILE\.ssh\enclave_admin encadmin@<host-address>
```

```bash
ssh -i ~/.ssh/enclave_admin encadmin@<host-address>
```

### 4.3 host-params.env

```
scripts/install/02-host-autoinstall/host-params.env
```

Gitignored. Shared by all three hosts:

| Key | Value |
|---|---|
| `NIC_MATCH` | `en*` for single-NIC hosts; narrow it if a host has several |
| `PREFIX` | `24` |
| `GATEWAY` | your gateway |
| `DNS` | enclave DNS, not a public resolver |
| `PASSWORD_HASH` | the `$6$...` hash |
| `ALLOW_PW` | `true` during the build, `false` at step 03 hardening |
| `SSH_KEY_1` .. `SSH_KEY_8` | one public key per line. **Every one you define is installed on every host** |

**Add one key per environment you connect from.** WSL and Windows have separate `~/.ssh`
directories — a key generated in WSL is invisible to PowerShell's `ssh.exe` and to SecureCRT.
Numbering them means you revoke a lost workstation by deleting one line, not by rotating the
account:

```
SSH_KEY_1='ssh-rsa AAAA... you@windows'
SSH_KEY_2='ssh-rsa AAAA... you@wsl'
SSH_KEY_3='ssh-rsa AAAA... ops@jumpbox'
```

**`ALLOW_PW=true` is deliberate for the build phase.** You cannot finish a host you cannot
connect to, and being locked out of a half-built machine on a rack costs more than a password
on a lab network. Step 03 hardening sets it `false`, which is what the STIG requires. The
console password is set either way and is the last-resort way in.

## 5. Per host — no file editing

**There is nothing to copy or customise.** One template, one stick, rewritten per host.
Hostname and address are arguments; everything else comes from `host-params.env`.

**From Windows**

```powershell
.\scripts\install\02-build-seed.ps1 -HostName h1 -Address 10.0.20.11 -DriveLetter F
.\scripts\install\02-build-seed.ps1 -HostName h2 -Address 10.0.20.12 -DriveLetter F
.\scripts\install\02-build-seed.ps1 -HostName h3 -Address 10.0.20.13 -DriveLetter F
```

**From Linux**

```bash
./scripts/install/02-build-seed.sh -H h1 -a 10.0.20.11 -d /mnt
./scripts/install/02-build-seed.sh -H h2 -a 10.0.20.12 -d /mnt
./scripts/install/02-build-seed.sh -H h3 -a 10.0.20.13 -d /mnt
```

Same stick each time — write it, install that host, rewrite it for the next.

Three hosts that differ only in name and address are three hosts you can reason about — and
because they come from one template, they cannot drift.

Disks and NIC are matched by characteristic, not identity, so **no per-machine inventory is
needed**:

| | Matched by | Why |
|---|---|---|
| OS disk | `id_path: "*-ata-*"` | The bus, not a serial. Cannot select a USB stick |
| Data disk | `id_path: "*-nvme-*"` | Same |
| NIC | `NIC_MATCH`, default `en*` | Names vary by hardware — `enp1s0`, `eno1`, `ens192` |

Confirm the bus pattern holds on new hardware:

```bash
ls -l /dev/disk/by-path/ | grep -v part
```

## 6. Step 2 — Write the seed stick

FAT32 stick, volume label `CIDATA`, holding `user-data` and `meta-data`. cloud-init's NoCloud
datasource finds it by that label. No ISO tooling on either platform.

Check the resolved values first — this catches a typo before the stick is written rather than
after the install:

```powershell
.\scripts\install\02-build-seed.ps1 -HostName h1 -Address 10.0.20.11 -DryRun
```

**Windows**

```powershell
Format-Volume -DriveLetter F -FileSystem FAT32 -NewFileSystemLabel CIDATA
.\scripts\install\02-build-seed.ps1 -HostName h1 -Address 10.0.20.11 -DriveLetter F
```

**Linux**

```bash
lsblk -o NAME,SIZE,TRAN,RM,LABEL,FSTYPE          # confirm TRAN=usb, RM=1
sudo mkfs.vfat -F 32 -n CIDATA /dev/sdX1         # CHECK THE DEVICE
sudo mount /dev/sdX1 /mnt
./scripts/install/02-build-seed.sh -H h1 -a 10.0.20.11 -d /mnt
sudo umount /mnt
```

Both scripts refuse a non-removable drive, the wrong filesystem, a wrong label, an Ed25519 key,
or any unsubstituted placeholder.

Label the stick physically. It is rewritten between hosts, so the label tells you which host it
currently carries.

## 7. Step 3 — Boot and install

Insert **both** sticks — installer and seed. Boot the installer, **UEFI not legacy**.

Do not touch the GRUB menu. Let it boot the default entry.

The installer reads the seed and stops at **`Continue with autoinstall? (yes|no)`**. That prompt
shows **network configuration only — there is no disk or partition summary and no preview of
the partition plan.** Answer `yes`.

It runs unattended and reboots. Remove both sticks as it reboots.

**Zero-touch option**, if you would rather not answer the prompt: at GRUB press **`e`**, go to
the end of the line beginning `linux`, type a space then `autoinstall`, press **Ctrl-X**. The
edit applies to this boot only and nothing is written to the stick. Not required — one keypress
per host is fine for three machines, and it keeps the ISO pristine.

Headless? See §7a.

## 7a. Headless installation — console strategy

The installed system is headless by definition: Ubuntu Server has no GUI, and the template
sets `ssh.install-server: true`, with `allow-pw` from `ALLOW_PW`. The question is how you drive the
**installer** on a racked machine with no monitor, since something has to put `autoinstall`
on the kernel command line.

| Method | Console needed | Keeps Canonical's signed ISO |
|---|---|---|
| USB seed + GRUB edit at the machine | Physical, one edit | Yes |
| **BMC remote console + virtual media** | BMC only | Yes |
| **Serial console** `console=ttyS0,115200` over BMC serial-over-LAN | Serial only | Yes |
| Remastered ISO with the parameter baked in | None — zero touch | **No** |
| `autoinstall.yaml` at the root of the install medium, or `subiquity.autoinstallpath=` | Possibly none | Depends **[VERIFY]** |

**Recommended: serial console over BMC SOL, with the BMC's remote KVM as fallback.**

Two reasons that are not about convenience:

**Remastering the ISO breaks the provenance chain.** A rebuilt image no longer matches
Canonical's signed `SHA256SUMS` — the very artefact step 00 exists to produce. Taking the
zero-touch option means documenting the derivation and re-signing internally, and then
defending that to an assessor. Every other method in the table boots the pristine, verified
ISO. Not worth it to save one keypress.

**Installing via the BMC puts the BMC in the accreditation boundary.** Isolated management
VLAN, its own hardening, and DISA publishes STIGs for server management controllers. You need
the BMC for power control anyway — the point is to name it in the SSP deliberately rather than
have it surface during assessment.

Also available once networking is up: the installer offers **SSH access into the installer
itself** from its help menu. Useful when a build stalls and the serial console is not enough.

**[VERIFY] on the pathfinder (step 01, pass 2):** whether the `autoinstall` kernel parameter
is strictly required for a zero-prompt install, or whether delivering config via cloud-init
alone suppresses the disk-modification confirmation. Canonical's quick start says the
installer "prompts for a confirmation before modifying the disk" when booted without the
parameter; the tutorial page does not restate it. Also test the `autoinstall.yaml`-at-root
and `subiquity.autoinstallpath=` delivery paths — either could remove the GRUB edit while
keeping the ISO pristine, which would be the best of both.

## 8. What this deliberately does NOT do

No Ubuntu Pro attach. No FIPS. No STIG remediation. No LXD.

That is a sequencing decision, not an omission:

- **Pro attach needs infrastructure that does not exist yet.** In a disconnected enclave,
  attachment goes through the air-gapped contract server, which lives on `svc-01`, which does
  not exist during the first host's install.
- **FIPS and STIG are blocked on open questions 11 and 12.** Whether `pro enable
  fips-preview` and `usg fix disa_stig` even work on 24.04 is unanswered. Writing them into
  the autoinstall now means writing it twice.
- **`usg fix` must run on a fresh system** and requires a reboot afterwards. It belongs in a
  separate, deliberate, evidence-producing step where the pre- and post-audit reports are
  captured — not buried in `late-commands` where nothing is recorded.

Hardening lands in `03-host-harden.sh` once the capability test returns.

## 9. Step 5 — Verify before moving on

On each host:

```bash
lsblk -o NAME,SIZE,TRAN,TYPE,MOUNTPOINTS   # which bus did each matcher take?
lsblk -f                      # confirm the LVs and mount points below
findmnt -t ext4,xfs           # /var, /var/log, /var/log/audit, /home, /tmp separate
passwd -S "$(logname)"        # must show P — a password IS set
swapon --show                 # expect empty
sudo dmesg | grep -i secureboot
ip -br a                      # addresses match the IP plan
```

Expected filesystems, per §10:

```
/  /boot  /boot/efi  /home  /tmp  /var  /var/log  /var/log/audit
```

Then confirm the three hosts are genuinely identical:

```bash
lsblk -f | sha256sum          # compare across h1, h2, h3
dpkg-query -f '${Package}\n' -W | sha256sum
```

## 10. The disk and partition layout, and why

DISA STIGs require separate filesystems for `/tmp`, `/home`, `/var`, `/var/log` and
`/var/log/audit`. The rule text is *"ensure it has its own partition or logical volume at
installation time, or migrate it using LVM"* — and migrating a live `/var` on a hardened host
is miserable. **Get it right at install; this is the one part of the build you cannot cheaply
redo.**

The template puts the OS on the **SATA** disk (`id_path: "*-ata-*"`) in LVM on `vg0`, and takes
the **NVMe** (`id_path: "*-nvme-*"`) whole into a second, empty volume group `vg-data` for LXD
and Ceph to carve from. Anything on another bus — notably the USB sticks you booted from — is
not named in the config and is left untouched.

> **Do not use `size: smallest` or `size: largest` here.** Confirmed on the pathfinder
> 2026-08-28: subiquity does **not** exclude removable media from size matching. It selected the
> 120 MB CIDATA seed stick as the OS disk, wiped it, then failed creating a 1 GB ESP on a 120 MB
> device. Matching on `id_path` encodes the physical bus and structurally cannot pick a USB
> device.

> **[VERIFY] the exact rule list against the real benchmark.** The separate-filesystem
> requirement is well established across DISA Linux STIGs, but the authoritative list for
> *Canonical Ubuntu 24.04 LTS* — currently at revision v1r4/v1r5 (2026) — must come from
> DISA's own document library, not from this file. Pull the benchmark, grep the `UBTU-24-*`
> rules for partition requirements, and reconcile before the first real install. Add any
> filesystem it names that is missing from the template. This is install-time-irreversible.

## 11. Sources

Fetched 2026-08-27.

1. [Autoinstall configuration reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html) — top-level `autoinstall` key, `version: 1`, section names, `identity` subkeys and password-hash format, storage `layout`/`config`, curtin action types, `swap`
2. [Autoinstall quick start](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html) — NoCloud delivery, `user-data`/`meta-data`, `ds=nocloud-net;s=` kernel syntax
3. [Configuring storage](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/configure-storage.html) · [curtin storage](https://curtin.readthedocs.io/en/latest/topics/storage.html) — `lvm_volgroup`, `lvm_partition`, sizing syntax
4. [Providing autoinstall configuration](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html) · [Operating the server installer](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/operate-server-installer.html) — `autoinstall.yaml` at medium root, `subiquity.autoinstallpath`, serial console, SSH into the installer
5. [Ubuntu DISA-STIG compliance](https://ubuntu.com/security/disa-stig) — fresh-install requirement, administrative password requirement
6. [Canonical Ubuntu 24.04 LTS STIG](https://www.stigviewer.com/stigs/canonical_ubuntu_2404_lts) — index only; pull the authoritative benchmark from DISA
