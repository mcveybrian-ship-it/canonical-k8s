#!/usr/bin/env bash
# =========================================================================================
# make-credentials.sh - build the site credentials for an unattended rebuild (3.32 Part 3).
#
#     MACHINE: build-01 (outside the gap), with TWO PEOPLE PRESENT - the custodians who will
#     seal the emergency passwords. It refuses to run on any enclave machine.
#
#     ./make-credentials.sh -o <dir> [--site NAME] [--machines LIST|all] [--force] [--any-dir]
#
#   -o DIR       a directory ON THE REGISTERED CREDENTIALS STICK (filesystem label
#                CRED_LABEL, default enclave-cred, ext4). Anywhere else is refused.
#   --site NAME  a label for the register (default: SYSTEM_ACRONYM from facility-profile.env,
#                else this machine's name)
#   --machines   who gets a file. Default: the hosts and service VMs in enclave-addresses.env.
#                'all' adds the PG and K8S guests; or name them, e.g. host-1,svc-obs-01
#   --force      replace the files already in DIR (close the old register entry first)
#   --any-dir    allow a directory that is not on the stick - PRACTICE RUNS ONLY
#
# WHAT IT WRITES - one file per machine, holding ONLY what that machine uses:
#
#   credentials.<machine>.env   every machine: GRUB_PASSWORD_HASH, ADMIN2_PASSWORD_HASH and ITS
#                               OWN BREAKGLASS_PASSWORD_HASH_<MACHINE>; the hosts also get
#                               VM_ADMIN_PASSWORD_HASH (they compose the guests); HARBOR_* goes
#                               to HARBOR_MACHINE only, GRAFANA_* to OBS_MACHINE only.
#   REGISTER.txt                the custody record - no secret in it (see below)
#
#   Why split (2026-09-26): with one site file, every machine would briefly hold every other
#   machine's emergency hash and the REAL Harbor and Grafana passwords. Split, svc-repo-01
#   never sees Harbor's password and host-1 never holds host-2's emergency hash. On the
#   target each file is installed as /etc/enclave/credentials.env - the readers do not change.
#
# WHAT IT ENFORCES, AND WHY
#
#   Each secret is asked for twice and never shown. HASHES wherever a hash works (see
#   credentials.env.example); the passwords behind them are never written anywhere.
#
#   THE PASSWORD POLICY ITSELF. The targets' pwquality (minlen 15, one each of upper, lower,
#   digit and other, dictcheck - measured on host-1 2026-09-26) only runs when a password is
#   TYPED on the machine. A pre-made hash never passes through it (chpasswd -e), so without
#   this check the unattended route would accept passwords the interactive one rejects. The
#   dictionary part needs cracklib-check (cracklib-runtime); without it the script says so,
#   applies the rest, and the register records it.
#
#   EVERY PASSWORD DIFFERENT - above all the emergency ones: one envelope must never open two
#   machines (acting AO, 2026-09-23). Compared in memory during the run, never stored.
#
#   THE STICK, NOT A DISK. A copy on build-01's own disk is a copy outside custody that nothing
#   tracks and that cannot be destroyed without destroying build-01. The procedure, the
#   register and the stick's destruction: docs/airgap-media.md section 9.
# =========================================================================================
set -euo pipefail
umask 077

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ADDRS="$SELF/../enclave/enclave-addresses.env"
CRED_LABEL="${CRED_LABEL:-enclave-cred}"
HARBOR_MACHINE="${HARBOR_MACHINE:-SVC_HARBOR_01}"   # who gets HARBOR_*  (address-file key)
OBS_MACHINE="${OBS_MACHINE:-SVC_OBS_01}"            # who gets GRAFANA_* (address-file key)
# The enclave's machines, by their address-file key. NOT every key: STAGE_01 and BUILD_01
# live in the same file but sit outside the gap, and this script is meant to run on one.
ENCLAVE_RE='^(HOST_[0-9]+|SVC_[A-Z0-9_]+|PG_[0-9]+|K8S_(CP|WK)_[0-9]+)$'
DEFAULT_RE='^(HOST_[0-9]+|SVC_[A-Z0-9_]+)$'

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
lower() { printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-'; }
has()   { local x="$1"; shift; printf '%s\n' "$@" | grep -qxF "$x"; }   # has ITEM LIST...

# The site label defaults to the system's acronym, so the documented command needs no edit.
# A value still holding its placeholder (or anything but a plain label) falls back.
PROFILE="$SELF/../../docs/compliance/baseline/facility-profile.env"
SITE="$( [ -r "$PROFILE" ] && sed -n "s/^SYSTEM_ACRONYM='\([^']*\)'.*/\1/p" "$PROFILE" | head -1 || true)"
case "$SITE" in ""|*[!A-Za-z0-9._-]*) SITE="$(hostname -s)" ;; esac
OUT=""; MACHINES=""; FORCE=0; ANY_DIR=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="${2:-}"; shift 2 ;;
    --site) SITE="${2:-}"; shift 2 ;;
    --machines) MACHINES="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --any-dir) ANY_DIR=1; shift ;;
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
if [[ "$me_key" =~ $ENCLAVE_RE ]] && has "$me_key" "${ALL_KEYS[@]}"; then
  die "REFUSING: $(hostname -s) is an enclave machine. Run this on build-01."
