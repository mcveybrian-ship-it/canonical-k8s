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
# Write to MIRROR_BASE, which is where build-transfer-bundle.sh looks for it and copies it
# into the bundle from. Writing straight into the staging dir bypassed that, so the builder
# kept checking - and would have kept carrying - the previous copy. Two files, one stale, and
# the check reporting on the wrong one.
OUT="${OUT:-${MIRROR_BASE:-/srv/apt-mirror}/airgapped-contracts.yaml}"

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
#
# AND NOTE THE DEPTH. The aptURL is the parent of /ubuntu, NOT the directory the packages sit
# in. The pro client builds "<aptURL>/ubuntu/pool/" itself, so an aptURL ending in /ubuntu
# produces /ubuntu/ubuntu/pool/ and a 404 at enable time - long after the file has been
# generated, verified, carried in and installed. Found 2026-09-04 by `pro enable esm-infra`:
#
#     E: Failed to fetch http://svc-repo-01.enclave.internal/esm.ubuntu.com/infra/ubuntu/ubuntu/pool/  404
#
# Derive it from what the client requests, not from the mirror's directory layout.
# https by default. The enclave has an internal CA precisely so that nothing here has to
# run in the clear, and an assessor reading a config full of http:// URLs will not care that
# the wire happens to be inside a locked room. Override with REPO_SCHEME=http only to
# reproduce a pre-CA build.
#
# NOTE the host must be a name the certificate actually carries. svc-repo-01's SANs are the
# FQDN, the short name and the IP, so any of the three validate - but REPO_ADDRESS is a name
# that must match one of them, or every apt fetch fails certificate verification.
BASE="${REPO_SCHEME:-https}://${REPO_ADDRESS}"
say "target : $BASE"

INPUT=$(cat <<EOF
{
  "$TOKEN": {
    "esm-infra": { "directives": { "aptURL": "$BASE/esm.ubuntu.com/infra" } },
    "esm-apps":  { "directives": { "aptURL": "$BASE/esm.ubuntu.com/apps" } },
    "fips-updates": { "directives": { "aptURL": "$BASE/esm.ubuntu.com/fips-updates" } },
    "cis":       { "directives": { "aptURL": "$BASE/esm.ubuntu.com/usg" } }
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
for _u in "$BASE/esm.ubuntu.com/infra" \
          "$BASE/esm.ubuntu.com/apps" \
          "$BASE/esm.ubuntu.com/fips-updates" \
          "$BASE/esm.ubuntu.com/usg"; do
  grep -qF "aptURL: $_u" "$TMP" || _missing="$_missing
         $_u"
done
[ -z "$_missing" ] || die "these aptURLs were NOT rewritten:$_missing
       The overrides did not take for those entitlements. Check the names against what your
       contract returns - two do not match their archive: USG's entitlement is 'cis', and
       FIPS updates live under 'fips-updates'. See README §0.3."
n=$(grep -cF "aptURL: $BASE" "$TMP" || true)
ok "all 4 mirrored entitlements point at $BASE"

# A top-level directive is not the whole story. Each entitlement can carry `overrides` and
# `series` blocks with their OWN aptURL, and a matching one wins over the top-level value.
# pro-airgapped rewrites only the top-level directive, so an override matching the deployed
# series would silently send clients to Canonical from inside the gap.
#
# On this contract the leftovers are all series: precise and trusty - 12.04 and 14.04 - which
# a noble client never matches. That is luck, not design, and worth asserting rather than
# eyeballing.
python3 - "$TMP" "${TARGET_SERIES:-noble}" "$BASE" <<'PYEOF' || die "an override or series block for the deployed series points at Canonical - clients would bypass the enclave"
import sys, yaml
f, series, base = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(f)); bad = []
for info in d.values():
    for e in info.get('contractInfo', {}).get('resourceEntitlements', []):
        if e.get('type') not in ('esm-infra', 'esm-apps', 'cis', 'fips-updates'):
            continue
        for ov in (e.get('overrides') or []):
            if (ov.get('selector') or {}).get('series') != series:
                continue
            u = (ov.get('directives') or {}).get('aptURL')
            if u and not u.startswith(base): bad.append((e['type'], 'override', u))
        sv = (e.get('series') or {}).get(series) or {}
        u = (sv.get('directives') or {}).get('aptURL')
        if u and not u.startswith(base): bad.append((e['type'], f'series[{series}]', u))
for t, w, u in bad: print(f"       {t} {w} -> {u}", file=sys.stderr)
sys.exit(1 if bad else 0)
PYEOF
ok "no override or series block for ${TARGET_SERIES:-noble} bypasses the enclave"

# PROVE THE URLS RESOLVE, here, now. Every check above confirms the file says what we meant;
# none of them confirm the client can fetch it. The depth error was invisible until
# `pro enable` ran on a machine inside the gap - the file generated cleanly, verified
# cleanly, was carried in and installed, and failed at the last possible moment.
#
# The client requests "<aptURL>/ubuntu/pool/". Ask for exactly that.
if command -v curl >/dev/null; then
  _probe_fail=0
  for _u in $(grep -oE "aptURL: ${BASE}[^ ]*" "$TMP" | sed 's/aptURL: //' | sort -u); do
    _code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$_u/ubuntu/pool/" || true)
    if [ "${_code:-000}" = "200" ]; then
      say "  $(printf '%-58s' "$_u/ubuntu/pool/") $_code"
    else
      say "  $(printf '%-58s' "$_u/ubuntu/pool/") ${_code:-no response}  <-- WRONG"
      _probe_fail=1
    fi
  done
  if [ "$_probe_fail" -eq 0 ]; then
    ok "every aptURL resolves as the pro client will request it"
  else
    warn "an aptURL did not resolve. If the repo is not serving yet this is expected;"
    warn "if it IS serving, the URL depth is wrong and 'pro enable' will 404."
  fi
else
  say "  curl not present - skipping the resolve check"
fi

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

# MIRROR_BASE is owned by apt-mirror, so this needs root - and once written as root, the
# account that runs build-transfer-bundle.sh cannot read it. 0600 root:root would be the
# strictest thing and would break the next step; 0644 would expose a credential to every
# account on the box. root:<operator> 0640 is the documented middle ground, and it is what
# build-transfer-bundle.sh already tells you to set by hand when it finds the file unreadable.
if [ "$(id -u)" -ne 0 ] && [ ! -w "$(dirname "$OUT")" ]; then
  die "cannot write $OUT - $(dirname "$OUT") is owned by $(stat -c '%U' "$(dirname "$OUT")").
       Re-run with sudo:  sudo -E $0 $*
       (-E preserves PRO_TOKEN_FILE; without it the token is still found via SUDO_USER.)"
fi
install -m 0640 "$TMP" "$OUT"
_owner="${SUDO_USER:-$(id -un)}"
if [ "$(id -u)" -eq 0 ]; then
  chown "root:$_owner" "$OUT"
  ok "wrote $OUT (0640 root:$_owner, $n aptURLs rewritten to $BASE)"
else
  ok "wrote $OUT (0640, $n aptURLs rewritten to $BASE)"
fi
say ""
say "It is a credential. Do not commit it, do not print it."
say "On svc-repo-01 it is installed by restore-mirror.sh to /etc/ubuntu-advantage/."
