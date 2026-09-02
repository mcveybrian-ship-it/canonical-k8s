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

Hardening lands in **step 05** once the capability test returns and the contract server exists. It is not step 03 — step 03 is libvirt and the service-VM volumes, see `docs/03-host-services.md`.

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

## 10a. The second LUKS passphrase, and why the seed removes it

Two encrypted disks means two LUKS headers, so an unmodified install asks for **two**
passphrases at boot and blocks on the second. What that looks like at the rack is worse than
it sounds: the host answers ping, so it appears to be up, but `sshd` has not started and will
not until someone types at the console. Measured on host-4, 2026-09-02:

```
systemd-cryptsetup@crypt\x2ddata.service   374s   (waiting at a prompt)
```

Four hosts, two prompts each, is eight console entries per full-cluster reboot on machines
that already require a person present because there is no TPM.

**The seed now fixes this at install time.** When `ENCRYPT_DISKS=true`, `02-build-seed.sh`
emits a `late-command` that:

1. creates `/etc/luks/` and writes a random keyfile, `0400 root:root`, **on the encrypted
   root** — not on an unencrypted `/boot` and not on the data volume it unlocks;
2. `luksAddKey`s it as an **additional** keyslot, feeding the existing passphrase
   non-interactively (it is already in `user-data` at install time, which is the only reason
   this automates cleanly). The passphrase slot is never removed, so manual unlock still works
   if the keyfile is ever lost;
3. rewrites the `crypt-data` line in `crypttab` to use the keyfile with `luks,discard,nofail`;
4. rebuilds the initramfs.

After, on host-4:

```
4.742s systemd-cryptsetup@crypt\x2ddata.service
```

**374s to 4.7s, and the second prompt is gone.**

**Root still asks for its passphrase, and that is deliberate.** It is the secret protecting
everything else. The keyfile only exists once root is already open, so an attacker holding the
physical disks has an encrypted root and a key they cannot reach. Automating root's unlock
without a TPM would mean storing its key somewhere readable, which defeats the encryption.

**`nofail` is not cosmetic.** With it, a keyfile problem degrades to "data volume not mounted"
— the host boots, `sshd` starts, and you can log in and fix it. Without it, the failure is the
six-minute stall above, with no way in.

The block is emitted only when `ENCRYPT_DISKS=true`, and even then it acts only if a separate
data volume exists. host-4 was the only host that ever needed the manual version; hosts 1-3
have never booted the slow way.

### A bash trap this uncovered — worth more than the feature

While render-testing the above, the placeholder check rejected the output:

```
368:  if cryptsetup status crypt-data >/dev/null 2>@@KEYFILE_LATECMD@@1; then
```

In bash, `${var//pattern/replacement}` treats an `&` in the **replacement** as "the text that
was matched", the same rule `sed` uses. So substituting a block containing `2>&1` reinserted
the placeholder in the middle of it.

Here the check caught it, but **that was luck**. The same rule applies to every free-text value
the seed substitutes: a LUKS passphrase or an SSH key comment containing `&` would have
produced a corrupted seed with **no error at all**, and the first sign of trouble would be an
unbootable host at the rack.

`02-build-seed.sh` now defines `esc()` and applies it to every free-text substitution —
`PASSWORD_HASH`, `SSH_KEYS`, `CRYPT_OS`, `CRYPT_DATA`, the keyfile block, both disk matches and
`NIC_MATCH`. Verified by rendering a seed with `&` deliberately in the passphrase: it lands in
the storage config intact, and `2>&1` stays `2>&1`.

## 11. Sources

Fetched 2026-08-27.

