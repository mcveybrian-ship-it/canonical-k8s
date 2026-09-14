#!/usr/bin/env bash
# =========================================================================================
# monitoring.sh - put a metrics exporter on an enclave machine, correctly.
#
#     MACHINE: any in-gap machine. Refuses outside the boundary.
#
#     sudo ./monitoring.sh exporter          node-exporter: install, bind, prune collectors
#     sudo ./monitoring.sh libvirt           per-guest metrics, HYPERVISORS ONLY
#     ./monitoring.sh status                 what is running here and where it is bound
#
# WHY A SCRIPT FOR WHAT LOOKS LIKE ONE apt-get:
#
#   The install is one command. Everything that makes it SAFE differs per machine, and doing
#   that by hand five times is how one machine ends up wrong:
#
#   1. THE BIND ADDRESS. The package binds *:9100 - every interface, exactly the shape of the
#      postfix finding in 6.3e. Each machine must bind its OWN enclave address, which this
#      reads from enclave-addresses.env rather than being told.
#
#   2. THE COLLECTOR TIMERS. prometheus-node-exporter-collectors installs FIVE systemd timers -
#      apt, ipmitool-sensor, mellanox-hca-temp, nvme, smartmon. On a VM four of them collect
#      nothing forever: no BMC, no Mellanox card, no NVMe, no SMART behind virtio. On host-4
#      nvme and smartmon are genuinely useful because it has real disks.
#      **So decide from the HARDWARE, not from a list.** Each timer is kept only if the thing
#      it reads actually exists on this machine.
#
#   3. THE FIREWALL. 9100 exposes every mount, interface, process count and kernel version.
#      The rule belongs in stig-tailor.sh's ufw table, source-restricted to the collector -
#      not poked in by hand here. This script SAYS SO and does not touch ufw.
# =========================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
[ -f "$HERE/enclave-addresses.env" ] && . "$HERE/enclave-addresses.env"

NE_DEFAULTS=/etc/default/prometheus-node-exporter
LV_DEFAULTS=/etc/default/prometheus-libvirt-exporter
NE_PORT="${NODE_EXPORTER_PORT:-9100}"
LV_PORT="${LIBVIRT_EXPORTER_PORT:-9177}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# THE MACHINE'S OWN ENCLAVE ADDRESS, from the one file that owns addressing.
# Never `hostname -I` - stage-01 is multi-homed and that would pick whichever interface the
# kernel listed first, which is how a service ends up bound to the internet-facing NIC.
my_enclave_ip() {
  local me key ip
  me="$(hostname -s)"
  key="$(printf '%s' "$me" | tr '[:lower:]-' '[:upper:]_')"
  ip="$(eval "printf '%s' \"\${$key:-}\"")"
  printf '%s' "$ip"
}

guard_in_gap() {
  local me; me="$(hostname -s)"
  case "$me" in
    stage-01|build-01)
      die "monitoring.sh does not run on $me - it is outside the ATO boundary." ;;
  esac
}

# ---- keep a collector only if the hardware it reads is present --------------------------
have_ipmi()     { [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ] || [ -e /dev/ipmidev/0 ]; }
have_mellanox() { [ -d /sys/class/infiniband ] && [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; }
have_nvme()     { compgen -G '/dev/nvme[0-9]*n[0-9]*' >/dev/null 2>&1; }
have_smart()    { compgen -G '/dev/sd[a-z]' >/dev/null 2>&1 || have_nvme; }

cmd_exporter() {
  guard_in_gap; need_root
  local me ip; me="$(hostname -s)"; ip="$(my_enclave_ip)"
  [ -n "$ip" ] || die "no enclave address for '$me' in enclave-addresses.env.
       Add it there first - this script will not guess an interface."

  say "installing prometheus-node-exporter on $me"
  DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus-node-exporter 2>&1 | tail -3

  # ---- bind to THIS machine's enclave address -------------------------------------------
  [ -f "$NE_DEFAULTS" ] || die "no $NE_DEFAULTS - did the package install?"
  cp -a "$NE_DEFAULTS" "/var/backups/$(basename "$NE_DEFAULTS").$(date +%Y%m%dT%H%M%S)"
  # SET the existing line, never append. An appended ARGS= works (the file is sourced, last
  # wins) and leaves two lines that disagree - someone edits the first one and nothing changes.
  if grep -q '^ARGS=' "$NE_DEFAULTS"; then
    sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=${ip}:${NE_PORT}\"|" "$NE_DEFAULTS"
  else
    printf 'ARGS="--web.listen-address=%s:%s"\n' "$ip" "$NE_PORT" >> "$NE_DEFAULTS"
  fi
  local n; n="$(grep -c '^ARGS=' "$NE_DEFAULTS")"
  [ "$n" -eq 1 ] || {
    warn "$NE_DEFAULTS has $n ARGS lines - collapsing to the last one"
    local keep; keep="$(grep '^ARGS=' "$NE_DEFAULTS" | tail -1)"
    sed -i '/^ARGS=/d' "$NE_DEFAULTS"; printf '%s\n' "$keep" >> "$NE_DEFAULTS"
  }

  # ---- prune collectors whose hardware is not here ---------------------------------------
  say ""
  say "collector timers - kept only where the hardware exists:"
  local t hw
  for t in apt ipmitool-sensor mellanox-hca-temp nvme smartmon; do
    case "$t" in
      apt)               hw=yes ;;                                   # pending updates: always useful
      ipmitool-sensor)   have_ipmi     && hw=yes || hw=no ;;
      mellanox-hca-temp) have_mellanox && hw=yes || hw=no ;;
      nvme)              have_nvme     && hw=yes || hw=no ;;
      smartmon)          have_smart    && hw=yes || hw=no ;;
    esac
    systemctl list-unit-files "prometheus-node-exporter-$t.timer" >/dev/null 2>&1 || continue
    if [ "$hw" = yes ]; then
      systemctl enable --now "prometheus-node-exporter-$t.timer" >/dev/null 2>&1 || true
      printf '     %-20s KEPT      the hardware is present\n' "$t"
    else
      systemctl disable --now "prometheus-node-exporter-$t.timer" >/dev/null 2>&1 || true
      printf '     %-20s disabled  nothing on this machine to read\n' "$t"
    fi
  done

  systemctl restart prometheus-node-exporter
  sleep 2
  # PROVE THE BIND, do not assume it. A wildcard here is the postfix finding again.
  local bound
  bound="$(ss -tlnH "sport = :$NE_PORT" 2>/dev/null | awk '{print $4}' | head -1)"
  case "$bound" in
    "$ip:$NE_PORT") ok "bound $bound" ;;
    ""|*)           warn "expected $ip:$NE_PORT but ss says '${bound:-nothing listening}'"
                    warn "  the package may be ignoring ARGS - check: systemctl cat prometheus-node-exporter"
                    return 1 ;;
  esac
  curl -sf "http://$ip:$NE_PORT/metrics" >/dev/null 2>&1 \
    && ok "serving metrics" || { warn "bound but not serving"; return 1; }

  say ""
  warn "9100 IS NOT FIREWALLED BY THIS SCRIPT, deliberately."
  say "   It exposes every mount, interface, process count and kernel version on this box."
  say "   The rule belongs in stig-tailor.sh's ufw table, source-restricted to the collector:"
  say "     sudo ./stig-tailor.sh ufw          # plan"
  say "     sudo ./stig-tailor.sh ufw --apply"
  say "   ufw is only ENABLED on machines with a rule table. Where it is not enabled, this"
  say "   port is open to the whole enclave - which is why the gap must be shut."
}

