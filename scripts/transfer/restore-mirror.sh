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
ok()   { printf '  [ok] %s\n' "$*"; }   # used by the proof sections
warn() { printf '  [!!] %s\n' "$*" >&2; }
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
# Same trap as write-transfer-media.sh: progress2 emits a carriage-return frame many times a
# second. On a terminal that is one line updating in place; redirected to a log - which is how
# anyone sensibly runs a 318 GB copy - every frame lands on its own line and buries any real
# error in tens of MB of noise. Ask for it only when stdout is a terminal.
if [ -t 1 ]; then RS_INFO="--info=progress2,stats1"; else RS_INFO="--info=stats1"; fi
run rsync -a --delete "$RS_INFO" "$SRC/mirror/" "$REPO_ROOT/mirror/"
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
# The keyrings and .debs must live under $REPO_ROOT for the vhost aliases to reach them.
# Installing the keys into /usr/share/keyrings (section 4) serves THIS machine; serving them
# over HTTP is how host-1..3 and every other guest get them.
# --- 5b. this machine now uses ITS OWN tree -----------------------------------------------------
# The VM was composed pointing at whatever mirror existed at the time - stage-01, across a
# temporary bridge that is removed at cutover. After this script runs, this machine IS the
# repo, and leaving it pointed elsewhere means the one box that can never lose its package
# source is the one still depending on a machine outside the boundary.
#
# file:// rather than http://localhost, deliberately: it works before nginx is up, during an
# nginx reload, and if the vhost is ever misconfigured. The repo server should not need its
# own web server in order to patch itself.
head2 "pointing this machine at its own tree"
_us=/etc/apt/sources.list.d/ubuntu.sources
if [ -f "$_us" ] && grep -q "^URIs: file://$REPO_ROOT/mirror/" "$_us" 2>/dev/null; then
  note "already self-hosted"
else
  [ -f "$_us" ] && run cp "$_us" "$_us.pre-selfhost"
  run tee "$_us" >/dev/null <<EOF
# This machine serves the enclave mirror. It installs from its own copy over file://, so it
# can patch itself with nginx down, mid-reload, or misconfigured. Written by restore-mirror.sh.
Types: deb
URIs: file://$REPO_ROOT/mirror/archive.ubuntu.com/ubuntu/
Suites: ${BOOTSTRAP_SUITES:-noble noble-updates noble-security}
Components: ${BOOTSTRAP_COMPONENTS:-main universe}
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  # the bootstrap file from 2a is now redundant and would duplicate every entry
  [ -f /etc/apt/sources.list.d/zz-restore-bootstrap.sources ] \
    && run rm -f /etc/apt/sources.list.d/zz-restore-bootstrap.sources
  run apt-get update -qq || die "apt-get update failed against the local tree at $REPO_ROOT"
  note "self-hosted: file://$REPO_ROOT/mirror/, signatures verified"
fi

