#!/usr/bin/env bash
# =========================================================================================
# time-sync.sh - give the enclave one clock.
#
#   sudo ./time-sync.sh master [--upstream <host>... [--slew]]
#                                 this machine becomes the enclave time source. With
#                                 --upstream it is disciplined by a real reference and
#                                 serves that onward - clients need no change. --slew adopts
#                                 it without a jump - and REFUSES on a STIG-hardened machine,
#                                 where UBTU-24-600180's `makestep 1 -1` makes it a step anyway.
#   sudo ./time-sync.sh reference [--remove]
#                                 ON stage-01, LAB ONLY: serve real time to the time master
#                                 and nothing else, so it can be re-anchored (3.39, AO-13).
#   sudo ./time-sync.sh client    follow the enclave time source
#        ./time-sync.sh verify    read-only: are we synchronised, and to what
#        ./time-sync.sh drift     read-only: how far is this machine from a reference
#        ./time-sync.sh drift-log     ON stage-01: one measurement of the enclave against UTC, logged
#        ./time-sync.sh drift-report  ON stage-01: the log so far, and the drift RATE
#   sudo ./time-sync.sh drift-timer   ON stage-01: measure every DRIFT_EVERY (3 h), as the operator
#
#   MACHINE: `master` on TIME_MASTER only (host-4 - physical); `client` on every other enclave
#   machine, guests included; `verify` anywhere; `drift` on an enclave machine at gap-open,
#   against a reference it can then reach. Runbook 2.10 and 6.3b. Addresses AU-8 (poam AO-13)
#   and the STIG rule chronyd_or_ntpd_set_maxpoll.
#
# WHY THIS IS NOT OPTIONAL, AND WHY IT COMES BEFORE THE CLUSTER:
#
#   Before this script (2026-09-04) every machine in the enclave reported "System clock
#   synchronized: no": systemd-timesyncd ran with NO server configured - active, and doing
#   nothing. They agreed with each other only because they had been built recently from a
#   correct clock. `verify` is how you check that this is still not the case.
#
#   What breaks on skew, roughly in order of how confusing the failure is:
#     etcd     - leader elections and lease expiry are wall-clock sensitive. The failure is
#                a cluster that loses quorum for no visible reason.
#     TLS      - a certificate is not yet valid, or already expired, depending on which way
#                the clock is wrong. The error names the certificate, not the clock.
#     Ceph     - refuses to peer with monitors it considers out of sync.
#     Kerberos - if it ever appears, dies outright past five minutes.
#     Audit    - logs cannot be correlated with anything outside the enclave.
#
#   CONSISTENCY MATTERS MORE THAN ACCURACY here. If every node agrees, etcd is happy and TLS
#   works even if the whole enclave is minutes from UTC. What kills you is nodes disagreeing
#   with each other. One in-gap source fixes that with no hardware. Absolute accuracy is a
#   separate problem and needs a real reference - see "the honest limit" below.
#
# THE MASTER MUST BE PHYSICAL:
#
#   The service VMs run under KVM on host-4 and take their clock from it through kvm-clock.
#   A VM serving time to the network would be handing its own hypervisor's clock back to the
#   hypervisor. host-4 is already the de facto master by that mechanism; this makes it
#   deliberate. `master` refuses to run on a guest.
#
# THE HONEST LIMIT:
#
#   With no external reference the enclave free-runs. Every node will agree with every other
#   node, and the whole set will drift from UTC together. That is fine for etcd, Ceph and
#   TLS. It is NOT sufficient for audit correlation with outside systems, and a STIG that
#   requires an authoritative source will not accept it. The fix is hardware - a GPS or PTP
#   appliance on the enclave subnet - at which point TIME_MASTER points at that instead and
#   nothing else changes. Until then, re-anchor at each gap-open (see `drift`).
#
#   DECIDED 2026-09-28 by the acting AO (AO-13, backlog 3.39), after the rate was measured at
#   +0.583 s/day: PRODUCTION gets a receive-only GPS time source feeding host-4 through
#   `master --upstream`. The LAB was re-anchored the same day from stage-01 (`reference` there,
#   `master --upstream <stage-01's enclave address>` here). ClockReferenceLost fires if a
#   configured reference is lost and host-4 falls back to its own crystal.
#
#   ON THIS ENCLAVE A CORRECTION OVER 1 s IS A STEP, BY STIG. UBTU-24-600180 (SRG-OS-000356,
#   rule chronyd_sync_clock) writes `makestep 1 -1` into /etc/chrony/chrony.conf on every
#   hardened machine: step whenever the offset exceeds 1 s, forever. The drop-ins below cannot
#   override it. Found the hard way 2026-09-28: `--slew` was meant to pull host-4 back 10.9 s
#   at 1 ms/s, and host-4 stepped on its first update instead - while every client, polling
#   every 1 min (host-1) to 18 h (the service VMs), stayed 10.9 s ahead and marked host-4
#   "too variable" (^~) rather than follow. SO: a correction over 1 s is a COORDINATED STEP.
#   `master` here, then `sudo systemctl restart chrony` on EVERY client at once, so the split
#   lasts minutes, not the service VMs' poll interval. Do it in a window - every machine's
#   audit trail gets one backward discontinuity of the correction's size.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -r "$SELF/enclave-addresses.env" ] && . "$SELF/enclave-addresses.env"

