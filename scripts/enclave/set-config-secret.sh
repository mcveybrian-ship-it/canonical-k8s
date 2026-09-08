#!/usr/bin/env bash
# =========================================================================================
# set-config-secret.sh - put a typed secret into a config file without it leaking.
#
#   sudo ./set-config-secret.sh <file> <key> [<key> ...]
#
#   sudo ./set-config-secret.sh /opt/harbor-src/harbor/harbor.yml \
#        harbor_admin_password password
#
# WHY THIS EXISTS RATHER THAN AN EDITOR OR A sed:
#
#   Config files that ship with a publicly-known default password - harbor.yml has TWO,
#   Harbor12345 and root123 - have to be edited before the service starts. The obvious ways
#   are all bad:
#
#     sed -i "s/old/$NEWPASS/" file    the secret is in the command line, therefore in
#                                      shell history and visible in `ps` while it runs
#     nano / vim                       fine, but needs an editor on a deliberately slim VM,
#                                      and invites a typo in a file nobody re-reads
#     echo "$PASS" | ...               same command-line and history exposure
#
#   This reads with getpass, which opens /dev/tty directly. The value never appears in the
#   command line, in history, in `ps`, or in this script's own arguments.
#
#   It also verifies the key was actually replaced. A sed that silently matches nothing
#   leaves the default password in place and the service starts anyway - with the published
#   credential still live.
# =========================================================================================
set -euo pipefail

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

FILE="${1:-}"; shift || true
[ -n "$FILE" ] && [ $# -gt 0 ] || die "usage: sudo $0 <file> <key> [<key> ...]"
[ -w "$FILE" ] || die "cannot write $FILE - run with sudo"
[ "$(id -u)" -eq 0 ] || die "run with sudo"

# Back up before touching it. A half-edited config for a service that will not start is a
# worse position than the default password, because it is less obvious what happened.
BACKUP="$FILE.bak-$(date +%Y%m%dT%H%M%S)"
cp -a "$FILE" "$BACKUP"
chmod 0600 "$BACKUP"
say "backup: $BACKUP (0600 - it still holds the OLD secret)"

for key in "$@"; do
  FILE="$FILE" KEY="$key" python3 - <<'PYEOF'
import getpass, os, re, sys, pathlib
f = pathlib.Path(os.environ["FILE"]); key = os.environ["KEY"]
s = f.read_text()
# Anchored to a whole line so "password" does not also match "db_password" or a comment.
pat = re.compile(rf'^(\s*){re.escape(key)}:\s*\S.*$', re.M)
if not pat.search(s):
    print(f"  [x] no line matching '{key}:' with a value in {f}", file=sys.stderr); sys.exit(1)
v1 = getpass.getpass(f"  {key}: ")
v2 = getpass.getpass(f"  {key} (again): ")
if v1 != v2:
    print("  [x] the two entries do not match", file=sys.stderr); sys.exit(1)
if not v1:
    print("  [x] refusing to set an empty value", file=sys.stderr); sys.exit(1)
s, n = pat.subn(lambda m: f"{m.group(1)}{key}: {v1}", s, count=1)
if n != 1:
    print(f"  [x] replaced {n} occurrences, expected 1", file=sys.stderr); sys.exit(1)
f.write_text(s)
print(f"  [ok] {key} set")
PYEOF
done

say ""
say "Confirm no published default survived - this prints NO values:"
say "    sudo grep -cE 'Harbor12345|root123|changeme|CHANGEME' $FILE"
say ""
say "Then remove the backup once the service starts - it holds the old secret:"
say "    sudo shred -u $BACKUP"
