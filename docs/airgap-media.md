# Air-gap media — what goes on the drive

Everything that crosses into the enclave crosses on removable media. Nothing is fetched at
install time. This page says what to put on what, for each stage.

Referenced from [`START-HERE.md`](../START-HERE.md) step 02 onward.

---

## 1. Two stages, two very different sizes

| Stage | For | Contents | Size | Media |
|---|---|---|---|---|
| **A — OS install** | Steps 02, 03 | Ubuntu ISO + autoinstall seed | **~3.5 GB** | 2 × USB thumb drives |
| **B — Platform bundle** | Steps 05–08 | Snaps, container images, Harbor, MAAS images, Landscape | **Tens of GB** | Portable SSD, not a thumb drive |

Stage A is all you need for the host builds. Stage B is sized by open question 6 and is not
staged yet — see [`00-downloads.md`](00-downloads.md) "Not downloaded yet".

## 2. Stage A — the OS install kit

### Drive 1 — bootable installer

`ubuntu-24.04.4-live-server-amd64.iso`, written **raw**. 8 GB stick or larger. Do not copy the
ISO on as a file.

**Windows:** [Rufus](https://rufus.ie) — select the ISO, accept "DD Image mode" if prompted.
balenaEtcher and Ventoy also work.

**Linux:**

```bash
lsblk -o NAME,SIZE,TRAN,RM,LABEL,FSTYPE          # confirm TRAN=usb, RM=1
sudo dd if=ubuntu-24.04.4-live-server-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

Write to the **disk** (`/dev/sdb`), not a partition (`/dev/sdb1`).

This is Canonical's pristine, signed ISO. **Do not remaster it** — a rebuilt image no longer
matches the signed `SHA256SUMS` you verified in step 00, and that chain is supply-chain
evidence.

### Drive 2 — the autoinstall seed

The seed is a **FAT32 USB stick labelled `CIDATA`** holding two files: `user-data` and
`meta-data`. That is the only method — no ISO tooling on either platform. cloud-init accepts
`cidata` or `CIDATA`; case does not matter.

**Windows**

```powershell
Format-Volume -DriveLetter E -FileSystem FAT32 -NewFileSystemLabel CIDATA
.\scripts\install\02-build-seed.ps1 -HostName h1 -Address 10.0.20.115 -DriveLetter E
```

**Linux / macOS**

```bash
lsblk -o NAME,SIZE,TRAN,RM,LABEL,FSTYPE          # confirm TRAN=usb, RM=1
sudo mkfs.vfat -F 32 -n CIDATA /dev/sdX1         # CHECK THE DEVICE
sudo mount /dev/sdX1 /mnt
./scripts/install/02-build-seed.sh -H h1 -a 10.0.20.115 -d /mnt
sudo umount /mnt
```

Both scripts refuse to run on a non-removable drive, on the wrong filesystem, on a
wrongly-labelled volume, or with `REPLACE-ME` still in the config.

**One seed per host.** `h1`, `h2`, `h3` differ in hostname and IP address, so build three, label
the sticks physically, and do not mix them up.

### Drive 3 — post-install payload (optional but recommended)

A plain FAT32 stick holding whatever the host needs immediately after first boot:

- the step 01/03 scripts
- the diagnostic toolset `.deb` files for the Minimal nodes (runbook §2.4)
- `SHA256SUMS` and `SHA256SUMS.gpg` if the signature check is still outstanding

Anything not on this stick and not on the ISO **does not exist** inside the boundary.

## 3. Why two drives instead of one

The installer ISO is written raw and occupies the whole device. The seed must present itself
as a separate volume labelled `cidata`. Two sticks is the simple, reliable arrangement.

A single stick with the ISO in one partition and a `cidata` partition in the free space can
work, but it is fiddly and **untested here** — do not discover that on the enclave floor.
Two sticks, physically labelled.

**The HTTP seed method (`01-serve-seed.sh`) does not apply inside the enclave.** It exists for
the connected pathfinder only, where it also delivers the test scripts. Production installs are
USB-only. If you validate only the HTTP path, you have validated a delivery mechanism you can
never use — so pass 2 tests the USB path.

## 4. What makes the install work offline

Three settings in `02-host-autoinstall/user-data`. All three matter; the first two are the ones
that bite silently.

| Setting | Why |
|---|---|
| `apt.geoip: false` | **Default is `true`.** The installer otherwise calls `https://geoip.ubuntu.com/lookup` to choose a mirror — an outbound request that hangs on a disconnected host |
| `apt.fallback: offline-install` | When no mirror is usable, complete the install from the ISO pool instead of aborting. Values are `abort`, `offline-install`, `continue-anyway` |
| `refresh-installer.update: false` | Stops the installer trying to update itself before it starts |

Two consequences to plan around:

- **`packages:` can only name things on the ISO.** In an offline install, packages come from the
  ISO pool. Anything else fails silently. Keep the list minimal — currently just `lvm2`.
- **`updates:` accepts only `security` or `all`, never `none`.** With no reachable archive and
  the offline-install fallback, there is nothing to fetch. Left at the default.

Once Landscape's mirror exists on `svc-01`, hosts 2 and 3 can point at it:

```yaml
apt:
  geoip: false
  fallback: offline-install
  mirror-selection:
    primary:
      - uri: "http://svc-01.enclave.local/ubuntu"
```

Host-1 is built before that mirror exists, so it relies on the fallback alone.

### Line endings — check before every copy

**Every `.sh`, `user-data` and `meta-data` on the media must be LF, never CRLF.** A single
carriage return breaks the shebang (`bad interpreter: No such file or directory`) and breaks
cloud-init parsing. The failure happens on the enclave floor, where you cannot just re-copy.

`.gitattributes` enforces LF inside the repo, but files can pick up CRLF in transit — opened in
Notepad, copied by a sync tool, edited on Windows. **Verify on the media, after copying.**

**Linux**

```bash
file /mnt/*.sh /mnt/user-data                 # must NOT say "CRLF line terminators"
grep -lU '\r' /mnt/* 2>/dev/null   # lists offenders; silence is good
sed -i 's/\r$//' /mnt/*.sh        # fix if needed
```

**Windows**

```powershell
# lists any file on E: containing a CR byte - should print nothing
Get-ChildItem E:\ -File -Recurse | Where-Object {
    (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match "`r"
} | Select-Object FullName
```

If you must rewrite a file on Windows, write it with LF explicitly - `Set-Content` and
`Out-File` both emit CRLF by default:

```powershell
$t = (Get-Content .\script.sh -Raw) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText("E:\script.sh", $t, (New-Object System.Text.UTF8Encoding($false)))
```

`02-build-seed.ps1` already does this for `user-data` and `meta-data`. The rule applies to
anything else you hand-copy.

## 5. Before media crosses

- [ ] Every artefact checksummed, and the manifest kept — `MANIFEST.sha256` from step 00
- [ ] GPG signatures verified on the connected side
- [ ] Seeds built and physically labelled per host
- [ ] `grep REPLACE-ME` returns nothing in every `user-data` on the media
- [ ] **Line endings verified LF** on every `.sh`, `user-data` and `meta-data` - see above
- [ ] Password hashes and SSH keys are correct — **you cannot fix these from outside**
- [ ] Diagnostic toolset decided and included
- [ ] Media transfer follows the enclave's approved procedure

Last item is the one that ends trips: a wrong SSH key or an unfilled `REPLACE-ME` means
another media cycle.

## 6. Stage B — moving the 320 GB mirror (planned 2026-08-31, not yet built)

**Decision 6 is resolved in principle: STAGE-01 never writes physical media.** It is a Hyper-V
guest and Hyper-V has no casual USB passthrough. Instead it *produces a bundle*; a separate
physical machine writes the disk. That also splits the problem in two, which is the part that
makes it tractable — the two media have nothing in common:

| | Mirror SSD | Seed sticks |
|---|---|---|
| Size | **320 GB** (measured 2026-08-31) | ~120 MB each |
| Filesystem | ext4 (see below) | FAT32 / vfat, volume label `CIDATA` |
| Written by | a physical Ubuntu box | Windows `02-build-seed.ps1` on the Hyper-V host |
| Cadence | first trip, then deltas | once per host build |

Seed sticks are unchanged and stay a Windows job — that is §7 decision 4 in
`airgapped-setup-machine/README.md`, and nothing here alters it.

### 6.1 `build-01` — the machine that writes the media

Built **2026-08-31**. A dedicated physical Ubuntu box on the online side. Named to match the
existing convention (`stage-01`, `svc-repo-01`, `k8s-cp-01`); earlier drafts called it
"BUILD-BOX", which was a role placeholder, not a name.

| | |
|---|---|
| OS | Ubuntu 24.04 LTS Server, **manual install** — it is not an enclave host |
| RAM | 32 GB |
| OS disk | **256 GB** — ESP + ext4 `/`, no LVM, no LUKS |
| Data disk | **2 TB M.2 NVMe** → `/srv/bundle`, ext4, `LABEL=bundle` |
| User | `encadmin`, matching STAGE-01 so the transfer scripts need no per-host paths |
| Ubuntu Pro | **Not attached — deliberate** |

**Why no Pro attachment.** `build-01` sits outside the ATO boundary and needs nothing Pro
provides: ESM is empty on a young LTS (that is why the `esm-infra` mirror holds four packages),
Livepatch is pointless on a box you can reboot at will, and FIPS/USG are actively unwanted —
enabling FIPS would move it to the FIPS kernel and impose the Ed25519 SSH ban on a machine
whose only job is moving files. Same reasoning as STAGE-01 §0.2. *(If good-faith licence
coverage is wanted for the lab, the free personal tier costs nothing — see
`airgap-update-lab.md` §1. That is a licensing choice, not a capability one.)*

**Hardware note that cost time.** A 1 TB **M.2 SATA** drive was invisible to the installer in
slot 1 — that slot is PCIe/NVMe-only, and the SATA pins simply are not connected. No BIOS
setting fixes it. **Check the board's storage table before assuming an M.2 slot takes a SATA
drive**, and remember many boards also mux M.2 slots against SATA ports. The 256 GB drive went
back in and the 2 TB NVMe became the data disk, which is the better layout anyway — the bundle
belongs on the fast, large device.

**Set the data disk up after first boot, not in the installer.** Keeping it out of the
installer entirely is the simplest guarantee against wiping the wrong device:

```bash
sudo parted /dev/nvme0n1 mklabel gpt
sudo parted -a opt /dev/nvme0n1 mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L bundle /dev/nvme0n1p1
sudo mkdir -p /srv/bundle
echo 'LABEL=bundle /srv/bundle ext4 defaults 0 2' | sudo tee -a /etc/fstab
sudo mount -a
```

`LABEL=` rather than a device name, so it survives the drive changing slots — the same instinct
as pinning by `id_path` in the autoinstall template.

**Packages:**

```bash
sudo apt install -y rsync gnupg dosfstools whois python3-yaml shellcheck \
  git curl jq pv nvme-cli smartmontools gdisk parted e2fsprogs xorriso openssh-server
