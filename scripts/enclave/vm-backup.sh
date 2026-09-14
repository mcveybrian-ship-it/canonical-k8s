#!/usr/bin/env bash
# =========================================================================================
# vm-backup.sh - back up the enclave's guest VMs to a destination YOU name.
#
#     MACHINE: the hypervisor (host-4 today). It refuses to run anywhere else.
#
#     sudo ./vm-backup.sh status                 what would happen, changes nothing
#     sudo ./vm-backup.sh full  [vm|all]         full backup, starts a new chain
#     sudo ./vm-backup.sh incr  [vm|all]         incremental since the last checkpoint
#     sudo ./vm-backup.sh verify                 check what ARRIVED, not what was sent
#     sudo ./vm-backup.sh prune                  drop chains beyond BACKUP_KEEP_CHAINS
#     sudo ./vm-backup.sh restore-plan <vm>      print the restore steps - never automatic
#     sudo ./vm-backup.sh schedule [--at HH:MM]  install a nightly systemd timer (default 02:00)
#     sudo ./vm-backup.sh unschedule             remove it
#
#     --dest <path>            override BACKUP_DEST for this run
#     --accept-unencrypted     proceed when the destination is not on an encrypted device
#     --allow-non-mount        proceed when the destination is not a mountpoint (DANGEROUS)
#
# WHY A DESTINATION IS A PARAMETER AND NOT A PATH IN A SCRIPT: it is an external drive on the
# bench and a customer-provided mount, LUN or NFS export in production. Same procedure, one
# different value. It comes from --dest, then VM_BACKUP_DEST, then BACKUP_DEST in
# vm-specs.env - in that order.
#
# THREE THINGS THIS REFUSES TO DO, AND WHY EACH ONE IS HERE:
#
#   1. Write to a path that is not a mountpoint. An unmounted mountpoint is a normal empty
#      directory on the root disk. The backup runs, reports success, and fills the system
#      disk instead of the drive. Nothing distinguishes it from a good run until the machine
#      falls over. --allow-non-mount exists for a deliberate test, not for a bad night.
#
#   2. Write enclave data to an unencrypted destination without being told to. Q19 is
#      answered: data at rest must be encrypted at IL5. A backup of these VMs contains
#      everything the VMs contain - the issuing CA key among it. If the customer's storage
#      encrypts below the filesystem, pass --accept-unencrypted and say so in the artefact.
#
#   3. Start without enough room. It compares free space against the ACTUAL allocated size
#      of the disks being copied, not the nominal qcow2 ceiling, and says both numbers.
#
# ON HOST-4, USB STORAGE IS BLOCKED BY THE STIG. /etc/modprobe.d/99-stig-usb-storage.conf
# is deliberate (kernel_module_usb-storage_disabled, runbook 6.3g). Plugging in a USB drive
# does nothing until you open that window with `stig-tailor.sh usb enable --minutes <N>`, and you close
# it afterwards. This script detects the situation and says so rather than reporting an
# empty destination. A drive on eSATA, SAS or iSCSI is unaffected.
#
# WHAT THIS IS AND IS NOT. Image-level backup answers "the VM is gone". It does not answer
# "the database inside it is corrupt" - for that, back up the application from inside the
# guest. The three machines holding state nothing can regenerate are svc-mgmt-01 (issuing CA
# key, MAAS database), svc-harbor-01 (pushed images) and svc-obs-01 (Grafana database,
# Prometheus history). Everything else in this enclave is rebuildable from the repo, and a
# rebuild is better evidence than a restore.
# =========================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
[ -f "$HERE/vm-specs.env" ] && . "$HERE/vm-specs.env"

