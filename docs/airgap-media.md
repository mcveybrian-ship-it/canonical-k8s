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
      - uri: "http://svc-01.enclave.internal/ubuntu"
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

#### Installer choices, and why each one

The guided installer auto-selects the **largest** disk, which is the 2 TB — the wrong one. Use
the custom layout and pick the OS disk explicitly.

| Screen | Choice | Why |
|---|---|---|
| Guided storage | **Custom storage layout** | Guided defaults to the largest disk |
| The OS disk, first action | **Reformat** | It shipped with Windows. "Use As Boot Device" alone reuses the existing ESP and leaves the NTFS partitions in place, so no `free space` row appears and there is nothing to add a partition to |
| The OS disk, second action | **Use As Boot Device** | Creates the ~1 GB ESP |
| The `free space` row beneath it | **Add GPT Partition** → blank size, `ext4`, mount `/` | Blank size means "all remaining". The add action lives on the `free space` row, not on the disk row |
| The 2 TB | **touch nothing** | Set it up after first boot — see below |
| Profile | hostname `build-01`, user `encadmin` | Matching STAGE-01's username keeps the transfer scripts free of per-host paths |
| OpenSSH server | **Install: yes** · **Import SSH identity: NO** | The import pulls whatever public keys sit on a GitHub or Launchpad *account*. You do not control what is there, it may be Ed25519, and the repo deploy key is not on the account anyway. Push the key deliberately afterwards |
| Featured server snaps | **none** | `microk8s` in particular would be actively confusing — this project uses the `k8s` snap. Nothing on that screen is wanted, and `build-01` handles everything that crosses into the enclave, so it stays minimal by choice |

> **Do not press Reset after reformatting.** Reset reverts *every* planned change, including
> the reformat, and you land back at the NTFS partitions wondering why there is no free space.
> Nothing is written until the final red confirmation dialog, which names each device it will
> destroy — that dialog is the real checkpoint.

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

### 6.1a Preparing the transfer SSD — done 2026-09-02

**The drive as it arrived:** a 1 TB WD Blue SN550 (`WDS100T3X0C-00SJG0`, serial
`204188801050`) in a USB enclosure, so it presents as `/dev/sdb` with `TRAN=usb`, not as an
NVMe device. It shipped with a Windows layout — a 16 MB Microsoft Reserved partition and a
931.5 GB exFAT partition.

931.5 GB against a **322.6 GB** payload (319 G mirror + 4.3 G extras), so there is room for
several patch cycles before size becomes a question. The §6 table says 320 GB because that was
the measured payload, not a requirement.

**Look before destroying.** The drive was not blank, and a formatted-over drive is not
recoverable:

```bash
### MACHINE: build-01 (10.0.20.124) ###
sudo mkdir -p /mnt/inspect
sudo mount -o ro /dev/sdb2 /mnt/inspect
ls -la /mnt/inspect | head -30
sudo du -sh /mnt/inspect
sudo umount /mnt/inspect
```

**Confirm the device by serial, not by name.** `/dev/sdb` is assigned in discovery order and
moves between boots, especially for USB. Wiping by device name is how the wrong disk dies:

```bash
### MACHINE: build-01 (10.0.20.124) ###
lsblk -dno NAME,SIZE,TRAN,MODEL,SERIAL /dev/sdb
```

It must read `sdb 931.5G usb WDS100T3X0C-00SJG0 204188801050`. A different serial means stop.

**Wipe and format:**

```bash
### MACHINE: build-01 (10.0.20.124) ###
### DESTROYS ALL DATA ON /dev/sdb - serial must be 204188801050
sudo wipefs -a /dev/sdb
sudo sgdisk --zap-all /dev/sdb
sudo sgdisk -n1:0:0 -t1:8300 -c1:"enclave-xfer" /dev/sdb
sudo partprobe /dev/sdb
sudo mkfs.ext4 -L enclave-xfer -m 0 /dev/sdb1
```

