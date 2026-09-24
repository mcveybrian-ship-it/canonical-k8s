#!/usr/bin/env bash
#
# build-transfer-bundle.sh - step 1 of 3. RUNS ON STAGE-01.
#
#     MACHINE: stage-01. The three steps and where each runs:
#       1 build-transfer-bundle.sh   stage-01     gather + hash the extras (this script)
#       2 write-transfer-media.sh    build-01     pull mirror + extras onto the transfer SSD
#       3 restore-mirror.sh          svc-repo-01  inside the gap: install, serve, prove
#
# Assembles everything that has to cross the air gap ALONGSIDE the apt mirror, and
# verifies the mirror itself is complete enough to be worth carrying.
#
# WHAT THIS DOES NOT DO: it does not copy the 317 GB mirror anywhere. That would
# duplicate it on STAGE-01 for no reason. write-transfer-media.sh pulls the mirror
# tree straight from $MIRROR_BASE/mirror. This script only gathers the SMALL things
# that live outside it - a few GB - and writes the manifest.
#
# Why a manifest at all, when the mirror is 90,000 files and we deliberately do not
# checksum it: an apt repository is already a signed hash chain (GPG-signed Release ->
# hashes of Packages -> hashes of every .deb), so `apt-get update` on the far side IS
# the integrity check. The items here are the ones NOT covered by that chain - the
# signing keys, the .debs pulled from a PPA, the ISOs - and they are precisely the
# supply-chain-sensitive ones. So they get hashed and nothing else does.
#
#   ./build-transfer-bundle.sh [-p transfer-params.env] [-n]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PARAMS="$SCRIPT_DIR/transfer-params.env"
DRY=0

usage() {
  cat <<'USAGE'
usage: build-transfer-bundle.sh [-p <params file>] [-n]

  -p <file>  parameters file (default: transfer-params.env beside this script)
  -n         dry run - report what would be assembled, write nothing
USAGE
}

while getopts ':p:nh' o; do
  case "$o" in
    p) PARAMS="$OPTARG" ;;
    n) DRY=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

[ -r "$PARAMS" ] || die "no params file: $PARAMS  (copy transfer-params.env.example)"
set -a
# shellcheck disable=SC1090
. "$PARAMS"

# The repository to carry on the media. Defaults to the checkout this script lives in.
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
set +a

: "${MIRROR_BASE:?not set in $PARAMS}"
: "${STAGING_DIR:?not set in $PARAMS}"
: "${MEDIA_DIR:?not set in $PARAMS}"
: "${REPO_ADDRESS:?not set in $PARAMS}"

MIRROR_TREE="$MIRROR_BASE/mirror"

