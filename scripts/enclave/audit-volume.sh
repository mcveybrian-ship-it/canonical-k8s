#!/usr/bin/env bash
# =========================================================================================
# audit-volume.sh - measure how fast the audit trail actually grows.
#
#     MACHINE: any hardened enclave machine. Runs unprivileged for `report`.
#
#     sudo ./audit-volume.sh sample      # append one measurement
#     ./audit-volume.sh report           # growth rate and what it implies
#     sudo ./audit-volume.sh install     # hourly systemd timer
#     ./audit-volume.sh status
#
# WHY THIS EXISTS AS A SCRIPT AND NOT TWO du COMMANDS.
#
#   `svc-log-01`'s disk size is an AO question, and the answer depends on how much audit data
#   this enclave actually produces. The first attempt was a `du -sb` written to
#   /tmp/audit-volume.txt on 2026-09-10, to be compared 24 hours later.
#
#   svc-harbor-01 rebooted. /tmp was cleared. The measurement was lost, and nobody knew until
#   the follow-up was due. A baseline that must outlive a reboot cannot live in a directory
#   that a reboot clears - so this writes to /var/local, which survives.
#
#   The second problem was worse: two points 24 hours apart only give an average, and it is
#   only correct if nothing unusual happened in between. auditd's volume is bursty - a
#   `usg fix` run, a package upgrade or a failed-login sweep dwarfs a quiet hour. Hourly
#   samples give the rate AND its variance, which is what actually sizes a disk.
#
# IT MEASURES, IT DOES NOT DECIDE. The retention period is the AO's answer, not ours; this
# supplies the bytes-per-day that the answer gets multiplied by.
# =========================================================================================
set -euo pipefail

DIR="${AUDIT_VOL_DIR:-/var/local/enclave-metrics}"
LOG="$DIR/audit-volume.txt"
TARGET="${AUDIT_VOL_TARGET:-/var/log/audit}"
UNIT=enclave-audit-volume

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

cmd_sample() {
  need_root
  install -d -m 0755 "$DIR"
  local bytes files
  # du needs root here: /var/log/audit is 0700 after `usg fix`, and an unprivileged du returns
  # 0 rather than failing - which would silently record a flat line forever.
  bytes="$(du -sb "$TARGET" 2>/dev/null | awk '{print $1}')"
  [ -n "${bytes:-}" ] && [ "$bytes" -gt 0 ] 2>/dev/null \
    || die "du returned '${bytes:-empty}' for $TARGET - refusing to record a bogus sample.
       An unprivileged du on a 0700 directory returns 0, which looks exactly like 'no data'."
  files="$(find "$TARGET" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  printf '%s %s %s\n' "$(date -Is)" "$bytes" "$files" >> "$LOG"
  # 0644, NOT root's umask. This is a capacity metric, not a secret, and the whole point is
  # that a human can read it without sudo - the first sample was written 0600 and could not
  # even be cat'd by the account that took it.
  chmod 0644 "$LOG"
  ok "$(date -Is)  $bytes bytes  $files file(s)  -> $LOG"
}

