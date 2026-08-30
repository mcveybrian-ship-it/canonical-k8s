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

## 6. Not yet answered

- **Stage B size and cadence** — open question 6. Decides whether the platform bundle fits on a
  thumb drive, needs an SSD, and how often the transfer procedure runs.
- **Whether one stick can carry both ISO and `cidata`.** Would halve the drive count. Test it on
  the pathfinder if you want it; do not assume it.
- **Diagnostic toolset contents** — still undecided, and it must be fixed before the Stage A
  media is built.