head2 "staging keys and debs for HTTP"
run install -d -m 0755 "$REPO_ROOT/keys" "$REPO_ROOT/debs"
if compgen -G "$SRC/bundle/keys/*.gpg" >/dev/null; then
  run cp -a "$SRC"/bundle/keys/*.gpg "$REPO_ROOT/keys/"
  note "keys   : $(ls -1 "$SRC"/bundle/keys/*.gpg 2>/dev/null | wc -l) served at /keys/"
fi
if compgen -G "$SRC/bundle/debs/*.deb" >/dev/null; then
  run cp -a "$SRC"/bundle/debs/*.deb "$REPO_ROOT/debs/"
  note "debs   : $(ls -1 "$SRC"/bundle/debs/*.deb 2>/dev/null | wc -l) served at /debs/"
fi

head2 "serving the tree"
# Prefer the vhost sitting NEXT TO this script over the one in the bundle. The two travel
# together - in git as scripts/transfer/, and on the disk as bundle/scripts + bundle/config -
# so a script updated after the bundle was staged still installs its own matching config.
# Without this, re-running a fixed script reinstalls the stale vhost it was fixed to replace.
VHOST=""
for _c in "$SCRIPT_DIR/nginx-apt-mirror.conf" \
          "$SCRIPT_DIR/../config/nginx-apt-mirror.conf" \
          "$SRC/bundle/config/nginx-apt-mirror.conf"; do
  [ -f "$_c" ] && { VHOST="$_c"; break; }
done
if [ -n "$VHOST" ]; then
  note "vhost  : $VHOST"
  run install -m 0644 "$VHOST" /etc/nginx/sites-available/apt-mirror
  # Rewrite ALL THREE paths, not just the root. The carried vhost is written for stage-01
  # (/srv/apt-mirror/...); on this machine the tree is under $REPO_ROOT. Rewriting only the
  # root left /keys/ and /debs/ aliased to directories that do not exist here - and those
  # serve the five keyrings and the three .debs an in-gap machine cannot get any other way.
  run sed -i \
      -e "s#root .*/mirror;#root $REPO_ROOT/mirror;#" \
      -e "s#alias .*/keys/;#alias $REPO_ROOT/keys/;#" \
      -e "s#alias .*/debs/;#alias $REPO_ROOT/debs/;#" \
      /etc/nginx/sites-available/apt-mirror
  run ln -sf /etc/nginx/sites-available/apt-mirror /etc/nginx/sites-enabled/apt-mirror
  run rm -f /etc/nginx/sites-enabled/default   # also default_server; nginx refuses two
  run nginx -t
  run systemctl reload nginx
  note "nginx reloaded"
else
  note "no vhost carried - configure nginx by hand, root $REPO_ROOT/mirror"
fi

# --- 6a. wait for the reload to actually take effect ---------------------------------------------
# `systemctl reload nginx` signals the master and RETURNS IMMEDIATELY. For a second or two the
# previous config is still answering - and on this run nginx had only just been installed in
# section 2a, so the previous config was the stock default site.
#
# Measured on svc-repo-01 2026-09-03: the proof ran 5s after the reload, six requests hit the
# new workers and passed, three hit the old ones and 404'd against /var/www/html. They landed
# in the DEFAULT access log rather than apt-mirror's, which is the only reason it was findable.
# The tree was complete and byte-identical the whole time; the proof simply asked too early and
# could not tell that from a real failure.
if [ "$DRY" -eq 0 ]; then
  head2 "waiting for nginx to serve the new config"
  _probe="${EXPECTED_SUITES%%$'\n'*}"
  _pa="${_probe%%:*}"; _ps="${_probe##*:}"
  _url="http://localhost/$_pa/dists/$_ps/Release"
  _ok=0
  for _i in $(seq 1 30); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$_url")" = "200" ]; then
      _ok=1; note "serving after ${_i}s"; break
    fi
    sleep 1
  done
  [ "$_ok" -eq 1 ] || die "nginx is not serving $_url after 30s.
       This is a real failure, not a race - check: sudo nginx -T, and whether
       /etc/nginx/sites-enabled/default is still present."
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

# --- 8. LEVEL 3: a real GPG-verified apt resolution against the ESM suites ----------------------
# Levels 1 and 2 above prove files are served. They do NOT prove the ESM/FIPS/USG suites are
# consumable, because those are signed by the CARRIED Ubuntu Pro keyrings rather than the
# archive keyring - the reason the Pro subscription exists at all. A test that downloads from
# archive.ubuntu.com says nothing about them.
#
# apt runs with every Dir:: overridden, so this machine's own apt configuration is never
# touched and the test leaves nothing behind.
#
# The suite -> keyring mapping below was VERIFIED WITH gpgv on 2026-09-03, not inferred from
# the filenames. To re-verify:
#     gpgv --keyring /srv/repo/keys/<key>.gpg <tree>/dists/<suite>/InRelease
head2 "proving a GPG-verified apt resolution (ESM/FIPS/USG)"
if [ -z "${ESM_PROOF_PACKAGES:-}" ]; then
  note "ESM_PROOF_PACKAGES unset - skipping. Set it in $PARAMS to enable."
