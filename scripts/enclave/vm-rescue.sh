#!/usr/bin/env bash
# =========================================================================================
# vm-rescue.sh - get back into a VM you are locked out of. RUN ON THE HYPERVISOR.
#
#   sudo ./vm-rescue.sh status   <vm>    what state is it in, and can we edit its disk
#   sudo ./vm-rescue.sh password <vm>    reset the admin password OFFLINE
#   sudo ./vm-rescue.sh console  <vm>    attach to the serial console (escape: Ctrl-])
#   sudo ./vm-rescue.sh fix-console <vm> give a pre-2026-09-11 VM a real pty console
#   sudo ./vm-rescue.sh nopasswd <vm>    restore NOPASSWD sudo - last resort, see below
#
# WHY THIS EXISTS:
#
#   On 2026-09-08, applying the DISA STIG to svc-harbor-01 locked the only sudo-capable
#   account out of root. The composer created that user with `sudo: ALL=(ALL) NOPASSWD:ALL`
#   and NO password; usg correctly removed NOPASSWD, and sudo then demanded a password that
#   had never been set. No number of attempts succeeds. The machine is headless, the account
#   is the only member of the sudo group, and there is no root password.
#
#   The composer now sets a password hash on every VM, so this should not recur. This script
#   is for when something else does - a bad sshd config, a broken PAM stack, a full disk, a
#   fat-fingered passwd. Editing the disk offline works when nothing inside the guest does.
#
# HOW IT WORKS, AND WHY NOT GRUB:
#
#   `virt-customize` mounts the guest's filesystem from the hypervisor and edits it directly.
#   The alternative - catching GRUB over a serial console and booting init=/bin/bash - is
#   fiddly at the best of times and worse when GRUB_TIMEOUT is 0, which it is on machines
#   built here.
#
#   THE GUEST MUST BE SHUT DOWN. libguestfs will refuse, or silently corrupt, a running
#   guest's filesystem. This script shuts it down and will not proceed if it cannot.
# =========================================================================================
set -euo pipefail

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

ADMIN_USER="${VM_ADMIN_USER:-encadmin}"

need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo - this edits a guest filesystem"; }

vm_disk() {
  local vm="$1" d
  # Ask libvirt rather than guessing the path: a VM composed elsewhere may not follow the
  # naming convention, and editing the wrong qcow2 is unrecoverable.
  d=$(virsh domblklist "$vm" --details 2>/dev/null \
      | awk '$2=="disk" && $4 ~ /\.(qcow2|img|raw)$/ {print $4; exit}')
  [ -n "$d" ] || die "cannot determine the disk for '$vm'. virsh domblklist $vm"
  [ -f "$d" ] || die "libvirt reports a disk at $d but it does not exist"
  printf '%s' "$d"
}

need_guestfs() {
  command -v virt-customize >/dev/null 2>&1 && return 0
  warn "libguestfs-tools is not installed"
  say  "  it is in the enclave mirror:"
  say  "     sudo apt-get install -y libguestfs-tools"
  die  "install it and run this again"
}

ensure_off() {
  local vm="$1" state i
  state=$(virsh domstate "$vm" 2>/dev/null || true)
  [ -n "$state" ] || die "no such VM: $vm"
  if [ "$state" = "shut off" ]; then ok "$vm is already shut off"; return 0; fi

  say "$vm is '$state' - shutting it down (ACPI, graceful)"
  virsh shutdown "$vm" >/dev/null 2>&1 || true
  for i in $(seq 1 24); do
    sleep 5
    [ "$(virsh domstate "$vm" 2>/dev/null)" = "shut off" ] && { ok "shut off after ~$((i*5))s"; return 0; }
  done

  # ACPI needs a guest healthy enough to respond. A guest broken enough to need rescuing
  # often is not, so fall back - but say so, because it is an unclean stop.
  warn "did not shut down in 120s - forcing off. This is an unclean stop."
  virsh destroy "$vm" >/dev/null 2>&1 || true
  sleep 3
  [ "$(virsh domstate "$vm" 2>/dev/null)" = "shut off" ] || die "could not stop $vm"
  ok "forced off"
}

