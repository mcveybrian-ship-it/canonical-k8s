# Step 01 — Pathfinder machine

One spare bare-metal box, used to answer the questions that could invalidate the plan before
hardware is committed. Disposable: it gets wiped twice.

**Status: pass 1 done. Pass 2 is the active work.**

Previous: [`00-downloads.md`](00-downloads.md) · Next: [`02-host-install.md`](02-host-install.md)

---

## Results so far

### Pass 1 — FIPS and STIG availability · DONE 2026-08-28

Both blocking questions answered on real hardware. **The 24.04 decision holds.**

| | Question | Answer |
|---|---|---|
| **Q11** | Can a FIPS stream be enabled on 24.04? | **Yes — `fips-updates` only.** `fips` and `fips-preview` report `n/a`, which Canonical defines as entitled but not available on this machine |
| **Q12** | Does USG carry a STIG profile for 24.04? | **Yes — `stig-v1r1`** (aliases `stig`, `disa_stig`), benchmark `STIG/ubuntu2404` V1R1, released 2026-02-27 |

FIPS was then enabled and verified: `/proc/sys/crypto/fips_enabled` = **1**, kernel moved from
`7.0.0-30-generic` (HWE) to **`6.8.0-138-fips`**. FIPS tracks the GA kernel line, not HWE —
plan for that on the production hosts.

**Two things this changed:**

- The OS decision was argued on `fips-preview` covering submitted-but-uncertified modules.
  That stream is not offered on 24.04. `fips-updates` is what you get, and since 24.04 has no
  CMVP certificates it cannot mean what it means on 22.04. **Open question 17** — get Canonical
  to state what it actually delivers, because that sentence goes in the SSP.
- USG ships benchmark **V1R1** and `usg list --all` offers nothing newer, while DISA has
  published later revisions. **Open question 18** — settle with your assessor which revision
  you are held to.

The FIPS package list is large; retrieve it with `dpkg -l | grep -i fips` when the SSP needs
it. That list is what you cite in place of certificate numbers.

### Hardware baseline

Recorded 2026-08-28. **These values are this machine's, not the production hosts'** — re-run
`01-hw-inventory.sh` on each real host before filling in its step 02 config.

| | |
|---|---|
| Machine | AMD Ryzen 3 4300U, 30 GB RAM, DMI strings all `Default string` |
| Interface | `enp1s0`, gateway `10.0.20.1` |
| OS disk | `sda`, 256 GB SATA, serial `YB3K012368T` |
| Data disk | `nvme0n1`, 1 TB Intel, serial `PHHP933303DT1P0D` |
| Firmware | UEFI, **Secure Boot disabled, platform in Setup Mode** |
| RAID | none |

---

# Pass 2 — Autoinstall test

Proves the step 02 autoinstall config works on real hardware before it is pointed at three
production hosts.

**Part A is one-time setup.** Do it once; it is reused for every host, forever.
**Part B repeats per host** — one stick, rewritten each time.

> **This wipes both disks on the target.** Get anything you care about off it first.

---

## Part A — One-time setup

### A1. Generate the password hash

Do this **once**. It goes in `host-params.env` and is shared by all three hosts.

**On any Linux box** (or WSL):

```bash
sudo apt install -y whois
mkpasswd --method=SHA-512 --rounds=4096
```

**On Windows**, Git Bash ships OpenSSL:

```bash
openssl passwd -6
```

Output starts `$6$`. **Not optional** — the DISA profile requires a password on the admin
account and locks you out without one. Record the plaintext in your credential store.

- [ ] Hash copied.

### A2. Generate the SSH key — ON YOUR WORKSTATION

**Generate this on the machine you will SSH *from*. Never on the target.**

Every install wipes the target. A key generated there dies with it — so if `ALLOW_PW` is
`false` and that was your only key, you are down to console access on a racked machine.
`ALLOW_PW=true` during the build is the guard against exactly that; step 03 turns it off.

```powershell
ssh-keygen -t rsa -b 4096 -C "enclave-admin" -f $env:USERPROFILE\.ssh\enclave_admin
type $env:USERPROFILE\.ssh\enclave_admin.pub
```

Linux workstation:

```bash
ssh-keygen -t rsa -b 4096 -C "enclave-admin" -f ~/.ssh/enclave_admin
cat ~/.ssh/enclave_admin.pub
```

**RSA, not Ed25519.** With FIPS enabled OpenSSH refuses Ed25519 outright — *"ED25519 keys are
not allowed in FIPS mode"*, confirmed on the pathfinder 2026-08-28. Every host here runs FIPS.

Either way you get two files. Only the `.pub` goes into `host-params.env`:

| File | What it is | Where it lives |
|---|---|---|
| `enclave_admin` | **private key** — the secret | Stays on your workstation |
| `enclave_admin.pub` | public key — one line, starts `ssh-rsa` | Into `host-params.env`, installed on every host |

- [ ] Public key copied — one line, starts `ssh-rsa`.
- [ ] The **private** key is on your workstation, not on the target.

### A3. Fill in host-params.env

```
scripts/install/02-host-autoinstall/host-params.env
```

Gitignored — nothing secret is tracked.

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

Hostname and address are **not** here — they are per-host arguments in Part B.

- [ ] Every key set, and at least one `SSH_KEY_n`.

---

## Part B — Per host

Repeat for each host. One stick, rewritten each time.

### B1. Check the resolved values

Catches a typo before the stick is written rather than after the install:

```bash
./scripts/install/02-build-seed.sh -H h1 -a 10.0.20.115 -n
```

```powershell
.\scripts\install\02-build-seed.ps1 -HostName h1 -Address 10.0.20.115 -DryRun
```

Expect:

```
  hostname   h1
  address    10.0.20.115/24
  nic match  en*
  password   SET (sha512 crypt)
  ssh key    SET (ssh-rsa)
  OS disk    id_path *-ata-*   (SATA; never USB)
  data disk  id_path *-nvme-*  (NVMe)
```

- [ ] Values correct.

### B2. Write the seed stick

FAT32, volume label `CIDATA`. cloud-init accepts `cidata` or `CIDATA`.

**Windows**

```powershell
Format-Volume -DriveLetter F -FileSystem FAT32 -NewFileSystemLabel CIDATA
.\scripts\install\02-build-seed.ps1 -HostName h1 -Address 10.0.20.115 -DriveLetter F
```

**Linux**

```bash
lsblk -o NAME,SIZE,TRAN,RM,LABEL,FSTYPE          # confirm TRAN=usb, RM=1
sudo mkfs.vfat -F 32 -n CIDATA /dev/sdX1         # CHECK THE DEVICE
sudo mount /dev/sdX1 /mnt
./scripts/install/02-build-seed.sh -H h1 -a 10.0.20.115 -d /mnt
sudo umount /mnt
```

Both refuse a non-removable drive, the wrong filesystem, a wrong label, an Ed25519 key, or any
unsubstituted placeholder.

- [ ] Stick written, label is `CIDATA`, labelled physically.

### B3. Boot and install

Insert **both** sticks — installer and seed. Boot the installer, **UEFI not legacy**.

Do not touch the GRUB menu. Let it boot the default entry.

The installer reads the seed and stops at **`Continue with autoinstall? (yes|no)`**. That
prompt shows **network configuration only — no disk or partition summary.** There is no
preview of the partition plan. Answer **`yes`**.

It runs unattended and reboots. Remove both sticks as it reboots.

- [ ] Rebooted into the installed system.

> **Zero-touch option.** Adding `autoinstall` to the kernel line suppresses that one prompt.
> At GRUB press **`e`**, go to the end of the line starting `linux`, type a space then
> `autoinstall`, press **Ctrl-X**. The edit applies to this boot only. Not required — one
> keypress per host is fine for three machines.

### B4. Verify

Log in at the console as **`encadmin`**, or SSH from your workstation:

```powershell
ssh -i $env:USERPROFILE\.ssh\enclave_admin encadmin@10.0.20.115
```

```bash
# Which physical disks did the id_path matchers actually take?
lsblk -o NAME,SIZE,TRAN,TYPE,MOUNTPOINTS

findmnt -t ext4,vfat -o TARGET,SOURCE,SIZE
sudo vgs
sudo lvs
passwd -S encadmin
swapon --show
cat /etc/enclave-build-info
```

