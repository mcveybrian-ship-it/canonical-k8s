#!/usr/bin/env bash
# =========================================================================================
# audit-offload.sh - weekly offload of audit records to the in-boundary collector.
#
#     MACHINE: every hardened enclave machine (agent). `collector-init`, `prune` and
#              `verify` run on the COLLECTOR, which is svc-obs-01.
#
#     ./audit-offload.sh plan            # read-only: what would be sent, and where
#     sudo ./audit-offload.sh run        # one offload now
#     sudo ./audit-offload.sh install    # weekly systemd timer
#     ./audit-offload.sh status
#     sudo ./audit-offload.sh collector-init   # ON THE COLLECTOR - drop dir + the key line
#     sudo ./audit-offload.sh prune            # ON THE COLLECTOR - enforce retention
#     ./audit-offload.sh verify                # ON THE COLLECTOR - re-check every checksum
#
# WHAT THIS CLOSES, AND WHAT IT DOES NOT
#
#   UBTU-24-900950 (`auditd_offload_logs`) asks for "a crontab script running weekly to
#   offload audit events of standalone systems". DISA contemplates air-gapped machines and
#   its answer is a SCHEDULED OFFLOAD, not a live feed. This is that script.
#
#   It does NOT close UBTU-24-100450, the audit event multiplexor rule. That one passes
#   today with `active = yes` in au-remote.conf pointing at nothing - a HOLLOW PASS, see
#   runbook 6.3d - and closing it honestly needs audisp-remote actually delivering, which
#   is the next piece of work. Do not let this script be mistaken for that one.
#
# WHY A BUNDLE AND NOT JUST AN rsync OF /var/log/audit
#
#   The AO's answer (2026-09-23) was that the design must serve BOTH a self-contained
#   enclave AND a future external SIEM. A directory of rotated files serves the first and
#   not the second. A self-describing bundle serves both: the manifest records which machine
#   produced it, over what period, at what auditd allocation, and the checksum of every
#   member - so a SIEM ingesting it a year from now, over sneakernet or a one-way device,
#   does not need this enclave to interpret it.
#
# WHY IT FORCES A ROTATION FIRST
#
#   auditd writes to audit.log and rotates to audit.log.1..N. Only the ROTATED files are
#   safe to copy - the live one is being appended to. But a machine at 3.65 MB/day against
#   a 64 MB allocation may not rotate for a fortnight, so "weekly offload" of rotated files
#   only would be weekly in name and monthly in fact. SIGUSR1 makes auditd rotate on demand.
#   That is the documented signal; auditd refuses a plain restart and killing it drops
#   records.
#
# SIGNING
#
#   Bundles are CHECKSUMMED, not signed - decided 2026-09-23. Checksums detect corruption;
#   signatures detect tampering and need a key with a custody answer, which is backlog 3.7.
#   The manifest carries an explicit `signature: none` line and a note, so adding detached
#   signatures later does not invalidate or reformat earlier bundles.
#
# THE RECEIVING KEY IS RESTRICTED ON THE RECEIVER, NOT TRUSTED HERE
#
#   Same pattern as vm-backup.sh second-copy: `rrsync -wo` as a forced command, so the key
#   can only WRITE, only into one directory, and only from one address. A compromised
#   machine can add its own records; it cannot read or delete anyone else's - which is the
#   entire point of offloading in the first place.
#
#   IdentitiesOnly=yes is not decoration. Without it ssh also offers root's default key,
#   the forced rrsync command never applies, and the transfer SUCCEEDS while silently
#   bypassing the restriction. Same trap as vm-backup.sh.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDRS="${AUDIT_ADDRS:-$SELF/enclave-addresses.env}"

AUDIT_DIR="${AUDIT_DIR:-/var/log/audit}"
ACONF="${AUDIT_ACONF:-/etc/audit/auditd.conf}"
DROP="${AUDIT_DROP_DIR:-/srv/audit-offload}"
KEY="${AUDIT_KEY:-/etc/enclave/audit-offload.key}"
RETENTION_DAYS="${AUDIT_RETENTION_DAYS:-365}"
STATE="${AUDIT_STATE:-/var/local/enclave-metrics/audit-offload.state}"
UNIT="enclave-audit-offload"
ROTATE_WAIT="${AUDIT_ROTATE_WAIT:-10}"
RUN_TMP=""            # staging dir for `run`; global so the EXIT trap can still see it

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