cmd_status() {
  local vm="${1:?usage: $0 status <vm>}"
  say "state:  $(virsh domstate "$vm" 2>/dev/null || echo 'no such VM')"
  say "disk:   $(virsh domblklist "$vm" --details 2>/dev/null | awk '$2=="disk"{print $4}' | tr '\n' ' ')"
  say "guestfs tooling: $(command -v virt-customize >/dev/null 2>&1 && echo present || echo MISSING)"
  say "console log: $(ls -1 /var/lib/libvirt/images/console/"$vm"-console.log 2>/dev/null || echo none)"
}

cmd_password() {
  need_root; need_guestfs
  local vm="${1:?usage: sudo $0 password <vm>}"
  local disk; disk=$(vm_disk "$vm")
  say "vm:   $vm"
  say "disk: $disk"
  say "user: $ADMIN_USER   (override with VM_ADMIN_USER)"

  local p1 p2
  read -rsp "  new password: " p1; echo
  read -rsp "  again:        " p2; echo
  [ -n "$p1" ] || die "refusing to set an empty password"
  [ "$p1" = "$p2" ] || die "the two entries do not match"

  # Through a file, not the command line: virt-customize's arguments are visible in ps for
  # the duration, and this is the credential that is about to be the only route to root.
  local pf; pf=$(mktemp); chmod 600 "$pf"
  # shellcheck disable=SC2064
  trap "shred -u '$pf' 2>/dev/null || rm -f '$pf'" EXIT
  printf '%s' "$p1" > "$pf"
  unset p1 p2

  ensure_off "$vm"
  say "editing the disk offline"
  virt-customize -a "$disk" --password "$ADMIN_USER:file:$pf" \
    || die "virt-customize failed. The VM is still shut off; start it with:
       virsh start $vm"
  ok "password set for $ADMIN_USER"

  virsh start "$vm" >/dev/null || die "password was set but the VM did not start: virsh start $vm"
  ok "$vm started"
  say ""
  say "  Give it a minute, then from the VM:   sudo -v"
  say "  Put that password in your password manager - after STIG it is the only route to root."
}

cmd_nopasswd() {
  need_root; need_guestfs
  local vm="${1:?usage: sudo $0 nopasswd <vm>}"
  local disk; disk=$(vm_disk "$vm")
  warn "THIS UNDOES A STIG CONTROL."
  say  "  STIG requires sudo to authenticate; restoring NOPASSWD removes that requirement and"
  say  "  will show as a finding. Use it to regain access, then set a password and remove it"
  say  "  again. It is here because being locked out of a machine is also not a security"
  say  "  posture - but it is a deliberate, documented deviation, not a default."
  printf '  type EXACTLY "i accept the finding" to continue: '
  local c; read -r c
  [ "$c" = "i accept the finding" ] || die "not confirmed - nothing changed"

  ensure_off "$vm"
  virt-customize -a "$disk" \
    --write "/etc/sudoers.d/99-rescue-nopasswd:$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" \
    --run-command "chmod 0440 /etc/sudoers.d/99-rescue-nopasswd" \
    || die "virt-customize failed. VM is shut off; start it with: virsh start $vm"
  ok "wrote /etc/sudoers.d/99-rescue-nopasswd"
  virsh start "$vm" >/dev/null || die "start failed: virsh start $vm"
  ok "$vm started"
  say ""
  warn "REMOVE THIS once you have set a password:"
  say  "     sudo rm /etc/sudoers.d/99-rescue-nopasswd"
}