```

`dosfstools` and `xorriso` are what let `build-01` write seed sticks natively; `pv` gives
progress on long writes; `nvme-cli`/`smartmontools` matter because consumer M.2 is about to
take 320 GB.

**SSH key: RSA 3072+ or ECDSA, never Ed25519.** `build-01` does not run FIPS itself, but keys
get reused and every enclave host will refuse Ed25519.

**Consequence worth revisiting: `build-01` can retire the Windows seed-writer.**
`02-build-seed.sh` runs natively here, which removes the PowerShell dependency and the whole
BOM/CRLF class of failure that §7 decision 7 of `airgapped-setup-machine/README.md` was written
about. Decision 4 kept `02-build-seed.ps1` because no physical Linux box existed. One now does.

### The path

```
   ONLINE SIDE                    ║ GAP ║        INSIDE THE ENCLAVE

 [ STAGE-01, VM ]  --(1)-->  [ build-01, physical Ubuntu, SSD attached ]
   320 GB mirror              rsync over SSH, ~60-90 min first trip
                                        |
                                       (2) write-transfer-media.sh
                                        v
                                 [ 500 GB SSD ] ═════╬═════╬══>  [ MIRROR-01 ]
                                   carried by hand    ║     ║     nginx :80
                                                      ║     ║     contracts :8484
                                                                    (3) restore-mirror.sh
