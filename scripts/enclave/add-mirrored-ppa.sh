#!/usr/bin/env bash
# =========================================================================================
# add-mirrored-ppa.sh - point this machine at a PPA that lives in the enclave mirror.
#
#   sudo ./add-mirrored-ppa.sh maas/3.7
#   sudo ./add-mirrored-ppa.sh landscape/self-hosted-24.04
#   sudo ./add-mirrored-ppa.sh --list                 what the mirror actually carries
#   sudo ./add-mirrored-ppa.sh maas/3.7 --remove
#
# WHY THIS EXISTS:
#
#   Mirroring a PPA and being able to install from it are two different things, and the gap
#   between them is silent. svc-repo-01 served the MAAS PPA correctly - Release 200 - while
#   `apt-cache policy maas` on svc-mgmt-01 returned nothing at all, because no source file on
#   that machine ever mentioned it. The package was three feet away and invisible.
#
#   The restore and host-prep scripts configure the Ubuntu archive and the ESM suites. They
#   do not configure PPAs, and PPAs are where landscape-server and maas actually live.
#
# WHAT IT REFUSES TO DO:
#
#   It will not write a source file for an archive it cannot reach, and it will not write one
#   without a signing key. An apt source that 404s or cannot be verified is worse than no
#   source: `apt-get update` starts failing for everything on the machine, not just for the
#   package you wanted.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -r "$SELF/enclave-addresses.env" ] && . "$SELF/enclave-addresses.env"

REPO_HOST="${REPO_HOST:-svc-repo-01.${ENCLAVE_DOMAIN:-enclave.internal}}"
BASE="https://$REPO_HOST/ppa.launchpadcontent.net"
KEYS_URL="https://$REPO_HOST/keys"
SUITE="${PPA_SUITE:-noble}"
COMPONENT="${PPA_COMPONENT:-main}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

cmd_list() {
  say "PPAs carried by the mirror at $REPO_HOST:"
  # autoindex gives us plain hrefs; no pipeline into grep -q anywhere in this script.
  local top; top=$(curl -sS --max-time 15 "$BASE/" 2>/dev/null || true)
  [ -n "$top" ] || die "cannot reach $BASE/ - is the mirror serving, and is the root CA trusted?"
  # nginx autoindex emits a "../" parent link in every directory, and the character class
  # matches it because '.' and '-' are in it. Listing "landscape/.." as an installable PPA
  # makes the whole output untrustworthy, which defeats the point of a --list.
  local owner
  for owner in $(printf '%s' "$top" | grep -oE 'href="[a-z0-9.-]+/"' | cut -d'"' -f2 | tr -d '/'); do
    case "$owner" in ''|.|..) continue ;; esac
    local sub; sub=$(curl -sS --max-time 15 "$BASE/$owner/" 2>/dev/null || true)
    local rel
    for rel in $(printf '%s' "$sub" | grep -oE 'href="[a-zA-Z0-9._-]+/"' | cut -d'"' -f2 | tr -d '/'); do
      case "$rel" in ''|.|..) continue ;; esac
      say "    $owner/$rel"
    done
  done
}

main() {
  case "${1:-}" in
    --list|-l) cmd_list; exit 0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "")        die "usage: sudo $0 <owner>/<name>   e.g. maas/3.7   (--list to see what exists)" ;;
  esac

  local ppa="$1"; shift
  local remove=0
  [ "${1:-}" = "--remove" ] && remove=1
  case "$ppa" in */*) : ;; *) die "expected <owner>/<name>, e.g. maas/3.7 - got '$ppa'" ;; esac

  [ "$(id -u)" -eq 0 ] || die "run with sudo"

  local owner="${ppa%%/*}"
  local name="ppa-${owner}"
  local list="/etc/apt/sources.list.d/${name}.sources"
  local keyring="/usr/share/keyrings/${owner}-ppa.gpg"

  if [ "$remove" -eq 1 ]; then
    rm -f "$list"; ok "removed $list"
    say "the keyring at $keyring was left in place - other sources may use it"
    apt-get update -qq || warn "apt-get update reported a problem"
    exit 0
  fi

  local url="$BASE/$ppa/ubuntu"

  # 1. PROVE THE ARCHIVE IS THERE FIRST. Writing a source file for an unreachable archive
  #    breaks apt-get update for every other source on the machine, which is a much bigger
  #    problem than the missing package.
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url/dists/$SUITE/Release" 2>/dev/null || true)
  [ "$code" = "200" ] || die "no Release at $url/dists/$SUITE/Release (HTTP $code)
      The mirror may not carry this PPA, or not for suite '$SUITE'.
      See what it does carry:  sudo $0 --list"
  ok "archive reachable: $url ($SUITE/$COMPONENT)"

  # 2. THE KEY. An unsigned source is refused by apt outright on 24.04, and `trusted=yes` is
  #    not an acceptable answer in an accredited enclave - it disables the check that makes
  #    mirroring safe in the first place.
  if [ ! -s "$keyring" ]; then
    code=$(curl -sS -o "$keyring.tmp" -w '%{http_code}' --max-time 20 "$KEYS_URL/${owner}-ppa.gpg" 2>/dev/null || true)
    if [ "$code" != "200" ]; then
      rm -f "$keyring.tmp"
      die "no signing key at $KEYS_URL/${owner}-ppa.gpg (HTTP $code)
      The key has to be mirrored alongside the archive. On stage-01 it lives in
      /srv/apt-mirror/keys/ and reaches the enclave in the transfer bundle."
    fi
    mv "$keyring.tmp" "$keyring"; chmod 0644 "$keyring"
    ok "installed $keyring"
  else
    say "keyring already present: $keyring"
  fi
  say "key: $(gpg --show-keys --with-colons "$keyring" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"

  # 3. Write the source, deb822 style to match everything else on these machines.
  cat > "$list" <<EOF
# $ppa, served from the enclave mirror. Written by add-mirrored-ppa.sh on $(date -Is).
# The archive is a MIRROR of ppa.launchpadcontent.net - the signature is the PPA's own, so
# Signed-By points at the key mirrored beside it rather than at a Launchpad fetch.
Types: deb
URIs: $url
Suites: $SUITE
Components: $COMPONENT
Architectures: amd64
Signed-By: $keyring
EOF
  chmod 0644 "$list"
  ok "wrote $list"

  apt-get update -qq || die "apt-get update FAILED after adding $ppa.
      Removing the source again:  sudo $0 $ppa --remove"
  ok "apt-get update succeeded, signature verified"
}

main "$@"
