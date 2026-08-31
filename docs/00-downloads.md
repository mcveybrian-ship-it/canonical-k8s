# Software download manifest

**Step 00 of [`START-HERE.md`](../START-HERE.md).** What to download on the connected side,
and how to verify it. Nothing else — running the test is step 01, building hosts is step 02.

Covers only what step 01 needs: the two Ubuntu 24.04 images. Later downloads are listed at
the bottom but deliberately not staged yet.

Verified 2026-08-27. Filenames and point releases change; re-check the index pages rather
than pasting these URLs from memory in six months.

Automated by [`scripts/install/00-fetch-verify-media.sh`](../scripts/install/00-fetch-verify-media.sh),
**run on STAGE-01**.

> **Bash only, and that is the whole answer here.** Step 00 runs on STAGE-01, which is the
> connected staging machine and holds the media anyway. It has native `gpg`, `sha256sum` and
> `curl`, so there is nothing left for a PowerShell equivalent to do.
> `00-fetch-verify-media.ps1` was **retired 2026-08-30** — it could only ever do checksums, not
> signatures, because it could not assume Gpg4win. The Windows sections below are kept as a
> manual fallback for the case where you are verifying on the Windows box before the media
> moves; they need no script.

---

## What to download now

Two images, two different formats. **There is no Ubuntu Minimal ISO** — Minimal is published
only as cloud images, so it is installed by writing the disk image, not by booting an
installer. That difference drives how each one gets deployed.

### 1. Ubuntu Server 24.04.4 LTS — installer ISO

For the three bare-metal **hosts**, `svc-01`, and the step 01 pathfinder machine.

| | |
|---|---|
| Index | <https://releases.ubuntu.com/noble/> |
| File | `ubuntu-24.04.4-live-server-amd64.iso` (3.2 GB) |
| Direct | <https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso> |
| Checksums | `SHA256SUMS`, `SHA256SUMS.gpg` in the same directory |

24.04.4 is the current point release. Do not pin to it in documentation — point releases roll
roughly every six months and the ISO filename changes with them.

### 2. Ubuntu Minimal 24.04 — cloud image

For the six **cluster nodes** (`k8s-cp-01..03`, `k8s-wk-01..03`) in step 06, and for step 01
pass 1 repeated on Minimal — which is what proves USG behaves on the stripped base before the
image-variant decision is locked.

**Both images are used, and both must be verified.** The server ISO builds the three hosts,
`svc-01`, and the pathfinder; the Minimal image builds the six cluster nodes. Neither is
optional.

| | |
|---|---|
| Index | <https://cloud-images.ubuntu.com/minimal/releases/noble/release/> |
| Serial | `20260826` |
| File | `ubuntu-24.04-minimal-cloudimg-amd64.img` (253 MB) — QCow2, UEFI/GPT bootable |
| Direct | <https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img> |
| Checksums | `SHA256SUMS`, `SHA256SUMS.gpg` in the same directory |

Also fetch, from the same directory:

| File | Why |
|---|---|
| `ubuntu-24.04-minimal-cloudimg-amd64.manifest` (8.9 KB) | The exact package list in the image. **Keep this** — it is your baseline software inventory for the ATO package, and the real package inventory. **Measured 2026-08-27 on serial `20260826`: 284 packages.** Canonical's blog says 288 for the cloud-minimal seed — use the manifest count, not the blog. |
| `ubuntu-24.04-minimal-cloudimg-amd64-root.tar.xz` (112 MB) | Root filesystem tarball. Needed if you register the image with MAAS as a custom boot-resource rather than writing the qcow2 directly. |
| `ubuntu-24.04-minimal-cloudimg-amd64.squashfs` (136 MB) | Squashfs variant. Fetch only if the MAAS boot-resource path calls for it — a step 05 decision. |

