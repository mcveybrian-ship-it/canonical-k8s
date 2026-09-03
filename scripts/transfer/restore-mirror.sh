#!/usr/bin/env bash
#
# restore-mirror.sh - step 3 of 3. RUNS ON svc-repo-01, INSIDE THE AIR GAP.
#
# This is the one that matters. It turns files on a disk into a working enclave
# service, and it is the part nobody can improvise at the rack.
#
#   1. copy the repository tree off the SSD
#   2. install contracts-airgapped and pro-airgapped from the carried .debs -
#      they CANNOT come from the mirror, because they live in a Launchpad PPA and
#      this machine has no route to Launchpad. The contracts server cannot be
#      installed from the mirror it exists to authenticate.
#   3. place the four signing keyrings
#   4. serve the tree over nginx
#   5. PROVE it - Release, a real pool file, then a genuine GPG-verified apt
#      resolution. Metadata resolving is not proof.
#
# Run with sudo. Everything it needs is on the disk; nothing is fetched.
#
#   sudo ./restore-mirror.sh [-p params] [-s /mnt/transfer] [-n]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PARAMS="$SCRIPT_DIR/transfer-params.env"
SRC_OVERRIDE=""
DRY=0

usage() {
  cat <<'USAGE'
usage: sudo restore-mirror.sh [-p <params>] [-s <source mount>] [-n]

  -p <file>  parameters file (default: transfer-params.env beside this script)
  -s <path>  where the transfer SSD is mounted (default: MEDIA_MOUNT from params)
  -n         dry run - report, change nothing
USAGE
}

while getopts ':p:s:nh' o; do
  case "$o" in
    p) PARAMS="$OPTARG" ;;
    s) SRC_OVERRIDE="$OPTARG" ;;
    n) DRY=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }
# DRY messages go to STDERR. Several call sites redirect stdout - `run tee "$f" >/dev/null`
# is the obvious one - and on stdout the DRY line vanishes with it, so a dry run silently
# fails to show the very file it would write.
run()  { if [ "$DRY" -eq 1 ]; then echo "  DRY: $*" >&2; else "$@"; fi; }

[ -r "$PARAMS" ] || die "no params file: $PARAMS"
set -a
# shellcheck disable=SC1090
. "$PARAMS"
set +a

: "${REPO_ROOT:?}" "${REPO_ADDRESS:?}"
SRC="${SRC_OVERRIDE:-${MEDIA_MOUNT:?}}"
CONTRACTS_PORT="${CONTRACTS_PORT:-8484}"

