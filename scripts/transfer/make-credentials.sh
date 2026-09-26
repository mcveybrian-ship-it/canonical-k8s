#!/usr/bin/env bash
# =========================================================================================
# make-credentials.sh - build the site credentials file for an unattended rebuild (3.32 Part 3).
#
#     MACHINE: build-01 (outside the gap), with TWO PEOPLE PRESENT - the custodians who will
#     seal the emergency passwords. It refuses to run on any enclave machine.
#
#     ./make-credentials.sh -o <file> [--site NAME] [--machines LIST|all] [--force]
#
#   -o FILE      where to write the credentials file (it must not exist unless --force)
#   --site NAME  a label for the register entry (default: this machine's name)
#   --machines   who gets an emergency password. Default: the hosts and service VMs in
#                enclave-addresses.env. 'all' adds the PG and K8S guests; or name them,
#                e.g. --machines host-1,svc-obs-01
#   --force      replace an existing file (the old one's register entry must then be closed)
#
# WHAT IT DOES, AND WHY THIS WAY
#
#   It asks for every secret the rebuild would otherwise stop and ask for, twice, never showing
#   it, and writes HASHES wherever a hash works (see credentials.env.example for each key).
#   The passwords behind the hashes are never written anywhere by this script.
#
#   IT ENFORCES THE PASSWORD POLICY ITSELF. The targets' pwquality (minlen 15, one each of
#   upper, lower, digit and other, dictcheck - measured on host-1 2026-09-26) only runs when a
#   password is TYPED on the machine. A pre-made hash never passes through it (chpasswd -e), so
#   without this check the unattended route would accept passwords the interactive one rejects.
#   The dictionary part needs cracklib-check (package cracklib-runtime); without it the script
#   says so and applies the rest.
#
#   EVERY PASSWORD MUST BE DIFFERENT - above all the emergency ones: one envelope must never
#   open two machines (acting AO, 2026-09-23). Compared in memory during the run, never stored.
#
#   It ends with a REGISTER ENTRY that holds no secret - the file's sha256, which items it
#   holds, and blanks for who made it, the witness, the medium and the destroy-by date. That
#   entry goes in the custody log (docs/airgap-media.md, credential custody).
# =========================================================================================
set -euo pipefail
umask 077

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ADDRS="$SELF/../enclave/enclave-addresses.env"
# The enclave's machines, by their address-file key. NOT every key: STAGE_01 and BUILD_01
# live in the same file but sit outside the gap, and this script is meant to run on one.
ENCLAVE_RE='^(HOST_[0-9]+|SVC_[A-Z0-9_]+|PG_[0-9]+|K8S_(CP|WK)_[0-9]+)$'
DEFAULT_RE='^(HOST_[0-9]+|SVC_[A-Z0-9_]+)$'

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-'; }

OUT=""; SITE="$(hostname -s)"; MACHINES=""; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="${2:-}"; shift 2 ;;
    --site) SITE="${2:-}"; shift 2 ;;
    --machines) MACHINES="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$OUT" ] || usage
[ -r "$ADDRS" ] || die "no address file at $ADDRS"
[ -t 0 ] || die "needs a terminal - the secrets are typed, never piped or passed as arguments"
command -v openssl >/dev/null || die "openssl not found"
command -v grub-mkpasswd-pbkdf2 >/dev/null || die "grub-mkpasswd-pbkdf2 not found (package grub-common)"

ALL_KEYS=()
while IFS= read -r k; do ALL_KEYS+=("$k"); done < <(grep -oE '^[A-Z0-9_]+=' "$ADDRS" | tr -d '=')

# ---- REFUSE TO RUN INSIDE THE ENCLAVE -----------------------------------------------------
# Making credentials on a machine they will protect puts them on it before custody begins.
me_key="$(hostname -s | tr '[:lower:]-' '[:upper:]_')"
if [[ "$me_key" =~ $ENCLAVE_RE ]] && printf '%s\n' "${ALL_KEYS[@]}" | grep -qxF "$me_key"; then
  die "REFUSING: $(hostname -s) is an enclave machine. Run this on build-01."
fi

# ---- which machines get an emergency password ---------------------------------------------
KEYS=()
case "$MACHINES" in
  "")  for k in "${ALL_KEYS[@]}"; do [[ "$k" =~ $DEFAULT_RE ]] && KEYS+=("$k"); done ;;
  all) for k in "${ALL_KEYS[@]}"; do [[ "$k" =~ $ENCLAVE_RE ]] && KEYS+=("$k"); done ;;
  *)   while IFS= read -r k; do
         [ -n "$k" ] || continue
         [[ "$k" =~ $ENCLAVE_RE ]] && printf '%s\n' "${ALL_KEYS[@]}" | grep -qxF "$k" \
           || die "'$(lower "$k")' is not an enclave machine in $ADDRS"
         [ "${#KEYS[@]}" -gt 0 ] && printf '%s\n' "${KEYS[@]}" | grep -qxF "$k" || KEYS+=("$k")
       done < <(printf '%s\n' "$MACHINES" | tr ',' '\n' | tr '[:lower:]-' '[:upper:]_') ;;
       # ^ '%s\n', not '%s': without a final newline 'read' drops the LAST name, silently.