fi

# ---- which machines get a file ------------------------------------------------------------
KEYS=()
case "$MACHINES" in
  "")  for k in "${ALL_KEYS[@]}"; do [[ "$k" =~ $DEFAULT_RE ]] && KEYS+=("$k"); done ;;
  all) for k in "${ALL_KEYS[@]}"; do [[ "$k" =~ $ENCLAVE_RE ]] && KEYS+=("$k"); done ;;
  *)   while IFS= read -r k; do
         [ -n "$k" ] || continue
         [[ "$k" =~ $ENCLAVE_RE ]] && has "$k" "${ALL_KEYS[@]}" \
           || die "'$(lower "$k")' is not an enclave machine in $ADDRS"
         [ "${#KEYS[@]}" -gt 0 ] && has "$k" "${KEYS[@]}" || KEYS+=("$k")
       done < <(printf '%s\n' "$MACHINES" | tr ',' '\n' | tr '[:lower:]-' '[:upper:]_') ;;
       # ^ '%s\n', not '%s': without a final newline 'read' drops the LAST name, silently.
esac
[ "${#KEYS[@]}" -gt 0 ] || die "no machines to make credentials for"

# ---- THE STICK, NOT A DISK ----------------------------------------------------------------
[ -d "$OUT" ] && [ -w "$OUT" ] || die "cannot write in $OUT - mount the credentials stick and create the directory"
OUT="$(cd "$OUT" && pwd -P)"
# One field per call: on an UNLABELLED filesystem the blank LABEL column collapses, and a single
# 'read a b' puts the type into the label.
fs_label="$(findmnt -n -o LABEL --target "$OUT" | xargs)"; fs_type="$(findmnt -n -o FSTYPE --target "$OUT" | xargs)"
case "${fs_type:-}" in
  vfat|exfat|msdos|ntfs|ntfs3|fuseblk)
    die "$OUT is on $fs_type, which cannot hold mode 600 - every file would be readable. Format the stick ext4." ;;
esac
if [ "${fs_label:-}" != "$CRED_LABEL" ]; then
  [ "$ANY_DIR" -eq 1 ] || die "$OUT is not on the registered credentials stick (want filesystem label
       '$CRED_LABEL', found '${fs_label:-none}'). A copy anywhere else is outside custody.
       Practice runs only: --any-dir"
  warn "--any-dir: $OUT is NOT the credentials stick - PRACTICE ONLY, delete it afterwards"
fi
existing="$(find "$OUT" -maxdepth 1 \( -name 'credentials.*.env' -o -name REGISTER.txt \) -printf '%f ')"
if [ -n "$existing" ] && [ "$FORCE" -ne 1 ]; then
  die "$OUT already holds: $existing- refusing to overwrite. --force only to REPLACE them."
fi

tmpd=""
trap 'stty echo 2>/dev/null || true; [ -z "$tmpd" ] || rm -rf "$tmpd"' EXIT

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
    if [ "${#SEEN[@]}" -gt 0 ] && has "$d" "${SEEN[@]}"; then
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
say "credentials for site '$SITE' -> $OUT (${#KEYS[@]} machines, one file each)"
say "every password: 15+ characters with upper, lower, digit and another character; all different."
[ "$HAVE_CRACKLIB" = 1 ] || warn "cracklib-check not installed here - the DICTIONARY check is NOT applied (apt install cracklib-runtime)"
say ""
declare -A V