cmd_libvirt() {
  guard_in_gap; need_root
  local me ip; me="$(hostname -s)"; ip="$(my_enclave_ip)"
  command -v virsh >/dev/null 2>&1 \
    || die "no virsh on $me - the libvirt exporter belongs on a HYPERVISOR."
  [ -n "$ip" ] || die "no enclave address for '$me' in enclave-addresses.env"

  # WHY THIS AND NOT JUST node-exporter IN THE GUEST: it reports per-guest CPU, disk and
  # network FROM THE HYPERVISOR, so a VM that is too sick to report its own metrics still has
  # metrics. That is the difference between monitoring and monitoring that helps at 3am.
  say "installing prometheus-libvirt-exporter on $me"
  DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus-libvirt-exporter 2>&1 | tail -3
  if [ -f "$LV_DEFAULTS" ]; then
    cp -a "$LV_DEFAULTS" "/var/backups/$(basename "$LV_DEFAULTS").$(date +%Y%m%dT%H%M%S)"
    if grep -q '^ARGS=' "$LV_DEFAULTS"; then
      sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=${ip}:${LV_PORT}\"|" "$LV_DEFAULTS"
    else
      printf 'ARGS="--web.listen-address=%s:%s"\n' "$ip" "$LV_PORT" >> "$LV_DEFAULTS"
    fi
  else
    warn "no $LV_DEFAULTS - check how this package takes its arguments before trusting the bind"
  fi
  systemctl restart prometheus-libvirt-exporter 2>/dev/null || true
  sleep 2
  ss -tlnH "sport = :$LV_PORT" 2>/dev/null | awk '{print "     bound " $4}' | head -1
  curl -sf "http://$ip:$LV_PORT/metrics" 2>/dev/null | grep -c '^libvirt' \
    | sed 's/^/     libvirt metrics exposed: /' || warn "not serving on $ip:$LV_PORT"
  say ""
  warn "add $LV_PORT to the ufw table too, source-restricted to the collector."
}

cmd_status() {
  local me ip; me="$(hostname -s)"; ip="$(my_enclave_ip)"
  printf '\n  monitoring on %s (%s)\n\n' "$me" "${ip:-no enclave address}"
  local svc
  for svc in prometheus-node-exporter prometheus-libvirt-exporter prometheus prometheus-alertmanager grafana-server; do
    systemctl list-unit-files "$svc.service" >/dev/null 2>&1 || continue
    printf '     %-30s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null)"
  done
  printf '\n  listening:\n'
  ss -tlnH 2>/dev/null | awk '{print $4}' \
    | grep -E ':(9090|9093|9094|9100|9177|3000)$' | sort -u | sed 's/^/     /' \
    || printf '     nothing on a monitoring port\n'
  # A WILDCARD BIND IS THE FINDING, so name it rather than printing an address list.
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(\*|0\.0\.0\.0|\[::\]):(9100|9177|9090|9093|3000)$'; then
    printf '\n'
    warn "a monitoring port is bound to ALL INTERFACES - that is the postfix shape (6.3e)."
    warn "  Re-run: sudo $0 exporter"
  fi
  printf '\n  collector timers:\n'
  systemctl list-timers 'prometheus-node-exporter-*' --no-pager 2>/dev/null \
    | awk 'NR>1 && NF>3 {print "     " $NF}' | sed '/^\s*$/d' || true
  echo
}

case "${1:-status}" in
  exporter) shift; cmd_exporter "$@" ;;
  libvirt)  shift; cmd_libvirt "$@" ;;
  status)   shift; cmd_status "$@" ;;
  *) printf 'usage: %s {exporter|libvirt|status}\n' "$0" >&2; exit 2 ;;
esac