```

| Step | Runs on | Does | Time |
|---|---|---|---|
| 1 | STAGE-01 | `build-transfer-bundle.sh` — gather mirror + 4 keyrings + 3 `.deb`s + ISOs + `airgapped-contracts.yaml` + MIRROR-01 configs into one staging tree; manifest the non-repo items | minutes |
| 2 | `build-01` | `write-transfer-media.sh` — rsync that tree onto the SSD, verify | **60–90 min first trip**, minutes after |
| 3 | MIRROR-01 | `restore-mirror.sh` — rsync in, install the 3 `.deb`s, place the 4 keyrings, drop the nginx vhost, start the contracts server, run the three-level proof from `airgap-update-lab.md` §6.5 | ~20 min |

Step 3 is the one that matters: it turns files on a disk into a working enclave service, and it
is the part nobody can improvise at the rack.

### Decisions baked in, so they are not re-argued

- **rsync, never tar.** Later trips carry only the delta because rsync compares against what is
  already on the drive. Tarring 320 GB of already-compressed `.deb`s costs hours and buys
  nothing.
- **No 90,000-file checksum manifest.** An apt repository is already a signed hash chain —
  GPG-signed `Release` → hashes of `Packages` → hashes of every `.deb`. **`apt-get update` on
  MIRROR-01 *is* the integrity check.** Manifest only what the repo does not cover: the
  keyrings, the three `.deb`s, the ISOs and the scripts — which are the supply-chain-sensitive
  items anyway.
- **Windows stays out of the mirror path.** Routing it through Windows means two copies and
  640 GB of I/O for no gain.
- **The bottleneck is the vNIC, not the disk.** STAGE-01 has a 1000 Mb/s link: 320 GB is ~43
  min at line rate, realistically 60–90 with **90,893 files across 38,128 directories** —
  per-file overhead dominates.

### Filesystem — ext4 recommended, NTFS viable

Measured on the real tree, 2026-08-31, because the usual objections turned out not to apply:

| Concern | Measured | Verdict |
|---|---|---|
| Case-insensitive collisions | **0 true collisions** | Not a blocker |
| Path length vs NTFS 260 | longest **207** chars, 1 file over 200 | Fits, tight |
| Largest file vs FAT32 4 GB | **2.76 GB** (`qgis-api-doc`) | Fits, but avoid FAT32 |
| Symlinks | **0** | Not a blocker |

**ext4** is still the recommendation — faster across 38,128 directories and it preserves
ownership. NTFS costs only a `chown -R` on arrival; choose it only if the drive must be
readable from Windows.

> **An earlier draft of this section claimed 76 case collisions. That was wrong** — the test
> compared basenames across *different* directories, so it was really just packages appearing
> in both the archive and an ESM pool. The correct test is per-directory and returns zero.

### Blocker before any of this runs

**`airgapped-contracts.yaml` does not exist yet.** `pro-airgapped` must consume the resource
tokens and emit it with every `aptURL` rewritten to MIRROR-01. Without it the enclave has a
repository it can pull from and **nothing to `pro attach` against** — the ESM and FIPS packages
sit on the disk unusable. It has to be in the bundle, so it comes before step 1.

## 7. Not yet answered

- **Stage B size and cadence** — open question 6. The apt half is now measured at 320 GB; what
  is still unknown is the container-image and snap half.
- **Whether one stick can carry both ISO and `cidata`.** Would halve the drive count. Test it on
  the pathfinder if you want it; do not assume it.
- **Diagnostic toolset contents** — still undecided, and it must be fixed before the Stage A
  media is built.
