#!/usr/bin/env bash
# =========================================================================================
# gap-state.sh - move the enclave between State A (build) and State B (air-gapped).
#
#     MACHINE: stage-01. It changes stage-01's addressing; the cable is yours to move.
#
#     ./gap-state.sh status     which state, and are the safety conditions holding
#     ./gap-state.sh open       State A - add stage-01's foot in the enclave subnet
#     ./gap-state.sh close      State B - remove it
#
# WHY THE FOOT GOES ON STAGE-01 AND NOT ON THE ENCLAVE HOSTS
#   The obvious alternative is to give host-4 an address on the staging subnet. Do not:
#     * it puts an ENCLAVE host on the internet-connected segment, so isolation then depends
#       on that host having no default route rather than on it having no address there;
#     * host-4's address lives on br0, which every enclave VM is bridged to - so the VMs land
#       on staging as well, not just the host;
#     * it does not scale. One address on stage-01 covers the whole enclave; the other way is
#       an address per machine, and there will be fourteen.
#
# WHAT STATE A IS AND IS NOT
#   State A is a BUILD convenience. While port 4 is connected the enclave is isolated from the
#   office network and from the internet, but it is NOT air-gapped - isolation rests on absent
#   routes and on ip_forward being 0. Nothing built in State A should be called accredited.
#   State B is the cable out of GS105E port 4, and that is the only claim worth making to an
#   assessor.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDRS="${ADDRS:-$SELF/enclave-addresses.env}"
NETPLAN="${GAP_NETPLAN:-/etc/netplan/70-newnet.yaml}"
NIC="${GAP_NIC:-eth1}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

[ -r "$ADDRS" ] || die "no address file at $ADDRS"
# shellcheck disable=SC1090
. "$ADDRS"
: "${STAGE_01:?}" "${HOST_4:?}"
STAGING_ADDR="$STAGE_01/24"
ENCLAVE_FOOT="$(printf '%s' "$HOST_4" | cut -d. -f1-3).160/24"

# --- the condition that must hold in BOTH states -----------------------------------------
# Multi-homed is fine. ROUTING is not. With forwarding on, stage-01 silently becomes a router
# joining the office network to staging - and in State A, to the enclave as well.
check_forwarding() {
  local f; f=$(cat /proc/sys/net/ipv4/ip_forward)
  if [ "$f" = "0" ]; then ok "ip_forward = 0 - stage-01 is multi-homed, not routing"
  else warn "ip_forward = $f - stage-01 IS ROUTING. Turn it off:  sudo sysctl -w net.ipv4.ip_forward=0"; return 1; fi
}

write_netplan() {
  local want_foot="$1" tmp; tmp=$(mktemp)
  {
    echo "# stage-01's second NIC. Managed by scripts/enclave/gap-state.sh - do not hand-edit."
    echo "#"
    echo "# No routes: block. eth0 keeps the default route; this NIC reaches its own subnets only."
    [ "$want_foot" = "yes" ] && echo "# STATE A: the $ENCLAVE_FOOT foot is TEMPORARY. Remove it with 'gap-state.sh close'."
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    $NIC:"
    echo "      dhcp4: false"
    echo "      dhcp6: false"
    echo "      addresses:"
    echo "        - $STAGING_ADDR"
    [ "$want_foot" = "yes" ] && echo "        - $ENCLAVE_FOOT"
  } > "$tmp"
  install -m 0600 "$tmp" "$NETPLAN"; rm -f "$tmp"
  netplan generate || die "netplan generate failed - $NETPLAN not applied"
  netplan apply
}

cmd_status() {
  local has_foot="no"
  ip -br addr show "$NIC" 2>/dev/null | grep -q "${ENCLAVE_FOOT%/*}" && has_foot="yes"
  say "nic      : $(ip -br addr show "$NIC" 2>/dev/null | awk '{$1="";$2="";print}' | xargs)"
  if [ "$has_foot" = "yes" ]; then
    say "state    : A (BUILD) - stage-01 has a foot at ${ENCLAVE_FOOT%/*}"
    say "           the enclave is NOT air-gapped while port 4 is connected"
  else
    say "state    : B (GAPPED) - no enclave address on stage-01"
  fi
  check_forwarding || true
  printf '  reach    : '
  if ping -c1 -W2 "$HOST_4" >/dev/null 2>&1; then
    echo "host-4 REACHABLE (cable in port 4 is connected)"
  else
    echo "host-4 unreachable (cable out, or foot removed)"
  fi
}

cmd_open() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  check_forwarding || die "refusing to open State A while stage-01 is forwarding"
  write_netplan yes
  ok "stage-01 now holds $ENCLAVE_FOOT on $NIC"
  say ""
  say "  NOW PLUG IN GS105E PORT 4."
  say "  Then:  ./gap-state.sh status   - host-4 should become reachable"
  say ""
  say "  While in State A the enclave is NOT air-gapped. Nothing built now is accredited."
}

cmd_close() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  say "Before closing, confirm everything the enclave needs is INSIDE it."
  say "Reopening costs a cable and one address, but it is still a trip."
  say ""
  write_netplan no
  ok "removed the enclave foot from $NIC"
  say ""
  say "  NOW UNPLUG GS105E PORT 4. That cable is the air gap."
  say "  Then verify - FAILURE is the pass:"
  say "      ping -c2 -W2 $HOST_4     # must fail"
}

case "${1:-status}" in
  status) cmd_status ;;
  open)   cmd_open ;;
  close)  cmd_close ;;
  *)      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
