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
    n="$(du -B1 --apparent-size=0 -s "$s" 2>/dev/null | cut -f1)" || n=0
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
    [ "$avail" -ge "$tot" ] && ok "one full backup fits" || warn "one full backup DOES NOT fit"
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
  install -d -m 0700 "$out"

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
  restore-plan) shift || true; cmd_restore_plan "${1:-}" ;;
  *) printf 'usage: %s {status|full [vm]|incr [vm]|verify|prune|restore-plan <vm>}\n' "$0" >&2; exit 2 ;;
esac
