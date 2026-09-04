#!/usr/bin/env bash
# =========================================================================================
# make-contracts-config.sh - generate airgapped-contracts.yaml for the enclave.
#
#     MACHINE: stage-01 ONLY. It calls Canonical's contract API, so it needs internet and
#     the paid Pro token. No in-gap machine can do this.
#
#     ./make-contracts-config.sh                     write to the bundle staging dir
#     ./make-contracts-config.sh -o /path/out.yaml   write elsewhere
#     ./make-contracts-config.sh -n                  show the INPUT, generate nothing
#
# WHY THIS EXISTS AS A SCRIPT
#   The step was in the README's index as "§6.4a" and that section was never written, so the
#   procedure that produces the credential the whole entitlement path depends on existed only
#   in someone's shell history. It also has to be re-run whenever an address or domain
#   changes - which happened on 2026-09-03 when the enclave moved to .internal.
#
# WHAT IT PRODUCES
#   A mapping of contract token -> AccountContractInfo, with every ESM aptURL rewritten to
#   point at the in-gap repo. Without it the enclave has packages it cannot entitle: the ESM
#   and FIPS debs sit on disk and `pro attach` has nothing to talk to.
#
# IT IS A CREDENTIAL, NOT A CONFIG FILE. It maps contract tokens to entitlements. Mode 0600,
# never printed, never committed. This script does not echo the token or the output.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS="${PARAMS:-$SELF/transfer-params.env}"
# Resolve SUDO_USER's home, not $HOME. If this is ever run under sudo, $HOME is /root and the
# operator's token file becomes invisible - the script then says "no token file" on a machine
# that plainly has one. Exactly the failure 03-compose-vm.sh hit with ssh keys on 2026-09-03.
if [ -n "${PRO_TOKEN_FILE:-}" ]; then
  TOKEN_FILE="$PRO_TOKEN_FILE"
elif [ -n "${SUDO_USER:-}" ] && _h=$(getent passwd "$SUDO_USER" | cut -d: -f6) && [ -n "$_h" ]; then
  TOKEN_FILE="$_h/.pro-contract-token"
else
  TOKEN_FILE="$HOME/.pro-contract-token"
fi
OUT=""; DRY=0

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -n) DRY=1; shift ;;
    -t) TOKEN_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

[ -r "$PARAMS" ] || die "no params file at $PARAMS"
# shellcheck disable=SC1090
. "$PARAMS"
: "${REPO_ADDRESS:?REPO_ADDRESS must be set in $PARAMS}"
OUT="${OUT:-${STAGING_DIR:-/srv/bundle-staging}/config/airgapped-contracts.yaml}"

command -v pro-airgapped >/dev/null || die "pro-airgapped not installed. It is in ppa:yellow/ua-airgapped."

# --- the token -----------------------------------------------------------------------------
# From a FILE, never an argument. A token on the command line is visible in `ps` to every
# user on the box and lands in shell history. The file must be 0600.
[ -r "$TOKEN_FILE" ] || die "no token file at $TOKEN_FILE
       Create it, readable only by you, containing the contract token on one line:
         install -m 600 /dev/null $TOKEN_FILE && \\
           printf '%s\\n' '<CONTRACT-TOKEN>' > $TOKEN_FILE
       Use -t to point somewhere else, or set PRO_TOKEN_FILE."
_perm=$(stat -c '%a' "$TOKEN_FILE")
[ "$_perm" = "600" ] || die "$TOKEN_FILE is mode $_perm - must be 600. It is a credential."
TOKEN=$(head -1 "$TOKEN_FILE" | tr -d '[:space:]')
[ -n "$TOKEN" ] || die "$TOKEN_FILE is empty"
say "token  : loaded from $TOKEN_FILE (${#TOKEN} chars, not shown)"

# --- the overrides -------------------------------------------------------------------------
# One aptURL per ESM archive. The entitlement NAMES are Canonical's, and two of them do not
# match the archive they serve - that is the naming trap recorded in README §0.3:
#   * the token and entitlement for USG print under "cis"; "usg" is an alias
#   * FIPS updates live in the "fips-updates" archive, not under "fips"
BASE="http://${REPO_ADDRESS}"
say "target : $BASE"

