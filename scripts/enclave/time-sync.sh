#!/usr/bin/env bash
# =========================================================================================
# time-sync.sh - give the enclave one clock.
#
#   sudo ./time-sync.sh master    this machine becomes the enclave time source
#   sudo ./time-sync.sh client    follow the enclave time source
#        ./time-sync.sh verify    read-only: are we synchronised, and to what
#        ./time-sync.sh drift     read-only: how far is this machine from a reference
#
# WHY THIS IS NOT OPTIONAL, AND WHY IT COMES BEFORE THE CLUSTER:
#
#   Every machine in the enclave currently reports "System clock synchronized: no".
#   systemd-timesyncd is running with NO server configured - active, and doing nothing. They
#   agree with each other today only because they were built recently from a correct clock.
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
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -r "$SELF/enclave-addresses.env" ] && . "$SELF/enclave-addresses.env"

MASTER="${TIME_MASTER:?TIME_MASTER must be set in enclave-addresses.env}"
MASTER_NAME="${TIME_MASTER_NAME:-time-master}"
ALLOW="${TIME_ALLOW:-10.2.20.0/24}"
CONF=/etc/chrony/chrony.conf
DROPIN=/etc/chrony/conf.d/10-enclave.conf

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

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
}

# ---------------------------------------------------------------------------- master
cmd_master() {
  need_root
  local virt; virt=$(systemd-detect-virt 2>/dev/null || echo unknown)
  [ "$virt" = "none" ] || die "this machine is a $virt guest.
      The time master must be PHYSICAL. A guest takes its clock from its hypervisor, so
      serving time from here would hand the hypervisor its own clock back. Run this on
      $MASTER_NAME ($MASTER)."

  install_chrony
  {
    echo "# Enclave time master. Written by time-sync.sh on $(date -Is)."
    echo "#"
    echo "# 'local stratum 10' is the load-bearing line: without it chrony will NOT serve time"
    echo "# while it is itself unsynchronised, which in an air gap is always. Stratum 10 is"
    echo "# deliberately poor - it says 'I am a local reference, believe me only because there"
    echo "# is nothing better', so a real reference added later wins automatically."
    echo "local stratum 10"
    echo ""
    echo "# Who may ask. The enclave subnet and nothing else."
    echo "allow $ALLOW"
    echo ""
    echo "# Step rather than slew for the first few updates only. A large BACKWARD step on a"
    echo "# running cluster is its own outage - etcd and Ceph both dislike it - so after the"
    echo "# third update chrony slews and never jumps."
    echo "makestep 1.0 3"
    echo "rtcsync"
  } > "$DROPIN"
  chmod 0644 "$DROPIN"
  ok "wrote $DROPIN"
  systemctl restart chrony
  systemctl enable chrony >/dev/null 2>&1 || true
  sleep 2
  ok "$(hostname -s) is the enclave time source, serving $ALLOW"
  cmd_verify
}

# ---------------------------------------------------------------------------- client
cmd_client() {
  need_root
  local myip; myip=$(ip -4 -br addr | awk '$1!="lo"{split($3,a,"/"); print a[1]; exit}')
  [ "$myip" != "$MASTER" ] || die "this machine IS $MASTER - run 'master' here, not 'client'"

  install_chrony
  {
    echo "# Enclave time client. Written by time-sync.sh on $(date -Is)."
    echo "# The enclave has exactly one source. Pointing at anything else - including a public"
    echo "# pool that is unreachable in the gap - produces a machine that never synchronises"
    echo "# and says so only in timedatectl, which nobody reads until something breaks."
    echo "server $MASTER iburst"
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
  # timedatectl is what an assessor and every other script will look at.
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    ok "System clock synchronized: yes"
  else
    warn "System clock synchronized: NO - chrony has not settled, or cannot reach $MASTER"
    fail=1
  fi
  return $fail
}

# ---------------------------------------------------------------------------- drift
# Measure against a reference WITHOUT changing anything. Used at gap-open to see how far the
# enclave has walked from real time before deciding whether to re-anchor.
cmd_drift() {
  local ref="${1:-}"
  [ -n "$ref" ] || die "usage: $0 drift <reference-host-or-ip>
      At gap-open, stage-01 has a route to real time and is the obvious reference."
  command -v chronyd >/dev/null 2>&1 || die "chrony is not installed"
  say "measuring against $ref - this CHANGES NOTHING"
  # -Q queries and prints the offset without setting the clock or binding a port.
  chronyd -Q -t 10 "server $ref iburst" 2>&1 | sed 's/^/    /' || true
  say ""
  say "  A large offset is not automatically something to correct. Stepping a running"
  say "  cluster's clock BACKWARD is its own outage. If the offset matters, correct it"
  say "  during a maintenance window, master first, and let the clients follow."
}

case "${1:-}" in
  master) cmd_master ;;
  client) cmd_client ;;
  verify) cmd_verify ;;
  drift)  shift; cmd_drift "$@" ;;
  *)      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