MASTER="${TIME_MASTER:?TIME_MASTER must be set in enclave-addresses.env}"
MASTER_NAME="${TIME_MASTER_NAME:-time-master}"
# ---- the enclave against UTC, measured from OUTSIDE (backlog 3.39, 2026-09-27) ----------------
# Nothing inside the gap can see the enclave's error against UTC: every machine follows host-4
# and host-4 follows its own crystal. stage-01 is outside, NTP-synced (ntp.ubuntu.com), and can
# reach host-4 while the gap is open - so it measures. How: SSH midpoint. Read host-4's clock
# inside one ssh call, bracket it with stage-01's clock before and after, offset = remote minus
# the midpoint, uncertainty = half the round trip; the best of DRIFT_SAMPLES calls is kept.
# First measured by hand 2026-09-27 14:15 UTC: +10.57 s, three samples within 5 ms.
DRIFT_TARGET="${DRIFT_TARGET:-$MASTER}"            # what is measured: the time master, whose clock every machine follows
DRIFT_LOG="${DRIFT_LOG:-/var/lib/enclave-time/drift.csv}"
DRIFT_KEY="${DRIFT_KEY:-$HOME/.ssh/build01}"
DRIFT_USER="${DRIFT_USER:-encadmin}"
DRIFT_SAMPLES="${DRIFT_SAMPLES:-3}"
DRIFT_EVERY="${DRIFT_EVERY:-*-*-* 00/3:17:00}"    # systemd OnCalendar - every 3 h, off the hour
ALLOW="${TIME_ALLOW:-10.2.20.0/24}"
MAXPOLL="${TIME_MAXPOLL:-16}"
CONF=/etc/chrony/chrony.conf
DROPIN=/etc/chrony/conf.d/10-enclave.conf
REF_DROPIN=/etc/chrony/conf.d/10-enclave-reference.conf     # stage-01 only - `reference`
SLEW_PPM="${TIME_SLEW_PPM:-1000}"                            # --slew: 1000 ppm = 1 ms per second

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# Shared by master and client: chrony from the mirror, timesyncd off, a conf.d include in
# chrony.conf so the enclave directives live in their own drop-in, and the dead public pools
# commented out.
install_chrony() {
  if ! dpkg -s chrony >/dev/null 2>&1; then
    say "installing chrony from the enclave mirror"
    apt-get install -y chrony >/dev/null 2>&1 || die "chrony install failed - is apt working?"
  fi
  # Installing chrony masks systemd-timesyncd automatically. Say so rather than leaving the
  # operator to wonder why the daemon they were told about has vanished.
  if systemctl is-enabled systemd-timesyncd >/dev/null 2>&1; then
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    say "systemd-timesyncd disabled - chrony replaces it"
  fi
  install -d -m 0755 /etc/chrony/conf.d
  grep -q '^confdir\|^include /etc/chrony/conf.d' "$CONF" 2>/dev/null \
    || echo 'confdir /etc/chrony/conf.d' >> "$CONF"

  # THE STOCK PUBLIC POOLS CAN NEVER RESOLVE IN HERE, AND LEAVING THEM IS NOT HARMLESS.
  #
  # Ubuntu ships chrony.conf with `pool ntp.ubuntu.com` and three `*.ubuntu.pool.ntp.org`
  # entries. Inside the boundary they are dead - no DNS, no route - so they contribute
  # nothing. What they DO is misrepresent the machine: a config naming four public internet
  # time servers is the first thing an assessor asks about on an air-gapped host, and on the
  # time master (which has no other server line at all) they are the only directives present,
  # so the machine looks configured to sync from the internet while actually serving from its
  # own clock.
  #
  # Commented, not deleted - the original stays visible and the change is self-describing.
  # Only $CONF is touched; the enclave's own directives live in conf.d and are never matched.
  local n
  # `|| true`, not `|| echo 0`: grep -c PRINTS 0 and exits 1 on no match, so `|| echo 0` made
  # n="0<newline>0" and the test below died with "integer expression expected" (2026-09-28).
  n="$(grep -cE '^[[:space:]]*(server|pool)[[:space:]]' "$CONF" 2>/dev/null || true)"
  if [ "${n:-0}" -gt 0 ]; then
    # Timestamped copy first, so the original file can always be put back by hand.
    cp -a "$CONF" "/var/backups/chrony.conf.$(date +%Y%m%dT%H%M%S)"
    # awk, NOT sed. The pattern contains '|' and every sed delimiter worth using appears
    # either in the pattern or in the replacement text - the same trap that broke the
    # node-exporter ARGS line on 2026-09-15. awk has no delimiter to collide with.
    # NEVER COMMENT A LINE THAT NAMES THE ENCLAVE'S OWN TIME MASTER. The enclave directives
    # live in conf.d today, so nothing here should match one - but a client with
    # `server <master>` written into chrony.conf by hand would otherwise be silently cut off
    # from time, and a script that can do that is not one to leave unguarded.
    local ct; ct="$(mktemp)"
    awk -v m="$MASTER" -v mn="$MASTER_NAME" '
      {
        if ($0 ~ /^[[:space:]]*(server|pool)[[:space:]]/ \
            && index($0, m) == 0 && (mn == "" || index($0, mn) == 0))
          print "# disabled by time-sync.sh - unreachable inside the boundary: " $0
        else print $0
      }' "$CONF" > "$ct"
    cat "$ct" > "$CONF"; rm -f "$ct"
    ok "commented out $n stock time source(s) in $CONF - they cannot resolve in the gap"
  fi
}