`-m 0` matters here. ext4 reserves 5% of the filesystem for root by default — a sensible
guard against a full root filesystem, and pure waste on a courier disk. On 931.5 GB that is
**~46 GB** given back.

`wipefs` before `sgdisk` because a stale exFAT superblock signature can survive a partition
table rewrite and confuse `blkid` afterwards.

**Mount it where `write-transfer-media.sh` expects, and no further:**

```bash
### MACHINE: build-01 (10.0.20.124) ###
sudo mkdir -p /mnt/transfer
sudo mount LABEL=enclave-xfer /mnt/transfer
sudo chown encadmin:encadmin /mnt/transfer
df -h /mnt/transfer && findmnt -no SOURCE,TARGET,FSTYPE,LABEL /mnt/transfer
```

Mounted by `LABEL=`, for the same reason the device was verified by serial.

**Deliberately NOT in `/etc/fstab`.** This disk lives in a bag between trips. An entry for a
disk that is not present fails the boot, and `build-01` is not a machine anyone wants to
rescue at a console — `nofail` would fix the boot but leaves `/mnt/transfer` as an ordinary
empty directory, which is exactly the case `write-transfer-media.sh` refuses to write into.
Mount it by hand each trip; the script checks `mountpoint -q` and dies if you forget.

The `chown` is required: the script tests `[ -w "$MEDIA_MOUNT" ]` as the invoking user, and a
freshly-made ext4 filesystem is owned by root.

### 6.1b The SSH key build-01 needs — a prerequisite the scripts assume

`write-transfer-media.sh` **pulls** from stage-01, so build-01 needs a key **to** stage-01.
This is the opposite direction from `~/.ssh/build01`, which is stage-01's private key for
reaching build-01 — build-01 had never been anything but an SSH *destination* and held no
private key at all. The first run failed on exactly this:

```
error: cannot ssh to encadmin@10.0.20.160 with /home/encadmin/.ssh/build01
```

**`ssh-copy-id` cannot bootstrap it**, because stage-01 sets `PasswordAuthentication no`. The
public key has to be installed from stage-01, which already trusts you.

```bash
### MACHINE: build-01 (10.0.20.124) ###
ssh-keygen -t ed25519 -f ~/.ssh/stage01 -N '' -C 'build-01 -> stage-01 transfer'
```

**No passphrase, deliberately.** The transfer runs unattended for an hour; a passphrase means
an ssh-agent, and an agent that dies mid-rsync is a worse failure than the bare key.

stage-01 can already reach build-01, so pull the public key across rather than pasting it:

```bash
### MACHINE: stage-01 ###
ssh -i ~/.ssh/build01 encadmin@10.0.20.124 'cat ~/.ssh/stage01.pub' \
  | sed 's|^|from="10.0.20.124",no-agent-forwarding,no-X11-forwarding |' \
  >> ~/.ssh/authorized_keys
```

**The `from=` restriction is not decoration.** This key grants access to the machine holding
the paid Pro token and the 319 GB mirror. Bound to build-01's address, a leaked copy is useless
anywhere else. `no-agent-forwarding` and `no-X11-forwarding` cost nothing and remove two things
an unattended transfer never needs.

```bash
### MACHINE: build-01 (10.0.20.124) ###
cd ~/canonical-k8s/scripts/transfer
sed -i 's|^SSH_KEY=.*|SSH_KEY=/home/encadmin/.ssh/stage01|' transfer-params.env
ssh -i ~/.ssh/stage01 -o BatchMode=yes encadmin@10.0.20.160 'hostname'
```

That must print `stage-01` before the transfer will run.

### 6.1c Four defects found auditing `restore-mirror.sh` before it ever ran

`write-transfer-media.sh` had never been executed before 2026-09-02 and failed on its first
line. `restore-mirror.sh` was in the same state — written 2026-08-31, never run — except that
it runs on `svc-repo-01` **inside the gap**, where a failure costs a trip rather than a re-run.
Audited rather than discovered:

**1. nginx cannot be installed, and the script assumes it exists.** It writes
`/etc/nginx/sites-available/apt-mirror`, runs `nginx -t` and reloads — on a freshly built
air-gapped VM that has no nginx. It cannot come from the mirror, because *serving the mirror is
what this script does*, and it is not among the three carried `.debs` (those are the PPA tools
the mirror can never serve). A genuine chicken-and-egg that only surfaces at the rack.

The fix: by that point the tree is on local disk, so apt can read it over `file://` — no
network, no nginx, no ordering problem, and the archive keyring ships with Ubuntu. Verified
against the real tree: `apt-get update` succeeds and is GPG-verified, and `nginx-core` resolves
to 7 packages, all present in the pool.

**2. That bootstrap must include the update pockets.** With `Suites: noble` alone, apt resolves
nginx `1.24.0-2ubuntu7` — the **unpatched** release-pocket build, because that is the only
version the release suite indexes:

| Suite | `nginx` |
|---|---|
| `noble` | 1.24.0-2ubuntu7 |
| `noble-updates` | 1.24.0-2ubuntu7.17 |
| `noble-security` | 1.24.0-2ubuntu7.17 |

Installing a knowingly unpatched web server as the enclave's first service is not a defensible
start. The bootstrap source now carries all three.

**3. No free-space check before a 317 GiB copy.** `write-transfer-media.sh` checks before
writing the SSD; this side did not, so running out at 90% would waste hours and leave a
half-populated tree that looks plausible. Now checked first.

**4. The proof could pass having verified nothing.** Two paths:

- an unset `EXPECTED_SUITES` ran the loop once on an empty line, matched `continue`, and
  reported zero failures — success with zero checks;
- a suite with no `Packages` file scored `"----"`, which was explicitly treated as a pass.

Both are the same shape as the bad Pro token that produced a healthy-looking empty archive on
2026-08-31, which is the exact failure this section exists to catch. The script now refuses an
empty `EXPECTED_SUITES`, counts what it checked, dies if that count is zero, and treats `----`
as the mirroring failure it is.

### 6.2 Rebuilding the bundle — what step 1 actually does

`build-transfer-bundle.sh` is safe to re-run at any time and is expected to be run repeatedly
— every time the mirror changes, a key is added, or a snap is restaged. **It is idempotent by
construction, not by luck.**

```bash
### MACHINE: stage-01 ###
cd ~/canonical-k8s
./scripts/transfer/build-transfer-bundle.sh          # -n for a dry run
```

In order, it:

1. **Refuses to proceed unless `STAGING_DIR` is a plausible directory.** This is the first
   thing it does, before touching anything — see the box below.
2. **Verifies the mirror**, counting `.deb` files in the `pool/` of every suite named by
   `EXPECTED_SUITES`, not just checking that a `Release` file exists. A `Release` without a
   pool is what a bad bearer token looks like.
3. **Cleans its own subdirectories** (`keys debs media config scripts snaps` and the manifest)
   so a file removed from the source cannot survive in the bundle and cross the gap as a stale
   artefact nobody remembers adding.
4. **Copies the extras and verifies each arrived**, comparing the destination count against
   the source count and dying on a mismatch.
5. **Checks every `.snap` has its `.assert`.** Installing without one requires `--dangerous`,
   which discards signature verification, and inside the gap there is no second chance.
6. **Counts the rewritten `aptURL`s** in `airgapped-contracts.yaml`, expecting four.
7. **Writes `MANIFEST.sha256`** over the extras only — the mirror is a signed hash chain
   already.

Expected output on a healthy run:

```
  cleaned previous staging content
  signing keys: 5 file(s)
  airgap debs: 3 file(s)
  snaps: 6 file(s)
  snap asserts: 6 file(s)
  ...
  snap/assert pairs verified: 6
  28 item(s) hashed -> /srv/bundle-staging/MANIFEST.sha256
  extras size: 4.3G
```