ask "GRUB password (enclave-wide)" 0 0
h="$(grubhash "$SECRET")"; SECRET=""
[[ "$h" =~ ^grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-F]+\.[0-9A-F]+$ ]] || die "grub-mkpasswd-pbkdf2 produced nothing usable"
V[GRUB_PASSWORD_HASH]="$h"; ok "GRUB hash made"

ask "second named admin password" 0 0
V[ADMIN2_PASSWORD_HASH]="$(sha512 "$SECRET")"; SECRET=""; ok "second admin hash made"

say ""
say "EMERGENCY passwords - ONE PER MACHINE (${#KEYS[@]}). Seal each one for its machine only."
for k in "${KEYS[@]}"; do
  ask "EMERGENCY password for $(lower "$k")" 0 0
  V[BREAKGLASS_PASSWORD_HASH_$k]="$(sha512 "$SECRET")"; SECRET=""
done
ok "${#KEYS[@]} emergency hashes made"

# Optional items are asked for only when a machine in this run would receive them.
hosts=0; for k in "${KEYS[@]}"; do [[ "$k" =~ ^HOST_ ]] && hosts=1; done
say ""
say "OPTIONAL - press Enter to skip; a skipped item is asked for on the target instead."
if [ "$hosts" = 1 ]; then
  ask "VM admin password (compose time, every guest)" 1 0
  [ -z "$SECRET" ] || V[VM_ADMIN_PASSWORD_HASH]="$(sha512 "$SECRET")"
fi
# REAL VALUES - these consumers need the password itself, not a hash (see the .example).
if has "$HARBOR_MACHINE" "${KEYS[@]}"; then
  ask "Harbor admin password (stored as the REAL value)" 1 1
  [ -z "$SECRET" ] || V[HARBOR_ADMIN_PASSWORD]="$SECRET"
  ask "Harbor database password (stored as the REAL value)" 1 1
  [ -z "$SECRET" ] || V[HARBOR_DB_PASSWORD]="$SECRET"
fi
if has "$OBS_MACHINE" "${KEYS[@]}"; then
  ask "Grafana admin password (stored as the REAL value)" 1 1
  [ -z "$SECRET" ] || V[GRAFANA_ADMIN_PASSWORD]="$SECRET"
fi
SECRET=""

# ---- which keys each machine gets ---------------------------------------------------------
keys_for() {   # MACHINE_KEY -> the credential keys that machine uses, one per line
  local m="$1" k
  for k in GRUB_PASSWORD_HASH ADMIN2_PASSWORD_HASH "BREAKGLASS_PASSWORD_HASH_$m"; do printf '%s\n' "$k"; done
  [[ "$m" =~ ^HOST_ ]] && [ -n "${V[VM_ADMIN_PASSWORD_HASH]:-}" ] && printf '%s\n' VM_ADMIN_PASSWORD_HASH
  if [ "$m" = "$HARBOR_MACHINE" ]; then
    for k in HARBOR_ADMIN_PASSWORD HARBOR_DB_PASSWORD; do [ -z "${V[$k]:-}" ] || printf '%s\n' "$k"; done
  fi
  if [ "$m" = "$OBS_MACHINE" ] && [ -n "${V[GRAFANA_ADMIN_PASSWORD]:-}" ]; then printf '%s\n' GRAFANA_ADMIN_PASSWORD; fi
  return 0
}

# ---- write every file to a temp dir ON THE STICK, prove it, then move into place ----------
tmpd="$(mktemp -d "$OUT/.credentials.XXXXXX")"
stamp="$(date -u +%FT%TZ)"
declare -A KL   # machine -> the keys it was given; recorded HERE, while the values still exist
for m in "${KEYS[@]}"; do
  f="$tmpd/credentials.$(lower "$m").env"
  KL[$m]="$(keys_for "$m")"
  {
    printf "# credentials for %s - site %s, made %s on %s. Keys: credentials.env.example.\n" \
      "$(lower "$m")" "$SITE" "$stamp" "$(hostname -s)"
    printf "# CUSTODY-CONTROLLED. Install as /etc/enclave/credentials.env (root 600); delete after hardening.\n"
    while IFS= read -r k; do printf "%s='%s'\n" "$k" "${V[$k]}"; done <<< "${KL[$m]}"
  } > "$f"
  chmod 600 "$f"