[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"

# --- 1. source checks ---------------------------------------------------------------------------
head2 "checking the transfer disk"
mountpoint -q "$SRC" || die "$SRC is not a mount point - mount the transfer SSD there first"
[ -d "$SRC/mirror" ] || die "no mirror tree at $SRC/mirror"
[ -d "$SRC/bundle" ] || die "no bundle at $SRC/bundle"
note "source : $SRC"
note "mirror : $(du -sh "$SRC/mirror" 2>/dev/null | cut -f1)"

if [ -f "$SRC/bundle/MANIFEST.sha256" ]; then
  ( cd "$SRC/bundle" && sha256sum -c --quiet MANIFEST.sha256 ) \
    && note "manifest: verified" || die "MANIFEST MISMATCH - the disk is not trustworthy"
else
  note "manifest: absent (continuing)"
fi

# --- 2. copy the tree in --------------------------------------------------------------------
head2 "installing the repository tree"
run mkdir -p "$REPO_ROOT"

# Check the space FIRST. Copying 317 GiB and running out at 90% wastes hours and leaves a
# half-populated tree that looks plausible. write-transfer-media.sh checks before writing the
# SSD; there is no reason this side should be less careful, and far less excuse - a failure
# here is inside the gap.
need_gb=$(du -sBG "$SRC/mirror" 2>/dev/null | cut -f1 | tr -dc '0-9')
# df the nearest EXISTING ancestor. In a dry run the mkdir above did not happen, so
# df "$REPO_ROOT" fails with "No such file or directory" and the check that exists to
# prevent a half-copied tree becomes the thing that stops the run.
_df_target="$REPO_ROOT"
while [ ! -d "$_df_target" ] && [ "$_df_target" != "/" ]; do
  _df_target=$(dirname "$_df_target")
done
have_gb=$(df -BG --output=avail "$_df_target" | tail -1 | tr -dc '0-9')
note "need   : ${need_gb} GB"
note "have   : ${have_gb} GB on $_df_target"
[ "${have_gb:-0}" -ge "${need_gb:-0}" ] \
  || die "not enough space on $REPO_ROOT: need ${need_gb} GB, have ${have_gb} GB"
run rsync -a --delete --info=progress2 "$SRC/mirror/" "$REPO_ROOT/mirror/"
note "tree   : $REPO_ROOT/mirror"

# --- 2a. make apt work from the copied tree, BEFORE anything needs it ---------------------------
# ORDER MATTERS AND THIS USED TO BE LAST. The carried .debs are installed in the next section,
# and inside the real gap there are NO working apt sources at that point - so dependency
# resolution fails and the dpkg -i fallback installs them without their dependencies. Setting
# up file:// here, immediately after the tree lands, gives every later step a working apt.
#
# The chicken-and-egg nobody notices until they are at the rack: this script configures nginx,
# but a freshly-built air-gapped VM does not HAVE nginx, and it cannot install it from the
# mirror because serving the mirror is what this script is for. nginx is not among the three
# carried .debs either - those are the PPA tools the mirror can never serve.
#
# The tree is already on local disk by now, so apt can read it directly over file://. No
# network, no nginx, no ordering problem. The archive keyring ships with Ubuntu.
#
# The update pockets are in the bootstrap source deliberately. With 'noble' alone apt resolves
# nginx 1.24.0-2ubuntu7 - the UNPATCHED release-pocket build - because that is the only version
# that suite indexes. Measured against the real tree: with all three suites it resolves
# 1.24.0-2ubuntu7.17 and pulls 7 packages, every one present in the pool. Installing a
# knowingly unpatched web server as the enclave's first service is not a defensible start.
head2 "local apt source, and nginx"
if command -v nginx >/dev/null 2>&1; then
  note "already installed: $(nginx -v 2>&1)"
else
  note "not installed - bootstrapping from the local tree over file://"
  BOOTSTRAP_LIST=/etc/apt/sources.list.d/zz-restore-bootstrap.sources
  run tee "$BOOTSTRAP_LIST" >/dev/null <<EOF
# Temporary, written by restore-mirror.sh. Reads the copied tree directly off local disk.
Types: deb
URIs: file://$REPO_ROOT/mirror/archive.ubuntu.com/ubuntu/
Suites: ${BOOTSTRAP_SUITES:-noble noble-updates noble-security}
Components: ${BOOTSTRAP_COMPONENTS:-main}
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  run apt-get update -qq \
    || die "apt-get update failed against file://$REPO_ROOT/mirror - is the tree complete?"
  run apt-get install -y --no-install-recommends nginx-core \
    || die "could not install nginx from the carried tree"
  [ "$DRY" -eq 1 ] && note "installed: (dry run - nginx not actually installed)" \
                   || note "installed: $(nginx -v 2>&1)"
  # Leave the file:// source in place: it is how this machine patches itself before the
  # HTTP vhost exists, and removing it would strand the box if nginx ever needed reinstalling.
  note "left $BOOTSTRAP_LIST in place - it is this machine's own package source"
fi

# --- 3. the three .debs the mirror can never serve ---------------------------------------------
head2 "installing the air-gap tooling from carried .debs"
if compgen -G "$SRC/bundle/debs/*.deb" >/dev/null; then
  # NOT --no-download: these three .debs have dependencies, and after 2a they resolve from
  # the file:// source pointing at the copied tree. --no-download would refuse to use it and
  # force the dpkg -i fallback, which installs them with their dependencies UNMET - a package
  # that is present but broken, which is worse than one that failed to install.
  run apt-get install -y "$SRC"/bundle/debs/*.deb \
    || die "could not install the carried .debs. Their dependencies come from the file://
       source set up in section 2a - check that apt-get update succeeded there."
  note "installed: $(ls -1 "$SRC"/bundle/debs/*.deb | wc -l) package(s)"
else
  note "NO .debs carried - contracts-airgapped cannot be installed. This is fatal for"
  note "the entitlement path; the repo will still serve packages."
fi

# --- 4. signing keyrings ------------------------------------------------------------------------
head2 "placing signing keyrings"
if compgen -G "$SRC/bundle/keys/*.gpg" >/dev/null; then
  run install -d -m 0755 /usr/share/keyrings
  for k in "$SRC"/bundle/keys/*.gpg; do
    run install -m 0644 "$k" /usr/share/keyrings/
    note "$(basename "$k")"
  done
else
  note "NO keyrings carried - the ESM/FIPS/USG repos cannot be verified"
fi

# --- 5. contracts server config ------------------------------------------------------------------
head2 "contracts server"
if [ -f "$SRC/bundle/config/airgapped-contracts.yaml" ]; then
  run install -d -m 0755 /etc/ubuntu-advantage
  run install -m 0600 "$SRC/bundle/config/airgapped-contracts.yaml" /etc/ubuntu-advantage/
  note "config placed. Start it with:"
  note "  contracts-airgapped --config /etc/ubuntu-advantage/airgapped-contracts.yaml"
  note "Clients then point uaclient.conf at http://$REPO_ADDRESS:$CONTRACTS_PORT"
else
  note "*** airgapped-contracts.yaml NOT PRESENT ***"
  note "Packages will serve, but no client can 'pro attach' - ESM and FIPS stay inert."
fi

# --- 6. nginx ------------------------------------------------------------------------------------
head2 "serving the tree"
if [ -f "$SRC/bundle/config/nginx-apt-mirror.conf" ]; then
  run install -m 0644 "$SRC/bundle/config/nginx-apt-mirror.conf" \
      /etc/nginx/sites-available/apt-mirror
  # The vhost roots at the mirror tree; rewrite that path for this machine.
  run sed -i "s#root .*/mirror;#root $REPO_ROOT/mirror;#" /etc/nginx/sites-available/apt-mirror
  run ln -sf /etc/nginx/sites-available/apt-mirror /etc/nginx/sites-enabled/apt-mirror
  run rm -f /etc/nginx/sites-enabled/default   # also default_server; nginx refuses two
  run nginx -t
  run systemctl reload nginx
  note "nginx reloaded"
else
  note "no vhost carried - configure nginx by hand, root $REPO_ROOT/mirror"
fi

# --- 7. PROVE IT ---------------------------------------------------------------------------------
# Three levels. Release alone proves nothing: metadata is served more permissively than
# content, which is exactly how a bad token produced a healthy-looking empty archive on
# 2026-08-31.
head2 "proving the mirror"
if [ "$DRY" -eq 1 ]; then note "DRY RUN - skipped"; exit 0; fi

# A proof that can pass having checked nothing is not a proof. Both of these silently
# returned success before: an unset EXPECTED_SUITES ran the loop once on an empty line and
# reported no failures, and a suite with no Packages file scored "----" which was treated as
# a pass. That is the same shape as the bad token that produced a healthy-looking empty
# archive on 2026-08-31.
[ -n "${EXPECTED_SUITES:-}" ] \
  || die "EXPECTED_SUITES is empty - there is nothing to verify. Set it in $PARAMS."

fail=0
checked=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  checked=$((checked+1))
  archive="${line%%:*}"; suite="${line##*:}"

  rc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
       "http://localhost/$archive/dists/$suite/Release")

  pkgs=$(find "$REPO_ROOT/mirror/$archive/dists/$suite" -name Packages 2>/dev/null | head -1)
  fn=$(grep -m1 '^Filename:' "$pkgs" 2>/dev/null | awk '{print $2}')
  if [ -n "$fn" ]; then
    pc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://localhost/$archive/$fn")
  else
    pc="----"
  fi

  printf '  Release %s   pool %s   %-38s %s\n' "$rc" "$pc" "$archive" "$suite"
  [ "$rc" = "200" ] || fail=$((fail+1))
  # "----" means no Packages file was found for this suite. That is a mirroring failure,
  # not an exemption - count it.
  [ "$pc" = "200" ] || fail=$((fail+1))
done <<< "$EXPECTED_SUITES"

[ "$checked" -gt 0 ] || die "verified 0 suites - EXPECTED_SUITES parsed to nothing"
note "checked: $checked suite(s)"
[ "$fail" -eq 0 ] || die "$fail check(s) failed - the tree is not correctly served"

note ""
note "HTTP checks passed. Now prove a real GPG-verified apt resolution:"
note "  see airgap-update-lab.md section 6.5 - build a sources list pointing at"
note "  http://$REPO_ADDRESS with signed-by= each carried keyring, then:"
note "    apt-get \$OPTS update && apt-get \$OPTS download usg openssl-fips-module-3"
note ""
note "Until a package downloads and dpkg-deb -I reads it, you have proven only that"
note "files are on a disk."