> **Two bugs found here on 2026-08-31, both worth knowing because both are recurring shapes.**
>
> **It reported success on a failed copy.** `copy_in` counted files in the *source* and
> swallowed every `cp` failure inside `find -exec`, so it printed `snaps: 6 file(s)` while all
> twelve copies failed against a subdirectory the `mkdir` list had omitted — then wrote a
> manifest and announced "ready to transfer" with no snaps in the bundle. **A bundle script
> that claims success while dropping content is worse than no script**, because it moves the
> discovery inside the gap. It now counts what *arrived*.
>
> **A safety guard that only worked because the caller was unprivileged.** The clean step's
> path check originally ran *after* a writability test, so `STAGING_DIR=/etc` was refused only
> because `encadmin` cannot write to `/etc` — **run as root it would have proceeded and deleted
> subdirectories under `/etc`.** The guard now runs first, before anything else touches the
> path, and rejects `/`, `/etc*`, `/usr*`, `/var*`, `/srv`, anything inside `MIRROR_BASE`,
> relative paths, and anything implausibly short. Verified by running it against each.
> **A safety check that depends on the caller being unprivileged is not a safety check.**
>
> Note also that `case` patterns must be **unquoted** to glob — a quoted `"/*"` matches the
> literal two characters and silently protects nothing.

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

### Blocker before any of this runs — CLEARED 2026-08-31

**`airgapped-contracts.yaml` exists.** `pro-airgapped` consumed the resource tokens and emitted
it with **4 of 4** `aptURL`s rewritten to `svc-repo-01`. It is in the bundle at mode `0600`; it
is a credential, not a config file.

Why it gated everything: without it the enclave has a repository it can pull from and
**nothing to `pro attach` against**, so the ESM and FIPS packages sit on the disk unusable.

## 7. Not yet answered

- **Stage B size and cadence** — open question 6. The apt half is now measured at 320 GB; what
  is still unknown is the container-image and snap half.
- **Whether one stick can carry both ISO and `cidata`.** Would halve the drive count. Test it on
  the pathfinder if you want it; do not assume it.
- **Diagnostic toolset contents** — still undecided, and it must be fixed before the Stage A
  media is built.

## 8. Backing up the client-private material

**git cannot carry it.** `HANDOFF.md`, `docs/open-questions.md`, `docs/runbook.md`, `artifact/`
and `archive/` are gitignored because `origin` is public. That means the bake-off decision, the
entire Q-list, the runbook and the published artifact source exist **only** as files on whatever
machines you have put them on — and for two days that was one VM.

```bash
### MACHINE: stage-01 ###
./scripts/private-sync.sh backup
```

Packs, copies to `build-01`, and **proves it arrived**: compares the SHA-256 of the file that
actually landed, then opens the archive on the far end to confirm it is a readable tarball and
not just the right number of bytes. Rotates to the last 10 by default.

Everything is a parameter — `-t user@host`, `-d remote dir`, `-k ssh key`, `-r keep`, or the
`BACKUP_TARGET` / `BACKUP_DIR` / `BACKUP_KEY` / `BACKUP_KEEP` environment variables. Defaults
point at `build-01`.

The remote directory is `0700` and the archive `0600`, because `build-01` is outside the ATO
boundary and this is client-private engagement material.

**Restore anywhere:**

```bash
scp encadmin@10.0.20.124:private-backups/canonical-k8s-private-<date>.tar.gz .
./scripts/private-sync.sh unpack -i canonical-k8s-private-<date>.tar.gz
```

`unpack` re-verifies that every restored path is still gitignored on the machine it lands on —
that check is the point of the script, not the tar.

**Run it after any change to the runbook, HANDOFF or the open questions.** Those files never
appear in `git status`, so nothing will remind you.

> **This is a second copy, not an offsite one.** `stage-01` and `build-01` sit on the same
> network in the same room. It removes the single-machine risk; it does not survive the room.
> The Windows working copy is the third leg — see §7 decision 7 in
> `airgapped-setup-machine/README.md`.
