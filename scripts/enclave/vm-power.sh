#!/usr/bin/env bash
# =========================================================================================
# vm-power.sh - shut the enclave's guests down in the right order, and reboot the host safely.
#
#     MACHINE: the hypervisor (host-4 today). It refuses to run anywhere that has no domains.
#
#     sudo ./vm-power.sh status                     what is running, changes nothing
#     sudo ./vm-power.sh guests-down                ordered graceful shutdown, waits for each
#     sudo ./vm-power.sh guests-up                  ordered start, reverse order
#     sudo ./vm-power.sh host-reboot                guests down FIRST, then reboot the host
#     sudo ./vm-power.sh host-down                  guests down FIRST, then power off
#     sudo ./vm-power.sh after-boot                 the three checks that follow every boot
#
#     --only "a b c"     operate on these domains only, in the order given
#     --timeout N        seconds to wait per guest      (VM_POWER_TIMEOUT, default 300)
#     --dry-run          print what would happen, touch nothing
#     --yes              skip the confirmation on host-reboot / host-down
#     --force-destroy    if a guest will not stop gracefully, KILL it. Never the default.
#
# WHY THIS EXISTS, and it is not convenience.
#
# On 2026-09-17 host-4 rebooted with all four guests running. `libvirt-guests` logged
# "Can't connect to default. Skipping." - libvirtd had already stopped when it ran - so
# NOTHING shut the guests down. All four took the equivalent of a power cord pull: Harbor's
# containerised PostgreSQL 18.3, MAAS's PostgreSQL 16 and Prometheus's TSDB. They came back,
# which was luck rather than design.
#
#   *** libvirt-guests IS NOT A SAFETY NET ON THIS HOST. This script is. ***
#
# Two facts drive the whole design:
#
#   1. `virsh shutdown` is ASYNCHRONOUS. It sends ACPI and returns immediately. What corrupts
#      a database is not the wrong order, it is the host going down while a guest is still
#      flushing. So every shutdown here WAITS for 'shut off' and the host commands REFUSE to
#      proceed while anything is still running.
#
#   2. `virsh destroy` is a power cord pull. On Harbor's Postgres that is how a reboot becomes
#      a restore. It is available behind --force-destroy and it is never automatic.
#
# The order, the per-guest timeout and the boot timeout are parameters in vm-specs.env
# (VM_POWER_ORDER, VM_POWER_TIMEOUT, VM_POWER_BOOT_TIMEOUT) - not values in this file.
#
# Runbook section 10c.
# =========================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/vm-specs.env" ] && . "$HERE/vm-specs.env"

ORDER="${VM_POWER_ORDER:-svc-obs-01 svc-harbor-01 svc-mgmt-01 svc-repo-01}"
TIMEOUT="${VM_POWER_TIMEOUT:-300}"
BOOT_TIMEOUT="${VM_POWER_BOOT_TIMEOUT:-180}"
POOL_PATH="${VM_POOL:-/var/lib/libvirt/images}"

DRY=0; YES=0; FORCE_DESTROY=0; ONLY=""

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
hdr()  { printf '\n== %s ==\n' "$*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

run() {
  if [ "$DRY" -eq 1 ]; then printf '  DRY: %s\n' "$*"; return 0; fi
  "$@"
}

# ---- guards ------------------------------------------------------------------------------
# NOT a hostname check. This has to keep working when host-1..3 become hypervisors too, so
# the test is "does this machine actually run libvirt and own domains" - which is the thing
# that matters and cannot be defeated by renaming a host.
assert_hypervisor() {
  command -v virsh >/dev/null 2>&1 \
    || die "virsh is not installed - this is not a hypervisor.
       vm-power.sh runs on the machine that OWNS the guests, not inside one."
  virsh list --all >/dev/null 2>&1 \
    || die "cannot talk to libvirt. Is libvirtd running?  systemctl status libvirtd"
  local n
  n="$(virsh list --all --name 2>/dev/null | awk 'NF' | wc -l)"
  [ "$n" -gt 0 ] || die "libvirt is running but no domains are defined here - nothing to do."
}

domstate() { virsh domstate "$1" 2>/dev/null || echo missing; }

# The list to act on, and it must be a real list of real domains.
targets() {
  local list="${ONLY:-$ORDER}" d out=""
  for d in $list; do
    case "$(domstate "$d")" in
      missing) warn "no such domain: $d - skipping" ;;
      *) out="$out $d" ;;
    esac
  done
  printf '%s' "${out# }"
}