esac
[ "${#KEYS[@]}" -gt 0 ] || die "no machines to make emergency passwords for"

if [ -e "$OUT" ] && [ "$FORCE" -ne 1 ]; then
  die "$OUT already exists - refusing to overwrite a credentials file. Use --force only to REPLACE it."
fi
OUTDIR="$(dirname "$OUT")"
[ -d "$OUTDIR" ] && [ -w "$OUTDIR" ] || die "cannot write in $OUTDIR"

tmp=""
trap 'stty echo 2>/dev/null || true; [ -z "$tmp" ] || rm -f "$tmp"' EXIT

# ---- one secret: twice, silently, policy-checked, never reused ----------------------------
HAVE_CRACKLIB=0; command -v cracklib-check >/dev/null && HAVE_CRACKLIB=1
SEEN=()   # sha256 of each secret accepted in THIS run, to refuse reuse. Memory only.

policy_ok() {   # $1 candidate, $2 = 1 when stored as the REAL value. Mirrors the targets' pwquality.
  local p="$1" r
  [ "${#p}" -ge 15 ]         || { warn "too short: ${#p} characters, the policy wants 15"; return 1; }
  [[ "$p" =~ [A-Z] ]]        || { warn "needs an upper-case letter"; return 1; }
  [[ "$p" =~ [a-z] ]]        || { warn "needs a lower-case letter"; return 1; }
  [[ "$p" =~ [0-9] ]]        || { warn "needs a digit"; return 1; }
  [[ "$p" =~ [^A-Za-z0-9] ]] || { warn "needs a character that is not a letter or digit"; return 1; }
  if [ "$2" = 1 ] && [[ "$p" == *"'"* ]]; then
    warn "a value stored as-is cannot contain a single quote (the file format uses them)"; return 1
  fi
  if [ "$HAVE_CRACKLIB" = 1 ]; then
    # cracklib-check echoes the word back - capture it, print only the verdict after it.
    r="$(printf '%s\n' "$p" | cracklib-check)"; r="${r##*: }"
    [ "$r" = OK ] || { warn "dictionary check: $r"; return 1; }
  fi
  return 0
}

# ask LABEL OPTIONAL REAL -> sets SECRET (left empty only when OPTIONAL=1 and Enter was pressed)
ask() {
  local label="$1" optional="$2" real="$3" a b d
  SECRET=""
  for _ in 1 2 3; do
    read -rsp "  $label: " a || die "input closed - nothing written"; echo
    if [ -z "$a" ]; then
      [ "$optional" = 1 ] && { say "   skipped - the target will prompt for it instead"; return 0; }
      warn "required"; continue
    fi
    read -rsp "  again: " b || die "input closed - nothing written"; echo
    if [ "$a" != "$b" ]; then warn "the two entries differ - try again"; a=""; b=""; continue; fi
    b=""
    policy_ok "$a" "$real" || { a=""; continue; }
    d="$(printf '%s' "$a" | sha256sum | cut -c1-64)"
    if [ "${#SEEN[@]}" -gt 0 ] && printf '%s\n' "${SEEN[@]}" | grep -qxF "$d"; then
      warn "already used for another item in this file - every password must be different"; a=""; continue
    fi
    SEEN+=("$d"); SECRET="$a"; a=""; return 0
  done
  die "three failed attempts for '$label' - nothing written"
}
# Both read the password on STDIN - never as an argument, where ps would show it.
sha512()   { printf '%s' "$1" | openssl passwd -6 -stdin; }
grubhash() { printf '%s\n%s\n' "$1" "$1" | grub-mkpasswd-pbkdf2 | awk '/PBKDF2 hash/{print $NF}'; }

# ---- collect ------------------------------------------------------------------------------
say "credentials file for site '$SITE' -> $OUT"
say "every password: 15+ characters with upper, lower, digit and another character; all different."
[ "$HAVE_CRACKLIB" = 1 ] || warn "cracklib-check not installed here - the DICTIONARY check is NOT applied (apt install cracklib-runtime)"
say ""
declare -A V; ITEMS=()
put() { V[$1]="$2"; ITEMS+=("$1"); }

ask "GRUB password (enclave-wide)" 0 0
h="$(grubhash "$SECRET")"; SECRET=""
[[ "$h" =~ ^grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-F]+\.[0-9A-F]+$ ]] || die "grub-mkpasswd-pbkdf2 produced nothing usable"
put GRUB_PASSWORD_HASH "$h"; ok "GRUB hash made"

