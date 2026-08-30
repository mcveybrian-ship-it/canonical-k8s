#!/usr/bin/env bash
#
# 00 — Fetch and verify the Ubuntu 24.04 base images.
#
# Runs on the CONNECTED staging host (stage-ext). Downloads the Ubuntu Server ISO and the
# Ubuntu Minimal cloud image, verifies both against their signed checksums, and writes a
# manifest for the air-gap evidence trail.
#
# Nothing here touches the enclave. See docs/00-downloads.md for what each file is for.
#
# Usage:
#   ./00-fetch-verify-media.sh [-d DEST] [-s] [-m]
#     -d DEST   download directory (default: ./media)
#     -s        server ISO only
#     -m        minimal cloud image only
#
set -euo pipefail

DEST="./media"
WANT_SERVER=1
WANT_MINIMAL=1

while getopts ":d:smh" opt; do
  case "$opt" in
    d) DEST="$OPTARG" ;;
    s) WANT_MINIMAL=0 ;;
    m) WANT_SERVER=0 ;;
    h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

# --- what we are fetching -----------------------------------------------------------------
# Verified 2026-08-27. Point releases and image serials change; re-check the index pages
# rather than trusting these constants indefinitely.
SERVER_BASE="https://releases.ubuntu.com/noble"
SERVER_ISO="ubuntu-24.04.4-live-server-amd64.iso"

MINIMAL_BASE="https://cloud-images.ubuntu.com/minimal/releases/noble/release"
MINIMAL_IMG="ubuntu-24.04-minimal-cloudimg-amd64.img"
MINIMAL_MANIFEST="ubuntu-24.04-minimal-cloudimg-amd64.manifest"

# Ubuntu CD image signing keys. Fingerprints are asserted below and checked, not assumed.
CD_KEYS=(0x46181433FBB75451 0xD94AA3F0EFE21092)
CD_FPRS=(
  "C5986B4F1257FFA86632CBA746181433FBB75451"
  "843938DF228D22F7B3742BC0D94AA3F0EFE21092"
)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

for tool in curl gpg sha256sum; do
  command -v "$tool" >/dev/null || die "required tool not found: $tool"
done

mkdir -p "$DEST"
cd "$DEST"
say "Working in $(pwd)"

# --- signing keys -------------------------------------------------------------------------
import_cd_keys() {
  say "Importing Ubuntu CD image signing keys"
  gpg --keyid-format long --keyserver hkp://keyserver.ubuntu.com \
      --recv-keys "${CD_KEYS[@]}" >/dev/null 2>&1 \
    || die "could not fetch signing keys from keyserver.ubuntu.com"

  # Confirm the imported keys are the ones we expect, not merely that some key arrived.
  local present
  present="$(gpg --with-colons --fingerprint "${CD_KEYS[@]}" 2>/dev/null \
             | awk -F: '/^fpr:/ {print $10}')"
  for fpr in "${CD_FPRS[@]}"; do
    grep -qx "$fpr" <<<"$present" || die "expected fingerprint not present: $fpr"
    echo "    verified fingerprint $fpr"
  done
}

# --- download + verify ---------------------------------------------------------------------
fetch() {
  local base="$1" file="$2"
  if [[ -f "$file" ]]; then
    echo "    already present, skipping: $file"
  else
    echo "    downloading $file"
    curl -fL --progress-bar -O "$base/$file" || die "download failed: $base/$file"
  fi
}

# Verify SHA256SUMS.gpg -> SHA256SUMS, then the named file against SHA256SUMS.
# $3 = "trusted" to require a good signature, "report" to print the signing key and continue.
verify_set() {
  local sums="$1" file="$2" mode="$3"

  if [[ "$mode" == "trusted" ]]; then
    gpg --keyid-format long --verify "${sums}.gpg" "$sums" 2>&1 | grep -q "Good signature" \
      || die "signature check FAILED on $sums"
    echo "    good signature on $sums"
  else
    local keyid
    keyid="$(gpg --verify "${sums}.gpg" "$sums" 2>&1 \
             | sed -n 's/.*using [A-Za-z]* key \([0-9A-F]\{8,\}\).*/\1/p' | head -1)"
    warn "cloud-image ${sums} is signed by key ${keyid:-<unknown>}, which this script does"
    warn "not trust automatically. Confirm that fingerprint against a Canonical source, then"
    warn "import it and re-run. Checksums are still being verified below."
  fi

  grep -F "$file" "$sums" > "${sums}.${file}.filtered" \
    || die "$file not listed in $sums"
  sha256sum -c "${sums}.${file}.filtered" \
    || die "CHECKSUM MISMATCH on $file — do not use this file"
  rm -f "${sums}.${file}.filtered"
  echo "    checksum OK: $file"
}

if (( WANT_SERVER )); then
  say "Ubuntu Server 24.04.4 LTS — installer ISO"
  import_cd_keys
  fetch "$SERVER_BASE" "$SERVER_ISO"
  fetch "$SERVER_BASE" "SHA256SUMS"
  fetch "$SERVER_BASE" "SHA256SUMS.gpg"
  verify_set "SHA256SUMS" "$SERVER_ISO" trusted
fi

if (( WANT_MINIMAL )); then
  say "Ubuntu Minimal 24.04 — cloud image"
  mkdir -p minimal && pushd minimal >/dev/null
  fetch "$MINIMAL_BASE" "$MINIMAL_IMG"
  fetch "$MINIMAL_BASE" "$MINIMAL_MANIFEST"
  fetch "$MINIMAL_BASE" "SHA256SUMS"
  fetch "$MINIMAL_BASE" "SHA256SUMS.gpg"
  verify_set "SHA256SUMS" "$MINIMAL_IMG" report
  echo "    package count in image: $(wc -l < "$MINIMAL_MANIFEST")"
  popd >/dev/null
fi

# --- evidence manifest -----------------------------------------------------------------------
say "Writing manifest"
{
  echo "# Ubuntu 24.04 media manifest"
  echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# host:      $(hostname)"
  echo "# sources:   $SERVER_BASE"
  echo "#            $MINIMAL_BASE"
  echo
  find . -type f \( -name '*.iso' -o -name '*.img' -o -name '*.manifest' \) -print0 \
    | sort -z | xargs -0 sha256sum
} > MANIFEST.sha256

cat MANIFEST.sha256
say "Done. Manifest: $(pwd)/MANIFEST.sha256"
cat <<'NEXT'

Next:
  1. Keep MANIFEST.sha256 — it is supply-chain evidence, not scratch output.
  2. Confirm the cloud-image signing key fingerprint if it was reported above.
  3. Write the ISO to USB and install Ubuntu Server on the bare-metal pathfinder
     machine, then run 01-hw-inventory.sh and 01-capability-test.sh there.
     That is step 01 - see docs/01-pathfinder.md.
NEXT