| Check | Expected |
|---|---|
| `lsblk` | `vg0` on the SATA disk, `vg-data` on the NVMe, USB sticks untouched |
| `findmnt` | `/` `/boot` `/boot/efi` `/home` `/tmp` `/var` `/var/log` `/var/log/audit` |
| `vgs` | `vg0` and `vg-data` |
| `lvs` | six LVs in `vg0`, **none** in `vg-data` |
| `passwd -S` | second field is `P` |
| `swapon` | empty |
| build-info | `hostname=h1`, `address=10.0.20.115/24` |
| SSH | key auth works from the workstation |

- [ ] All eight match.

---

## What can go wrong

| Symptom | Meaning | Fix |
|---|---|---|
| Install dies in `cmd-block-meta` | The disk matcher took the wrong device | Press enter for a shell, `lsblk -o NAME,SIZE,TRAN,RM,TYPE`. See the note below |
| Installer never finds the config | Seed volume not detected | Check the label is `CIDATA` — `lsblk -o NAME,LABEL` from the installer shell (Ctrl-Z or F2). Try the other USB port |
| Errors on the `vg-data` block | Subiquity may reject an empty VG | Delete the `disk-data`/`p-data`/`vg-data` block, finish, then `sudo pvcreate /dev/nvme0n1 && sudo vgcreate vg-data /dev/nvme0n1` |
| Cannot log in at console | Wrong username | It is **`encadmin`** |
| Cannot SSH, password refused | `ALLOW_PW=false` — keys only | Set `ALLOW_PW=true` and rebuild, or use `-i` with the private key from A2 |
| Cannot SSH, key refused | Wrong key, or it lives in a different `~/.ssh` | WSL and Windows are separate stores. Use `-i <path to private key>`. Add a key per environment as `SSH_KEY_n` |
| Network down after install | Static address collides with a DHCP lease | Use an address outside the pool |

> **`size: smallest` destroyed the seed stick on the first attempt, 2026-08-28.** Subiquity
> does **not** exclude removable media from size matching — it selected the 120 MB CIDATA stick
> as the OS disk, wiped it, and died creating a 1 GB ESP on it. The template now matches by
> `id_path` (`*-ata-*`, `*-nvme-*`), which cannot select a USB device. **Never use `size:` in an
> autoinstall that boots from USB.** Confirm the bus pattern on new hardware with
> `ls -l /dev/disk/by-path/ | grep -v part`.

## Why this test exists

Four things were unproven before it ran. Three are now answered:

1. Does 24.04 pick up a `cidata` USB seed — **yes**
2. Is the `autoinstall` keyword required — **no**, it only suppresses one prompt
3. Does the disk matcher pick the right device — **`size:` did not; `id_path` does**
4. Does an empty `vg-data` volume group survive the installer — **still unproven**

# Pass 3 — Hardening recon · optional

Not required; step 01 is complete without it. It tells you what STIG hardening *breaks* on a
box that will later run LXD and Kubernetes, which is what writes step 03.

```bash
sudo usg audit stig-v1r1 | tail -20      # baseline
sudo usg fix stig-v1r1
sudo reboot
sudo usg audit stig-v1r1 | tail -20      # after
```

Reports land in `/var/lib/usg/`. Keep them all — pre-fix, post-fix, and any tailoring file are
the STIG evidence package.

---

## Sources

Fetched 2026-08-27/28.

1. [Screen-by-screen installer walk-through](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/screen-by-screen.html) · [Basic server installation](https://canonical-subiquity.readthedocs-hosted.com/en/latest/howto/basic-server-installation.html) · [Operating the server installer](https://canonical-subiquity.readthedocs-hosted.com/en/latest/tutorial/operate-server-installer.html)
2. [The pro status output explained](https://documentation.ubuntu.com/pro-client/en/latest/explanations/status_columns/) — `n/a` means entitled but not available on this machine
3. [NoCloud datasource](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html) — the volume label may be `cidata` or `CIDATA`
4. [Ubuntu Pro dashboard](https://ubuntu.com/pro/dashboard) — free personal token