[ -r "$ADDRS" ] || die "no address file at $ADDRS"
# shellcheck disable=SC1090
. "$ADDRS"
: "${SVC_OBS_01:?SVC_OBS_01 not set in $ADDRS}"

COLLECTOR="${AUDIT_COLLECTOR:-$SVC_OBS_01}"
ME="$(hostname -s)"

# Is this machine the collector? Then `run` copies locally instead of over ssh - the
# collector audits itself too, and a machine cannot rsync to itself over a forced command.
is_collector() {
  local a
  a="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)" || true
  printf '%s\n' "$a" | grep -qx "$COLLECTOR"
}

my_addr() {
  local p="${SVC_OBS_01%.*}."            # the enclave prefix, from the address file
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | grep "^${p}" | head -1 || true
}

alloc_mb() {
  local m n
  m="$(awk -F= '/^max_log_file[[:space:]]*=/{gsub(/ /,"",$2); print $2}' "$ACONF" 2>/dev/null | head -1)" || true
  n="$(awk -F= '/^num_logs[[:space:]]*=/{gsub(/ /,"",$2); print $2}' "$ACONF" 2>/dev/null | head -1)" || true
  printf '%s' "$(( ${m:-0} * ${n:-0} ))"
}

# Rotated files only. The live audit.log is being appended to and is never copied.
rotated_files() {
  find "$AUDIT_DIR" -maxdepth 1 -type f -name 'audit.log.*' 2>/dev/null | sort || true
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
          -o LogLevel=ERROR -o IdentitiesOnly=yes)