DEST="${VM_BACKUP_DEST:-${BACKUP_DEST:-}}"
KEEP="${BACKUP_KEEP_CHAINS:-2}"
ACCEPT_PLAIN=0
ALLOW_NONMOUNT=0
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# WHO QEMU RUNS AS. The backup target is opened by the QEMU process, NOT by this script,
# and on Ubuntu that process is libvirt-qemu:kvm rather than root. The first version created
# the destination 0700 root:root and QEMU could not even enter the directory:
#     unable to execute QEMU command 'blockdev-add': Could not open '...': Permission denied
# Read it from libvirt's config rather than assuming, because a site that changed it would
# hit the same wall with no clue why.
qemu_user()  { awk -F'"' '/^[[:space:]]*user[[:space:]]*=/{print $2}'  /etc/libvirt/qemu.conf 2>/dev/null | tail -1; }
qemu_group() { awk -F'"' '/^[[:space:]]*group[[:space:]]*=/{print $2}' /etc/libvirt/qemu.conf 2>/dev/null | tail -1; }
QUSER="$(qemu_user)";  QUSER="${QUSER:-libvirt-qemu}"
QGROUP="$(qemu_group)"; QGROUP="${QGROUP:-kvm}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# ---------------------------------------------------------------- where am I
# THE ASSERTION LIVES IN THE SCRIPT, NOT IN A COMMENT ABOVE A PASTED BLOCK. A label cannot
# refuse anything; this can, and it cannot be pasted somewhere else and lose its guard.
assert_hypervisor() {
  command -v virsh >/dev/null 2>&1 \
    || die "virsh is not installed - this is not the hypervisor. Run it on host-4."
  virsh list --all --name >/dev/null 2>&1 \
    || die "cannot talk to libvirt. Is libvirtd running, and are you root?"
}

domains() {  # every defined domain, one per line
  virsh list --all --name 2>/dev/null | sed '/^$/d'
}

# Disks worth copying: file/block backed, device=disk. CDROMs and readonly devices are not
# state and copying them wastes the whole window.
domain_disks() {  # <domain> -> "target<TAB>source"
  virsh domblklist "$1" --details 2>/dev/null \
    | awk 'NR>2 && $2=="disk" && $4 != "-" {print $3"\t"$4}'
}

alloc_bytes() {  # actual bytes on disk for a domain's disks, not the qcow2 ceiling
  local d t s total=0 n
  while IFS=$'\t' read -r t s; do
    [ -n "${s:-}" ] || continue
    # PLAIN `du -sB1` - ALLOCATED blocks, which is what a qcow2 actually occupies.
    # The first version wrote `du -B1 --apparent-size=0`, and --apparent-size takes NO
    # value, so du rejected the argument, 2>/dev/null swallowed the error, and every
    # domain reported 0 bytes. The status page then said "one full backup fits" on the
    # strength of a total of zero - a false pass produced by a hidden error.
    n="$(du -sB1 "$s" 2>/dev/null | cut -f1)"
    case "${n:-}" in ""|*[!0-9]*) n=0 ;; esac
    total=$((total + ${n:-0}))
  done < <(domain_disks "$1")
  printf '%s\n' "$total"
}

human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%s\n' "${1:-0}"; }

# ---------------------------------------------------------------- destination checks
check_dest() {
  [ -n "$DEST" ] || die "no destination. Set BACKUP_DEST in vm-specs.env, or pass --dest."

  if [ ! -d "$DEST" ]; then
    warn "$DEST does not exist."
    if [ -e /etc/modprobe.d/99-stig-usb-storage.conf ] && ! lsmod | grep -q '^usb_storage'; then
      warn "  USB STORAGE IS BLOCKED ON THIS MACHINE by the STIG, deliberately:"
      say  "    /etc/modprobe.d/99-stig-usb-storage.conf  (runbook 6.3g)"
      say  "  A USB drive plugged in now will not appear. To use one:"
      say  "    sudo $HERE/stig-tailor.sh usb enable --minutes 60     # opens the window"
      say  "    ... mount it, run the backup, unmount ..."
      say  "    sudo $HERE/stig-tailor.sh usb disable     # closes it again"
      say  "  A drive on eSATA, SAS or iSCSI is not affected by this."
    fi
    die "create or mount $DEST first"
  fi

  # 1. MOUNTPOINT. The single most dangerous failure this script can have.
  if ! mountpoint -q "$DEST"; then
    if [ "$ALLOW_NONMOUNT" -eq 1 ]; then
      warn "$DEST is NOT a mountpoint - proceeding because --allow-non-mount was given."
      warn "  This writes to whatever filesystem holds that path. Usually the root disk."
    else
      warn "$DEST is NOT a mountpoint."
      say  "  An unmounted mountpoint is an ordinary empty directory on the root disk. The"
      say  "  backup would run, report success, and fill the system disk instead of the"
      say  "  drive - and nothing would look wrong until the machine fell over."
      say  "  Mount the destination, or pass --allow-non-mount if you mean it."
      die  "refusing to write to a non-mountpoint"
    fi
  fi

  # 2. ENCRYPTION. Say what was actually checked, so the answer can be disagreed with.
  local src fstype enc="no"
  src="$(findmnt -no SOURCE --target "$DEST" 2>/dev/null || true)"
  fstype="$(findmnt -no FSTYPE --target "$DEST" 2>/dev/null || true)"
  if [ -n "$src" ]; then
    # A dm-crypt device, or one stacked on top of it.
    if lsblk -no TYPE "$src" 2>/dev/null | grep -q crypt; then enc="yes"
    elif lsblk -ns -o TYPE "$src" 2>/dev/null | grep -q crypt; then enc="yes"; fi
  fi
  if [ "$enc" != yes ]; then
    if [ "$ACCEPT_PLAIN" -eq 1 ]; then
      warn "destination is NOT on an encrypted device - proceeding (--accept-unencrypted)."
      warn "  Record that in the artefact: these images contain everything the VMs contain,"
      warn "  including svc-mgmt-01's issuing CA private key."
    else
      warn "destination does not appear to be on an encrypted device."
      say  "    device: ${src:-unknown}   filesystem: ${fstype:-unknown}"
      say  "  Q19 is answered: data at rest is encrypted at IL5, and a backup of these VMs"
      say  "  contains everything they contain - svc-mgmt-01's issuing CA key included."
      say  "  Either put LUKS under it, or pass --accept-unencrypted if the customer's"
      say  "  storage encrypts below the filesystem, and say so in the artefact."
      die  "refusing to write enclave images to an unencrypted destination"
    fi
  else
    ok "destination is on an encrypted device (${src})"
  fi

  [ -w "$DEST" ] || die "$DEST is not writable by $(id -un)"
}

