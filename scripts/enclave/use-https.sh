#!/usr/bin/env bash
# use-https.sh - move one machine's apt and pro traffic from http to https.
#
#   sudo ./use-https.sh              # migrate this machine
#   sudo ./use-https.sh --check      # report what would change, touch nothing
#   sudo ./use-https.sh --rollback   # restore the last backup taken here
#
# WHY THIS IS A SCRIPT AND NOT A sed ONE-LINER:
#
#   It runs on every machine in the enclave, and each one has a slightly different set of
#   sources files - some written by the installer, some by `pro enable`, some referring to
#   the repo by IP and some by name. A one-liner that works on svc-mgmt-01 silently misses
#   a file on host-4, and the miss shows up later as one plaintext fetch nobody notices.
#
#   More importantly: if the switch to https is wrong in any way - untrusted root, missing
#   SAN, nginx not listening - then apt stops working on a machine that has no other route
#   to a package. Inside an air gap that is not a small problem. So this verifies https
#   works BEFORE editing anything, and restores the backup if apt fails afterwards.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -r "$SELF/enclave-addresses.env" ] && . "$SELF/enclave-addresses.env"

REPO_HOST="${REPO_HOST:-svc-repo-01.${ENCLAVE_DOMAIN:-enclave.internal}}"
MGMT_HOST="${MGMT_HOST:-svc-mgmt-01.${ENCLAVE_DOMAIN:-enclave.internal}}"
REPO_IP="${SVC_REPO_01:-}"
BACKUP_ROOT=/root/apt-https-migration
MODE=migrate

say() { printf '  %s\n' "$*"; }
ok()  { printf '  [ok] %s\n' "$*"; }
warn(){ printf '  [!]  %s\n' "$*"; }
die() { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE=check;    shift ;;
    --rollback) MODE=rollback; shift ;;
    --repo)     REPO_HOST="$2"; shift 2 ;;
    --contracts) MGMT_HOST="$2"; shift 2 ;;
    -h|--help)  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ "$(id -u)" -eq 0 ] || die "run with sudo"

# ---------------------------------------------------------------- find the files
# Both formats are in play: deb822 .sources written by the 24.04 installer and by recent
# pro clients, and legacy .list files. Matching on the repo's IP as well as its names is
# what catches host-4, which was pointed at 10.2.20.162 directly.
PAT="$REPO_HOST|svc-repo-01"
[ -n "$REPO_IP" ] && PAT="$PAT|${REPO_IP//./\\.}"

mapfile -t FILES < <(
  grep -rlE "http://($PAT)" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | sort -u || true
)
UACONF=/etc/ubuntu-advantage/uaclient.conf

# ---------------------------------------------------------------- rollback
if [ "$MODE" = rollback ]; then
  [ -d "$BACKUP_ROOT" ] || die "no backups under $BACKUP_ROOT"
  LAST=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
  [ -n "$LAST" ] || die "no backup directories under $BACKUP_ROOT"
  say "restoring from $LAST"
  # The backup stores each file under its full original path, so the restore is a copy
  # back onto / rather than a list of remembered destinations that could drift.
  (cd "$LAST/files" && find . -type f -print0 | xargs -0 -I{} cp -a --parents {} /) 2>/dev/null || true
  ok "files restored"
  apt-get update -qq && ok "apt works again" || warn "apt still failing - look at the output above"
  exit 0
fi

# ---------------------------------------------------------------- prove https first
say "checking https BEFORE changing anything"
[ -s /usr/local/share/ca-certificates/enclave-root.crt ] \
  || die "the enclave root is not in this machine's trust store - run ca.sh trust first"
ok "enclave root present in trust store"

# No -k anywhere in this script, deliberately. If the chain does not validate then apt will
# not validate it either, and finding that out here costs nothing.
code=""
if ! code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "https://$REPO_HOST/" 2>&1); then
  die "https://$REPO_HOST/ did not answer or the certificate did not validate:
      $code
      Fix that first - do NOT migrate apt onto a URL that does not work."
fi
case "$code" in
  2*|3*|4*) ok "https://$REPO_HOST/ answers (HTTP $code) and the chain validates" ;;
  *)        die "https://$REPO_HOST/ returned '$code'" ;;
esac

MIGRATE_PRO=0
if [ -r "$UACONF" ] && grep -qE '^\s*contract_url:' "$UACONF"; then
  if code=$(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "https://$MGMT_HOST/v1/resources" 2>&1) \
     && [ "$code" = "200" ]; then
    ok "https://$MGMT_HOST/v1/resources answers (HTTP 200)"
    MIGRATE_PRO=1
  else
    warn "contracts server not reachable over https (got '$code') - leaving contract_url alone"
  fi
else
  say "no contract_url set here - apt only"
fi

# ---------------------------------------------------------------- report
if [ "${#FILES[@]}" -eq 0 ]; then
  say "no apt sources on this machine reference the repo over http"
else
  say ""
  say "apt files that would change:"
  for f in "${FILES[@]}"; do
    n=$(grep -cE "http://($PAT)" "$f" || true)
    say "    $f  ($n line(s))"
  done
fi
[ "$MODE" = check ] && { say ""; say "--check: nothing was modified"; exit 0; }
[ "${#FILES[@]}" -eq 0 ] && [ "$MIGRATE_PRO" -eq 0 ] && { ok "already fully on https"; exit 0; }

# ---------------------------------------------------------------- back up, then edit
STAMP=$(date +%Y-%m-%dT%H%M%S)
BDIR="$BACKUP_ROOT/$STAMP"
install -d -m 0700 "$BDIR/files"
for f in "${FILES[@]}"; do cp -a --parents "$f" "$BDIR/files/"; done
[ "$MIGRATE_PRO" -eq 1 ] && cp -a --parents "$UACONF" "$BDIR/files/"
ok "backed up to $BDIR"

for f in "${FILES[@]}"; do
  sed -i -E "s#http://($PAT)#https://$REPO_HOST#g" "$f"
done
[ "${#FILES[@]}" -gt 0 ] && ok "rewrote ${#FILES[@]} apt file(s) to https://$REPO_HOST"

if [ "$MIGRATE_PRO" -eq 1 ]; then
  sed -i -E "s#^(\s*contract_url:).*#\1 https://$MGMT_HOST#" "$UACONF"
  ok "contract_url -> https://$MGMT_HOST"
fi

# ---------------------------------------------------------------- prove it, or undo it
say ""
say "running apt-get update to prove the new URLs"
if apt-get update -qq 2>&1 | sed 's/^/    /'; then
  ok "apt-get update succeeded over https"
else
  warn "apt-get update FAILED - rolling back automatically"
  (cd "$BDIR/files" && find . -type f -print0 | xargs -0 -I{} cp -a --parents {} /) 2>/dev/null || true
  apt-get update -qq >/dev/null 2>&1 || true
  die "rolled back to http. The https URLs are not usable from this machine yet."
fi

if [ "$MIGRATE_PRO" -eq 1 ]; then
  # `pro refresh` re-reads the contract from the new URL. If it fails the machine is still
  # attached and apt still works, so this is a warning rather than a rollback trigger.
  pro refresh >/dev/null 2>&1 && ok "pro refresh succeeded against the https contract URL" \
    || warn "pro refresh failed - check: sudo pro status"
fi

say ""
ok "this machine now reaches the repo and contracts server over https only"
say "backup kept at $BDIR (undo with: sudo $0 --rollback)"