# -----------------------------------------------------------------------------------------
cmd_plan() {
  printf '\n  audit offload - plan for %s\n\n' "$ME"
  if is_collector; then
    say "collector : $COLLECTOR (THIS MACHINE - bundles are written locally)"
  else
    say "collector : $COLLECTOR (over ssh)"
  fi
  say "drop dir  : $DROP"
  say "retention : $RETENTION_DAYS days"
  if [ -r "$ACONF" ]; then
    say "allocation: $(alloc_mb) MB"
  else
    say "allocation: $ACONF not readable as this user"
  fi

  local n=0 bytes=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1)); bytes=$(( bytes + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
  done <<< "$(rotated_files)"
  if [ "$n" -eq 0 ]; then
    say "rotated   : none yet - 'run' forces a rotation first, so this is not a blocker"
  else
    say "rotated   : $n file(s), $(( bytes / 1024 )) KB would be bundled"
  fi

  if is_collector; then
    say "key       : not needed - this machine IS the collector"
  elif [ -r "$KEY" ]; then
    ok "key       : $KEY present"
  else
    warn "key       : $KEY MISSING - run 'collector-init' on $COLLECTOR, then authorize this machine"
  fi

  if systemctl list-timers --all 2>/dev/null | grep -q "$UNIT"; then
    ok "timer     : installed"
  else
    say "timer     : NOT installed"
  fi
  printf '\n  nothing above has been changed.\n\n'
}

# -----------------------------------------------------------------------------------------
cmd_collector_init() {
  need_root
  is_collector || die "collector-init runs on the COLLECTOR ($COLLECTOR); this is $ME"
  install -d -m 0750 -o root -g root "$DROP"
  ok "drop directory $DROP (0750 root:root)"
  if ! command -v rrsync >/dev/null 2>&1; then
    warn "rrsync NOT found - locate it (often /usr/bin/rrsync from the rsync package)"
    warn "before authorizing any key, or the forced command will fail closed"
  fi
  printf '\n  AUTHORIZE EACH SENDING MACHINE. First, ON THAT MACHINE, as root:\n\n'
  printf '    ssh-keygen -t rsa -b 4096 -N "" -f %s -C "audit-offload $(hostname -s)"\n' "$KEY"
  printf '    cat %s.pub\n\n' "$KEY"
  printf '  then back HERE, one line per machine:\n\n'
  printf '    echo '\''from="<THAT MACHINE ADDR>",restrict,command="/usr/bin/rrsync -wo %s" <ITS PUBLIC KEY>'\'' | sudo tee -a /root/.ssh/authorized_keys >/dev/null\n' "$DROP"
  printf '    sudo chmod 600 /root/.ssh/authorized_keys\n\n'
  say "RSA 4096 deliberately - FIPS refuses ed25519 ('ED25519 keys are not allowed in FIPS mode')."
  say "restrict + a forced 'rrsync -wo' means that key can only WRITE, only into $DROP,"
  say "and only from the named address. It cannot read or delete another machine's records."
  printf '\n'
}

# -----------------------------------------------------------------------------------------
cmd_run() {
  need_root
  [ -d "$AUDIT_DIR" ] || die "$AUDIT_DIR does not exist"

  # 1. Force a rotation so the week's records are actually in a rotated file.
  local pid
  pid="$(pidof auditd 2>/dev/null | awk '{print $1}')" || true
  if [ -n "${pid:-}" ]; then
    kill -USR1 "$pid" && ok "SIGUSR1 to auditd (pid $pid) - rotation requested"
    sleep "$ROTATE_WAIT"
  else
    warn "auditd not running - bundling whatever rotated files exist"
  fi

  local files; files="$(rotated_files)"
  [ -n "$files" ] || { warn "no rotated audit files to offload"; return 0; }

  # 2. Build the bundle in a staging directory.
  #
  # RUN_TMP IS DELIBERATELY NOT `local`. An EXIT trap fires after the function has returned,
  # so a `local tmp` is out of scope by then: under `set -u` the trap itself died with
  # "tmp: unbound variable" and the staging directory was NEVER cleaned up - every run
  # leaking a full copy of the bundle into /tmp. Measured on svc-obs-01 2026-09-23.
  # The `:-` guard means the trap is also safe if `run` exits before this line.
  local stamp bundle
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  bundle="${ME}-audit-${stamp}"
  RUN_TMP="$(mktemp -d)"
  trap '[ -n "${RUN_TMP:-}" ] && rm -rf "${RUN_TMP}"' EXIT
  local tmp="$RUN_TMP"
  install -d -m 0700 "$tmp/$bundle"

  local f first last
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    gzip -c "$f" > "$tmp/$bundle/$(basename "$f").gz"
  done <<< "$files"

  first="$(printf '%s\n' "$files" | head -1)"
  last="$(printf '%s\n' "$files" | tail -1)"

  {
    printf 'machine: %s\n' "$ME"
    printf 'address: %s\n' "$(my_addr)"
    printf 'bundle: %s\n' "$bundle"
    printf 'created-utc: %s\n' "$(date -u -Is)"
    printf 'oldest-file-mtime-utc: %s\n' "$(date -u -Is -d "@$(stat -c %Y "$last" 2>/dev/null || echo 0)")"
    printf 'newest-file-mtime-utc: %s\n' "$(date -u -Is -d "@$(stat -c %Y "$first" 2>/dev/null || echo 0)")"
    printf 'auditd-allocation-mb: %s\n' "$(alloc_mb)"
    printf 'file-count: %s\n' "$(printf '%s\n' "$files" | grep -c . || true)"
    printf 'script-revision: %s\n' "$(head -1 "$HOME/canonical-k8s/.pushed-from" 2>/dev/null || echo unknown)"
    printf 'signature: none\n'
    printf 'signature-note: checksums only, decided 2026-09-23. Signing needs a key custody answer (backlog 3.7). Detached signatures may be added beside SHA256SUMS without reformatting this manifest.\n'
  } > "$tmp/$bundle/MANIFEST"

  ( cd "$tmp/$bundle" && sha256sum ./*.gz MANIFEST > SHA256SUMS )
  ( cd "$tmp" && tar -czf "$bundle.tar.gz" --sort=name --owner=0 --group=0 --numeric-owner "$bundle" )
  sha256sum "$tmp/$bundle.tar.gz" | awk '{print $1}' > "$tmp/$bundle.tar.gz.sha256"
  ok "bundle built: $bundle.tar.gz ($(stat -c %s "$tmp/$bundle.tar.gz") bytes)"

  # 3. Deliver.
  if is_collector; then
    install -d -m 0750 "$DROP/$ME"
    install -m 0640 "$tmp/$bundle.tar.gz" "$tmp/$bundle.tar.gz.sha256" "$DROP/$ME/"
    ok "delivered locally to $DROP/$ME/"
  else
    [ -r "$KEY" ] || die "no key at $KEY - run collector-init on $COLLECTOR first"
    rsync -q -e "ssh ${SSH_OPTS[*]} -i $KEY" \
      "$tmp/$bundle.tar.gz" "$tmp/$bundle.tar.gz.sha256" "root@$COLLECTOR:$ME/"
    ok "delivered to $COLLECTOR:$DROP/$ME/"
  fi

  install -d -m 0755 "$(dirname "$STATE")"
  printf '%s %s\n' "$(date -u -Is)" "$bundle" >> "$STATE"

  # 4. The rotated files stay. A copy in two places is the point, and deleting them here
  #    would shorten the window this machine can answer from on its own.
  say "local rotated files left in place - auditd manages that window itself"
}

# -----------------------------------------------------------------------------------------
cmd_install() {
  need_root
  cat > "/etc/systemd/system/${UNIT}.service" <<UNIT_EOF
[Unit]
Description=Weekly audit-record offload to the enclave collector
Documentation=man:auditd.conf(5)

[Service]
Type=oneshot
ExecStart=${SELF}/audit-offload.sh run
UNIT_EOF
  cat > "/etc/systemd/system/${UNIT}.timer" <<TIMER_EOF
[Unit]
Description=Weekly audit-record offload

[Timer]
OnCalendar=Sun 03:00 UTC
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF
  systemctl daemon-reload
  systemctl enable --now "${UNIT}.timer"
  ok "timer installed and started"
  systemctl list-timers --all "${UNIT}.timer" --no-pager | sed 's/^/       /'
  say "Persistent=true so a machine that was off on Sunday offloads when it returns."
  say "RandomizedDelaySec spreads eight machines so they do not all hit the collector at 03:00."
}

# -----------------------------------------------------------------------------------------
cmd_prune() {
  need_root
  is_collector || die "prune runs on the COLLECTOR ($COLLECTOR); this is $ME"
  [ -d "$DROP" ] || die "$DROP does not exist - run collector-init"
  local n
  n="$(find "$DROP" -type f -name '*.tar.gz' -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null | grep -c . || true)"
  find "$DROP" -type f -name '*.tar.gz.sha256' -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
  ok "pruned ${n:-0} bundle(s) older than $RETENTION_DAYS days"
  say "retention is 1 year by AO decision 2026-09-23 (AUDIT_RETENTION_DAYS overrides)"
}

# -----------------------------------------------------------------------------------------
cmd_verify() {
  is_collector || die "verify runs on the COLLECTOR ($COLLECTOR); this is $ME"
  [ -d "$DROP" ] || die "$DROP does not exist"
  local bad=0 total=0 t want got
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    total=$((total+1))
    if [ ! -r "$t.sha256" ]; then
      warn "no sidecar checksum for $t"; bad=$((bad+1)); continue
    fi
    # Both guarded: a single unreadable bundle must be REPORTED, not abort the run.
    # Without `|| true` an unreadable file kills verify under `set -e` and every other
    # bundle goes unchecked - a verifier that stops at the first fault verifies nothing.
    want="$(cat "$t.sha256" 2>/dev/null || true)"
    got="$(sha256sum "$t" 2>/dev/null | awk '{print $1}' || true)"
    if [ -z "$got" ]; then
      warn "UNREADABLE: $t"; bad=$((bad+1))
    elif [ "$want" != "$got" ]; then
      warn "CHECKSUM MISMATCH: $t"; bad=$((bad+1))
    fi
  done <<< "$(find "$DROP" -type f -name '*.tar.gz' 2>/dev/null | sort || true)"
  if [ "$bad" -eq 0 ]; then
    ok "$total bundle(s) verified, no mismatches"
  else
    die "$bad of $total bundle(s) FAILED verification"
  fi
}

# -----------------------------------------------------------------------------------------
cmd_status() {
  printf '\n  audit offload - %s\n\n' "$ME"
  if [ -r "$STATE" ]; then
    say "runs recorded: $(grep -c . "$STATE" || true)"
    say "last: $(tail -1 "$STATE")"
  else
    say "no run recorded yet ($STATE absent)"
  fi
  systemctl list-timers --all "${UNIT}.timer" --no-pager 2>/dev/null | sed 's/^/  /' || true
  if is_collector && [ -d "$DROP" ]; then
    printf '\n  collector store:\n'
    du -sh "$DROP" 2>/dev/null | sed 's/^/    /' || true
    find "$DROP" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while read -r d; do
      printf '    %-16s %s bundle(s)\n' "$(basename "$d")" "$(find "$d" -name '*.tar.gz' | grep -c . || true)"
    done
  fi
  printf '\n'
}

case "${1:-plan}" in
  plan)           shift || true; cmd_plan "$@" ;;
  run)            shift; cmd_run "$@" ;;
  install)        shift; cmd_install "$@" ;;
  collector-init) shift; cmd_collector_init "$@" ;;
  prune)          shift; cmd_prune "$@" ;;
  verify)         shift; cmd_verify "$@" ;;
  status)         shift; cmd_status "$@" ;;
  *) die "unknown subcommand: $1 (plan|run|install|collector-init|prune|verify|status)" ;;
esac