> **The Minimal image has no point release, and this catches people out.** The server ISO is
> `ubuntu-24.04.4-...` — the `.4` pins it. The Minimal filename is only
> `ubuntu-24.04-minimal-cloudimg-amd64.img`: no point release, ever. Cloud images are
> republished continuously and are identified by the **serial** in the directory path, here
> `20260826`. Two downloads of the same filename weeks apart are different images.
>
> **Consequences for this build:**
>
> - **Record the serial and the SHA-256 together.** "The minimal image" is not a reproducible
>   identifier; `20260826` plus `d2ed9beb...` is. Both go in the ATO software inventory.
> - **Do not re-download it later expecting the same bytes.** Build all six cluster nodes from
>   the one copy you verified, or you will have nodes built from different images with no
>   record of the difference.
> - The `.manifest` file is what tells you the actual package versions inside a given serial.
>   Keep it with the image.

The `release/` path is the current published release. Prefer it over `daily/` — daily builds
change under you.

## Verification

There are **two independent checks**, and they prove different things:

| Check | Proves | Skippable? |
|---|---|---|
| **GPG signature** on `SHA256SUMS` | The checksum list itself is genuinely Canonical's | No — without it, a tampered `SHA256SUMS` matches a tampered ISO perfectly |
| **SHA-256** of the image against that list | Your download is intact and unmodified | No |

Do both on the connected side **before** anything crosses, and keep the output. A signed
checksum manifest is the first supply-chain artefact an assessor asks for, and it is far
easier to produce now than to reconstruct later.

### Where you run these — read this first

The fetch scripts produce **two directories, each with its own `SHA256SUMS`**. They are
different lists covering different files. Every `gpg` and checksum command below is
**relative to the directory you are standing in**, so running one in the wrong place verifies
the wrong list.

Layout produced by the fetch script (sizes from a real run, 2026-08-27):

```
<media-dir>/                                          <- run the SERVER ISO checks here
    ubuntu-24.04.4-live-server-amd64.iso     3,247 MB
    SHA256SUMS                                  594 bytes   6 entries
    SHA256SUMS.gpg                              833 bytes
    MANIFEST.sha256                             628 bytes   (written by the fetch script)
    minimal/                                          <- run the CLOUD IMAGE checks here
        ubuntu-24.04-minimal-cloudimg-amd64.img     253 MB
        ubuntu-24.04-minimal-cloudimg-amd64.manifest
        SHA256SUMS                            2,174 bytes  18 entries
        SHA256SUMS.gpg                          833 bytes
```

`<media-dir>` is wherever you pointed the fetch script — on STAGE-01 that is a local path; on
the Windows fallback path it was `E:\media`, and the Windows sections below still use that.

> **Both `SHA256SUMS` files list far more than you downloaded.** The server list has **6
> entries** (24.04.3 and 24.04.4, desktop/server/WSL) and you downloaded 1. The minimal list
> has **18 entries** (amd64 and arm64, img/squashfs/root.tar.xz/manifests) and you downloaded
> 2 — measured on a real run, 2026-08-27. A bare `sha256sum -c SHA256SUMS` therefore reports
> "No such file or directory" for everything you skipped and exits non-zero. **That is not a
> failure of your download.** The commands below check only what is actually present.

### Which path applies to you

| Your machine | Signature check | Checksum check |
|---|---|---|
| **STAGE-01 — do it here** | `gpg`, installed 2026-08-30 | `00-fetch-verify-media.sh` |
| Windows + Gpg4win | `gpg` — see install below | `Get-FileHash`, manual |
| Windows, no Gpg4win | **Defer** — do it on STAGE-01 | `Get-FileHash`, manual |

**The bootstrap problem this table used to describe is gone.** It assumed the Windows box was
the connected side and that you had no Linux machine until the ISO was written — so signatures
got deferred to the pathfinder and the ISO travelled one hop unverified. STAGE-01 is now the
connected side and has native `gpg`, so signature and checksum both happen before the media
moves, which is the correct supply-chain posture and what the ATO evidence package wants.

Deferring is now only a fallback, and there is no longer a reason to reach for it.

### Linux / macOS