ask "second named admin password" 0 0
put ADMIN2_PASSWORD_HASH "$(sha512 "$SECRET")"; SECRET=""; ok "second admin hash made"

say ""
say "EMERGENCY passwords - ONE PER MACHINE (${#KEYS[@]}). Seal each one for its machine only."
for k in "${KEYS[@]}"; do
  ask "EMERGENCY password for $(lower "$k")" 0 0
  put "BREAKGLASS_PASSWORD_HASH_$k" "$(sha512 "$SECRET")"; SECRET=""
done
ok "${#KEYS[@]} emergency hashes made"

say ""
say "OPTIONAL - press Enter to skip; a skipped item is asked for on the target instead."
ask "VM admin password (compose time)" 1 0
[ -z "$SECRET" ] || put VM_ADMIN_PASSWORD_HASH "$(sha512 "$SECRET")"
# REAL VALUES - these consumers need the password itself, not a hash (see the .example).
ask "Harbor admin password (stored as the REAL value)" 1 1
[ -z "$SECRET" ] || put HARBOR_ADMIN_PASSWORD "$SECRET"
ask "Harbor database password (stored as the REAL value)" 1 1
[ -z "$SECRET" ] || put HARBOR_DB_PASSWORD "$SECRET"
ask "Grafana admin password (stored as the REAL value)" 1 1
[ -z "$SECRET" ] || put GRAFANA_ADMIN_PASSWORD "$SECRET"
SECRET=""

# ---- write, atomically, mode 600 ----------------------------------------------------------
tmp="$(mktemp "$OUTDIR/.credentials.XXXXXX")"
{
  printf "# credentials.env - site %s, made %s on %s. Keys explained in credentials.env.example.\n" \
    "$SITE" "$(date -u +%FT%TZ)" "$(hostname -s)"
  printf "# CUSTODY-CONTROLLED. Never commit it, never copy it to a runtime dir, delete it from the target after hardening.\n"
  for k in "${ITEMS[@]}"; do printf "%s='%s'\n" "$k" "${V[$k]}"; done
} > "$tmp"
chmod 600 "$tmp"; mv -f "$tmp" "$OUT"; tmp=""
for k in "${ITEMS[@]}"; do V[$k]=""; done

# ---- prove what was written, reading it the way the targets will --------------------------
bad=0
for k in "${ITEMS[@]}"; do
  val="$(sed -n "s/^$k='\([^']*\)'.*/\1/p" "$OUT" | head -1)"
  case "$k" in
    GRUB_PASSWORD_HASH) [[ "$val" =~ ^grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-F]+\.[0-9A-F]+$ ]] || { warn "$k does not read back as a GRUB hash"; bad=1; } ;;
    *_HASH*)            [[ "$val" =~ ^\$6\$[^\$]+\$[./A-Za-z0-9]+$ ]] || { warn "$k does not read back as SHA-512 crypt"; bad=1; } ;;
    *)                  [ -n "$val" ] || { warn "$k reads back empty"; bad=1; } ;;
  esac
done
val=""
[ "$bad" -eq 0 ] || die "$OUT failed its read-back - do not use it; re-run with --force"
[ "$(stat -c %a "$OUT")" = 600 ] || die "$OUT is not mode 600"
ok "wrote $OUT (mode 600): ${#ITEMS[@]} items, each read back and checked"

# ---- the register entry: NO SECRET, only what custody needs to track the file -------------
names=""; for k in "${KEYS[@]}"; do names="$names $(lower "$k")"; done
reg="$OUT.register.txt"
{
  printf 'CREDENTIAL MATERIAL - REGISTER ENTRY (holds no secret)\n'
  printf '  made         %s UTC on %s, account %s\n' "$(date -u '+%F %T')" "$(hostname -s)" "$(id -un)"
  printf '  site         %s\n' "$SITE"
  printf '  file         %s\n' "$(basename "$OUT")"
  printf '  sha256       %s\n' "$(sha256sum "$OUT" | cut -d' ' -f1)"
  printf '  items        %s\n' "${ITEMS[*]}"
  printf '  emergency    %s machines:%s\n' "${#KEYS[@]}" "$names"
  printf '  dictionary   %s\n' "$([ "$HAVE_CRACKLIB" = 1 ] && echo checked || echo 'NOT checked (no cracklib-check)')"
  printf '  made by      ______________________   witness  ______________________\n'
  printf '  medium / ID  ______________________   location ______________________\n'
  printf '  destroy by   ______________________   (delete from each target after hardening; wipe the medium - MP-6)\n'
} > "$reg"
chmod 644 "$reg"
say ""; sed 's/^/  /' "$reg"; say ""
ok "register entry also saved to $reg - copy it into the custody log and keep it with the medium"
