#!/usr/bin/env bash
# =========================================================================================
# set-config-secret.sh - put a secret into a config file without it leaking.
#
#   sudo ./set-config-secret.sh <file> <key>[=<CRED_KEY>] [<key>[=<CRED_KEY>] ...]
#
#   sudo ./set-config-secret.sh /opt/harbor-src/harbor/harbor.yml \
#        harbor_admin_password=HARBOR_ADMIN_PASSWORD password=HARBOR_DB_PASSWORD
#
#   MACHINE: whichever machine owns the file - svc-harbor-01 for harbor.yml, before Harbor
#   first starts (runbook 4.5b).
#
#   <key>             the YAML key whose value is replaced (a whole-line match, see below)
#   =<CRED_KEY>       where the value may come from without anyone typing it (3.32):
#                     the environment variable CRED_KEY > CRED_KEY in the site credentials
#                     file (/etc/enclave/credentials.env, root 600 - credentials.sh) > asked
#                     for at the terminal. Without =<CRED_KEY> it is always asked for.
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
#   A typed value is read with getpass, which opens /dev/tty directly; a supplied one reaches
#   python through its environment (readable only by root). Neither appears in the command
#   line, in history, in `ps`, or in this script's arguments.
#
#   It verifies the key matched EXACTLY ONE line before asking, and that the file still parses
#   as YAML with the new value in place afterwards. A sed that silently matches nothing leaves
#   the default password in place and the service starts anyway - with the published
#   credential still live.
#
#   THE VALUE IS WRITTEN SINGLE-QUOTED (2026-09-26). It used to go in bare, and the password
#   policy REQUIRES a symbol: a value starting with ! & * or containing " #" is not the string
#   it looks like to a YAML parser - it becomes a tag, an anchor, or a truncated comment.
# =========================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

FILE="${1:-}"; shift || true
[ -n "$FILE" ] && [ $# -gt 0 ] || die "usage: sudo $0 <file> <key>[=<CRED_KEY>] [...]"
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -w "$FILE" ] || die "cannot write $FILE"

# ---- resolve every value BEFORE touching the file -----------------------------------------
# A run that sets the first key and then stops on the second leaves a half-edited config.
# shellcheck source=credentials.sh
. "$HERE/credentials.sh"
KEYS=(); CREDS=(); SRCS=(); need_tty=0; checked=0
for arg in "$@"; do
  key="${arg%%=*}"; ck=""; [ "$arg" = "$key" ] || ck="${arg#*=}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "'$key' is not a plain config key"
  src="typed"
  if [ -n "$ck" ]; then
    [[ "$ck" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "'$ck' is not a credentials key name"
    if [ -n "${!ck:-}" ]; then src="env:$ck"
    else
      [ "$checked" = 1 ] || { cred_require_safe; checked=1; }
      [ -z "$(cred_get "$ck")" ] || src="file:$ck"
    fi
  fi
  [ "$src" = typed ] && need_tty=1
  KEYS+=("$key"); CREDS+=("$ck"); SRCS+=("$src")
done
[ "$need_tty" = 0 ] || [ -t 0 ] || die "a value has to be typed and there is no terminal - supply it as
       <key>=<CRED_KEY> with CRED_KEY in the environment or in $ENCLAVE_CREDENTIALS"

# Back up before touching it. A half-edited config for a service that will not start is a
# worse position than the default password, because it is less obvious what happened.
BACKUP="$FILE.bak-$(date +%Y%m%dT%H%M%S)"
cp -a "$FILE" "$BACKUP"
chmod 0600 "$BACKUP"
say "backup: $BACKUP (0600 - it still holds the OLD secret)"

# One python run per key. File and key go in through the environment, and so does a supplied
# value (SECRET_VALUE); a typed one comes only from getpass, asked twice.
for i in "${!KEYS[@]}"; do
  key="${KEYS[$i]}"; src="${SRCS[$i]}"; ck="${CREDS[$i]}"; val=""
  case "$src" in
    env:*)  val="${!ck}";  say "$key: value from \$$ck (environment)" ;;
    file:*) val="$(cred_get "$ck")"; say "$key: value from $ck in $ENCLAVE_CREDENTIALS" ;;
  esac
  FILE="$FILE" KEY="$key" SECRET_VALUE="$val" python3 - <<'PYEOF'
import getpass, os, re, sys, pathlib
f = pathlib.Path(os.environ["FILE"]); key = os.environ["KEY"]
s = f.read_text()
# Anchored to a whole line so "password" does not also match "db_password" or a comment.
pat = re.compile(rf'^(\s*){re.escape(key)}:\s*\S.*$', re.M)
n = len(pat.findall(s))
if n != 1:
    # Counted BEFORE replacing: sub(count=1) would report 1 even with two candidate lines,
    # and quietly change whichever came first.
    print(f"  [x] {n} lines match '{key}:' with a value in {f} - expected exactly 1", file=sys.stderr); sys.exit(1)
v1 = os.environ.get("SECRET_VALUE", "")
if not v1:
    v1 = getpass.getpass(f"  {key}: ")
    v2 = getpass.getpass(f"  {key} (again): ")
    if v1 != v2:
        print("  [x] the two entries do not match", file=sys.stderr); sys.exit(1)
if not v1:
    print("  [x] refusing to set an empty value", file=sys.stderr); sys.exit(1)
if "\n" in v1 or "\r" in v1:
    print("  [x] refusing a value with a line break in it", file=sys.stderr); sys.exit(1)
quoted = "'" + v1.replace("'", "''") + "'"   # YAML single-quoted: only ' needs escaping, as ''
s = pat.sub(lambda m: f"{m.group(1)}{key}: {quoted}", s, count=1)
# PROVE IT READS BACK as the value, the way the consumer's YAML parser will read it.
try:
    import yaml
except ImportError:
    yaml = None
if yaml is not None:
    def found(node):
        if isinstance(node, dict):
            return any((k == key and v == v1) or found(v) for k, v in node.items())
        if isinstance(node, list):
            return any(found(x) for x in node)
        return False
    try:
        tree = yaml.safe_load(s)
    except yaml.YAMLError as e:
        print(f"  [x] the edited file would not parse as YAML - NOT written: {e}", file=sys.stderr); sys.exit(1)
    if not found(tree):
        print(f"  [x] after the edit, '{key}' does not read back as the new value - NOT written", file=sys.stderr); sys.exit(1)
f.write_text(s)
print(f"  [ok] {key} set" + ("" if yaml is not None else " (python3-yaml missing - NOT parse-checked)"))
PYEOF
  val=""
done

say ""
say "Confirm no published default survived - this prints NO values:"
say "    sudo grep -cE 'Harbor12345|root123|changeme|CHANGEME' $FILE"
say ""
say "Then remove the backup once the service starts - it holds the old secret:"
say "    sudo shred -u $BACKUP"