# ---------------------------------------------------------------- status
cmd_status() {
  assert_hypervisor
  printf '\n  VM backup on %s\n\n' "$(hostname -s)"
  say "destination : ${DEST:-<unset>}"
  if [ -n "$DEST" ] && [ -d "$DEST" ]; then
    if mountpoint -q "$DEST"; then
      ok "  is a mountpoint: $(findmnt -no SOURCE,FSTYPE,SIZE,AVAIL --target "$DEST" 2>/dev/null | tr -s ' ')"
    else
      warn "  NOT a mountpoint - a backup here would land on the root disk"
    fi
  else
    warn "  does not exist yet"
  fi
  say "keep chains : $KEEP"
  printf '\n  %-16s %-8s %10s  %s\n' DOMAIN STATE "ON DISK" DISKS
  local d st sz
  for d in $(domains); do
    st="$(virsh domstate "$d" 2>/dev/null | head -1)"
    sz="$(alloc_bytes "$d")"
    printf '  %-16s %-8s %10s  %s\n' "$d" "$st" "$(human "$sz")" \
      "$(domain_disks "$d" | cut -f1 | tr '\n' ' ')"
  done
  printf '\n'
  local tot=0
  for d in $(domains); do tot=$((tot + $(alloc_bytes "$d"))); done
  say "total allocated across all domains: $(human "$tot")"
  if [ -n "$DEST" ] && mountpoint -q "$DEST" 2>/dev/null; then
    local avail; avail="$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')"
    say "free at destination              : $(human "$avail")"
    # A TOTAL OF ZERO WITH DISKS PRESENT IS A MEASUREMENT FAILURE, NOT A TINY ENCLAVE.
    # Saying "it fits" on the back of a number that is obviously wrong is worse than
    # saying nothing, because it is the answer the operator was looking for.
    if [ "$tot" -eq 0 ]; then
      warn "CANNOT SIZE THIS - every domain measured 0 bytes, which cannot be right."
      say  "     Check that the disk paths resolve and are readable:"
      say  "       virsh domblklist <domain> --details"
    elif [ "$avail" -ge "$tot" ]; then
      ok "one full backup fits"
    else
      warn "one full backup DOES NOT fit"
    fi
  fi
  printf '\n  existing checkpoints (what an incremental would build on):\n'
  for d in $(domains); do
    local cps; cps="$(virsh checkpoint-list "$d" --name 2>/dev/null | sed '/^$/d' | tr '\n' ' ')"
    printf '     %-16s %s\n' "$d" "${cps:-none - next run must be a full}"
  done
  printf '\n'
}