reverse() { local d out=""; for d in $1; do out="$d $out"; done; printf '%s' "${out% }"; }

# ---- status -------------------------------------------------------------------------------
cmd_status() {
  assert_hypervisor
  hdr "domains"
  printf '  %-16s %-12s %s\n' NAME STATE AUTOSTART
  local d
  for d in $(virsh list --all --name 2>/dev/null | awk 'NF'); do
    printf '  %-16s %-12s %s\n' "$d" "$(domstate "$d")" \
      "$(virsh dominfo "$d" 2>/dev/null | awk -F': *' '/^Autostart/{print $2}')"
  done

  hdr "shutdown order (VM_POWER_ORDER)"
  say "$ORDER"
  say "timeout per guest: ${TIMEOUT}s"

  hdr "the image pool - a nofail mount, and that is why autostart can fail silently"
  if findmnt -no TARGET,SOURCE "$POOL_PATH" 2>/dev/null; then
    ok "pool mounted"
  else
    warn "$POOL_PATH IS NOT A SEPARATE MOUNT - if it should be, the guests' disks are not there"
  fi

  hdr "libvirt-guests - NOT a safety net, and here is its actual configuration"
  say "enabled : $(systemctl is-enabled libvirt-guests 2>/dev/null || echo unknown)"
  if [ -f /etc/default/libvirt-guests ]; then
    awk -F= '/^(ON_BOOT|ON_SHUTDOWN|SHUTDOWN_TIMEOUT|PARALLEL_SHUTDOWN)=/{printf "  %-18s %s\n",$1,$2}' \
      /etc/default/libvirt-guests
  else
    say "no /etc/default/libvirt-guests - distribution defaults apply"
  fi
  say ""
  say "  On 2026-09-17 it logged \"Can't connect to default. Skipping.\" during a host reboot"
  say "  and shut down nothing. Do not rely on it. Use guests-down."
}

# ---- one guest down, and WAIT ------------------------------------------------------------
# Returns 0 only when the domain really is 'shut off'.
stop_one() {
  local d="$1" st waited=0
  st="$(domstate "$d")"
  case "$st" in
    "shut off") ok "$(printf '%-16s already shut off' "$d")"; return 0 ;;
    running|paused|"pmsuspended") : ;;
    *) warn "$(printf '%-16s state is %s - leaving it alone' "$d" "$st")"; return 1 ;;
  esac

  if [ "$DRY" -eq 1 ]; then
    printf '  DRY: virsh shutdown %s   then wait up to %ss for it to reach shut off\n' "$d" "$TIMEOUT"
    return 0
  fi

  printf '  %-16s ACPI shutdown' "$d"
  virsh shutdown "$d" >/dev/null 2>&1 || true
  # ACPI is a REQUEST. Poll until the domain is genuinely gone, or the timeout expires.
  while [ "$waited" -lt "$TIMEOUT" ]; do
    if [ "$(domstate "$d")" = "shut off" ]; then
      printf ' stopped after %ss\n' "$waited"; return 0
    fi
    printf '.'
    sleep 5; waited=$((waited+5))
  done
  printf ' STILL %s after %ss\n' "$(domstate "$d")" "$TIMEOUT"
  return 1
}