# ---------------------------------------------------------------------------- master
# master: refuse on a guest, install chrony, write the drop-in (optional upstream, local
# stratum, allow the enclave subnet, makestep/rtcsync), restart chrony and verify.
cmd_master() {
  need_root
  # --upstream is how a real reference gets adopted WITHOUT touching a single client.
  # host-4 stays the machine every client points at; it simply stops being the origin of
  # the time and starts being a relay for one. `local stratum 5` below (TIME_MASTER_STRATUM)
  # is worse than any real reference, so chrony prefers any genuine source and falls back to the local clock only if
  # the reference dies - which is exactly the behaviour you want from an appliance that
  # can lose GPS lock.
  local upstream=() u slew=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --upstream) upstream+=("${2:?--upstream needs a host}"); shift 2 ;;
      --upstream=*) upstream+=("${1#--upstream=}"); shift ;;
      --slew) slew=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ "$slew" = 0 ] || [ ${#upstream[@]} -gt 0 ] || die "--slew adopts a reference - it needs --upstream <host>"
  # THE STIG'S makestep WINS over anything a drop-in says (2026-09-28). Refuse rather than let
  # an option promise a slew and deliver a step.
  local stig_step=""
  stig_step="$(grep -hE '^[[:space:]]*makestep[[:space:]]+[0-9.]+[[:space:]]+-1' "$CONF" 2>/dev/null | head -1 || true)"
  [ "$slew" = 0 ] || [ -z "$stig_step" ] || die "--slew cannot work on this machine: $CONF has '$stig_step'.
      That is STIG UBTU-24-600180 - step whenever the offset exceeds 1 s, forever - and no
      drop-in overrides it. A correction over 1 s here IS a step, and the clients will not
      follow until they next poll (up to 18 h). Do it as a coordinated step instead:
        1. sudo ./time-sync.sh master --upstream <host>        (this machine steps)
        2. sudo systemctl restart chrony   on EVERY client     (each steps within seconds)
      in a maintenance window - every audit trail gets one backward jump. Runbook 2.10."
  [[ "$SLEW_PPM" =~ ^[0-9]+$ ]] && [ "$SLEW_PPM" -ge 1 ] && [ "$SLEW_PPM" -le 83333 ] \
    || die "TIME_SLEW_PPM must be a whole number of ppm, 1-83333 (chrony's own ceiling) - got '$SLEW_PPM'"
  # systemd-detect-virt EXITS 1 WHEN IT FINDS NO VIRTUALISATION. It is reporting "no", not
  # failing, but `cmd || echo unknown` therefore fires on bare metal and appends a second
  # line - so $virt became "none\nunknown" and the guard rejected the one machine that
  # should have passed. Capture the output and ignore the status; the STRING is the answer.
  local virt=""
  virt=$(systemd-detect-virt 2>/dev/null) || true
  [ -n "$virt" ] || virt=unknown
  [ "$virt" = "none" ] || die "this machine is a $virt guest.
      The time master must be PHYSICAL. A guest takes its clock from its hypervisor, so
      serving time from here would hand the hypervisor its own clock back. Run this on
      $MASTER_NAME ($MASTER)."

  install_chrony
  if [ ${#upstream[@]} -gt 0 ] && [ -n "$stig_step" ]; then
    warn "$CONF has '$stig_step' (STIG UBTU-24-600180): if this machine is more than 1 s from"
    warn "the new reference it STEPS at the first update, and every client stays on the old time"
    warn "until it next polls. Restart chrony on EVERY client right after this (runbook 2.10)."
  fi
  {
    echo "# Enclave time master. Written by time-sync.sh on $(date -Is)."
    echo "#"
    if [ ${#upstream[@]} -gt 0 ]; then
      echo "# Disciplined by a real reference. Clients still point at this machine and need"
      echo "# no change; it relays this source onward at one stratum lower."
      for u in "${upstream[@]}"; do echo "server $u iburst maxpoll $MAXPOLL"; done
      echo ""
    else
      echo "# NO EXTERNAL REFERENCE. The enclave's time is this machine's RTC. Every node will"
      echo "# agree with every other node and the whole set will drift from UTC together."
      echo "# Add one with:  sudo ./time-sync.sh master --upstream <address>"
      echo "#"
    fi
    echo "# 'local stratum N' is the load-bearing line: without it chrony will NOT serve time"
    echo "# while it is itself unsynchronised, which in an air gap is always."
    echo "#"
    echo "# STRATUM 5, NOT 10. It was 10 - 'deliberately poor, so a real reference wins" 
    echo "# automatically' - and that was too poor. Installing MAAS on svc-mgmt-01 wrote"
    echo "# /etc/chrony/maas.conf containing 'local stratum 8 orphan', which BEATS 10. That"
    echo "# machine then preferred its own clock, marked host-4 unselected, and the enclave"
    echo "# quietly ran two independent clocks - the exact failure this script exists to"
    echo "# prevent, arriving with no error at all."
    echo "#"
    echo "# 5 still loses to any genuine reference (GPS/PTP appliances present as 1-2) while"
    echo "# beating the local-clock defaults other software helps itself to."
    echo "local stratum ${TIME_MASTER_STRATUM:-5}"
    echo ""
    echo "# Who may ask. The enclave subnet and nothing else."
    echo "allow $ALLOW"
    echo ""
    if [ "$slew" = 1 ]; then
      echo "# ADOPTING A REFERENCE ON A RUNNING ENCLAVE (--slew, 2026-09-28). No makestep, so chrony"
      echo "# NEVER jumps: a backward step puts audit timestamps out of order on every machine and"
      echo "# is its own outage for etcd. maxslewrate bounds the correction instead - $SLEW_PPM ppm is"
      echo "# $(awk -v p="$SLEW_PPM" 'BEGIN{printf "%.1f", 1/(p*1e-6)/3600}') h per second of offset. The bound is set by the clients: host-1..3 poll"
      echo "# this machine every ~128 s and so trail it by at most ~$(awk -v p="$SLEW_PPM" 'BEGIN{printf "%.2f", p*1e-6*128}') s while it moves."
      echo "# Re-run 'master --upstream ...' without --slew once converged to restore boot-time stepping."
      echo "maxslewrate $SLEW_PPM"
    else
      echo "# Step rather than slew for the first few updates only. A large BACKWARD step on a"
      echo "# running cluster is its own outage - etcd and Ceph both dislike it - so after the"
      echo "# third update chrony slews and never jumps."
      echo "makestep 1.0 3"
    fi
    echo "rtcsync"
  } > "$DROPIN"
  chmod 0644 "$DROPIN"
  ok "wrote $DROPIN"
  systemctl restart chrony
  systemctl enable chrony >/dev/null 2>&1 || true
  sleep 2
  if [ ${#upstream[@]} -gt 0 ]; then
    ok "$(hostname -s) serves $ALLOW, disciplined by: ${upstream[*]}"
    say "    clients need NO change - they already point here"
    if [ "$slew" = 1 ]; then
      say "    SLEWING at up to $SLEW_PPM ppm - never a step. Watch it close:"
      say "      chronyc -n tracking      ('System time' shrinks toward 0)"
      say "      ClockOffsetHigh fires for $(hostname -s) until it is inside ${AL_CLOCK_MAX_OFFSET:-1} s - expected, it is the truth"
    fi
  else
    ok "$(hostname -s) is the enclave time source, serving $ALLOW"
  fi
  cmd_verify
}

# ---------------------------------------------------------------------------- client
# client: refuse on the master's own address, install chrony, write one `server <master>`
# line with maxpoll, restart, wait up to ~20 s for NTPSynchronized, then verify.
cmd_client() {
  need_root
  local myip; myip=$(ip -4 -br addr | awk '$1!="lo"{split($3,a,"/"); print a[1]; exit}')
  [ "$myip" != "$MASTER" ] || die "this machine IS $MASTER - run 'master' here, not 'client'"

  install_chrony
  {
    echo "# Enclave time client. Written by time-sync.sh on $(date -Is)."
    echo "#"
    echo "# IF THIS MACHINE IGNORES THE MASTER, look for another 'local stratum' on it."
    echo "# chrony prefers the lowest stratum, so any software that declares itself a local"
    echo "# reference at a better number silently wins - MAAS writes 'local stratum 8 orphan'"
    echo "# into /etc/chrony/maas.conf, and did exactly this on svc-mgmt-01 on 2026-09-08."
    echo "# Symptom: chronyc sources shows '^?' against a master with full reach, and"
    echo "# timedatectl reports synchronized: no while nothing errors."
    echo "# The enclave has exactly one source. Pointing at anything else - including a public"
    echo "# pool that is unreachable in the gap - produces a machine that never synchronises"
    echo "# and says so only in timedatectl, which nobody reads until something breaks."
    echo "# maxpoll is a STIG requirement (chronyd_or_ntpd_set_maxpoll), not a tuning choice."
    echo "# Its OVAL object is obj_chrony_all_server_has_maxpoll - EVERY server line needs it."
    echo "server $MASTER iburst maxpoll $MAXPOLL"
    echo ""
    echo "makestep 1.0 3"
    echo "rtcsync"
  } > "$DROPIN"
  chmod 0644 "$DROPIN"
  ok "wrote $DROPIN -> $MASTER ($MASTER_NAME)"
  systemctl restart chrony
  systemctl enable chrony >/dev/null 2>&1 || true
  say "waiting for the first measurement"
  local tries=0
  while [ "$tries" -lt 10 ]; do
    # NTPSynchronized is the flag every other tool reads, so wait on that rather than on a
    # string in chronyc output that varies with version.
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then break; fi
    tries=$((tries + 1)); sleep 2
  done
  cmd_verify
}

# ---------------------------------------------------------------------------- verify
# verify: read-only. Prints chrony tracking and sources, then judges by role - the master by
# its leap status, a client by the kernel's NTPSynchronized flag. Non-zero on failure.
cmd_verify() {
  local fail=0
  if ! command -v chronyc >/dev/null 2>&1; then
    warn "chrony is not installed on this machine"
    return 1
  fi
  say ""
  say "tracking:"
  chronyc tracking 2>/dev/null | grep -E 'Reference ID|Stratum|System time|Last offset|Leap' | sed 's/^/    /' || true
  say ""
  say "sources:"
  chronyc sources 2>/dev/null | sed 's/^/    /' || true
  say ""
  # THE TWO ROLES HAVE DIFFERENT SUCCESS CRITERIA, and conflating them reports a healthy
  # master as broken.
  #
  # A client is synchronised when the kernel says so - chrony clears the kernel's UNSYNC flag
  # once it has disciplined the clock from a source, and that is what timedatectl reads.
  #
  # THE MASTER HAS NO SOURCE. It IS the source. chrony never disciplines its clock from
  # anything, so the kernel flag stays set and timedatectl will report "no" forever. That is
  # not a fault, it is the honest state of an enclave with no external reference: the time is
  # this machine's RTC, and every other machine agrees with it. Checking for "yes" here says
  # a correctly-serving master is broken.
  if [ -f "$DROPIN" ] && grep -q '^local stratum' "$DROPIN"; then
    local leap stratum
    leap=$(chronyc tracking 2>/dev/null | awk -F': *' '/Leap status/{print $2}')
    stratum=$(chronyc tracking 2>/dev/null | awk -F': *' '/Stratum/{print $2}')
    if [ "$leap" = "Normal" ]; then
      ok "serving as the enclave reference (stratum ${stratum:-?}, leap $leap)"
      if grep -q '^server ' "$DROPIN"; then
        say "    upstream: $(grep '^server ' "$DROPIN" | awk '{print $2}' | tr '\n' ' ')"
        say "    this machine relays a real reference - stratum should be its upstream plus one, not the local fallback ${TIME_MASTER_STRATUM:-5}."
      else
        say "    timedatectl will report 'synchronized: no' on this machine, correctly:"
        say "    nothing synchronises the reference. Absolute accuracy is this machine's RTC"
        say "    until an external source exists - see the honest limit in this header."
      fi
    else
      warn "chrony is not serving: leap status '$leap'"
      fail=1
    fi
    say ""
    say "the check that actually matters is on a CLIENT:"
    say "    ./time-sync.sh verify        # expect  ^* $MASTER_NAME  and synchronized: yes"
  else
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
      ok "System clock synchronized: yes"
    else
      warn "System clock synchronized: NO - chrony has not settled, or cannot reach $MASTER"
      fail=1
    fi
  fi
  return $fail
}

# ---------------------------------------------------------------------------- drift
# Measure against a reference WITHOUT changing anything. Used at gap-open to see how far the
# enclave has walked from real time before deciding whether to re-anchor.
# stage-01 only: the enclave's addresses are the other machines, and this measures FROM outside.
assert_stage01() {
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "${STAGE_01:?STAGE_01 not set in enclave-addresses.env}" \
    || die "this runs on stage-01 (${STAGE_01}) - outside the gap, on real time. This is $(hostname -s)."
}

# One measurement, one CSV row. Unreachable is a row too: a gap in the log must be explained.
cmd_drift_log() {
  assert_stage01
  local synced refoff best="" a b r rtt off
  synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  # stage-01's own error against its reference. `timedatectl timesync-status` is timesyncd's and
  # prints NOTHING under chrony - which `reference` installs - so read whichever daemon runs.
  # chrony: + means stage-01 is fast of NTP time.
  if systemctl is-active --quiet chrony 2>/dev/null; then
    refoff="$(chronyc -n tracking 2>/dev/null | awk -F': ' '/^System time/ {split($2,a," "); printf "%s%.3fms", (a[3]=="slow" ? "-" : "+"), a[1]*1000}')"
  else
    refoff="$(timedatectl timesync-status 2>/dev/null | awk '/Offset:/ {print $2}' | head -1)"
  fi
  for _ in $(seq 1 "$DRIFT_SAMPLES"); do
    a="$(date +%s.%N)"
    r="$(ssh -i "$DRIFT_KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes \
          "$DRIFT_USER@$DRIFT_TARGET" 'echo ENCLAVE-TIME; date +%s.%N' 2>/dev/null | sed -n '/^ENCLAVE-TIME$/{n;p}')" || r=""
    b="$(date +%s.%N)"
    [[ "$r" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    rtt="$(echo "$b - $a" | bc -l)"; off="$(echo "$r - ($a + $b) / 2" | bc -l)"
    if [ -z "$best" ] || [ "$(echo "$rtt < ${best%% *}" | bc -l)" = 1 ]; then best="$rtt $off"; fi
  done
  install -d -m 0755 "$(dirname "$DRIFT_LOG")" 2>/dev/null || true
  [ -w "$DRIFT_LOG" ] || [ ! -e "$DRIFT_LOG" ] || die "$DRIFT_LOG is not writable by $(id -un)"
  [ -s "$DRIFT_LOG" ] || echo "utc,target,offset_s,uncertainty_s,reference_synced,reference_offset" > "$DRIFT_LOG"
  if [ -n "$best" ]; then
    printf '%s,%s,%.3f,%.3f,%s,%s\n' "$(date -u +%FT%TZ)" "$DRIFT_TARGET" "${best#* }" "$(echo "${best%% *} / 2" | bc -l)" "$synced" "${refoff:-?}" >> "$DRIFT_LOG"
    ok "$DRIFT_TARGET is $(printf '%+.3f' "${best#* }") s from stage-01's clock (+/- $(printf '%.3f' "$(echo "${best%% *} / 2" | bc -l)") s; stage-01 NTPSynchronized=$synced, offset ${refoff:-?})"
    [ "$synced" = yes ] || warn "stage-01 is NOT synchronised - this row measures against an unreliable reference"
  else
    printf '%s,%s,,,%s,%s\n' "$(date -u +%FT%TZ)" "$DRIFT_TARGET" "$synced" "${refoff:-?}" >> "$DRIFT_LOG"
    warn "$DRIFT_TARGET did not answer - logged as unreachable (gap closed, or the key is not accepted)"
  fi
}

# The rate: least squares over the rows measured against a synchronised reference.
cmd_drift_report() {
  [ -r "$DRIFT_LOG" ] || die "no drift log at $DRIFT_LOG - run drift-log (or drift-timer) on stage-01 first"
  python3 - "$DRIFT_LOG" <<'PY'
import csv, sys, datetime as dt
rows = list(csv.DictReader(open(sys.argv[1])))
good = [r for r in rows if r["offset_s"] and r["reference_synced"] == "yes"]
print(f"  {len(rows)} row(s): {len(good)} usable, {len(rows) - len(good)} unreachable or against an unsynchronised reference")
if not good:
    sys.exit(0)
t = [dt.datetime.fromisoformat(r["utc"].replace("Z", "+00:00")).timestamp() for r in good]
y = [float(r["offset_s"]) for r in good]
print(f"  first  {good[0]['utc']}  {y[0]:+.3f} s")
print(f"  last   {good[-1]['utc']}  {y[-1]:+.3f} s")
if len(good) < 2 or t[-1] - t[0] < 6 * 3600:
    print("  RATE: not yet - needs at least two usable rows six hours apart"); sys.exit(0)
n = len(t); mt = sum(t) / n; my = sum(y) / n
slope = sum((a - mt) * (b - my) for a, b in zip(t, y)) / sum((a - mt) ** 2 for a in t)
print(f"  RATE:  {slope * 86400:+.3f} s/day  ({slope * 1e6:+.1f} ppm) over {(t[-1] - t[0]) / 86400:.1f} day(s)")
print(f"         at that rate the enclave moves 1 s from UTC every {abs(1 / (slope * 86400)):.1f} day(s)" if slope else "")
PY
}

# Install the measurement as a timer - RUN AS THE OPERATOR, not root: it needs the operator's key
# and nothing privileged, and a root unit running a repo copy the operator can edit is the 3.11 path.
cmd_drift_timer() {
  need_root; assert_stage01
  local op="${SUDO_USER:-}" home
  [ -n "$op" ] && [ "$op" != root ] || die "run with sudo as the operator whose key reaches host-4"
  home="$(getent passwd "$op" | cut -d: -f6)"
  install -d -m 0755 -o "$op" -g "$(id -gn "$op")" "$(dirname "$DRIFT_LOG")"
  cat > /etc/systemd/system/enclave-time-drift.service <<UNIT
[Unit]
Description=Measure the enclave clock against UTC from stage-01 (backlog 3.39)
[Service]
Type=oneshot
User=$op
Environment=HOME=$home DRIFT_LOG=$DRIFT_LOG
ExecStart=$SELF/time-sync.sh drift-log
UNIT
  cat > /etc/systemd/system/enclave-time-drift.timer <<UNIT
[Unit]
Description=Measure the enclave clock against UTC every few hours
[Timer]
OnCalendar=$DRIFT_EVERY
Persistent=true
[Install]
WantedBy=timers.target
UNIT
  systemd-analyze verify /etc/systemd/system/enclave-time-drift.service /etc/systemd/system/enclave-time-drift.timer \
    || die "the drift units do not verify - not enabling them"
  systemctl daemon-reload
  systemctl enable --now enclave-time-drift.timer
  ok "enclave-time-drift.timer: $DRIFT_EVERY, as $op, logging to $DRIFT_LOG"
  systemctl start enclave-time-drift.service && ok "first measurement taken: $(tail -1 "$DRIFT_LOG")"
}

# ---------------------------------------------------------------------------- reference
# reference: ON stage-01, LAB ONLY (backlog 3.39, decided 2026-09-28). stage-01 is outside the
# gap and on real time; this makes it serve that time to the enclave time master and to nothing
# else, so host-4 can be re-anchored with `master --upstream $STAGE_01_ENCLAVE` - a coordinated
# step on this STIG-hardened enclave, see THE HONEST LIMIT above.
# Production's answer is a GPS source (AO-13) and this is never run there. At cutover stage-01's
# enclave address goes: host-4 falls back to its own clock and ClockReferenceLost says so until
# its upstream line is replaced (GPS) or removed (`master` with no --upstream).
cmd_reference() {
  need_root
  assert_stage01
  local eaddr="${STAGE_01_ENCLAVE:?STAGE_01_ENCLAVE not set in enclave-addresses.env}"
  local rule=(proto udp from "$MASTER" to "$eaddr" port 123)
  if [ "${1:-}" = "--remove" ]; then
    rm -f "$REF_DROPIN" && ok "removed $REF_DROPIN"
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
      ufw delete allow "${rule[@]}" && ok "ufw: 123/udp from $MASTER removed"
    fi
    systemctl restart chrony && ok "chrony restarted - stage-01 serves no one"
    return 0
  fi
  [ -z "${1:-}" ] || die "unknown argument: $1"
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$eaddr" \
    || die "stage-01 does not hold its enclave address $eaddr - $MASTER_NAME could not reach this reference"

  if ! dpkg -s chrony >/dev/null 2>&1; then
    say "installing chrony - it REPLACES systemd-timesyncd (the packages conflict), same upstream"
    apt-get install -y chrony || die "chrony install failed"
  fi
  # stage-01 is ONLINE. Its stock pools (ntp.ubuntu.com) ARE its reference and stay as shipped -
  # commenting them out is install_chrony's job inside the gap, never here.
  grep -q '^confdir\|^include /etc/chrony/conf.d' "$CONF" 2>/dev/null \
    || echo 'confdir /etc/chrony/conf.d' >> "$CONF"
  install -d -m 0755 /etc/chrony/conf.d
  {
    echo "# stage-01 as a time reference for the enclave. Written by time-sync.sh reference on $(date -Is)."
    echo "# LAB ONLY (backlog 3.39, AO-13): remove with 'time-sync.sh reference --remove'."
    echo "#"
    echo "# The time master and nothing else may ask."
    echo "allow $MASTER"
    echo "#"
    echo "# NO 'local' LINE, DELIBERATELY. If stage-01 loses its own reference it must stop being"
    echo "# one: chrony then answers 'unsynchronised', $MASTER_NAME rejects it and falls back to its"
    echo "# own clock, and ClockReferenceLost says so. A 'local' line here would serve stage-01's"
    echo "# free-running clock into the enclave as though it were UTC."
  } > "$REF_DROPIN"
  chmod 0644 "$REF_DROPIN"
  ok "wrote $REF_DROPIN (allow $MASTER only)"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${rule[@]}" comment 'enclave time reference - lab only (time-sync.sh reference, 3.39)' \
      && ok "ufw: 123/udp from $MASTER to $eaddr"
  fi
  systemctl restart chrony
  systemctl enable chrony >/dev/null 2>&1 || true
  say "waiting for stage-01 to synchronise to its own reference (up to 60 s)"
  local tries=0
  while [ "$tries" -lt 30 ]; do
    timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes && break
    tries=$((tries + 1)); sleep 2
  done
  chronyc -n sources 2>&1 | sed 's/^/    /'
  chronyc -n tracking 2>&1 | grep -E '^(Reference ID|Stratum|System time|Leap status)' | sed 's/^/    /'
  timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes \
    || die "stage-01 is NOT synchronised - it must not be offered as a reference until it is"
  ok "stage-01 serves real time to $MASTER_NAME ($MASTER) on $eaddr"
  say "  next, ON $MASTER_NAME:  sudo ./scripts/enclave/time-sync.sh master --upstream $eaddr"
  say "  then AT ONCE, on every client:  sudo systemctl restart chrony   (runbook 2.10 - it is a step)"
}

cmd_drift() {
  local ref="${1:-}"
  [ -n "$ref" ] || die "usage: $0 drift <reference-host-or-ip>
      The reference must SERVE NTP to this machine. stage-01 does NOT today - it runs
      systemd-timesyncd, a client only (found 2026-09-27, backlog 3.39). To measure the
      enclave against UTC from stage-01's side instead:  ./time-sync.sh drift-log  (on stage-01)"
  command -v chronyd >/dev/null 2>&1 || die "chrony is not installed"
  say "measuring against $ref - this CHANGES NOTHING"
  # -Q queries and prints the offset without setting the clock or binding a port.
  chronyd -Q -t 10 "server $ref iburst" 2>&1 | sed 's/^/    /' || true
  say ""
  say "  A large offset is not automatically something to correct. Stepping a running"
  say "  cluster's clock BACKWARD is its own outage, and on a hardened machine (STIG"
  say "  UBTU-24-600180, makestep 1 -1) any correction over 1 s IS a step. Correct it in a"
  say "  maintenance window: master first, then restart chrony on EVERY client at once -"
  say "  'letting them follow' leaves them split from the master until they next poll."
}

case "${1:-}" in
  drift-log)    cmd_drift_log ;;
  drift-report) cmd_drift_report ;;
  drift-timer)  cmd_drift_timer ;;
  master) shift; cmd_master "$@" ;;
  reference) shift; cmd_reference "$@" ;;
  client) cmd_client ;;
  verify) cmd_verify ;;
  drift)  shift; cmd_drift "$@" ;;
  *)      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