# ---------------------------------------------------------------- backup
backup_one() {  # <domain> <full|incr>
  local dom="$1" mode="$2"
  local out="$DEST/$dom/$STAMP"
  local prev="" bxml cxml rc=0
  # Owned by the QEMU user, because QEMU is what opens the files here. 0700 on that user
  # keeps them unreadable to everyone else, which is the point on a volume holding an image
  # of the machine that stores the issuing CA key.
  install -d -m 0755 -o "$QUSER" -g "$QGROUP" "$DEST/$dom" 2>/dev/null || install -d "$DEST/$dom"
  install -d -m 0700 -o "$QUSER" -g "$QGROUP" "$out" 2>/dev/null || install -d -m 0700 "$out"
  if ! sudo -u "$QUSER" test -w "$out" 2>/dev/null; then
    warn "$dom: $QUSER cannot write $out - QEMU will fail to open its target"
    warn "  check ownership above, and whether AppArmor confines libvirt to known paths"
  fi

  if [ "$mode" = incr ]; then
    prev="$(virsh checkpoint-list "$dom" --name 2>/dev/null | sed '/^$/d' | tail -1)"
    [ -n "$prev" ] || { warn "$dom: no checkpoint to build on - doing a FULL instead"; mode=full; }
  fi

  bxml="$(mktemp)"; cxml="$(mktemp)"
  {
    printf '<domainbackup mode="push">\n'
    [ "$mode" = incr ] && printf '  <incremental>%s</incremental>\n' "$prev"
    printf '  <disks>\n'
    local t s
    while IFS=$'\t' read -r t s; do
      [ -n "${t:-}" ] || continue
      printf '    <disk name="%s" backup="yes" type="file">\n' "$t"
      printf '      <target file="%s/%s.%s.qcow2"/>\n' "$out" "$t" "$mode"
      printf '      <driver type="qcow2"/>\n'
      printf '    </disk>\n'
    done < <(domain_disks "$dom")
    printf '  </disks>\n</domainbackup>\n'
  } > "$bxml"
  printf '<domaincheckpoint><name>chk-%s</name></domaincheckpoint>\n' "$STAMP" > "$cxml"

  say "$dom: $mode backup -> $out"
  [ -n "$prev" ] && say "   building on checkpoint $prev"
  if ! virsh backup-begin "$dom" "$bxml" "$cxml" >/dev/null 2>&1; then
    warn "$dom: backup-begin failed. libvirt said:"
    virsh backup-begin "$dom" "$bxml" "$cxml" 2>&1 | sed 's/^/       /' || true
    rm -f "$bxml" "$cxml"
    return 1
  fi
  rm -f "$bxml" "$cxml"

  # WAIT, AND SAY SO. backup-begin returns immediately; without this the script would report
  # success while qemu is still copying, and prune could then delete a chain still in use.
  local waited=0
  while virsh domjobinfo "$dom" 2>/dev/null | grep -qi '^Job type:.*\(Unbounded\|Bounded\)'; do
    sleep 5; waited=$((waited + 5))
    [ $((waited % 60)) -eq 0 ] && say "   ... $((waited / 60))m elapsed"
  done
  local res; res="$(virsh domjobinfo "$dom" --completed 2>/dev/null | awk -F': *' '/Job type/{print $2}')"
  say "   finished after ${waited}s (job: ${res:-unknown})"

  # Manifest of what ARRIVED. Sizes and hashes of the files on the destination, not of the
  # sources - a copy that silently truncated looks identical from the source side.
  ( cd "$out" && sha256sum ./*.qcow2 > MANIFEST.sha256 2>/dev/null ) || true
  printf 'domain=%s\nmode=%s\nbased_on=%s\nstamp=%s\nhost=%s\n' \
    "$dom" "$mode" "${prev:-none}" "$STAMP" "$(hostname -s)" > "$out/INFO"
  ok "$dom: $(find "$out" -name '*.qcow2' | wc -l) file(s), $(du -sh "$out" | cut -f1)"
  return $rc
}

cmd_backup() {  # <full|incr> [domain|all]
  need_root; assert_hypervisor; check_dest
  local mode="$1" target="${2:-all}" rc=0 list
  if [ "$target" = all ]; then list="$(domains)"; else
    virsh dominfo "$target" >/dev/null 2>&1 || die "no such domain: $target"
    list="$target"
  fi
  local need=0 d
  for d in $list; do need=$((need + $(alloc_bytes "$d"))); done
  local avail; avail="$(df -B1 --output=avail "$DEST" | tail -1 | tr -d ' ')"
  say "need up to $(human "$need"), $(human "$avail") free at $DEST"
  [ "$avail" -ge "$need" ] || die "not enough room for a $mode of: $(printf '%s ' $list)"
  for d in $list; do backup_one "$d" "$mode" || rc=1; done
  printf '\n'
  [ "$rc" -eq 0 ] && ok "all backups completed" || warn "one or more backups FAILED - see above"
  return $rc
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  need_root; check_dest
  local bad=0 n=0 dir
  while IFS= read -r dir; do
    [ -f "$dir/INFO" ] || continue
    n=$((n + 1))
    local f
    for f in "$dir"/*.qcow2; do
      [ -e "$f" ] || continue
      if qemu-img check -q "$f" >/dev/null 2>&1; then :; else
        warn "CORRUPT or unreadable: $f"; bad=1
      fi
    done
    if [ -f "$dir/MANIFEST.sha256" ]; then
      ( cd "$dir" && sha256sum -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1 \
        || { warn "checksum mismatch in $dir"; bad=1; }
    else
      warn "no MANIFEST.sha256 in $dir"; bad=1
    fi
  done < <(find "$DEST" -mindepth 2 -maxdepth 2 -type d | sort)
  printf '\n'
  # SAY THE COUNT. "all backups verified" reads the same whether it checked forty or zero.
  [ "$bad" -eq 0 ] && ok "verified $n backup set(s) - images readable, checksums match" \
                   || warn "verified $n set(s), PROBLEMS FOUND - see above"
  return "$bad"
}

# ---------------------------------------------------------------- prune
cmd_prune() {
  need_root; check_dest
  local dom chains drop d
  for dom in "$DEST"/*/; do
    [ -d "$dom" ] || continue
    chains="$(find "$dom" -mindepth 1 -maxdepth 1 -type d | sort)"
    local total; total="$(printf '%s\n' "$chains" | sed '/^$/d' | wc -l)"
    [ "$total" -gt "$KEEP" ] || { say "$(basename "$dom"): $total set(s), keeping all"; continue; }
    drop="$(printf '%s\n' "$chains" | head -n $((total - KEEP)))"
    for d in $drop; do
      say "$(basename "$dom"): removing $(basename "$d") ($(du -sh "$d" | cut -f1))"
      rm -rf -- "$d"
    done
  done
  ok "prune complete - kept $KEEP set(s) per domain"
}

# ---------------------------------------------------------------- schedule
# NIGHTLY BACKUPS ON A MACHINE THAT DELIBERATELY BLOCKS USB STORAGE.
#
# The STIG blocks usb-storage on host-4 (kernel_module_usb-storage_disabled, runbook 6.3g).
# A drive that is mounted right now keeps working because the module is already loaded - but
# it will NOT come back after a reboot, and a timer would then fail every night without
# anyone noticing. So the unit checks the destination before it does anything and FAILS
# LOUDLY rather than skipping, because a backup that quietly stops running is worse than one
# that was never scheduled.
#
# If the destination is a USB drive, either keep the deviation window open and documented,
# or move the destination to storage that survives a reboot. `status` says which you have.
SVC_NAME="enclave-vm-backup"

cmd_schedule() {
  need_root; assert_hypervisor
  local at="${1:-02:00}"
  case "$at" in [0-2][0-9]:[0-5][0-9]) : ;; *) die "--at wants HH:MM, got '$at'" ;; esac
  [ -n "$DEST" ] || die "no destination set - fix BACKUP_DEST in vm-specs.env first"
  local self; self="$(readlink -f "$0")"

  cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=Enclave VM backup (libvirt incremental) to ${DEST}