```bash
cd /path/to/media                      # the directory holding the ISO and its SHA256SUMS

# 1. Import Canonical's CD image signing keys
gpg --keyid-format long --keyserver hkp://keyserver.ubuntu.com \
    --recv-keys 0x46181433FBB75451 0xD94AA3F0EFE21092

# 2. Check the fingerprints BEFORE trusting anything they signed
gpg --keyid-format long --list-keys --with-fingerprint 0x46181433FBB75451 0xD94AA3F0EFE21092

# 3. Verify the signature on the checksum list
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS

# 4. Check every file you actually downloaded here, skipping the minimal/ subdirectory
for f in *; do
  case "$f" in SHA256SUMS*|MANIFEST.sha256) continue ;; esac
  [ -d "$f" ] && continue
  grep " \*\?$f\$" SHA256SUMS | sha256sum -c
done
```

Step 2 must produce exactly:

```
DSA  C598 6B4F 1257 FFA8 6632  CBA7 4618 1433 FBB7 5451
RSA  8439 38DF 228D 22F7 B374  2BC0 D94A A3F0 EFE2 1092
```

Step 4 output on a correct download:

```
ubuntu-24.04.4-live-server-amd64.iso: OK
```

Then the **cloud image**, in the `minimal/` subfolder the fetch scripts create. Its own
checksum list, its own — **different** — signing key:

```bash
cd /path/to/media/minimal

# Signature: expect "Can't check signature: No public key" - see the note at the end of
# this section. Do not blindly import the key the error names.
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS

# Checksum every file you actually downloaded here, whichever they are.
# SHA256SUMS lists 18 files; you downloaded 2. Filtering to what is present is the point.
for f in *; do
  case "$f" in SHA256SUMS*|MANIFEST.sha256) continue ;; esac
  grep " \*\?$f\$" SHA256SUMS | sha256sum -c
done
```

Expected on a correct download — both files, not just the image:

```
ubuntu-24.04-minimal-cloudimg-amd64.img: OK
ubuntu-24.04-minimal-cloudimg-amd64.manifest: OK
```

Automated by [`00-fetch-verify-media.sh`](../scripts/install/00-fetch-verify-media.sh), which
checks the imported fingerprints against those values rather than trusting whatever the
keyserver returns, and which stops rather than auto-importing the cloud-image key.

### Windows — manual fallback

Everything from here to "Next" is the **fallback path**, kept because the Windows box remains
the seed-stick writer and you may want to verify media there before it moves. It is entirely
manual — no script backs it any more. Prefer STAGE-01 above.

#### Install Gpg4win

Confirmed available via winget as `GnuPG.Gpg4win`, version 5.1.0 as of 2026-08-27:

```powershell
winget install --id GnuPG.Gpg4win --exact
```

**Open a new PowerShell window afterwards.** The installer adds `gpg.exe` to PATH and your
current session will not see it. Confirm with `gpg --version`.

#### Verify the server ISO

```powershell
cd E:\media                            # the directory with the ISO and its SHA256SUMS

# 1. Import Canonical's CD image signing keys.
#    PowerShell continues lines with a BACKTICK, not a backslash.
gpg --keyid-format long --keyserver hkp://keyserver.ubuntu.com `
    --recv-keys 0x46181433FBB75451 0xD94AA3F0EFE21092

# 2. Check the fingerprints BEFORE trusting anything they signed.
#    Do not skip this - a keyserver can hand back any key for a given ID.
gpg --keyid-format long --list-keys --with-fingerprint 0x46181433FBB75451 0xD94AA3F0EFE21092

# 3. Verify the signature on the checksum list
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS

# 4. Compare the checksum for the one file you downloaded
(Select-String -Path .\SHA256SUMS -Pattern 'live-server-amd64.iso').Line
(Get-FileHash .\ubuntu-24.04.4-live-server-amd64.iso -Algorithm SHA256).Hash
```

Step 2 must match the two fingerprints above. Step 3 should say
`Good signature from "Ubuntu CD Image Automatic Signing Key"`. In step 4 the two hashes must
match — PowerShell prints uppercase and `SHA256SUMS` is lowercase, which does not matter; the
hex digits do. For reference, `ubuntu-24.04.4-live-server-amd64.iso` should be
`e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433`.

> **The "not certified" warning is normal, not a failure.** Step 3 also prints
> *"WARNING: This key is not certified with a trusted signature!"* That only means you have
> not marked the key as trusted in your personal GPG web of trust. The fingerprint comparison
> in step 2 is what establishes trust here. A **BAD signature** is a failure; this warning is
> not.

#### The cloud image

Different folder, different `SHA256SUMS`, **different signing key**. The fetch script puts it
in a `minimal` subfolder of your download directory:

```powershell
cd E:\media\minimal

# Signature - expect this one to FAIL with "No public key". See the note below.
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS

# Checksum every file you actually downloaded here.
# SHA256SUMS lists 18 files; you downloaded 2. Filtering to what is present is the point.
Get-ChildItem -File | Where-Object { $_.Name -notlike 'SHA256SUMS*' } | ForEach-Object {
    $row = Select-String -Path .\SHA256SUMS -Pattern ([regex]::Escape($_.Name)) | Select-Object -First 1
    if (-not $row) { "{0,-58} NOT LISTED" -f $_.Name; return }
    $expected = ($row.Line -split '\s+')[0].ToLower()
    $actual   = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    if ($expected -eq $actual) { "{0,-58} OK" -f $_.Name } else { "{0,-58} MISMATCH" -f $_.Name }
}
```

Run and confirmed working on 2026-08-27. Expected output:

```
ubuntu-24.04-minimal-cloudimg-amd64.img                    OK
ubuntu-24.04-minimal-cloudimg-amd64.manifest               OK
```

Reference values for serial `20260826`:

| File | SHA-256 |
|---|---|
| `ubuntu-24.04-minimal-cloudimg-amd64.img` | `d2ed9bebd51635f75b48ef0b27a58f03e27a32a2a6544c507d117d323eeac714` |
| `ubuntu-24.04-minimal-cloudimg-amd64.manifest` | `76ffd053ebcac90c322c38d1258f69d0de162afc7f7c8353cd5a9bdb717c1363` |

`Get-FileHash` prints uppercase, `SHA256SUMS` is lowercase — the comparison above lowercases
both, so that is handled.

> **The cloud-image signing key is a different key.** The fingerprints above are the Ubuntu
> **CD image** keys and cover the server ISO only. `cloud-images.ubuntu.com` signs with its
> own key, which is deliberately not recorded here because it has not been checked against a
> Canonical-published fingerprint. `00-fetch-verify-media.sh` reports the key ID that signed
> the cloud-image `SHA256SUMS` and stops rather than importing it. **Confirm that fingerprint
> against a Canonical source before trusting it** — auto-importing whatever key signed a file
> proves only that the file is self-consistent with itself.

## Next

When step 00 is verified, go to [`01-pathfinder.md`](01-pathfinder.md).

## Not downloaded yet

Listed so nothing is forgotten. Do not fetch these until the step that consumes them is
written and its blockers are cleared.

| Needed by | What | Blocked on |
|---|---|---|
| Step 06/07 | `k8s` snap + base snaps (`core22`/`core24` — confirm with `snap info k8s`) | Q8, the FIPS channel question |
| Step 08 | `microceph` snap; `maas` snap if installing MAAS from snap | — |
| Step 07 | Container images from `k8s list-images`, mirrored to Harbor | Q8 |
| Step 08 | ceph-csi RBAC manifests — must be carried, not applied from GitHub (runbook §9) | — |
| Step 05 | Harbor offline installer | Harbor section undrafted |
| Step 05 | Landscape, Enterprise Store / `store-admin` | KB-gated procedure, Q9 |
| Step 05 | MAAS boot images — **both** the server stream and the Minimal image | Q9, §11.3 |
| Step 06 | Node diagnostic toolset for the Minimal nodes | Not yet decided — runbook §2.4 |
| Step 03 | FIPS and USG packages via the Pro air-gapped path | Q9, Q11, Q12 |
