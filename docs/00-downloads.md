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

### 3. Grafana 13.2.1 — standalone `.deb`

**Added 2026-09-14, retrospectively.** This was carried into the enclave before it was written
down here, which meant a rebuild from a fresh download run would have reached
`monitoring.sh collector` and found nothing to install. It is recorded now so that cannot
happen again.

| | |
|---|---|
| Index | <https://grafana.com/grafana/download?platform=linux> |
| File | `grafana_13.2.1_33191028959_linux_amd64.deb` (375 MB) |
| SHA-256 | `b4f088f661c5103746f23cb5cbbe2b2bb2e18ba9870ad68a3c2a90451f511ded` |
| Staged to | `$MIRROR_BASE/debs/` on `stage-01`, from where `build-transfer-bundle.sh` carries it |
| Installed to | `/srv/repo/debs/` on `svc-repo-01`, fetched over TLS by `monitoring.sh collector` |

> **Carried as a file, not installed from Grafana's apt repository — deliberately.** Adding
> `packages.grafana.com` would put a third-party signing key in the trust store of a machine
> inside the ATO boundary. **The SHA-256 above is the control**, and it is enforced in
> `scripts/enclave/monitoring.sh` (`GRAFANA_SHA`): the install refuses on a mismatch rather
> than warning. Verified against the staged copy on 2026-09-14.
>
> **The build number in the filename is part of the identity.** `13.2.1` alone does not
> identify these bytes; `33191028959` does. Same trap as the Minimal image serial above.

Everything else the monitoring stack needs — `prometheus`, `prometheus-alertmanager`,
`prometheus-node-exporter`, `prometheus-libvirt-exporter`, `nginx` — comes from the apt mirror's
`universe` component and needs no separate download.

What the stack is and what it measures: [`compliance/dashboards-and-metrics.md`](compliance/dashboards-and-metrics.md).

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

## STIG and SRG content to collect from cyber.mil — the CAC trip

**One trip, one list.** Everything below comes from <https://public.cyber.mil/stigs/downloads/>
and **requires a CAC** — the anonymous download path is gone. Give this to whoever holds the
card.

**Two formats, and they are not interchangeable:**

- **SCAP benchmark** (`*_STIG_SCAP_*-xccdf.xml` inside a zip) — machine-readable, drives an
  automated scan. Only some products have one.
- **STIG zip** (`U_*_STIG_V#R#_Manual-xccdf.xml`) — the manual XCCDF. **Take this for every row
  below, even where a SCAP benchmark also exists.** `StigContent/Manual/` consumes it and
  `answerfile.sh` writes portable `ValidationCode` against it, so the manual XCCDF is what this
  enclave actually assesses from.

> ⚠️ **Do not trust any version number written in this repository.** DISA re-releases
> frequently and the revision recorded here is the one that was current when the line was
> typed. **Take whatever is current on the day**, then record what was actually taken in
> `HANDOFF.md` §3. The version numbers below are stated only so a wrong file is obvious.

### The list, ordered by what it unblocks

| # | Target | What to download | Why we need it | Blocks |
|---|---|---|---|---|
| 1 | **Kubernetes** | **Kubernetes STIG** — manual XCCDF | Canonical maps it to **91 guidelines**: 62 Default, 13 Bootstrap, 10 Post-Deployment, 6 N/A. **The 13 Bootstrap guidelines must be correct AT CLUSTER CREATION** and cannot be retrofitted | 🔴 **Step 06/07.** Getting it wrong means rebuilding the cluster. Highest priority on this list |
| 2 | **PostgreSQL 16** | **Crunchy Data PostgreSQL 16 STIG** (covers 13–16) | The pg HA guests and `svc-mgmt-01`'s MAAS database. Without it the database layer has an OS STIG and **no application STIG** | 🔴 **Step 06a.** Already owed since 2026-09-14 |
| 3 | **nginx** | **Web Server SRG** | No nginx STIG exists. `svc-repo-01` serves the mirror over nginx and Harbor fronts itself with it | Assessment of two machines already built |
| 4 | **Docker CE** | **Container Platform SRG** | The Docker Enterprise 2.x STIG **does not apply to CE**. `svc-harbor-01` runs Docker CE | Assessment of `svc-harbor-01` |
| 5 | **PostgreSQL 18.3** | **Database SRG** | Harbor's bundled Postgres is 18.3 and **no STIG covers 18**. The version is not ours to choose — it ships inside `goharbor/harbor-db:v2.15.2` | Written rationale for an appliance-internal database |
| 6 | **KVM / libvirt / QEMU** | **General Purpose Operating System SRG** | Needed to **cite** the position, not to scan. No hypervisor STIG or SRG exists; `host-4` is governed through the OS STIG. §3a: *"cite the absence of hypervisor guidance, do not report a gap"* | The SSP's hypervisor paragraph |
| 6a | **The 800-53 mapping itself** | **CCI List** (Control Correlation Identifiers) | 🔴 **This is how STIG results become 800-53 evidence, mechanically.** Every CKL/CKLB Evaluate-STIG has produced already carries `CCI_REF` per finding; the CCI List is the translation table from those to 800-53 controls. Without it, five machines of assessed evidence has to be mapped by hand | The entire 800-53 control-mapping effort — see [`compliance/nist-800-53-plan.md`](compliance/nist-800-53-plan.md) |
| 7 | **Ubuntu 24.04** | **Ubuntu 24.04 LTS STIG** — ✅ **already in hand at V1R6** via Evaluate-STIG | Take the standalone zip anyway, so the accreditation package cites a file rather than a tool's bundled copy | Nothing — completeness of the package |

### Three more to ask the AO about before buying a trip for them

Not on the list above because **whether they apply is a boundary question, not a technical
one** — and guessing wrong either wastes the trip or leaves a gap:

| | Question for the AO |
|---|---|
| **Network device STIGs** (router / switch / firewall) | The enclave sits behind its own router (§3.1). **Is that router inside the accreditation boundary?** If yes, its STIG applies and it is a gap today. If it is programme-managed infrastructure, it is inherited. |
| **Traditional Security Checklist** | Physical and environmental security is commonly required in a DoD package. Ask whether it is expected here or inherited from the facility's existing ATO. |
| **Application Security and Development STIG** | Likely **N/A** — this enclave runs no locally-developed application; the shell scripts are build automation, not a fielded system. Confirm rather than assume, because "we decided it was N/A" needs to be someone's decision on the record. |

### Hand this to the CAC holder — copy-paste email

**The strategy is one download, not eight.** DISA publishes a **"SRG/STIG Library
Compilation"** — a single quarterly archive containing every STIG and every SRG. For someone
who does not know this material, hunting eight individual files is how you get seven of them
and a second trip. Take the whole library, and we extract what we need on our side.

**The CCI List is NOT inside the compilation** and has to be taken separately. That is the one
item most likely to be forgotten, and it is the one that makes STIG results into 800-53
evidence.

```text
Subject: DoD cyber.mil downloads needed - one trip, ~4 items

Hi -

I need some files from DISA's public cyber.mil site. You'll need your CAC and a
card reader on whatever machine you use. Everything here is unclassified and
publicly releasable; the CAC is just how they gate the download now.

Please DON'T unzip anything. Bring the .zip files exactly as downloaded - we
verify them by checksum on our side and unzipping breaks that.

--------------------------------------------------------------------
ITEM 1 - THE BIG ONE (this is the whole job in one file)
--------------------------------------------------------------------
Go to:  https://public.cyber.mil/stigs/downloads/

Look for an entry called:
    "SRG/STIG Library Compilation"
(it may read "Compilation", "Library Compilation", or show a quarter and year,
e.g. "... Compilation - January 2026")

Download the most recent one. It is large - expect somewhere between several
hundred MB and a few GB - and it contains every STIG and every SRG in one
archive. That is deliberate: it means you don't have to find individual files.

If you see BOTH a "SCAP" compilation and a non-SCAP one, TAKE BOTH.

--------------------------------------------------------------------
ITEM 2 - THE CCI LIST (separate, and easy to miss)
--------------------------------------------------------------------
This is NOT in the compilation above. It's its own download.

On the same site, find:  "Control Correlation Identifier" or "CCI"
Direct page, if it still works:  https://public.cyber.mil/stigs/cci/

The file is usually named something like:  U_CCI_List.zip

Please make sure you get this one. It's small and it's the piece everything
else depends on.

--------------------------------------------------------------------
ITEM 3 - DoD CERTIFICATE BUNDLE (only if the site warns you)
--------------------------------------------------------------------
If your browser complains about certificates on cyber.mil, there's a package
called "DoD Certificates" or "PKI CA Certificate Bundles" on the same site.
Grab it. If you get no warnings, skip this.

--------------------------------------------------------------------
ITEM 4 - IF, AND ONLY IF, ITEM 1 IS UNAVAILABLE
--------------------------------------------------------------------
If there's no compilation archive, download these individually. Search the
downloads page for each name. Take the NEWEST version of each - the version
numbers look like "V1R6" and higher R numbers are newer.

  1. Kubernetes STIG                     <- most important, don't miss it
  2. Crunchy Data PostgreSQL 16 STIG     (may be listed under "Crunchy Data")
  3. Web Server SRG
  4. Application Server SRG              (take it if you see it, cheap insurance)
  5. Container Platform SRG
  6. Database SRG
  7. General Purpose Operating System SRG
  8. Canonical Ubuntu 24.04 LTS STIG

For each one, if the page offers both a "STIG" zip and a "SCAP Benchmark" zip,
TAKE BOTH.

--------------------------------------------------------------------
WHEN YOU'RE DONE - two things that save us a second trip
--------------------------------------------------------------------
1) Send me the exact filename of every file you downloaded. Copy-paste the
   list; don't retype it. The version numbers matter to us.

2) Generate a checksum for each file so we can confirm nothing corrupted in
   transit. On Windows, open Command Prompt in the download folder and run:

       certutil -hashfile "FILENAME.zip" SHA256

   Do that for each file and paste me the output.

Put everything on a USB drive or external disk - don't email the files, some
are too big.

Thanks -
```

**Why "take both" appears twice:** a product page often offers a manual STIG zip *and* a SCAP
benchmark zip, and they contain different things. The manual XCCDF is what `StigContent/Manual/`
consumes; the SCAP benchmark is what drives an automated scan. Asking for both costs nothing and
removes the most likely reason for a second trip.

### When the files arrive

1. **Record what was actually taken** — product, version, revision, release date, and the SHA-256
   of each zip — into `HANDOFF.md` §3. The package has to cite a specific benchmark, not "the
   current STIG".
2. Place the manual XCCDFs under `StigContent/Manual/` (runbook §10.1).
3. **Re-run the coverage matrix in `HANDOFF.md` §3a** and change every ⬜ that is now satisfied.
4. The Kubernetes STIG gets **read before step 06 runs**, not after — that is the whole point of
   it being first on the list.

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
| Step 09a | **Trivy CLI** — a standalone binary or `.deb`, plus a current `trivy-db` OCI artifact. Discovered 2026-09-15: Trivy exists in this enclave **only inside Harbor's container**, so nothing can scan the machines' own filesystems for vulnerabilities. USG and Evaluate-STIG assess configuration, not patch state. The DB is an OCI artifact and can be mirrored into Harbor like any other image | **Q27** — the AO decision on scanning against data of a known age sets the cadence |