After=libvirtd.service
Wants=libvirtd.service
# If the destination is not mounted, systemd fails the unit instead of running a backup
# into an empty directory on the root disk.
RequiresMountsFor=${DEST}

[Service]
Type=oneshot
# Nice and idle I/O so a 300 GB copy does not starve the guests it is copying.
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=6h
ExecStart=${self} incr
ExecStart=${self} verify
ExecStart=${self} prune
EOF

  cat > "/etc/systemd/system/${SVC_NAME}.timer" <<EOF
[Unit]
Description=Nightly enclave VM backup at ${at}

[Timer]
OnCalendar=*-*-* ${at}:00
# Persistent so a missed run (machine off, drive absent) happens at the next opportunity
# rather than being skipped in silence.
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SVC_NAME}.timer" >/dev/null 2>&1 \
    || die "could not enable ${SVC_NAME}.timer"
  ok "scheduled: ${SVC_NAME}.timer at ${at} daily -> ${DEST}"
  systemctl list-timers "${SVC_NAME}.timer" --no-pager | sed 's/^/       /'
  printf '\n'
  say "each run does: incr (falls back to full with no checkpoint), verify, prune"
  say "watch it with:   journalctl -u ${SVC_NAME}.service -n 50"

  # SAY THE REBOOT PROBLEM OUT LOUD, EVERY TIME, IF IT APPLIES.
  local src; src="$(findmnt -no SOURCE --target "$DEST" 2>/dev/null)"
  local disk; disk="$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)"
  if [ -n "$disk" ] && [ "$(lsblk -no TRAN "/dev/$disk" 2>/dev/null | head -1)" = usb ]; then
    printf '\n'
    warn "THE DESTINATION IS A USB DRIVE, AND THIS MACHINE BLOCKS USB STORAGE."
    warn "  It works now only because the module is already loaded. After a reboot the"
    warn "  drive will NOT reappear and every run will fail until someone opens the"
    warn "  window again with:  stig-tailor.sh usb enable"
    warn "  Either keep that deviation open and documented, or move ${DEST} to storage"
    warn "  that survives a reboot. The unit fails loudly either way - it will not"
    warn "  quietly write to the root disk."
  fi
}