else
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  mkdir -p "$T"/lists/partial "$T"/cache/archives/partial "$T"/etc
  K="${REPO_ROOT}/keys"
  {
    printf 'deb [arch=amd64 signed-by=%s/ubuntu-pro-esm-infra.gpg] http://localhost/esm.ubuntu.com/infra/ubuntu noble-infra-security main\n' "$K"
    printf 'deb [arch=amd64 signed-by=%s/ubuntu-pro-esm-infra.gpg] http://localhost/esm.ubuntu.com/infra/ubuntu noble-infra-updates main\n'  "$K"
    printf 'deb [arch=amd64 signed-by=%s/ubuntu-pro-esm-apps.gpg]  http://localhost/esm.ubuntu.com/apps/ubuntu noble-apps-security main\n'   "$K"
    printf 'deb [arch=amd64 signed-by=%s/ubuntu-pro-esm-apps.gpg]  http://localhost/esm.ubuntu.com/apps/ubuntu noble-apps-updates main\n'    "$K"
    printf 'deb [arch=amd64 signed-by=%s/ubuntu-pro-fips.gpg]      http://localhost/esm.ubuntu.com/fips-updates/ubuntu noble-updates main\n' "$K"
    printf 'deb [arch=amd64 signed-by=%s/ubuntu-pro-cis.gpg]       http://localhost/esm.ubuntu.com/usg/ubuntu noble main\n'                  "$K"
  } > "$T/etc/sources.list"

  O=(-o "Dir::Etc::sourcelist=$T/etc/sources.list" -o "Dir::Etc::sourceparts=/dev/null"
     -o "Dir::State::lists=$T/lists" -o "Dir::Cache=$T/cache"
     -o "Dir::Etc::preferencesparts=/dev/null" -o "APT::Get::AllowUnauthenticated=false")

  # Do NOT pipe apt-get into `grep -q`. grep -q exits at the first match, closing the pipe and
  # sending SIGPIPE to apt-get; under `set -o pipefail` the pipeline then reports failure
  # BECAUSE the check succeeded quickly. Redirect to a file and inspect it separately.
  #
  # The log is kept on failure. An earlier version deleted it in an EXIT trap before anyone
  # could read it, which turned a one-line diagnosis into a reproduction exercise.
  ESM_LOG="${REPO_ROOT}/esm-proof.log"
  if ! apt-get "${O[@]}" update > "$ESM_LOG" 2>&1; then
    sed 's/^/       /' "$ESM_LOG" >&2
    die "apt-get update failed against the ESM suites. Log kept at $ESM_LOG"
  fi
  grep -qE '^(Get|Hit)' "$ESM_LOG" \
    || die "apt fetched nothing from the ESM suites - an empty success. Log: $ESM_LOG"
  if grep -qiE 'NO_PUBKEY|not signed|BADSIG|EXPKEYSIG' "$ESM_LOG"; then
    sed 's/^/       /' "$ESM_LOG" >&2
    die "GPG verification FAILED on an ESM suite - the carried keyrings do not match the tree.
       Log kept at $ESM_LOG"
  fi
  note "fetched $(grep -cE '^Get:' "$ESM_LOG") index file(s), signatures verified"
  note "apt-get update: signatures verified against the carried keyrings"

  ( cd "$T" && apt-get "${O[@]}" download $ESM_PROOF_PACKAGES ) >/dev/null 2>&1 \
    || die "could not download: $ESM_PROOF_PACKAGES
       The suites resolve but a package did not. Check it exists in the mirrored components."
  for _p in $ESM_PROOF_PACKAGES; do
    _f=$(ls "$T"/${_p}_*.deb 2>/dev/null | head -1)
    [ -n "$_f" ] || die "$_p did not download"
    dpkg-deb -I "$_f" >/dev/null 2>&1 || die "$_p downloaded but dpkg-deb cannot read it"
    note "$(printf '%-28s %s' "$_p" "$(dpkg-deb -f "$_f" Version) - dpkg-deb OK")"
  done
  ok "ESM/FIPS/USG proven: signed, downloadable, and readable by dpkg"
  rm -rf "$T"; trap - EXIT
fi

note ""
ok "all three verification levels passed"
note "  1. Release for every expected suite"
note "  2. a real pool file from each archive"
note "  3. a GPG-verified apt resolution against the ESM suites, with dpkg-deb reading the result"
note ""
note "The repo is serving. Remaining before clients can 'pro attach':"
note "  contracts-airgapped --config /etc/ubuntu-advantage/airgapped-contracts.yaml"