cmd_console() {
  local vm="${1:?usage: sudo $0 console <vm>}"

  # CHECK FOR A PTY FIRST. Until 2026-09-11 every VM here was composed with a FILE-backed
  # serial and no pty, so this subcommand died with libvirt's
  #     error: internal error: character device serial0 is not using a PTY
  # which tells the operator nothing about what to do instead. Worse, the runbook advertised
  # this as THE recovery route for a VM that will not boot - so the message matters at exactly
  # the moment someone is in trouble. runbook 6.3j.
  if ! virsh dumpxml "$vm" 2>/dev/null | grep -q "<serial type='pty'>"; then
    warn "$vm HAS NO INTERACTIVE CONSOLE."
    say  "   Its serial device is file-backed, so there is output but nowhere to type."
    say  "   virsh console would fail with: character device serial0 is not using a PTY"
    say  ""
    say  "   READ the boot output (no input possible):"
    say  "     sudo tail -f /var/lib/libvirt/images/console/$vm-console.log"
    say  ""
    say  "   RECOVER by editing the disk offline - this DOES work and is what was used for the"
    say  "   STIG lockout (runbook 6.3a):"
    say  "     sudo $0 password $vm"
    say  "     sudo $0 nopasswd $vm"
    say  ""
    say  "   FIX IT PERMANENTLY - needs the guest shut down, then reboot it:"
    say  "     sudo virsh shutdown $vm"
    say  "     sudo virsh edit $vm     # <serial type='file'> -> type='pty', keep a <log> child"
    say  "     sudo virsh start $vm"
    say  "   New VMs get this right: 03-compose-vm.sh now asks for"
    say  "     --serial pty,log.file=...,log.append=on"
    return 1
  fi

  say "attaching to $vm - escape is Ctrl-]"
  say "if nothing appears, press Enter; the console only shows output since you attached."
  say "history is in /var/lib/libvirt/images/console/$vm-console.log"
  exec virsh console "$vm"
}

# ---------------------------------------------------------------------------- fix-console
#
# Retrofit a VM composed before 2026-09-11 so it has a real interactive console.
#
# Transforms the PERSISTENT config (dumpxml --inactive, not the live one) so the change
# applies at the guest's next restart. `virsh define` on a running domain updates the stored
# XML and leaves the running instance alone - so this can be done now and take effect with
# whatever reboot is already planned, instead of forcing downtime on the DHCP/PXE machine.
#
# XML surgery in python rather than sed: the elements have children and the edit has to remove
# <source> while adding <log>. A regex that gets this subtly wrong produces a domain that will
# not define, on the tool you reach for when a VM is already broken.
cmd_fix_console() {
  local vm="${1:?usage: sudo $0 fix-console <vm>}"
  need_root
  command -v python3 >/dev/null 2>&1 || die "python3 is needed for the XML edit"

  if virsh dumpxml --inactive "$vm" 2>/dev/null | grep -q "<serial type='pty'>"; then
    ok "$vm already has a pty serial - nothing to do"
    return 0
  fi

  local log="/var/lib/libvirt/images/console/$vm-console.log"
  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  virsh dumpxml --inactive "$vm" > "$tmp" 2>/dev/null || die "cannot dump $vm - does it exist?"

  python3 - "$tmp" "$log" <<'PYEOF' || die "XML transform failed - $vm NOT changed"
import sys, xml.etree.ElementTree as ET
path, logfile = sys.argv[1], sys.argv[2]
tree = ET.parse(path); root = tree.getroot()
dev = root.find('devices')
changed = 0
for tag in ('serial', 'console'):
    for el in dev.findall(tag):
        if el.get('type') != 'file':
            continue
        el.set('type', 'pty')
        for src in el.findall('source'):
            el.remove(src)
        for old in el.findall('log'):
            el.remove(old)
        lg = ET.SubElement(el, 'log')
        lg.set('file', logfile); lg.set('append', 'on')
        for al in el.findall('alias'):   # libvirt assigns aliases itself
            el.remove(al)
        changed += 1
if changed == 0:
    sys.exit(1)
tree.write(path)
PYEOF

  virsh define "$tmp" >/dev/null || die "virsh define rejected the edited XML - $vm unchanged"
  ok "$vm persistent config updated: serial + console are now pty, logging to $log"
  say ""
  warn "THE DOMAIN MUST BE STOPPED AND STARTED - a reboot INSIDE the guest is NOT enough."
  say  "   \`virsh define\` updated the persistent config, but a guest-initiated reboot keeps the"
  say  "   same qemu process, so the device list is unchanged. libvirt only rebuilds the process"
  say  "   on a full stop/start. Verified the hard way on svc-repo-01, 2026-09-11."
  say  ""
  say  "   sudo virsh shutdown $vm      # wait for it to be shut off"
  say  "   sudo virsh start $vm"
  say  "   then prove it:  sudo $0 console $vm"
}

case "${1:-}" in
  status)   shift; cmd_status "$@" ;;
  fix-console) shift; cmd_fix_console "$@" ;;
  password) shift; cmd_password "$@" ;;
  nopasswd) shift; cmd_nopasswd "$@" ;;
  console)  shift; cmd_console "$@" ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