cmd_guests_down() {
  need_root; assert_hypervisor
  local list; list="$(targets)"
  [ -n "$list" ] || die "nothing to shut down"

  hdr "shutting down in order"
  say "$list"
  say "up to ${TIMEOUT}s each. Harbor is the slow one: 11 containers and a Postgres to close."
  say ""

  local d stuck=""
  for d in $list; do
    stop_one "$d" || stuck="$stuck $d"
  done

  if [ -n "$stuck" ]; then
    say ""
    warn "these did NOT reach 'shut off':$stuck"
    if [ "$FORCE_DESTROY" -eq 1 ]; then
      warn "--force-destroy given. THIS IS A POWER CORD PULL on each of them."
      for d in $stuck; do
        run virsh destroy "$d" || true
        say "$(printf '%-16s %s' "$d" "$(domstate "$d")")"
      done
      warn "destroyed guests did not flush. Check every database before trusting it."
    else
      die "refusing to go further. Something in$stuck is ignoring SIGTERM.
       Find out what before reaching for a kill - on Harbor's Postgres, destroy is how a
       reboot becomes a restore. Look inside:  virsh console <domain>
       If you have decided it is safe:  re-run with --force-destroy"
    fi
  fi

  say ""
  virsh list --all
  ok "all target guests are shut off"
}

# ---- up -----------------------------------------------------------------------------------
cmd_guests_up() {
  need_root; assert_hypervisor

  # THE SILENT FAILURE THIS CATCHES: the image pool is mounted nofail, so if libvirtd wins
  # the race against it the guests' disks are simply absent - autostart fails and nothing
  # anywhere reports an error. Starting them by hand against a missing pool fails the same way.
  if ! findmnt -no TARGET "$POOL_PATH" >/dev/null 2>&1; then
    warn "$POOL_PATH is not a mountpoint on this machine."
    say  "  If the guests' disks live on a separate volume, it is NOT mounted and starting"
    say  "  them now will fail. That volume is mounted nofail, so boot did not complain."
    [ "$DRY" -eq 1 ] || die "mount the pool first, then re-run"
  fi

  local list; list="$(reverse "$(targets)")"
  [ -n "$list" ] || die "nothing to start"

  hdr "starting in reverse order"
  say "$list"
  say "  reversed so the mirror is up before anything that might want it."
  say ""

  local d
  for d in $list; do
    case "$(domstate "$d")" in
      running) ok "$(printf '%-16s already running' "$d")"; continue ;;
    esac
    if [ "$DRY" -eq 1 ]; then printf '  DRY: virsh start %s\n' "$d"; continue; fi
    printf '  %-16s starting' "$d"
    if virsh start "$d" >/dev/null 2>&1; then
      # 'running' means qemu exec'd, which is long before the guest is usable. Wait for it
      # to answer on the network, because that is the thing the operator actually needs.
      local waited=0 up=0
      while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
        if ping -c1 -W1 "$d" >/dev/null 2>&1; then up=1; break; fi
        printf '.'
        sleep 5; waited=$((waited+5))
      done
      if [ "$up" -eq 1 ]; then printf ' answering after %ss\n' "$waited"
      else printf ' running but NOT answering after %ss\n' "$BOOT_TIMEOUT"; fi
    else
      printf ' FAILED to start\n'
      warn "  virsh start $d failed. Check the pool and:  virsh start $d"
    fi
  done

  say ""
  virsh list --all
}