INPUT=$(cat <<EOF
{
  "$TOKEN": {
    "esm-infra": { "directives": { "aptURL": "$BASE/esm.ubuntu.com/infra/ubuntu" } },
    "esm-apps":  { "directives": { "aptURL": "$BASE/esm.ubuntu.com/apps/ubuntu" } },
    "fips-updates": { "directives": { "aptURL": "$BASE/esm.ubuntu.com/fips-updates/ubuntu" } },
    "cis":       { "directives": { "aptURL": "$BASE/esm.ubuntu.com/usg/ubuntu" } }
  }
}
EOF
)

if [ "$DRY" -eq 1 ]; then
  say ""
  say "--- input that would be sent (token masked) ---"
  printf '%s\n' "$INPUT" | sed "s|$TOKEN|<CONTRACT-TOKEN>|g" | sed 's/^/  /'
  say ""
  say "would write: $OUT"
  exit 0
fi

install -d -m 0755 "$(dirname "$OUT")"
TMP=$(mktemp); chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
# STDIN with NO --input flag. Its own help says `--input -` means stdin; it does not - it
# tries to open a file named "" and fails with `open : no such file or directory`. Verified
# 2026-09-04 against pro-airgapped 1.8.1: `--input FILE` works, bare stdin works, `--input -`
# does not.
#
# stdin also keeps the token off disk entirely, which `--input FILE` would not.
printf '%s\n' "$INPUT" | pro-airgapped --output "$TMP" \
  || die "pro-airgapped failed.
       'unauthorized' means the token was rejected - check it is the CONTRACT token from
       ubuntu.com/pro/dashboard, not a machine token or a resource token.
       A connection error means this machine cannot reach contracts.canonical.com."

# --- verify BEFORE installing --------------------------------------------------------------
# The whole point is the rewritten URLs. A file that generated cleanly but kept Canonical's
# URLs is useless in the gap and looks fine on inspection.
# Check the FOUR we mirror, individually. A Pro contract carries many more entitlements -
# livepatch, landscape, realtime-kernel, ros, anbox and so on - and those legitimately keep
# their Canonical URLs: they are not mirrored and are not available in the gap. An earlier
# version failed on "any Canonical URL remains", which rejected a perfectly good file.
_missing=""
for _u in "$BASE/esm.ubuntu.com/infra/ubuntu" \
          "$BASE/esm.ubuntu.com/apps/ubuntu" \
          "$BASE/esm.ubuntu.com/fips-updates/ubuntu" \
          "$BASE/esm.ubuntu.com/usg/ubuntu"; do
  grep -qF "aptURL: $_u" "$TMP" || _missing="$_missing
         $_u"
done
[ -z "$_missing" ] || die "these aptURLs were NOT rewritten:$_missing
       The overrides did not take for those entitlements. Check the names against what your
       contract returns - two do not match their archive: USG's entitlement is 'cis', and
       FIPS updates live under 'fips-updates'. See README §0.3."
n=$(grep -cF "aptURL: $BASE" "$TMP" || true)
ok "all 4 mirrored entitlements point at $BASE"

# Report - not fail on - the entitlements that stay at Canonical, because knowing which
# capabilities are NOT available in the gap is worth having in front of you.
_remote=$(grep -oE 'aptURL: https?://[a-z.]*ubuntu\.com[^ ]*' "$TMP" | sed 's|aptURL: ||' | sort -u || true)
if [ -n "$_remote" ]; then
  say ""
  say "  These entitlements keep Canonical URLs - they are NOT mirrored and will not work"
  say "  inside the gap. That is expected; it is the list of what the enclave cannot offer:"
  printf '%s\n' "$_remote" | sed 's|^|         |'
  say ""
fi

install -m 0600 "$TMP" "$OUT"
ok "wrote $OUT (0600, $n aptURLs rewritten to $BASE)"
say ""
say "It is a credential. Do not commit it, do not print it."
say "On svc-repo-01 it is installed by restore-mirror.sh to /etc/ubuntu-advantage/."
