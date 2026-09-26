# shellcheck shell=bash
# =========================================================================================
# credentials.sh - read the site credentials file (backlog 3.32). SOURCED, never run.
#
#     . "$HERE/credentials.sh"        by stig-tailor.sh, monitoring.sh, set-config-secret.sh
#                                     and 03-compose-vm.sh - the ONE copy of this logic.
#
#   cred_require_safe   call in the MAIN shell before the first cred_get. Stops the run if
#                       the file exists but is not root-owned mode 600, or cannot be read.
#   cred_get KEY        prints KEY's value, or nothing if the file or the key is absent.
#
# WHY THE CHECK IS A SEPARATE CALL (found 2026-09-26): cred_get usually runs inside $(...).
# A refusal there only ends the SUBSHELL - the script prints it and carries on to a prompt,
# and when cred_get is a function ARGUMENT not even set -e stops it. Proven on the shape used
# for the second admin. A refusal that the caller can walk past is not a refusal, so the
# decision is made once, up front, where 'exit' actually ends the run.
#
# The file: KEY='value' per line, root 600, parsed with sed and NEVER sourced - a secrets
# file is data, not code. Keys: credentials.env.example. Made by make-credentials.sh.
# Precedence in every consumer: environment variable > this file > prompt at the terminal.
# =========================================================================================
ENCLAVE_CREDENTIALS="${ENCLAVE_CREDENTIALS:-/etc/enclave/credentials.env}"

cred_require_safe() {
  local f="$ENCLAVE_CREDENTIALS" m
  [ -e "$f" ] || return 0
  m="$(stat -c '%U %a' "$f" 2>&1)" || m="stat failed: $m"
  if [ "$m" != "root 600" ]; then
    printf '\n  [x] %s is not root-owned mode 600 (%s) - refusing to read credentials from it.\n' "$f" "$m" >&2
    printf '      A readable hash is a hash an offline cracker can work on. If this copy is yours:\n' >&2
    printf '        sudo chown root:root %s && sudo chmod 600 %s\n\n' "$f" "$f" >&2
    exit 1
  fi
  # Without this, an unprivileged run gets "Permission denied" from sed, reads nothing, and
  # falls back to a prompt - which looks like "the file does not have that key".
  if [ ! -r "$f" ]; then
    printf '\n  [x] %s exists but this run cannot read it - run with sudo.\n\n' "$f" >&2
    exit 1
  fi
  # EVERY LINE IN THE EXACT FORMAT, or nothing is read (found 2026-09-26). The parser stops
  # at the first ' - so KEY='It's-long' read back as "It", and a 2-character password went
  # into the config with no error. make-credentials.sh refuses quotes; a hand edit would not.
  # Reports line NUMBERS only - the content is the secret.
  # '|| true': a clean file makes grep exit 1, and under pipefail + set -e that ended the run
  # SILENTLY - exit 1, no message - on every GOOD file (caught in testing, 2026-09-26).
  local bad
  bad="$( { grep -nvE "^([[:space:]]*(#.*)?|[A-Z][A-Z0-9_]*='[^']*'[[:space:]]*)$" "$f" || true; } | cut -d: -f1 | paste -sd, -)"
  if [ -n "$bad" ]; then
    printf "\n  [x] %s has line(s) not in the form KEY='value' (a value cannot contain '): line %s.\n" "$f" "$bad" >&2
    printf '      Nothing was read from it. Re-make it with make-credentials.sh rather than editing it.\n\n' >&2
    exit 1
  fi
}

cred_get() {
  local f="$ENCLAVE_CREDENTIALS"
  [ -e "$f" ] || return 0
  # Re-checked here too, in case the file changed after cred_require_safe. From inside $(...)
  # this can only fail the read, not the run - which is why cred_require_safe exists.
  [ "$(stat -c '%U %a' "$f" 2>/dev/null)" = "root 600" ] \
    || { printf '  [x] %s is no longer root 600 - not reading it\n' "$f" >&2; return 1; }
  sed -n "s/^$1='\\([^']*\\)'.*/\\1/p" "$f" | head -1
}