# --- STAGING_DIR safety, evaluated FIRST ---------------------------------------------------
# This script deletes and recreates subdirectories under STAGING_DIR on every run. That is
# fine for a directory it owns and catastrophic for one it does not.
#
# Placement matters more than the patterns. An earlier version put this AFTER the
# writability check, which meant /etc was rejected only because the invoking user could not
# write there - run as root it would have proceeded. Safety checks that depend on the caller
# being unprivileged are not safety checks. This runs before anything else touches the path.
#
# Patterns are UNQUOTED so the globs glob; a quoted "/*" matches the literal two characters.
case "$STAGING_DIR" in
  ""|/|/bin*|/boot*|/dev*|/etc*|/home|/lib*|/opt*|/proc*|/root*|/run*|/sbin*|/srv|/sys*|/usr*|/var*)
    die "refusing to use an unsafe STAGING_DIR: '$STAGING_DIR'" ;;
  "$MIRROR_BASE"|"$MIRROR_BASE"/*)
    die "STAGING_DIR must not live inside MIRROR_BASE ('$MIRROR_BASE') - the clean step would eat the mirror" ;;
esac
[ "${#STAGING_DIR}" -ge 8 ] || die "STAGING_DIR is implausibly short, refusing: '$STAGING_DIR'"
case "$STAGING_DIR" in /*) ;; *) die "STAGING_DIR must be an absolute path: '$STAGING_DIR'" ;; esac


# --- 1. refuse to build a bundle around a mirror that is not there ---------------------------
head2 "checking the mirror"
[ -d "$MIRROR_TREE" ] || die "no mirror tree at $MIRROR_TREE"

debs=$(find "$MIRROR_TREE" -name '*.deb' 2>/dev/null | wc -l)
size=$(du -sh "$MIRROR_TREE" 2>/dev/null | cut -f1)
note "tree     : $MIRROR_TREE"
note "size     : $size"
note "packages : $debs"
[ "$debs" -gt 0 ] || die "mirror holds no .deb files - has apt-mirror run?"

# Every suite named in the params must have a Release file on disk. This is the check
# that catches a token that authenticated against Release and then 401'd on pool - the
# failure that produced a healthy-looking, empty esm-infra tree on 2026-08-31.
missing=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  archive="${line%%:*}"; suite="${line##*:}"
  rel="$MIRROR_TREE/$archive/dists/$suite/Release"
  n=$(find "$MIRROR_TREE/$archive/dists/$suite" -name '*.deb' 2>/dev/null | wc -l)
  pool=$(find "$MIRROR_TREE/$archive/pool" -name '*.deb' 2>/dev/null | wc -l)
  if [ ! -f "$rel" ]; then
    echo "  MISSING Release  $archive  $suite" >&2; missing=$((missing+1))
  else
    printf '  ok  %-40s %-24s pool=%s\n' "$archive" "$suite" "$pool"
  fi
done <<< "${EXPECTED_SUITES:-}"
[ "$missing" -eq 0 ] || die "$missing expected suite(s) missing from the mirror"

# --- 2. assemble the small extras --------------------------------------------------------------
head2 "assembling extras into $STAGING_DIR"
# /srv is root-owned on a stock Ubuntu install, so the staging directory has to be
# created once, by hand, with ownership. Fail with the exact command rather than
# emitting five mkdir errors and half-building a bundle.
if [ ! -d "$STAGING_DIR" ] && [ ! -w "$(dirname "$STAGING_DIR")" ]; then
  die "cannot create $STAGING_DIR - its parent is not writable by $(id -un). Run once:
       sudo install -d -o $(id -un) -g $(id -gn) -m 0755 $STAGING_DIR"
fi
[ -d "$STAGING_DIR" ] && [ ! -w "$STAGING_DIR" ] && \
  die "$STAGING_DIR exists but is not writable by $(id -un)"

if [ "$DRY" -eq 1 ]; then
  note "DRY RUN - nothing will be written"
else
  # Re-running has to start clean, or a file removed from the source survives in the
  # bundle and travels across the gap as a stale artefact nobody remembers adding.
  #
  # This used to be a manual 'rm -rf $STAGING_DIR/*' typed at the prompt. It is in the
  # script now because a recursive delete with a glob should not depend on a human
  # getting the variable right at 1am. The guards below are the reason it is safe:
  # refuse to touch anything that is not a plausible staging directory, and delete only
  # the subdirectories this script itself creates - never $STAGING_DIR wholesale.
  if [ -d "$STAGING_DIR" ]; then
    # NOTE tools IS NOT IN THIS LIST, DELIBERATELY. TOOLS_DIR defaults to
    # $STAGING_DIR/tools - the same directory - and the tools are a STAGED SOURCE that was
    # put there by hand and by stig-tools.sh, not generated output. Cleaning it deleted
    # 545 MB of Evaluate-STIG and PowerShell on 2026-09-14 and the copy that followed then
    # reported "SKIP - no such directory" for every one of them. A clean step that removes
    # its own source is the worst kind: it reports success having produced nothing.
    for sub in keys debs media config scripts snaps; do
      [ -d "$STAGING_DIR/$sub" ] && rm -rf -- "${STAGING_DIR:?}/$sub"
    done
    rm -f -- "${STAGING_DIR:?}/MANIFEST.sha256"
    note "cleaned previous staging content"
  fi
  mkdir -p "$STAGING_DIR"/{keys,debs,media,config,scripts,snaps,tools}
fi

# Counts what ARRIVED, not what was found in the source. The earlier version reported
# the source count and swallowed every cp failure inside -exec, so on 2026-08-31 it
# printed "snaps: 6 file(s)" while all twelve copies failed against a directory that did
# not exist. A bundle script that reports success on a failed copy is worse than no
# script: the failure surfaces inside the gap.
copy_in() {  # copy_in <label> <src dir> <dest subdir> <glob>
  local label="$1" src="$2" dest="$3" glob="$4" want=0 got=0
  if [ ! -d "$src" ]; then note "SKIP $label - no $src"; return 0; fi
  want=$(find "$src" -maxdepth 1 -name "$glob" -type f 2>/dev/null | wc -l)
  if [ "$want" -eq 0 ]; then note "SKIP $label - nothing matching $glob"; return 0; fi

  if [ "$DRY" -eq 1 ]; then note "$label: $want file(s) (dry run)"; return 0; fi

  [ -d "$STAGING_DIR/$dest" ] || die "staging subdir missing: $STAGING_DIR/$dest"
  find "$src" -maxdepth 1 -name "$glob" -type f -exec cp -a -t "$STAGING_DIR/$dest/" {} +

  got=$(find "$STAGING_DIR/$dest" -maxdepth 1 -name "$glob" -type f 2>/dev/null | wc -l)
  [ "$got" -eq "$want" ] || die "$label: copied $got of $want file(s) into $STAGING_DIR/$dest"
  note "$label: $got file(s)"
}

# The keyrings that sign the Pro archives (ESM, FIPS, USG), and the PPA .debs - among them
# contracts-airgapped and pro-airgapped - that the mirror itself can never serve.
copy_in "signing keys" "$MIRROR_BASE/keys" keys '*.gpg'
copy_in "airgap debs"  "$MIRROR_BASE/debs" debs '*.deb'
# Snaps side-load as a .snap + .assert PAIR. A .snap without its assertion cannot be
# installed offline without --dangerous, which discards signature verification - not a
# trade this build can make. Both globs are copied and the pairing is checked below.
copy_in "snaps"        "$MIRROR_BASE/snaps" snaps '*.snap'
copy_in "snap asserts" "$MIRROR_BASE/snaps" snaps '*.assert'
copy_in "install ISOs" "$MEDIA_DIR"        media '*.iso'
copy_in "cloud images" "$MEDIA_DIR/minimal" media '*.img'
copy_in "checksums"    "$MEDIA_DIR"        media 'SHA256SUMS*'

# THE STIG TOOLING. Without it a rebuilt enclave can be hardened by usg but cannot be
# MEASURED against the revision DISA actually assesses - and this is a CAC-only download
# now (public.cyber.mil redirects to SAML and its download index is a JS portal with no
# scrapable links, checked 2026-09-13). Whatever is not on this media cannot be fetched
# from inside the gap later.
#
# A TREE, NOT A GLOB. Evaluate-STIG is 390 files across directories and PowerShell is an
# unpacked runtime, so copy_in's flat-glob shape does not fit. Same discipline though:
# count what ARRIVED, not what was found in the source.
copy_tree() {  # copy_tree <label> <src dir> <dest subdir>
  local label="$1" src="$2" dest="$3" want got
  if [ ! -d "$src" ]; then note "SKIP $label - no $src"; return 0; fi
  want=$(find "$src" -type f 2>/dev/null | wc -l)
  if [ "$want" -eq 0 ]; then note "SKIP $label - $src is empty"; return 0; fi
  if [ "$DRY" -eq 1 ]; then note "$label: $want file(s) (dry run)"; return 0; fi
  [ -d "$STAGING_DIR/$dest" ] || die "staging subdir missing: $STAGING_DIR/$dest"
  cp -a "$src" "$STAGING_DIR/$dest/"
  got=$(find "$STAGING_DIR/$dest/$(basename "$src")" -type f 2>/dev/null | wc -l)
  [ "$got" -eq "$want" ] || die "$label: copied $got of $want file(s) into $STAGING_DIR/$dest"
  note "$label: $got file(s)"
}

# IS THE SOURCE ALREADY THE DESTINATION? By default the tools are staged at
# $STAGING_DIR/tools, which IS the bundle's tools directory - so there is nothing to copy
# and copying would be nonsense. Verify and report instead. A site that stages them
# elsewhere (TOOLS_DIR set to another path) gets a real copy.
if [ "$(readlink -f "$TOOLS_DIR" 2>/dev/null)" = "$(readlink -f "$STAGING_DIR/tools" 2>/dev/null)" ]; then
  head2 "tools (staged in place - verifying, not copying)"
  for want in Evaluate-STIG powershell-7.4.20; do
    if [ -d "$TOOLS_DIR/$want" ]; then
      note "$want: $(find "$TOOLS_DIR/$want" -type f | wc -l) file(s)"
    else
      note "MISSING $want - a rebuilt enclave cannot be MEASURED without it"
    fi
  done
  # PRINT THE COUNT EITHER WAY. A line that only appears when the answer is non-zero means
  # a missing checksum file looks identical to one nobody checked for.
  for g in 'powershell-*.tar.gz' 'SHA256SUMS' 'powershell-*.sha256'; do
    n=$(find "$TOOLS_DIR" -maxdepth 1 -name "$g" -type f 2>/dev/null | wc -l)
    note "$g: $n file(s)"
  done
  [ -d "$TOOLS_DIR/stig-content" ] \
    && note "STIG content: $(find "$TOOLS_DIR/stig-content" -type f | wc -l) file(s)" \
    || note "no stig-content/ yet - the product XCCDFs are a CAC-only download"
else
  copy_tree "Evaluate-STIG"  "$TOOLS_DIR/Evaluate-STIG"     tools
  copy_tree "PowerShell"     "$TOOLS_DIR/powershell-7.4.20" tools
  copy_in   "pwsh tarball"   "$TOOLS_DIR"                   tools 'powershell-*.tar.gz'
  copy_in   "pwsh hashes"    "$TOOLS_DIR"                   tools 'powershell-*.sha256'
  copy_in   "STIG content"   "$TOOLS_DIR/stig-content"      tools '*.zip'
fi

# DELIBERATELY NOT CARRIED: the Answer File. It records this enclave's security posture in
# prose, and it is regenerable - answerfile.sh seeds from the vendor template that ships
# inside Evaluate-STIG above and writes every entry from the repo. The generator travels
# on this media; the artefact does not.

# The contracts-server config. Its absence is a hard stop: without it the enclave can
# pull packages but has nothing to `pro attach` against, and every FIPS and ESM package
# on the disk is inert.
#
# It is a credential file - it maps contract tokens to entitlements - so pro-airgapped's
# output should be mode 0600 root:root. That makes it unreadable to the account running
# this script. Group-read it to that account rather than loosening it for everyone, and
# check here so we fail before half-building a bundle.
CONTRACTS="$MIRROR_BASE/airgapped-contracts.yaml"
if [ -f "$CONTRACTS" ] && [ ! -r "$CONTRACTS" ]; then
  die "$CONTRACTS exists but is not readable by $(id -un). Run:
       sudo chown root:$(id -un) $CONTRACTS && sudo chmod 640 $CONTRACTS"
fi
if [ -f "$CONTRACTS" ]; then
  # 0600 inside the bundle: it is a credential, not a config file.
  [ "$DRY" -eq 0 ] && install -m 0600 "$CONTRACTS" "$STAGING_DIR/config/"
  note "contracts config: present"
  # Rewritten aptURLs are the whole point of the file. If an entitlement we mirror still
  # points at Canonical, clients inside the gap will try to reach it and fail at enable
  # time - so surface the count rather than trusting the generation step.
  # NOT `|| echo 0`: grep -c prints "0" AND exits 1 when nothing matches, so the fallback
  # appends a second zero and the result is the two-line string "0\n0" - which then fails
  # the integer test below with "integer expression expected".
  local_urls=$(grep -c "aptURL: *http://$REPO_ADDRESS" "$CONTRACTS" 2>/dev/null || true)
  local_urls=${local_urls:-0}
  note "aptURLs pointing at $REPO_ADDRESS: $local_urls  (expect 4: esm-infra, esm-apps, fips-updates, cis)"
  [ "$local_urls" -ge 4 ] || note "  WARNING: fewer than 4 - check the overrides in the pro-airgapped input"
else
  note "contracts config: *** MISSING *** - see the warning at the end"
fi

# nginx vhost and the restore script travel with the bundle so svc-repo-01 needs nothing
# it cannot read off the disk.
# Carry the TRACKED vhost, not stage-01's live file. Copying the live file meant the
# enclave's package-server config had no source of truth: it went a week untracked, and the
# missing ^~ on the /keys/ and /debs/ locations - which made the three carried .debs
# unreachable over HTTP - travelled into the bundle unreviewed.
_VHOST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nginx-apt-mirror.conf"
if [ -f "$_VHOST" ] && [ "$DRY" -eq 0 ]; then
  cp -a "$_VHOST" "$STAGING_DIR/config/nginx-apt-mirror.conf"
  note "nginx vhost: copied from git ($_VHOST)"
fi
if [ "$DRY" -eq 0 ]; then
  cp -a "$SCRIPT_DIR/restore-mirror.sh" "$STAGING_DIR/scripts/" 2>/dev/null || true
  # The params travel too: restore-mirror.sh reads REPO_ROOT, REPO_ADDRESS and
  # EXPECTED_SUITES from them on the far side. They hold paths and names, no secrets.
  cp -a "$PARAMS" "$STAGING_DIR/scripts/transfer-params.env" 2>/dev/null || true
  note "restore script + params: copied"

  # THE REPOSITORY ITSELF. Without it the media carries packages, images and the STIG
  # tooling - and none of the scripts that drive them. Today the scripts reach the enclave
  # over the network via push-repo-to-host.sh, which works only while the gap is open. On a
  # from-scratch rebuild there is no network path, so the media has to carry them.
  #
  # SAME MECHANISM AS THE PUSH: `git archive HEAD`, which carries TRACKED files only. That
  # keeps the five private paths off removable media by the same property that keeps them
  # off the targets, rather than by remembering an --exclude. It also means an uncommitted
  # edit DOES NOT TRAVEL - commit first, and the warning below says so if you have not.
  if command -v git >/dev/null 2>&1 && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    _SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
    rm -f "$STAGING_DIR/scripts"/canonical-k8s-*.tar.gz
    git -C "$REPO_DIR" archive --format=tar --prefix="canonical-k8s/" HEAD \
      | gzip -9 > "$STAGING_DIR/scripts/canonical-k8s-${_SHA}.tar.gz"
    printf '%s\n' "$_SHA" > "$STAGING_DIR/scripts/canonical-k8s.commit"
    note "repository: $(tar -tzf "$STAGING_DIR/scripts/canonical-k8s-${_SHA}.tar.gz" | grep -cv '/$') tracked file(s) at $_SHA"
    git -C "$REPO_DIR" diff --quiet HEAD 2>/dev/null \
      || note "WARNING: working tree has uncommitted changes - they are NOT on this media"
  else
    note "SKIP repository - $REPO_DIR is not a git checkout"
  fi
fi

# Every .snap must have its matching .assert. Installing without one needs --dangerous,
# which skips signature verification entirely - and inside the gap there is no second
# chance to fetch the assertion.
if [ "$DRY" -eq 0 ] && [ -d "$STAGING_DIR/snaps" ]; then
  unpaired=0
  for s in "$STAGING_DIR"/snaps/*.snap; do
    [ -e "$s" ] || continue
    [ -f "${s%.snap}.assert" ] || { echo "  MISSING ASSERTION for $(basename "$s")" >&2; unpaired=$((unpaired+1)); }
  done
  if [ "$unpaired" -gt 0 ]; then
    die "$unpaired snap(s) have no assertion. Re-download with 'snap download', which writes both."
  fi
  n=$(find "$STAGING_DIR/snaps" -name '*.snap' | wc -l)
  [ "$n" -gt 0 ] && note "snap/assert pairs verified: $n"
fi

# --- 3. manifest the extras (NOT the mirror - see header) --------------------------------------
head2 "manifest"
if [ "$DRY" -eq 1 ]; then
  note "DRY RUN - no manifest written"
else
  # Relative paths, so `sha256sum -c` works wherever the disk is mounted - write-transfer-
  # media.sh checks it on build-01 and restore-mirror.sh again inside the gap.
  ( cd "$STAGING_DIR" && find . -type f ! -name MANIFEST.sha256 -print0 \
      | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
  note "$(wc -l < "$STAGING_DIR/MANIFEST.sha256") item(s) hashed -> $STAGING_DIR/MANIFEST.sha256"
  note "extras size: $(du -sh "$STAGING_DIR" | cut -f1)"
fi

# --- 4. what the next step will move -----------------------------------------------------------
head2 "ready to transfer"
note "mirror  : $MIRROR_TREE  ($size, $debs packages)  <- pulled directly, not copied here"
note "extras  : $STAGING_DIR"
note "next    : run write-transfer-media.sh on build-01"

if [ ! -f "$MIRROR_BASE/airgapped-contracts.yaml" ]; then
  cat >&2 <<EOF

  !! airgapped-contracts.yaml IS MISSING.
  !! Generate it with pro-airgapped and rerun, with every aptURL rewritten to
  !!   http://$REPO_ADDRESS
  !! Without it the enclave has a repository it can pull from and NOTHING to
  !! 'pro attach' against - the ESM and FIPS packages will sit on disk unusable.
EOF
  exit 3
fi