# ---- the host ----------------------------------------------------------------------------
host_power() {  # <reboot|poweroff>
  local action="$1"
  need_root; assert_hypervisor

  hdr "this will $action $(hostname -s), which is the hypervisor"
  say "Every guest goes with it. On host-4 that is the whole enclave."
  say ""
  say "And when it comes back, the OS volume prompts for a LUKS passphrase at the console -"
  say "so somebody has to be AT the machine. Confirmed on host-4 2026-09-17."
  say ""

  if [ "$YES" -eq 0 ] && [ "$DRY" -eq 0 ]; then
    printf '  type the hostname to continue (%s): ' "$(hostname -s)"
    local answer=""; read -r answer || true
    [ "$answer" = "$(hostname -s)" ] || die "not confirmed - nothing has been done"
  fi

  cmd_guests_down

  # THE GUARD THAT MATTERS. cmd_guests_down already dies on a stuck guest, but re-check
  # here: this is the last moment before the host goes down, and a domain that came back
  # up between then and now must stop this.
  local still; still="$(virsh list --state-running --name 2>/dev/null | awk 'NF' | tr '\n' ' ')"
  [ -z "${still// /}" ] || die "domains are STILL running: $still
       refusing to $action the host. Nothing has been done to the host."

  hdr "backup volume"
  if findmnt -no TARGET /mnt/vmbackup >/dev/null 2>&1; then
    say "unmounting /mnt/vmbackup cleanly before the host goes down"
    run umount /mnt/vmbackup || warn "could not unmount - it will be dirty on the way back"
  else
    say "not mounted - nothing to do"
  fi

  hdr "$action"
  say "AFTER IT COMES BACK, run:   sudo ./vm-power.sh after-boot"
  run systemctl "$action"
}

# ---- after a boot ------------------------------------------------------------------------
cmd_after_boot() {
  assert_hypervisor
  local bad=0

  hdr "1. the image pool - the nofail mount that makes autostart fail in silence"
  if findmnt -no TARGET,SOURCE "$POOL_PATH" 2>/dev/null; then ok "mounted"
  else warn "NOT MOUNTED - that is why any guest is down"; bad=1; fi

  hdr "2. domains"
  virsh list --all
  local d down=""
  for d in $(virsh list --all --name 2>/dev/null | awk 'NF'); do
    [ "$(domstate "$d")" = "running" ] || down="$down $d"
  done
  if [ -n "$down" ]; then warn "not running:$down    ->  sudo $0 guests-up"; bad=1
  else ok "all domains running"; fi

  hdr "3. the backup volume - it does NOT come back on its own"
  if findmnt -no TARGET,SIZE,USED /mnt/vmbackup 2>/dev/null; then ok "mounted"
  else
    warn "NOT MOUNTED  ->  sudo ./vm-backup.sh reattach"; bad=1
  fi

  hdr "4. did anything die hard last boot?"
  # A guest that was killed rather than shut down does not say so itself - libvirt-guests is
  # where the evidence is, and its silence is the tell.
  journalctl -b -1 -u libvirt-guests --no-pager 2>/dev/null | tail -4 \
    || say "no previous boot recorded"
  say ""
  say "  \"Can't connect to default. Skipping.\" means it shut down NOTHING and every guest"
  say "  was killed. Check each database before trusting it."

  say ""
  [ "$bad" -eq 0 ] && ok "host is back and complete" || warn "items above need attention"
  return 0
}

# ---- args --------------------------------------------------------------------------------
CMD="${1:-}"; [ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --only)          ONLY="${2:?--only needs a quoted list of domains}"; shift 2 ;;
    --timeout)       TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --boot-timeout)  BOOT_TIMEOUT="${2:?--boot-timeout needs seconds}"; shift 2 ;;
    -n|--dry-run)    DRY=1; shift ;;
    -y|--yes)        YES=1; shift ;;
    --force-destroy) FORCE_DESTROY=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a whole number of seconds" ;; esac
case "$BOOT_TIMEOUT" in ''|*[!0-9]*) die "--boot-timeout must be a whole number of seconds" ;; esac

case "$CMD" in
  status)      cmd_status ;;
  guests-down) cmd_guests_down ;;
  guests-up)   cmd_guests_up ;;
  host-reboot) host_power reboot ;;
  host-down)   host_power poweroff ;;
  after-boot)  cmd_after_boot ;;
  *)
    printf 'usage: %s {status|guests-down|guests-up|host-reboot|host-down|after-boot}\n' "$(basename "$0")" >&2
    printf '       [--only "a b c"] [--timeout N] [--boot-timeout N] [--dry-run] [--yes] [--force-destroy]\n' >&2
    exit 2 ;;
esac