cmd_unschedule() {
  need_root
  systemctl disable --now "${SVC_NAME}.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SVC_NAME}.timer" "/etc/systemd/system/${SVC_NAME}.service"
  systemctl daemon-reload
  ok "removed ${SVC_NAME}.timer and .service"
}

# ---------------------------------------------------------------- restore
# DELIBERATELY NOT AUTOMATIC. Restoring overwrites a running system's disk. It is rare, it is
# done under pressure, and it is exactly where an unattended script does the most damage.
cmd_restore_plan() {
  local dom="${1:-}"; [ -n "$dom" ] || die "usage: $0 restore-plan <domain>"
  check_dest
  local sets; sets="$(find "$DEST/$dom" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)"
  [ -n "$sets" ] || die "no backups for $dom at $DEST"
  printf '\n  RESTORE PLAN for %s - read it, then run the steps by hand\n\n' "$dom"
  say "available sets, oldest first:"
  local s
  for s in $sets; do
    printf '     %-24s %s  %s\n' "$(basename "$s")" \
      "$(awk -F= '/^mode=/{print $2}' "$s/INFO" 2>/dev/null)" \
      "$(du -sh "$s" | cut -f1)"
  done
  cat <<PLAN

  1. STOP THE DOMAIN. A restore over a running disk corrupts both.
         virsh shutdown $dom      # then wait for it to be 'shut off'
         virsh domstate $dom

  2. KEEP THE CURRENT DISK. Rename, do not delete - if the restore is wrong you want
     the option to go back, and 'I deleted it first' has no undo.
         mv /var/lib/libvirt/images/$dom.qcow2 /var/lib/libvirt/images/$dom.qcow2.pre-restore

  3. COPY THE FULL, then apply incrementals in order if you are restoring a chain.
     Each set's INFO file names the checkpoint it was based on.

  4. CHECK THE IMAGE BEFORE BOOTING IT.
         qemu-img check /var/lib/libvirt/images/$dom.qcow2

  5. START, and verify the SERVICE, not just the boot.
         virsh start $dom

  NOTE ON CHECKPOINTS: restoring an old image while libvirt still holds newer checkpoints
  leaves the two disagreeing about what has changed. Clear them after a restore:
         virsh checkpoint-list $dom --name | xargs -r -n1 virsh checkpoint-delete $dom --metadata

PLAN
}

# ---------------------------------------------------------------- args
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2:-}"; shift 2 ;;
    --accept-unencrypted) ACCEPT_PLAIN=1; shift ;;
    --allow-non-mount) ALLOW_NONMOUNT=1; shift ;;
    --at) ARGS+=("${2:-}"); shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"

case "${1:-status}" in
  status)       cmd_status ;;
  full)         shift || true; cmd_backup full "${1:-all}" ;;
  incr)         shift || true; cmd_backup incr "${1:-all}" ;;
  verify)       cmd_verify ;;
  prune)        cmd_prune ;;
  schedule)     shift || true; cmd_schedule "${1:-02:00}" ;;
  unschedule)   cmd_unschedule ;;
  restore-plan) shift || true; cmd_restore_plan "${1:-}" ;;
  *) printf 'usage: %s {status|full [vm]|incr [vm]|verify|prune|schedule [HH:MM]|unschedule|restore-plan <vm>}\n' "$0" >&2; exit 2 ;;
esac