cmd_report() {
  [ -f "$LOG" ] || die "no samples yet at $LOG - run: sudo $0 sample"
  local n; n="$(grep -c . "$LOG" 2>/dev/null)" || true
  printf '\n  audit volume on %s - %s sample(s)\n\n' "$(hostname -s)" "${n:-0}"
  awk '
    { t=$1; b=$2; f=$3
      # ISO-8601 to epoch without calling date per line
      gsub(/[-T:+]/," ",t); split(t,a," ")
      e=mktime(sprintf("%s %s %s %s %s %s", a[1],a[2],a[3],a[4],a[5],a[6]))
      if (prev_e != "") {
        dt = e - prev_e; db = b - prev_b
        if (dt > 0) {
          rate = db/dt*86400
          # AN INTERVAL LONGER THAN 2 HOURS CANNOT SEE A BURST - it averages it away. Mark
          # those, and keep them out of the "busiest" figure, or a 25-hour hand sample gets
          # read as a peak rate when it is the flattest number in the file.
          coarse = (dt > 7200)
          printf "  %s  %10d B  %2d files  %+9d B over %6ds  = %+10.1f B/day%s\n", \
                 $1, b, f, db, dt, rate, (coarse ? "   COARSE - averages bursts away" : "")
          sum += rate; cnt++
          if (!coarse) { if (rate > max || fine == 0) max = rate; fine++ }
        }
      } else {
        printf "  %s  %10d B  %2d files  (baseline)\n", $1, b, f
      }
      prev_e = e; prev_b = b
      first_e = (first_e == "" ? e : first_e); first_b = (first_b == "" ? b : first_b)
      last_e = e; last_b = b
    }
    END {
      if (cnt > 0) {
        span = last_e - first_e
        printf "\n  span            : %.1f hours over %d interval(s), %d of them under 2h\n", span/3600, cnt, fine
        printf "  overall rate    : %.1f B/day  (%.2f MB/day)\n", (last_b-first_b)/span*86400, (last_b-first_b)/span*86400/1048576
        if (fine > 0) {
          printf "  busiest fine-grained interval: %.1f B/day  (%.2f MB/day)  <- size for THIS\n", max, max/1048576
          printf "\n  30 days at that rate : %.2f GB\n", max*30/1073741824
          printf "  90 days at that rate : %.2f GB\n", max*90/1073741824
          printf "  365 days at that rate: %.2f GB\n", max*365/1073741824
        } else {
          printf "\n  NO INTERVAL UNDER 2 HOURS YET, so there is no usable peak rate - only an\n"
          printf "  average, and an average is the wrong number to size a disk with. Install\n"
          printf "  the hourly timer and come back:  sudo %s install\n", "audit-volume.sh"
        }
      } else {
        print "\n  only one sample - no rate yet. Wait for the next one."
      }
    }' "$LOG"
  printf '\n  RETENTION IS THE AO ANSWER, not ours. This supplies the bytes-per-day.\n'
  printf '  Size for the busiest interval - auditd is bursty, and an average hides a\n'
  printf '  usg fix run or a failed-login sweep. runbook 6.3d\n\n'
}

cmd_install() {
  need_root
  local self; self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
  cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Sample audit log volume for svc-log-01 sizing
Documentation=file://$self

[Service]
Type=oneshot
ExecStart=$self sample
EOF
  cat > "/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Hourly audit volume sample

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "/etc/systemd/system/$UNIT".{service,timer}
  systemctl daemon-reload
  systemctl enable --now "$UNIT.timer"
  ok "timer installed and started"
  # Persistent=true means a machine that was off catches up on boot rather than losing the
  # sample - which is exactly how the first attempt died.
  systemctl list-timers "$UNIT.timer" --no-pager | sed 's/^/       /'
}

cmd_status() {
  printf '\n  audit volume sampling on %s\n\n' "$(hostname -s)"
  if [ -f "$LOG" ]; then
    ok "$LOG  $(grep -c . "$LOG" 2>/dev/null || echo 0) sample(s), $(stat -c '%a' "$LOG")"
    tail -3 "$LOG" | sed 's/^/       /'
  else
    warn "no samples at $LOG"
  fi
  if systemctl list-unit-files "$UNIT.timer" >/dev/null 2>&1 \
     && systemctl is-enabled "$UNIT.timer" >/dev/null 2>&1; then
    ok "timer enabled: $(systemctl is-active "$UNIT.timer")"
    systemctl list-timers "$UNIT.timer" --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/       /'
  else
    warn "no timer - samples only happen when someone remembers. sudo $0 install"
  fi
  echo
}

case "${1:-status}" in
  sample)  shift; cmd_sample "$@" ;;
  report)  shift; cmd_report "$@" ;;
  install) shift; cmd_install "$@" ;;
  status)  shift; cmd_status "$@" ;;
  *) printf 'usage: %s {sample|report|install|status}\n' "$0" >&2; exit 2 ;;
esac