1. [Autoinstall configuration reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html) — top-level `autoinstall` key, `version: 1`, section names, `identity` subkeys and password-hash format, storage `layout`/`config`, curtin action types, `swap`
2. [Autoinstall quick start](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/autoinstall-quickstart.html) — NoCloud delivery, `user-data`/`meta-data`, `ds=nocloud-net;s=` kernel syntax
3. [Configuring storage](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/configure-storage.html) · [curtin storage](https://curtin.readthedocs.io/en/latest/topics/storage.html) — `lvm_volgroup`, `lvm_partition`, sizing syntax
4. [Providing autoinstall configuration](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/providing-autoinstall.html) · [Operating the server installer](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/operate-server-installer.html) — `autoinstall.yaml` at medium root, `subiquity.autoinstallpath`, serial console, SSH into the installer
5. [Ubuntu DISA-STIG compliance](https://ubuntu.com/security/disa-stig) — fresh-install requirement, administrative password requirement
6. [Canonical Ubuntu 24.04 LTS STIG](https://www.stigviewer.com/stigs/canonical_ubuntu_2404_lts) — index only; pull the authoritative benchmark from DISA

---

## host-4 — first real execution of this procedure, 2026-09-01

**This is the first time the step-02 autoinstall has been run on real hardware.** Everything
below is measured from that build, not drafted. host-4 is built first because it carries MAAS,
which composes every other VM (runbook §1.6).

### Hardware as probed

```
sda      28.9G  usb   USB Flash Disk           <- installer stick, must never match
nvme0n1  931.5G nvme  WDS100T3X0C-00SJG0       <- 1 TB WD, onboard M.2
nvme1n1  1.9T   nvme  XF-2TB 2280              <- 2 TB, PCIe card
nvme2n1  1.9T   nvme  XF-2TB 2280              <- 2 TB, PCIe card

pci-0000:01:00.0-nvme-1  -> nvme0n1
pci-0000:0c:00.0-nvme-1  -> nvme1n1
pci-0000:0f:00.0-nvme-1  -> nvme2n1
pci-0000:2d:00.3-usb-... -> sda
```

**All three drives are NVMe**, so `TRAN` cannot distinguish them and the shipped defaults
(`*-ata-*` / `*-nvme-*`) are useless here — `*-ata-*` matches nothing, `*-nvme-*` matches all
three. This is exactly why the patterns moved into `host-params.env` on 2026-09-01. Matched by
PCI address instead:

| Param | Value | Resolves to |
|---|---|---|
| `OS_DISK_MATCH` | `pci-0000:01:00.0-nvme-*` | `nvme0n1`, 1 TB — OS + `vg0` |
| `DATA_DISK_MATCH` | `pci-0000:0c:00.0-nvme-*` | `nvme1n1`, 2 TB — `vg-data` |
| *(unmatched)* | `pci-0000:0f:00.0` | `nvme2n1`, 2 TB — left **raw** for `k8s-wk-04`'s Ceph OSD |

Leaving the third disk unmatched is deliberate: Ceph wants its own device, and an OSD on a
separate spindle keeps recovery I/O off the mirror and Harbor.

### Network — air-gapped from the first boot

```
ADDRESS   10.0.20.158    PREFIX 24
GATEWAY   <empty>        no default route is written at all
DNS       <empty>        nothing outside resolves
NIC_MATCH 'en*'          resolves to enp42s0
```

**It was never connected to the internet, at any point.** "This host has never had egress" is a
clean statement for the SSP; "we built it connected then disconnected it" is not, and cannot be
walked back. The host reaches everything on `10.0.20.0/24` — so SSH administration works
normally — and has no path off it. Not a firewall rule; an absent route.

### Findings from this build

**A wireless adapter is present** — `wlo1` / `wlp41s0`, `ec:91:61:db:47:c1`. **On an
air-gapped IL5 host that is a finding**, and "we didn't configure it" is not an answer since
anyone with root can bring it up. Disable it in firmware, remove the card if it is an M.2
module, or at minimum blacklist the module and mask the interface. **Spec production hosts
without wireless.**

**The two 2 TB drives are DRAM-less** (Realtek RTS5772DL controllers, `XF-2TB 2280`). Fine for
a lab, but one of them carries the Ceph OSD, and DRAM-less NVMe has poor sustained-write and
`fsync` behaviour. When Ceph recovery is slow, that is why — lab artefact, not design fault.
Same category as the consumer-M.2 note in runbook §1.5.

**The old install on `nvme0n1` (partitions p1–p5) is wiped** by `wipe: superblock-recursive`.

### The trap that cost the most time — `PASSWORD_HASH` quoting

`mkpasswd -m sha-512` output **must** be wrapped in single quotes:

```
PASSWORD_HASH='$6$....'      # correct
PASSWORD_HASH=$6$....        # WRONG - the shell expands $6 to nothing
```

Unquoted, the shell expands `$6` and the hash is silently mangled — the account is created with
a garbage password and **nothing errors**. You discover it at the console of a host that also
wants a LUKS passphrase. This is the same failure already recorded in
`airgapped-setup-machine/README.md` §8 for the Hyper-V provisioning script; it recurs because
the trigger is generic — `$` in a value, in a file that gets sourced.

Worse, the symptom pointed nowhere: an unbalanced quote swallowed the next three lines,
including a comment containing `PowerShell's ssh.exe`, and the script died with
**`ssh.exe: command not found`**. `02-build-seed.sh` now validates quote balance and rejects an
unquoted `PASSWORD_HASH` **before sourcing**, naming the line and the fix.

### Building the seed without USB

`stage-01` is a Hyper-V guest with no practical USB passthrough, so the seed is generated to a
directory and the two files copied to media elsewhere:

```bash
### MACHINE: stage-01 ###
./scripts/install/02-build-seed.sh -H host-4 -a 10.0.20.158 -o ~/seed-host-4
```

Then, anywhere with USB: `sudo mkfs.vfat -F 32 -n CIDATA /dev/sdX1` and copy both files to its
root. **Verify line endings after copying** — `file user-data` must not say CRLF. Routing via
Windows is how that happens.

`user-data` contains the LUKS passphrase in plaintext. The stick is a credential; wipe it when
the build is done.