done
for k in "${!V[@]}"; do V[$k]=""; done

# Read back the way the targets will (credentials.sh's parser), and prove each machine holds
# exactly its own keys - no other machine's emergency hash, no service password it does not run.
bad=0
for m in "${KEYS[@]}"; do
  f="$tmpd/credentials.$(lower "$m").env"
  want="${KL[$m]}"
  got="$(grep -oE "^[A-Z][A-Z0-9_]*=" "$f" | tr -d '=')"
  [ "$(printf '%s\n' "$got" | sort)" = "$(printf '%s\n' "$want" | sort)" ] \
    || { warn "$(basename "$f") holds [$(printf '%s' "$got" | tr '\n' ' ')] - expected [$(printf '%s' "$want" | tr '\n' ' ')]"; bad=1; }
  while IFS= read -r k; do
    val="$(sed -n "s/^$k='\([^']*\)'.*/\1/p" "$f" | head -1)"
    case "$k" in
      GRUB_PASSWORD_HASH) [[ "$val" =~ ^grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-F]+\.[0-9A-F]+$ ]] || { warn "$m $k is not a GRUB hash"; bad=1; } ;;
      *_HASH*)            [[ "$val" =~ ^\$6\$[^\$]+\$[./A-Za-z0-9]+$ ]] || { warn "$m $k is not SHA-512 crypt"; bad=1; } ;;
      *)                  [ -n "$val" ] || { warn "$m $k reads back empty"; bad=1; } ;;
    esac
  done <<< "$got"
  [ "$(stat -c %a "$f")" = 600 ] || { warn "$(basename "$f") is not mode 600"; bad=1; }
done
val=""
[ "$bad" -eq 0 ] || die "read-back failed - nothing was moved into place"

# Replacing: the old files go only now, once the new set is proven.
if [ -n "$existing" ]; then
  find "$OUT" -maxdepth 1 \( -name 'credentials.*.env' -o -name REGISTER.txt \) -delete
  say "replaced: $existing"
fi
mv "$tmpd"/credentials.*.env "$OUT"/; rmdir "$tmpd"; tmpd=""
ok "wrote ${#KEYS[@]} files to $OUT (mode 600), each read back and holding only its own keys"

# ---- the register: NO SECRET - what custody needs to track every file to its destruction ---
reg="$OUT/REGISTER.txt"
{
  printf 'SITE CREDENTIALS - CUSTODY REGISTER (holds no secret)      docs/airgap-media.md section 9\n\n'
  printf '  made         %s on %s, account %s\n' "$stamp" "$(hostname -s)" "$(id -un)"
  printf '  site         %s\n' "$SITE"
  printf '  medium       filesystem label %s     medium ID ________________\n' "${fs_label:-NONE - practice}"
  printf '  dictionary   %s\n' "$([ "$HAVE_CRACKLIB" = 1 ] && echo checked || echo 'NOT checked (no cracklib-check on this machine)')"
  printf '  made by      ______________________   witness ______________________\n\n'
  printf '  %-34s %-12s %-4s  %s\n' "file" "sha256 (12)" "keys" "placed (date/by)      deleted from target (date/by)"
  for m in "${KEYS[@]}"; do
    f="$OUT/credentials.$(lower "$m").env"
    printf '  %-34s %-12s %-4s  ____________________  ____________________\n' \
      "$(basename "$f")" "$(sha256sum "$f" | cut -c1-12)" "$(grep -cE "^[A-Z]" "$f")"
  done
  printf '\n  full sha256 of each file:\n'
  for m in "${KEYS[@]}"; do f="$OUT/credentials.$(lower "$m").env"; printf '    %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"; done
  printf '\n  envelopes    %s emergency passwords sealed, one per machine, signed across the seal\n' "${#KEYS[@]}"
  printf '               by both custodians: ______ / ______   location ____________________\n'
  printf '  stick        DESTROYED on ____________ by ______________ witness ______________\n'
  printf '               method ____________________ (NIST SP 800-88r2 3.1.3 - not wiped: flash\n'
  printf '               wear-levelling defeats overwrite)      register CLOSED ____________\n'
} > "$reg"
chmod 644 "$reg"
say ""; sed 's/^/  /' "$reg"; say ""
ok "REGISTER.txt is on the stick; copy it into the custody log. It holds no secret."
