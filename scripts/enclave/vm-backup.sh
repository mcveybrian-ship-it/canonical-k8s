#!/usr/bin/env bash
# =========================================================================================
# vm-backup.sh - back up the enclave's guest VMs to a destination YOU name.
#
#     MACHINE: the hypervisor (host-4 today). It refuses to run anywhere else.
#
#     sudo ./vm-backup.sh status                 what would happen, changes nothing
#     sudo ./vm-backup.sh full  [vm|all]         full backup, starts a new chain
#     sudo ./vm-backup.sh incr  [vm|all]         incremental since the last checkpoint
#     sudo ./vm-backup.sh progress               how far along a running backup is
#     sudo ./vm-backup.sh verify                 check what ARRIVED, not what was sent
#     sudo ./vm-backup.sh prune                  drop chains beyond BACKUP_KEEP_CHAINS
#     sudo ./vm-backup.sh restore-plan <vm>      print the restore steps - never automatic
#     sudo ./vm-backup.sh restore-test <vm>      REHEARSE one: rebuild the chain into its own
#                                                directory, boot it as restore-test-<vm> with
#                                                no NIC, prove it, remove it. Touches nothing live
#     sudo ./vm-backup.sh schedule [--at HH:MM]  install a nightly systemd timer (default 02:00)
#     sudo ./vm-backup.sh unschedule             remove it
#     sudo ./vm-backup.sh keyfile                add a keyfile so unlocking needs no human
#     sudo ./vm-backup.sh reattach               after a reboot: unlock, mount, re-block USB
#
#     --dest <path>            override BACKUP_DEST for this run
#     --accept-unencrypted     proceed when the destination is not on an encrypted device
#     --allow-non-mount        proceed when the destination is not a mountpoint (DANGEROUS)
#     --detach                 run under systemd-run instead of this shell, and return
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
LUKS_UUID="${BACKUP_LUKS_UUID:-}"
LUKS_NAME="${BACKUP_LUKS_NAME:-vmbackup}"
KEYFILE="${BACKUP_KEYFILE:-/etc/enclave/vmbackup.key}"
ACCEPT_PLAIN=0
ALLOW_NONMOUNT=0
DETACH=0
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# WHO QEMU RUNS AS. The backup target is opened by the QEMU process, NOT by this script,
# and on Ubuntu that process is libvirt-qemu:kvm rather than root. The first version created
# the destination 0700 root:root and QEMU could not even enter the directory:
#     unable to execute QEMU command 'blockdev-add': Could not open '...': Permission denied
# Read it from libvirt's config rather than assuming, because a site that changed it would
# hit the same wall with no clue why.
qemu_user()  { awk -F'"' '/^[[:space:]]*user[[:space:]]*=/{print $2}'  /etc/libvirt/qemu.conf 2>/dev/null | tail -1; }
qemu_group() { awk -F'"' '/^[[:space:]]*group[[:space:]]*=/{print $2}' /etc/libvirt/qemu.conf 2>/dev/null | tail -1; }
# `|| true` IS LOAD-BEARING, AND WITHOUT IT NO UNPRIVILEGED COMMAND IN THIS SCRIPT WORKED.
#
# /etc/libvirt/qemu.conf is -rw------- root:root. For any other user awk exits 2. The 2>/dev/null
# above hides the message but not the status, and `set -o pipefail` propagates awk's 2 through
# the pipe instead of tail's 0 - so the ASSIGNMENT fails, `set -e` kills the script during
# initialisation, and the ${...:-default} on the same line never runs.
#
# Effect, measured 2026-09-16: `vm-backup.sh progress` exited 2 with NO OUTPUT AT ALL for a
# non-root user, so `watch` showed a blank screen while a backup was running perfectly. The
# whole point of `progress` is to be readable from another shell without privilege, and it had
# never once worked that way.
#
# The defaults are correct for this enclave and always were; they just needed to be reachable.
QUSER="$(qemu_user || true)";  QUSER="${QUSER:-libvirt-qemu}"
QGROUP="$(qemu_group || true)"; QGROUP="${QGROUP:-kvm}"

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
# ONLY DISKS THAT CAN CARRY A PERSISTENT DIRTY BITMAP - which means qcow2, and only qcow2.
#
# This cost the first scheduled run, 2026-09-15. Every guest here has vdb = its cloud-init
# seed ISO, format raw. A RAW FILE CANNOT STORE A PERSISTENT BITMAP: qemu keeps it in memory
# and it dies with the process. So the checkpoint libvirt wrote referenced a bitmap that no
# longer existed, and every incremental failed with
#
#     error: checkpoint inconsistent: missing or broken bitmap 'chk-...' for disk 'vdb'
#
# The first incremental after any VM restart was always going to fail. Nothing was damaged.
#
# The seed ISO should never have been in the set anyway: it is read-only, a few hundred KB,
# regenerated by 03-compose-vm.sh, and it CONTAINS THE PASSWORD HASH AND SSH KEYS - which is
# why it is gitignored. Copying it to the backup volume spread a credential for no benefit.
#
# Parsed from the XML rather than domblklist, because the format lives in <driver type=> and
# domblklist does not print it.
domain_disks() {  # <domain> -> "target<TAB>source", backup-capable disks only
  virsh dumpxml "$1" 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
except Exception:
    sys.exit(0)
for d in root.findall("./devices/disk"):
    if d.get("device") != "disk":
        continue
    drv, tgt, src = d.find("driver"), d.find("target"), d.find("source")
    if tgt is None or src is None:
        continue
    path = src.get("file") or src.get("dev") or src.get("name")
    fmt = drv.get("type") if drv is not None else None
    if not path or fmt != "qcow2":
        continue
    print("%s\t%s" % (tgt.get("dev"), path))
'
}

# What was left out, and why. SAY IT - a disk silently dropped from a backup is the kind of
# thing discovered during a restore.
domain_skipped_disks() {  # <domain> -> "target<TAB>format<TAB>source"
  virsh dumpxml "$1" 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
except Exception:
    sys.exit(0)
for d in root.findall("./devices/disk"):
    drv, tgt, src = d.find("driver"), d.find("target"), d.find("source")
    if tgt is None or src is None:
        continue
    path = src.get("file") or src.get("dev") or src.get("name")
    fmt = drv.get("type") if drv is not None else "?"
    if not path:
        continue
    if d.get("device") == "disk" and fmt == "qcow2":
        continue
    print("%s\t%s\t%s" % (tgt.get("dev"), fmt, path))
'
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

  # A DOMAIN WITH NOTHING BACKUP-CAPABLE MUST NOT PRODUCE AN EMPTY, SUCCESSFUL-LOOKING SET.
  if [ -z "$(domain_disks "$dom")" ]; then
    warn "$dom: no qcow2 disks - nothing here can be backed up incrementally. SKIPPED."
    domain_skipped_disks "$dom" | while IFS=$'\t' read -r t f p; do
      say "     excluded: $t ($f) $p"
    done
    return 1
  fi
  domain_skipped_disks "$dom" | while IFS=$'\t' read -r t f p; do
    say "   not backed up: $t format=$f  $p"
  done

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
  # CAPTURE THE OUTPUT ONCE. The first version ran backup-begin, and when that failed ran it
  # AGAIN purely to show the error - so a failure became two attempts against the same
  # domain. On 2026-09-14 the second collided with the first and reported "cannot acquire
  # state change lock", which described the script's own retry rather than the real problem.
  # A diagnostic must not change what it is diagnosing.
  local bout
  if ! bout="$(virsh backup-begin "$dom" "$bxml" "$cxml" 2>&1)"; then
    warn "$dom: backup-begin failed. libvirt said:"
    printf '%s\n' "$bout" | sed 's/^/       /'
    case "$bout" in
      *"state change lock"*)
        warn "  A JOB IS ALREADY HELD ON THIS DOMAIN - usually an interrupted backup."
        say  "  Clear it, then retry:"
        say  "     virsh domjobabort $dom"
        ;;
      *"checkpoint inconsistent"*|*"missing or broken bitmap"*)
        # SELF-HEAL, ONCE, AND ONLY FOR THIS ERROR.
        #
        # The chain is unusable: the bitmap the checkpoint names is gone, and no incremental
        # will ever succeed against it. The only way forward is a fresh full. Doing it
        # automatically is right because the alternative is a backup job that fails silently
        # every night until someone reads a log.
        #
        # --metadata ONLY. It drops libvirt's record of the checkpoint; it does not touch the
        # guest's disk, and it does not touch the backup sets already on the volume.
        #
        # This is a REMEDIATION, not a diagnostic - the distinction that was got wrong on
        # 2026-09-14, when a retry meant purely to print an error collided with the attempt
        # it was describing. The cause is removed first, it happens once, and it says so.
        if [ "$mode" = incr ] && [ "${_healed:-0}" -eq 0 ]; then
          warn "  THE CHECKPOINT CHAIN IS BROKEN - falling back to a FULL backup."
          say  "  A raw disk cannot hold a persistent bitmap, so a chain that included one"
          say  "  cannot survive a guest restart. Dropping the stale checkpoint metadata:"
          local c
          for c in $(virsh checkpoint-list "$dom" --name 2>/dev/null | sed '/^$/d'); do
            virsh checkpoint-delete "$dom" "$c" --metadata >/dev/null 2>&1 \
              && say "     dropped $c" || warn "     could NOT drop $c"
          done
          rm -f "$bxml" "$cxml"
          _healed=1 backup_one "$dom" full
          return $?
        fi
        ;;
    esac
    rm -f "$bxml" "$cxml"
    # CLEAN UP THE EMPTY SET DIRECTORY THIS ATTEMPT CREATED. rmdir, never rm -rf: it removes
    # the directory only if it is empty, so it cannot destroy a set that holds data even if
    # this path is reached with a half-written one. Last night's failure left four of these,
    # and they are indistinguishable from an interrupted backup - which is what
    # BackupInterrupted now alerts on, so leaving them would be a standing false alarm.
    rmdir "$out" 2>/dev/null || true
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
  # THE DISKS ARE NOT ENOUGH TO RESTORE A GUEST. Without the domain definition a restore on a
  # rebuilt host means hand-writing the XML - vCPU, RAM, machine type, firmware, the disk and
  # network layout - from memory, under pressure. Found 2026-09-20 while building restore-test.
  # --inactive so it is the DEFINITION, not the running state with its runtime additions.
  virsh dumpxml --inactive "$dom" > "$out/DOMAIN.xml" 2>/dev/null \
    || warn "$dom: could not save the domain definition - a restore will need it written by hand"
  ( cd "$out" && sha256sum ./*.qcow2 ./DOMAIN.xml > MANIFEST.sha256 2>/dev/null ) || true
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

# ---------------------------------------------------------------- progress
# ASK LIBVIRT, NOT THE FILESYSTEM. `df` tells you how many bytes have landed; only
# domjobinfo knows the TOTAL, so only domjobinfo can tell you how far along you are. A
# sparse qcow2 also makes the on-disk figure a poor proxy for progress.
cmd_progress() {
  assert_hypervisor
  local d any=0 jt
  printf '\n  backup progress on %s\n\n' "$(hostname -s)"
  for d in $(domains); do
    # TRIM THE TRAILING SPACES. virsh pads the value, so "$2" is "None        " and a match
    # against exactly "None" never fires - which is why a machine with nothing running
    # printed "svc-mgmt-01 [None        ]" and called it progress.
    jt="$(virsh domjobinfo "$d" 2>/dev/null \
          | awk -F': *' '/^Job type/{gsub(/[[:space:]]+$/,"",$2); print $2}')"
    case "${jt:-None}" in
      None|none|"") continue ;;
    esac
    any=1
    printf '  %s  [%s]\n' "$d" "$jt"
    virsh domjobinfo "$d" 2>/dev/null \
      | grep -E 'Time elapsed|Data processed|Data remaining|Data total|File processed|File remaining|File total' \
      | sed 's/^/       /'
    # THREE INDEPENDENT FAULTS LIVED IN THE FOUR LINES THIS REPLACES, and every one of
    # them was silent. Measured on host-4, 2026-09-16, while a full backup ran perfectly:
    #
    #   1. `--bytes` IS NOT SUPPORTED by this libvirt's domjobinfo:
    #        error: command 'domjobinfo' doesn't support option --bytes
    #      2>/dev/null hid it, so the substitution returned empty.
    #
    #   2. THE FIELDS ARE NAMED `File *`, NOT `Data *`, for a backup operation. Real output:
    #        Job type: Unbounded   Operation: Backup
    #        File processed: 34.947 GiB   File remaining: 989.053 GiB   File total: 1.000 TiB
    #      Even with --bytes gone, grepping `Data processed` finds nothing here.
    #
    #   3. `File total` IS THE VIRTUAL SIZE, not what gets copied. svc-repo-01 reports
    #      1.000 TiB while only 331 GB is allocated. A percentage against it read 3% when
    #      the copy was 10% done - worse than printing no number at all.
    #
    # So: no --bytes, accept either field name, and divide by the ALLOCATED size from
    # alloc_bytes() - which is what qemu actually writes. Each fault alone made the
    # percentage vanish; together they meant this function never once printed one.
    local jinfo proc_h proc_b alloc
    jinfo="$(virsh domjobinfo "$d" 2>/dev/null || true)"
    proc_h="$(printf '%s\n' "$jinfo" \
      | awk -F: '/^File processed|^Data processed/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    proc_b=0
    if [ -n "${proc_h:-}" ]; then
      proc_b="$(numfmt --from=iec "$(printf '%s' "$proc_h" | tr -d ' ' | sed 's/iB$//')" 2>/dev/null || echo 0)"
    fi
    case "${proc_b:-}" in ''|*[!0-9]*) proc_b=0 ;; esac
    alloc="$(alloc_bytes "$d")"
    case "${alloc:-}" in ''|*[!0-9]*) alloc=0 ;; esac
    if [ "$alloc" -gt 0 ] && [ "$proc_b" -gt 0 ]; then
      printf '       => %s of %s allocated  (%s%%)\n' \
        "$(human "$proc_b")" "$(human "$alloc")" "$(( proc_b * 100 / alloc ))"
    elif [ "$proc_b" -gt 0 ]; then
      printf '       => %s processed (cannot size this domain to give a percentage)\n' \
        "$(human "$proc_b")"
    fi
    printf '\n'
  done
  [ "$any" -eq 1 ] || say "no backup COPY job is running right now"

  # A VERIFY IN PROGRESS IS ALSO PROGRESS. It used to be invisible here, so `progress`
  # answered "nothing is running" while a 402 GB read was an hour from finishing.
  if [ -r "$VERIFY_STATE" ]; then
    local vstart vtotal vdev vbase now cur readb pct rate eta
    vstart=""; vtotal=""; vdev=""; vbase=""
    # shellcheck source=/dev/null
    . "$VERIFY_STATE" 2>/dev/null || true
    vstart="${start:-0}"; vtotal="${total:-0}"; vdev="${dev:-}"; vbase="${base:-0}"
    now="$(date +%s)"
    cur="$(awk -v x="$vdev" '$3==x {print $6+0; exit}' /proc/diskstats 2>/dev/null)"
    readb=$(( ( ${cur:-0} - vbase ) * 512 ))
    [ "$readb" -lt 0 ] && readb=0
    printf '\n  VERIFY in progress\n'
    printf '     read     %s of %s\n' "$(human "$readb")" "$(human "$vtotal")"
    if [ "${vtotal:-0}" -gt 0 ]; then
      pct=$(( readb * 100 / vtotal )); [ "$pct" -gt 100 ] && pct=100
      printf '     complete %s%%\n' "$pct"
    fi
    local elapsed=$(( now - vstart ))
    if [ "$elapsed" -gt 5 ] && [ "$readb" -gt 0 ]; then
      rate=$(( readb / elapsed ))
      printf '     rate     %s/s   elapsed %dm%02ds\n' "$(human "$rate")" $(( elapsed / 60 )) $(( elapsed % 60 ))
      if [ "$rate" -gt 0 ] && [ "${vtotal:-0}" -gt "$readb" ]; then
        eta=$(( (vtotal - readb) / rate ))
        printf '     ETA      ~%dm%02ds  (about %s)\n' $(( eta / 60 )) $(( eta % 60 )) \
          "$(date -d "+${eta} seconds" +%H:%M 2>/dev/null || echo '?')"
      fi
    fi
    printf '\n'
  fi
  if [ -n "$DEST" ] && mountpoint -q "$DEST" 2>/dev/null; then
    say "destination: $(df -h "$DEST" | tail -1 | awk '{print $3" used, "$4" free"}')"
  fi
  # Manual detached runs are systemd units; say where to read them.
  local units; units="$(systemctl list-units --no-legend 'vm-backup-manual-*' 'enclave-vm-backup*' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  [ -n "$units" ] && say "units: $units" && say "   journalctl -u <unit> -f"
  printf '\n'
}

# ---------------------------------------------------------------- verify
# WHERE THE PROGRESS STATE LIVES. /run, so it disappears on reboot and can never be mistaken
# for a record of something that is still happening.
VERIFY_STATE="${VERIFY_STATE:-/run/vm-backup-verify.state}"

# THE NEWEST mtime AMONG THE FILES A SET'S INTEGRITY DEPENDS ON.
# A completed set never changes, so this is a stable fingerprint of "the bytes I verified".
set_newest_mtime() {  # <setdir>
  find "$1" -maxdepth 1 -type f \( -name '*.qcow2' -o -name 'MANIFEST.sha256' \) \
    -printf '%T@\n' 2>/dev/null | cut -d. -f1 | sort -n | tail -1
}

# HAS THIS SET ALREADY PASSED, UNCHANGED, SINCE THEN?
#
# READ THIS BEFORE TRUSTING IT: an mtime cannot detect bit-rot. Silent corruption on the
# volume does not touch the timestamp, so a skipped set is NOT being re-checked for decay -
# it is being taken on the word of a previous run. That is the correct trade for the NIGHTLY
# job, whose question is "did the set we wrote twenty minutes ago arrive intact". It is the
# wrong trade for the only check that ever runs, which is why `verify --all` exists and why
# `schedule` installs a weekly timer for it. The two answer different questions and the
# enclave needs both.
set_already_verified() {  # <setdir>
  local st="$1/VERIFIED" rec now
  [ -f "$st" ] || return 1
  rec="$(awk -F= '/^newest_mtime=/{print $2+0}' "$st" 2>/dev/null)"
  [ -n "${rec:-}" ] && [ "${rec:-0}" -gt 0 ] || return 1
  now="$(set_newest_mtime "$1")"
  [ -n "${now:-}" ] || return 1
  [ "$now" -le "$rec" ]
}

mark_set_verified() {  # <setdir>
  printf 'verified_utc=%s\nnewest_mtime=%s\nby=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(set_newest_mtime "$1")" "$(basename "$0")" \
    > "$1/VERIFIED" 2>/dev/null || true
  chmod 0600 "$1/VERIFIED" 2>/dev/null || true
}

cmd_verify() {
  need_root; check_dest
  local all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1; shift ;;
      *) die "unknown argument: $1
       usage: $0 verify [--all]
         (default) only sets that changed since they last passed - seconds
         --all     re-read every byte of every set - catches bit-rot, takes an hour" ;;
    esac
  done

  # A ONE-HOUR OPERATION THAT PRINTS NOTHING IS INDISTINGUISHABLE FROM A HANG, and on
  # 2026-09-16 that is exactly what happened - the operator asked twice whether it was stuck
  # while it was reading 402 GB at 102 MB/s, and interrupted it once. Silence is not a
  # neutral default; it is a defect in anything that runs longer than a person will wait.
  #
  # Two things fix it: a line per set as it starts, and a state file that `progress` can read
  # from another shell to compute a percentage and an ETA.
  #
  # THE TOTAL COUNTS ONLY WHAT WILL ACTUALLY BE READ. Sizing it from the whole volume made
  # the ETA meaningless the moment skipping existed.
  local total=0 dev base dir0 nplan=0 nskip=0
  while IFS= read -r dir0; do
    [ -f "$dir0/INFO" ] || continue
    if [ "$all" -eq 0 ] && set_already_verified "$dir0"; then
      nskip=$((nskip + 1)); continue
    fi
    nplan=$((nplan + 1))
    total=$(( total + $(du -sb "$dir0" 2>/dev/null | awk '{print $1+0}') ))
  done < <(find "$DEST" -mindepth 2 -maxdepth 2 -type d | sort)
  dev="$(basename "$(readlink -f "$(findmnt -no SOURCE --target "$DEST" 2>/dev/null)" 2>/dev/null)" 2>/dev/null)"
  base="$(awk -v x="$dev" '$3==x {print $6+0; exit}' /proc/diskstats 2>/dev/null)"
  printf 'start=%s\ntotal=%s\ndev=%s\nbase=%s\n' \
    "$(date +%s)" "${total:-0}" "${dev:-}" "${base:-0}" > "$VERIFY_STATE" 2>/dev/null || true
  chmod 0644 "$VERIFY_STATE" 2>/dev/null || true
  # Remove it however this exits, so `progress` never reports a verify that has finished.
  trap 'rm -f "$VERIFY_STATE"' EXIT

  if [ "$all" -eq 1 ]; then
    say "DEEP verify: re-reading every byte of $nplan set(s), $(human "$total")"
    say "  this is the check that catches bit-rot. It takes as long as it takes."
  else
    say "verifying $nplan changed set(s), $(human "$total")   ($nskip unchanged, skipped)"
    say "  skipped sets passed a previous run and have not changed since. Silent decay does"
    say "  NOT change an mtime, so the weekly '$0 verify --all' is what covers that."
  fi
  [ "$nplan" -gt 0 ] && say "  watch from another shell with:  $0 progress"
  say ""

  local bad=0 n=0 dir
  while IFS= read -r dir; do
    [ -f "$dir/INFO" ] || continue
    if [ "$all" -eq 0 ] && set_already_verified "$dir"; then
      printf '  [-] %-38s %8s skipped (passed %s)\n' \
        "$(basename "$(dirname "$dir")")/$(basename "$dir")" "" \
        "$(awk -F= '/^verified_utc=/{print $2}' "$dir/VERIFIED" 2>/dev/null)"
      continue
    fi
    n=$((n + 1))
    # THE LINE THAT WAS MISSING. Name the set before spending minutes on it.
    printf '  [%d] %-38s %8s ' "$n" \
      "$(basename "$(dirname "$dir")")/$(basename "$dir")" \
      "$(du -sh "$dir" 2>/dev/null | cut -f1)"
    # `qemu-img check` IS THE WRONG TOOL FOR AN INCREMENTAL, and using it here reported every
    # healthy incremental as corrupt.
    #
    # A push-mode incremental qcow2 carries a BACKING FILE reference to the LIVE guest disk.
    # `check` opens the whole chain, the running VM holds a lock on that disk, and the open
    # fails - so the check fails for a reason that has nothing to do with the backup:
    #
    #   Could not open backing file: Failed to get shared "write" lock
    #   Is another process using the image [/var/lib/libvirt/images/svc-harbor-01.qcow2]?
    #
    # Measured 2026-09-16: BOTH of svc-harbor-01's incrementals failed identically while
    # their manifests verified clean. An alert that fires on every healthy run is worse than
    # no alert, because it is the run where something IS wrong that gets ignored.
    #
    # So: `qemu-img info` on everything - it reads the header without opening the backing
    # chain, which is exactly the structural question worth asking. `qemu-img check` only
    # where there is no backing file to open, which means fulls. And the MANIFEST is the
    # real integrity statement either way: it hashes the bytes that actually arrived.
    local f info
    for f in "$dir"/*.qcow2; do
      [ -e "$f" ] || continue
      if ! info="$(qemu-img info "$f" 2>&1)"; then
        warn "UNREADABLE (qcow2 header will not parse): $f"
        printf '%s\n' "$info" | sed 's/^/       /'
        bad=1
        continue
      fi
      case "$info" in
        *"backing file:"*)
          # An incremental. Its structure parsed; the manifest below is the integrity check.
          : ;;
        *)
          # A full, with no chain to open - check is meaningful and cheap here.
          if ! qemu-img check -q "$f" >/dev/null 2>&1; then
            warn "CORRUPT: $f"
            qemu-img check "$f" 2>&1 | head -4 | sed 's/^/       /'
            bad=1
          fi ;;
      esac
    done
    if [ -f "$dir/MANIFEST.sha256" ]; then
      if ( cd "$dir" && sha256sum -c --quiet MANIFEST.sha256 ) >/dev/null 2>&1; then
        printf 'ok\n'
        # STAMP ONLY ON A CLEAN PASS, and only if nothing else in this set failed. A set
        # whose qcow2 header would not parse must not be skipped next time.
        mark_set_verified "$dir"
      else
        printf 'CHECKSUM MISMATCH\n'; bad=1
      fi
    else
      printf 'NO MANIFEST\n'; bad=1
    fi
  done < <(find "$DEST" -mindepth 2 -maxdepth 2 -type d | sort)
  printf '\n'
  # SAY THE COUNT. "all backups verified" reads the same whether it checked forty or zero.
  if [ "$bad" -eq 0 ]; then
    if [ "$all" -eq 1 ]; then
      ok "DEEP verify clean: $n set(s) re-read in full, every manifest matches"
    else
      ok "verified $n changed set(s) clean; $nskip unchanged set(s) skipped"
      say "   skipped sets were NOT re-read. Bit-rot is covered by the weekly --all run."
    fi
    say "   fulls additionally passed qemu-img check. Incrementals are NOT check-ed: they"
    say "   reference the live guest disk, which is locked, so the manifest is the statement."
  else
    warn "verified $n set(s), PROBLEMS FOUND - see above"
  fi
  return "$bad"
}

# ---------------------------------------------------------------- prune
cmd_prune() {
  need_root; check_dest
  local dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run|-n) dry=1; shift ;;
      *) die "unknown argument: $1
       usage: $0 prune [--dry-run]" ;;
    esac
  done

  # ================================================================================
  # THIS FUNCTION DESTROYED EVERY FULL BACKUP IN THE ENCLAVE ON 2026-09-16.
  #
  # The parameter is called BACKUP_KEEP_CHAINS. The old code counted DIRECTORIES:
  # it sorted set directories by name, kept the newest KEEP, and deleted the rest.
  # The oldest directory is always the FULL, so "keep 2" reliably deleted the base
  # and kept two incrementals that reference it. Logged output from that run:
  #
  #     svc-obs-01:  removing 20260914T195447Z (7.2G)    <- the full
  #     svc-repo-01: removing 20260914T203840Z (331G)    <- the full
  #     [ok] prune complete - kept 2 set(s) per domain
  #
  # The volume went from 402 GB to 11 GB and NO VM HAD A RESTORABLE BACKUP. An
  # incremental without its base is not a backup; it is a diff against something
  # that no longer exists.
  #
  # A chain is a FULL plus every incremental after it, up to the next full. This
  # keeps the newest KEEP chains and refuses, hard, to leave a domain with no full.
  # ================================================================================

  local dom freed=0
  for dom in "$DEST"/*/; do
    [ -d "$dom" ] || continue
    local name; name="$(basename "$dom")"
    [ "$name" = "lost+found" ] && continue

    # Only sets carrying INFO are considered. A directory without one is an
    # interrupted run - it is not part of any chain and prune does not own it.
    local sets=() modes=() d
    while IFS= read -r d; do
      [ -f "$d/INFO" ] || continue
      sets+=("$d")
      modes+=("$(awk -F= '/^mode=/{print $2}' "$d/INFO" 2>/dev/null)")
    done < <(find "$dom" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    local n=${#sets[@]}
    if [ "$n" -eq 0 ]; then say "$name: no completed sets - nothing to prune"; continue; fi

    # Which sets are fulls, oldest first.
    local fulls=() i
    for ((i=0; i<n; i++)); do
      [ "${modes[$i]}" = full ] && fulls+=("$i")
    done
    local nf=${#fulls[@]}

    # ---- GUARD 1: NO FULL AT ALL. Refuse, loudly. --------------------------------
    # This is the state the old code left the enclave in, and if prune had had this
    # guard it could not have created it.
    if [ "$nf" -eq 0 ]; then
      warn "$name: $n set(s) and NOT ONE FULL - refusing to prune anything here."
      warn "  every set is an incremental with no base, so none of them can restore."
      warn "  fix it:  sudo $0 full $name"
      continue
    fi

    # ---- GUARD 2: fewer chains than we keep. Nothing to do. ----------------------
    if [ "$nf" -le "$KEEP" ]; then
      say "$name: $nf chain(s) / $n set(s), keeping all (KEEP=$KEEP)"
      continue
    fi

    # The oldest full we are keeping. Everything BEFORE it belongs to a chain that
    # is being retired, and that includes its incrementals - they are useless once
    # their base goes, which is exactly why they go with it and not before it.
    local cut=${fulls[$((nf - KEEP))]}
    say "$name: $nf chain(s) / $n set(s) - keeping the newest $KEEP chain(s) from $(basename "${sets[$cut]}")"

    for ((i=0; i<cut; i++)); do
      local sz; sz="$(du -sb "${sets[$i]}" 2>/dev/null | cut -f1)"
      case "${sz:-}" in ''|*[!0-9]*) sz=0 ;; esac
      if [ "$dry" -eq 1 ]; then
        say "  would remove $(basename "${sets[$i]}") [${modes[$i]}] $(human "$sz")"
      else
        say "  removing $(basename "${sets[$i]}") [${modes[$i]}] $(human "$sz")"
        rm -rf -- "${sets[$i]}"
        freed=$((freed + sz))
      fi
    done

    # ---- GUARD 3: prove a full survived, per domain, after acting. ---------------
    # Cheap, and it is the check that turns "I believe this is correct" into "this
    # domain can still be restored".
    if [ "$dry" -eq 0 ]; then
      local left=0
      for d in "$dom"*/; do
        [ -f "$d/INFO" ] || continue
        [ "$(awk -F= '/^mode=/{print $2}' "$d/INFO" 2>/dev/null)" = full ] && left=$((left + 1))
      done
      if [ "$left" -eq 0 ]; then
        warn "$name: PRUNE LEFT NO FULL BACKUP. This should be impossible - report it."
        warn "  take one now:  sudo $0 full $name"
      else
        ok "$name: $left full(s) retained"
      fi
    fi
  done

  if [ "$dry" -eq 1 ]; then
    ok "DRY RUN - nothing was removed"
  else
    # REPORT WHAT WAS KEPT, NOT WHAT THE POLICY SAYS. This line used to read
    # "kept $KEEP chain(s) per domain", which printed the POLICY (KEEP=2) regardless of what
    # was actually on the volume - so it announced "kept 2 chain(s)" when there was 1.
    #
    # That is the same substitution that caused the 2026-09-16 catastrophe in this very
    # function: a statement about the intended policy, presented as a statement about the
    # data. An operator reading "kept 2" has no reason to look further, which is exactly when
    # they should.
    ok "prune complete - freed $(human "$freed"), retained chains per domain listed above"
  fi
}

# ---------------------------------------------------------------- keyfile / reattach
# AFTER A REBOOT, THE DESTINATION IS GONE, AND FOR THREE SEPARATE REASONS.
#   1. usb-storage is blocked by the STIG, so the drive never appears.
#   2. The LUKS volume is locked, and unlocking wants a passphrase nobody is there to type.
#   3. Nothing mounts it.
# `reattach` does all three and then RE-BLOCKS USB immediately, so the deviation window is
# open for seconds rather than until somebody remembers.

luks_dev() { printf '/dev/disk/by-uuid/%s\n' "$LUKS_UUID"; }

cmd_keyfile() {
  need_root
  [ -n "$LUKS_UUID" ] || die "BACKUP_LUKS_UUID is not set in vm-specs.env"
  local dev; dev="$(luks_dev)"
  [ -b "$dev" ] || die "no LUKS device at $dev - is the drive attached and unlocked?"
  if [ -s "$KEYFILE" ]; then
    warn "$KEYFILE already exists - not overwriting."
    say  "  to replace it: cryptsetup luksRemoveKey $dev $KEYFILE, delete the file, re-run"
    return 0
  fi
  install -d -m 0700 "$(dirname "$KEYFILE")"
  # 4096 random bytes. Not a password - nothing ever types this.
  ( umask 077; head -c 4096 /dev/urandom > "$KEYFILE" )
  chmod 0400 "$KEYFILE"
  say "created $KEYFILE (0400 root, on this machine's encrypted root)"
  say "adding it to the LUKS header - you will be asked for the EXISTING passphrase:"
  if cryptsetup luksAddKey "$dev" "$KEYFILE"; then
    ok "keyfile added - reattach and scheduled runs no longer need a human"
    say "   the passphrase still works, and is still your way in from any other machine"
  else
    rm -f "$KEYFILE"
    die "luksAddKey failed - keyfile removed, nothing changed"
  fi
}

cmd_reattach() {
  need_root; assert_hypervisor
  [ -n "$DEST" ] || die "no destination set"
  if mountpoint -q "$DEST"; then ok "$DEST is already mounted - nothing to do"; return 0; fi
  [ -n "$LUKS_UUID" ] || die "BACKUP_LUKS_UUID is not set in vm-specs.env"

  # NOT `local`, AND THAT IS THE POINT. `reblock` below runs from an EXIT trap, which fires
  # after this function has already returned - so a `local` is out of scope by the time the
  # trap reads it. Under `set -u` that produced:
  #
  #     vm-backup.sh: line 906: opened_window: unbound variable
  #
  # on EVERY successful reattach, with a non-zero exit after a completely successful mount.
  # Found 2026-09-17 during the SSD swap; pre-existing, not introduced by the TRIM change.
  #
  # The tempting fix - ${opened_window:-0} - IS WRONG AND WOULD BE WORSE THAN THE BUG. It
  # makes the trap read 0 even when a window WAS opened, so the USB block would silently
  # never be restored and kernel_module_usb-storage_disabled would start failing with nothing
  # to say why. A cosmetic error traded for a security regression.
  #
  # Script scope is what the trap actually needs. Neither name is used anywhere else.
  tailor="$(dirname "$(readlink -f "$0")")/stig-tailor.sh"
  opened_window=0
  local dev; dev="$(luks_dev)"

  if [ ! -b "$dev" ]; then
    if ! lsmod | grep -q "^usb_storage"; then
      [ -x "$tailor" ] || die "need $tailor to open the USB window"
      say "USB storage is blocked - opening the window briefly"
      "$tailor" usb enable >/dev/null 2>&1 || warn "usb enable reported a problem - continuing"
      opened_window=1
    fi
    # The device node and its by-uuid link arrive via udev, not instantly.
    local i=0
    while [ ! -b "$dev" ] && [ "$i" -lt 20 ]; do sleep 1; udevadm settle --timeout=2 2>/dev/null; i=$((i+1)); done
  fi

  # CLOSE THE WINDOW WHATEVER HAPPENS NEXT. modprobe -r will fail once the volume is
  # mounted, and that is expected and harmless - what matters for the control is that the
  # block file is back in /etc/modprobe.d.
  reblock() {
    [ "$opened_window" -eq 1 ] || return 0
    [ -x "$tailor" ] && "$tailor" usb disable >/dev/null 2>&1 || true
    if grep -rqls "usb.storage" /etc/modprobe.d/ 2>/dev/null; then
      ok "USB re-blocked - the deviation window is closed again"
    else
      warn "COULD NOT RE-BLOCK USB - the window is still open. Close it by hand:"
      warn "    sudo $tailor usb disable"
    fi
  }
  trap reblock EXIT

  [ -b "$dev" ] || die "LUKS device $dev never appeared - is the drive plugged in and powered?"
  ok "found the encrypted volume: $(readlink -f "$dev")"

  # TRIM. OFF BY DEFAULT AND THAT IS DELIBERATE - it is a posture decision, not a tuning knob.
  #
  # An SSD backup target with nightly churn loses sustained write speed without discard, and
  # dm-crypt DROPS TRIM unless it is opened with --allow-discards. The cost is a documented
  # information leak: someone holding the drive can see which blocks are unused, so roughly
  # how full the filesystem is. The contents stay encrypted; the shape of the usage does not.
  #
  # Defensible on a backup volume. It belongs in the SSP as a STATED CHOICE rather than being
  # found in a config file later, which is why the default is off and turning it on is explicit.
  # Meaningless on a spinning disk - leave it off for the WD.
  local disc=""
  case "${BACKUP_TRIM:-false}" in
    true|yes|1)
      disc="--allow-discards"
      say "TRIM enabled (BACKUP_TRIM) - dm-crypt will pass discards to the device."
      say "  SSP: this reveals which blocks are unused, i.e. approximately how full the"
      say "  volume is, to anyone holding the drive. Contents remain encrypted." ;;
    false|no|0|'') : ;;
    *) die "BACKUP_TRIM must be true or false, got '${BACKUP_TRIM}'" ;;
  esac

  if [ ! -e "/dev/mapper/$LUKS_NAME" ]; then
    if [ -s "$KEYFILE" ]; then
      cryptsetup luksOpen $disc --key-file "$KEYFILE" "$dev" "$LUKS_NAME" \
        || die "luksOpen failed with $KEYFILE - run '$0 keyfile' first, or unlock by hand"
      ok "unlocked with the keyfile - no passphrase needed"
    else
      warn "no keyfile at $KEYFILE - unlock needs a passphrase, so this cannot run unattended"
      say  "  create one with:  sudo $0 keyfile"
      cryptsetup luksOpen $disc "$dev" "$LUKS_NAME" || die "luksOpen failed"
    fi
  fi

  install -d "$DEST"
  # discard in the mount options too - the dm-crypt layer allowing TRIM is necessary but not
  # sufficient; ext4 has to actually issue it.
  local mopts="defaults"
  [ -n "$disc" ] && mopts="defaults,discard"
  mount -o "$mopts" "/dev/mapper/$LUKS_NAME" "$DEST" || die "mount failed"

  # PROVE IT RATHER THAN ASSUME IT. A volume opened with --allow-discards on a bridge that
  # does not pass TRIM reports nothing and silently behaves as if discard were off.
  if [ -n "$disc" ]; then
    local dg; dg="$(lsblk -dno DISC-GRAN "$(readlink -f "$dev")" 2>/dev/null | tr -d ' ')"
    case "${dg:-0B}" in
      0B|0|'') warn "the device reports DISC-GRAN 0 - THIS BRIDGE DOES NOT PASS TRIM."
               warn "  BACKUP_TRIM is on and having no effect. Check 'lsusb -t' shows uas," 
               warn "  not usb-storage, and that the enclosure supports it." ;;
      *) ok "TRIM reaches the device (discard granularity $dg)" ;;
    esac
  fi
  mountpoint -q "$DEST" || die "$DEST still is not a mountpoint"
  ok "mounted $DEST"
  df -h "$DEST" | tail -1 | sed 's/^/       /'
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
VERIFY_SVC="enclave-vm-verify"
# WHEN THE DEEP VERIFY RUNS. Weekly, and deliberately not adjacent to the nightly backup:
# both read the same USB volume and overlapping them halves the throughput of each. Sunday
# 04:00 leaves the nightly run at 02:00 finished long before. A parameter, not a constant.
VERIFY_ONCALENDAR="${BACKUP_VERIFY_ONCALENDAR:-Sun *-*-* 04:00}"

# THE SCHEDULE IS IN THE OPERATOR'S TIMEZONE, NOT THE MACHINE'S.
#
# Every machine in this enclave runs UTC, deliberately - audit timestamps and doc timestamps
# are UTC and labelled. But "run the backup at 2am" means 2am where the person who has to
# deal with it lives, and that is US Central. Writing 02:00 into the unit put the job at
# 21:00 Central, in the middle of the working evening.
#
# The naive fix - write 07:00 UTC - is wrong twice a year. 02:00 Central is 07:00 UTC under
# CDT and 08:00 UTC under CST, so a hardcoded offset silently moves the job by an hour every
# March and November. systemd 252+ accepts a timezone IN the calendar spec and does the DST
# arithmetic itself; verified on systemd 255:
#
#   *-*-* 02:00:00 America/Chicago   ->  Thu 2026-09-17 07:00:00 UTC
#
# So the spec carries the zone and systemd tracks the change. A parameter, because the next
# enclave will not be in Central.
BACKUP_TZ="${BACKUP_TZ:-America/Chicago}"

cmd_schedule() {
  need_root; assert_hypervisor
  local at="${1:-02:00}"
  case "$at" in [0-2][0-9]:[0-5][0-9]) : ;; *) die "--at wants HH:MM, got '$at'" ;; esac
  [ -n "$DEST" ] || die "no destination set - fix BACKUP_DEST in vm-specs.env first"
  # THE UNITS RUN AS ROOT, SO THEY RUN A ROOT-OWNED COPY - backlog 3.11. This used to be
  # "$(readlink -f "$0")", i.e. the repo copy in encadmin's home, writable by encadmin: a
  # root timer executing user-writable code is a sudo bypass. Re-run `schedule` after
  # pushing a new version so the copy is refreshed.
  "$HERE/install-runtime.sh" || die "could not install the root-owned runtime copy"
  local self; self="$("$HERE/install-runtime.sh" --print-dir)/vm-backup.sh"
  [ -x "$self" ] || die "$self missing after install-runtime.sh"

  # ---- the schedule, in the operator's timezone, PROVEN BEFORE IT IS INSTALLED ----------
  # A calendar spec systemd cannot parse produces a timer that never fires and reports no
  # error at install. Ask systemd to normalise it first and print what it will actually do -
  # in UTC, because that is what every log on this machine is stamped in.
  [ -e "/usr/share/zoneinfo/$BACKUP_TZ" ] \
    || die "BACKUP_TZ='$BACKUP_TZ' is not a zone on this machine.
       list them with: timedatectl list-timezones"
  local night_cal="*-*-* ${at}:00 ${BACKUP_TZ}"
  local weekly_cal="${VERIFY_ONCALENDAR} ${BACKUP_TZ}"
  case "$VERIFY_ONCALENDAR" in
    *:*:*) weekly_cal="${VERIFY_ONCALENDAR} ${BACKUP_TZ}" ;;
    *)     weekly_cal="${VERIFY_ONCALENDAR}:00 ${BACKUP_TZ}" ;;
  esac
  local cal out
  for cal in "$night_cal" "$weekly_cal"; do
    if ! out="$(systemd-analyze calendar "$cal" 2>&1)"; then
      printf '%s\n' "$out" | sed 's/^/       /'
      die "systemd will not accept the calendar spec '$cal' - nothing installed"
    fi
  done
  say "schedule, as systemd reads it:"
  printf '     nightly  %s\n' "$night_cal"
  systemd-analyze calendar "$night_cal" 2>/dev/null | sed 's/^/       /'
  printf '     weekly   %s\n' "$weekly_cal"
  systemd-analyze calendar "$weekly_cal" 2>/dev/null | sed 's/^/       /'
  say ""

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
# NO --all HERE, DELIBERATELY. This step's question is "did the set written minutes ago
# arrive intact", and the answer is in that set alone. Re-reading 400 GB of unchanged sets
# every night took an hour, put the nightly job under sustained USB load until 03:05, and
# buried any real failure in an hour of expected disk noise. Bit-rot is the WEEKLY job's
# question - see ${VERIFY_SVC}.timer, installed alongside this one.
ExecStart=${self} verify
ExecStart=${self} prune
EOF

  cat > "/etc/systemd/system/${SVC_NAME}.timer" <<EOF
[Unit]
Description=Nightly enclave VM backup at ${at} ${BACKUP_TZ}

[Timer]
OnCalendar=${night_cal}
# Persistent so a missed run (machine off, drive absent) happens at the next opportunity
# rather than being skipped in silence.
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # ---- the weekly DEEP verify -----------------------------------------------------------
  # The nightly run only checks what changed, which cannot see decay. This is the run that
  # re-reads every byte, and it is the only thing standing between a rotting USB volume and
  # a restore that fails when it is needed.
  cat > "/etc/systemd/system/${VERIFY_SVC}.service" <<EOF
[Unit]
Description=Weekly DEEP verify of every enclave VM backup set (re-reads every byte)
After=libvirtd.service
RequiresMountsFor=${DEST}

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
# Sized from measurement: 402 GB at ~82 MB/s is about 80 minutes, and the volume grows.
TimeoutStartSec=6h
ExecStart=${self} verify --all
EOF

  cat > "/etc/systemd/system/${VERIFY_SVC}.timer" <<EOF
[Unit]
Description=Weekly deep verify of the VM backup volume

[Timer]
OnCalendar=${weekly_cal}
# A week is long enough that a missed run matters - catch it up rather than wait another.
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SVC_NAME}.timer" >/dev/null 2>&1 \
    || die "could not enable ${SVC_NAME}.timer"
  systemctl enable --now "${VERIFY_SVC}.timer" >/dev/null 2>&1 \
    || warn "could not enable ${VERIFY_SVC}.timer - the nightly backup still works, but"
  ok "scheduled: ${SVC_NAME}.timer at ${at} ${BACKUP_TZ} daily -> ${DEST}"
  ok "scheduled: ${VERIFY_SVC}.timer '${weekly_cal}' - deep verify, reads every byte"
  say ""
  say "   nightly: incr + verify (changed sets only) + prune   - minutes"
  say "   weekly : verify --all                                - reads the whole volume"
  say ""
  systemctl list-timers "${SVC_NAME}.timer" "${VERIFY_SVC}.timer" --no-pager | sed 's/^/       /'
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
  # BOTH TIMERS. schedule installs two; an unschedule that removes one leaves a weekly deep
  # verify running against a volume nothing is backing up any more - which reads for an hour
  # every Sunday and reports success on data that is going stale.
  local u
  for u in "$SVC_NAME" "$VERIFY_SVC"; do
    systemctl disable --now "${u}.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${u}.timer" "/etc/systemd/system/${u}.service"
  done
  systemctl daemon-reload
  ok "removed ${SVC_NAME} and ${VERIFY_SVC} (.timer and .service)"
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

# ---------------------------------------------------------------- restore TEST
# PROVING A RESTORE, WITHOUT RISKING THE THING BEING RESTORED. backlog 2.1, control CP-4.
#
#     sudo ./vm-backup.sh restore-test <domain> [--set <stamp>] [--keep] [-n]
#
# restore-plan above is for the day something is broken and it stays manual. THIS is the
# rehearsal, and it is safe to automate precisely because it NEVER writes where the live guest
# lives: it rebuilds the chain into its own directory and defines a SEPARATE domain,
# restore-test-<name>, WITH NO NETWORK INTERFACE - so it cannot collide with the running
# guest's address, and cannot be mistaken for it.
#
# WHAT IT PROVES, in order, and each one has failed somewhere for somebody:
#   1. the sets on the destination are complete and their checksums still match
#   2. the incremental chain can actually be reassembled - the step restore-plan only
#      describes in prose, and the one most likely to be wrong
#   3. the image passes qemu-img check
#   4. it BOOTS, evidenced by a login prompt on a captured serial console
#   5. how long all of that took, which is the recovery time nobody has measured
cmd_restore_test() {
  local dom="" want="" keep=0 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --set) want="${2:?--set needs a set stamp}"; shift 2 ;;
      --keep) keep=1; shift ;;
      -n|--dry-run) dry=1; shift ;;
      -*) die "restore-test: unknown option $1" ;;
      *) dom="$1"; shift ;;
    esac
  done
  [ -n "$dom" ] || die "usage: $0 restore-test <domain> [--set <stamp>] [--keep] [-n]"
  need_root; check_dest
  command -v qemu-img >/dev/null || die "qemu-img not installed"

  # ---- resolve the chain: newest set, then walk back to the full it was built on ----------
  local cur="$want"
  [ -n "$cur" ] || cur="$(find "$DEST/$dom" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1)"
  [ -n "$cur" ] || die "no backup sets for $dom at $DEST"
  local -a chain=(); local info mode based guard=0
  while :; do
    info="$DEST/$dom/$cur/INFO"
    [ -r "$info" ] || die "$cur has no INFO - the chain cannot be trusted; pick another --set"
    mode="$(awk -F= '/^mode=/{print $2}' "$info")"
    based="$(awk -F= '/^based_on=/{print $2}' "$info")"
    chain=("$cur" "${chain[@]}")
    [ "$mode" = full ] && break
    [ -n "$based" ] && [ "$based" != none ] \
      || die "$cur is an incremental with no base recorded - unrestorable, and that is a finding"
    cur="${based#chk-}"
    guard=$((guard+1)); [ "$guard" -lt 64 ] || die "chain walk did not terminate - loop in based_on"
  done
  say "chain for $dom: ${chain[*]}"

  # ---- verify what is on the disk, before spending time rebuilding it ---------------------
  local sset
  for sset in "${chain[@]}"; do
    if [ -r "$DEST/$dom/$sset/MANIFEST.sha256" ]; then
      ( cd "$DEST/$dom/$sset" && sha256sum -c --quiet MANIFEST.sha256 ) \
        || die "$sset FAILS its checksums - the backup is damaged. Stop and investigate."
      ok "$sset: checksums match"
    else
      warn "$sset has no MANIFEST.sha256 - cannot verify it, proceeding on trust"
    fi
  done

  # ---- where the rebuild happens. NEVER the live image directory. -------------------------
  local live_dir; live_dir="$(dirname "$(domain_disks "$dom" | head -1 | cut -f2)")"
  [ -n "$live_dir" ] && [ "$live_dir" != "." ] || live_dir=/var/lib/libvirt/images
  local work="${RESTORE_TEST_DIR:-$live_dir/restore-test}/$dom"
  local tname="restore-test-$dom"
  virsh dominfo "$tname" >/dev/null 2>&1 \
    && die "$tname already exists - remove it first:  virsh destroy $tname; virsh undefine $tname --nvram"

  # Targets come from the FULL set's filenames: <target>.full.qcow2
  local -a targets=(); local f
  for f in "$DEST/$dom/${chain[0]}"/*.full.qcow2; do
    [ -e "$f" ] || die "${chain[0]} holds no *.full.qcow2 - not a full set"
    targets+=("$(basename "$f" .full.qcow2)")
  done
  say "disks: ${targets[*]}"

  local need=0 avail
  for sset in "${chain[@]}"; do need=$(( need + $(du -sk "$DEST/$dom/$sset" | cut -f1) )); done
  need=$(( need * 2 ))   # the chain, plus the flattened copy it is converted into
  avail="$(df -k --output=avail "$live_dir" | tail -1)"
  say "space: rebuild needs ~$((need/1024/1024)) GB, $(( avail/1024/1024 )) GB free on $live_dir"
  [ "$need" -lt "$avail" ] || die "not enough room to rebuild - set RESTORE_TEST_DIR to somewhere with space"

  local rpo_src="${chain[-1]}"
  if [ "$dry" -eq 1 ]; then
    say "DRY RUN - would rebuild ${#chain[@]} set(s) into $work, define $tname with no NIC, boot it, then remove it"
    return 0
  fi

  # ---- rebuild ----------------------------------------------------------------------------
  local t0 t1 t2; t0="$(date +%s)"
  install -d -m 0700 "$work"
  local tgt i prev flat
  for tgt in "${targets[@]}"; do
    prev="$work/$tgt.base.qcow2"
    cp --sparse=always "$DEST/$dom/${chain[0]}/$tgt.full.qcow2" "$prev"
    i=0
    for sset in "${chain[@]:1}"; do
      i=$((i+1))
      local inc="$work/$tgt.incr$i.qcow2"
      cp --sparse=always "$DEST/$dom/$sset/$tgt.incr.qcow2" "$inc"
      # THE STEP restore-plan ONLY DESCRIBES. A libvirt push-mode incremental holds the changed
      # clusters and NO backing file reference, so on its own it is unreadable. -u sets the
      # backing link without touching data; the chain is then flattened by convert below.
      qemu-img rebase -u -b "$prev" -F qcow2 "$inc" \
        || die "could not chain $sset onto $(basename "$prev") - the chain is broken"
      prev="$inc"
    done
    flat="$work/$tgt.qcow2"
    if [ "$prev" != "$work/$tgt.base.qcow2" ]; then
      qemu-img convert -O qcow2 "$prev" "$flat" || die "flattening the chain failed for $tgt"
      rm -f "$work/$tgt".base.qcow2 "$work/$tgt".incr*.qcow2
    else
      mv "$prev" "$flat"
    fi
    qemu-img check "$flat" >/dev/null || die "qemu-img check FAILED on the restored $tgt"
    ok "$tgt rebuilt from ${#chain[@]} set(s) and passes qemu-img check"
  done
  chown -R "${QUSER}:${QGROUP}" "$work" 2>/dev/null || true
  t1="$(date +%s)"

  # ---- define a separate, network-less domain ---------------------------------------------
  local srcxml="$DEST/$dom/${chain[-1]}/DOMAIN.xml" xml="$work/$tname.xml"
  if [ -r "$srcxml" ]; then
    say "domain definition: from the backup set"
  elif virsh dumpxml --inactive "$dom" > "$work/live.xml" 2>/dev/null; then
    srcxml="$work/live.xml"
    warn "this set predates DOMAIN.xml capture - using the LIVE definition, which a real"
    warn "  disaster would not have. Fixed for future sets; re-run after the next backup."
  else
    die "no domain definition in the set and $dom is not defined here - cannot build $tname"
  fi
  python3 - "$srcxml" "$xml" "$tname" "$work" "${targets[@]}" <<'PY' || die "could not transform the domain XML"
import sys, xml.etree.ElementTree as ET
src, out, name, work = sys.argv[1:5]
targets = sys.argv[5:]
t = ET.parse(src); r = t.getroot()
r.find('name').text = name
for tag in ('uuid', 'nvram'):          # a new identity, and its own firmware vars file
    for e in r.iter(tag):
        (r if e in list(r) else r.find('os')).remove(e)
dev = r.find('devices')
for iface in dev.findall('interface'): # NO NETWORK: it must not collide with the live guest
    dev.remove(iface)
for d in dev.findall('disk'):
    tgt = d.find('target').get('dev')
    srcel = d.find('source')
    if tgt in targets and srcel is not None:
        srcel.set('file', f"{work}/{tgt}.qcow2")
    elif srcel is not None:            # a disk the backup did not cover - drop it, do not fake it
        dev.remove(d)
for c in dev.findall('console'):       # console mirrors serial; one file sink is enough
    dev.remove(c)
for sl in dev.findall('serial'):
    dev.remove(sl)
sl = ET.SubElement(dev, 'serial', {'type': 'file'})
ET.SubElement(sl, 'source', {'path': f"{work}/console.log"})
ET.SubElement(sl, 'target', {'port': '0'})
t.write(out)
PY
  virsh define "$xml" >/dev/null || die "virsh define failed for $tname"
  : > "$work/console.log"; chown "${QUSER}:${QGROUP}" "$work/console.log" 2>/dev/null || true
  virsh start "$tname" >/dev/null || { virsh undefine "$tname" --nvram >/dev/null 2>&1; die "$tname would not start"; }
  ok "$tname started - watching its console for a login prompt"

  # ---- did it actually come up? ------------------------------------------------------------
  local waited=0 booted=0 limit="${RESTORE_TEST_BOOT_WAIT:-300}"
  while [ "$waited" -lt "$limit" ]; do
    if grep -qE 'login:|Welcome to Ubuntu|systemd\[1\]: Startup finished' "$work/console.log" 2>/dev/null; then
      booted=1; break
    fi
    virsh domstate "$tname" 2>/dev/null | grep -q running || { warn "$tname stopped on its own"; break; }
    sleep 5; waited=$((waited+5))
  done
  t2="$(date +%s)"

  # ---- say what it proved, in the terms the control asks for -------------------------------
  local rpo_stamp="${rpo_src}" age_h
  age_h=$(( ( $(date +%s) - $(date -u -d "$(echo "$rpo_stamp" | sed -E 's/^(....)(..)(..)T(..)(..)(..)Z$/\1-\2-\3 \4:\5:\6 UTC/')" +%s 2>/dev/null || echo 0) ) / 3600 ))
  printf '\n'
  if [ "$booted" -eq 1 ]; then
    ok "RESTORE PROVEN: $dom rebuilt from ${#chain[@]} set(s) and booted"
  else
    warn "restored image did NOT reach a login prompt within ${limit}s - see $work/console.log"
  fi
  say "rebuild time : $((t1-t0))s   boot to login: $((t2-t1))s   total: $((t2-t0))s"
  say "data age     : newest set $rpo_stamp (~${age_h}h old) - this is the measured RPO"
  say "console log  : $work/console.log"

  local ev="${RESTORE_EVIDENCE_DIR:-/srv/stig-evidence}/restore-test-$dom-$STAMP.txt"
  install -d -m 0755 "$(dirname "$ev")" 2>/dev/null || true
  {
    printf 'restore test - %s\n' "$(date -u +%FT%TZ)"
    printf 'host=%s domain=%s target=%s\n' "$(hostname -s)" "$dom" "$tname"
    printf 'chain=%s\n' "${chain[*]}"
    printf 'disks=%s\n' "${targets[*]}"
    printf 'checksums=verified qemu_img_check=passed booted=%s\n' "$([ "$booted" -eq 1 ] && echo yes || echo NO)"
    printf 'rebuild_seconds=%s boot_seconds=%s total_seconds=%s\n' "$((t1-t0))" "$((t2-t1))" "$((t2-t0))"
    printf 'newest_set=%s approx_age_hours=%s\n' "$rpo_stamp" "$age_h"
  } > "$ev"
  [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$ev" 2>/dev/null
  ok "evidence: $ev"

  # ---- clean up. The test leaves nothing behind unless asked. ------------------------------
  if [ "$keep" -eq 1 ]; then
    warn "--keep: $tname is left DEFINED and RUNNING with no network. Remove it with:"
    say  "   virsh destroy $tname; virsh undefine $tname --nvram; rm -rf $work"
  else
    virsh destroy "$tname" >/dev/null 2>&1 || true
    virsh undefine "$tname" --nvram >/dev/null 2>&1 || true
    rm -rf "$work"
    ok "$tname removed and $work cleaned up"
  fi
  [ "$booted" -eq 1 ] || die "the restore did not boot - that is the finding, not a script error"
}

# ---------------------------------------------------------------- args
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="${2:-}"; shift 2 ;;
    --accept-unencrypted) ACCEPT_PLAIN=1; shift ;;
    --allow-non-mount) ALLOW_NONMOUNT=1; shift ;;
    --detach) DETACH=1; shift ;;
    --at) ARGS+=("${2:-}"); shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]:-}"

# A MULTI-HOUR COPY MUST NOT LIVE IN AN INTERACTIVE SHELL ON THIS MACHINE.
#
# The STIG sets TMOUT=600 readonly ("per security requirements"), and any dropped session
# SIGHUPs the foreground job. On 2026-09-14 a full backup died at ~125 GB of svc-repo-01's
# 331 GB for exactly that reason, leaving a partial set and a checkpoint pointing at a full
# that never finished - which a later incremental would have happily built on.
#
# --detach hands the work to systemd, which owns it instead of the terminal. Output goes to
# the journal, and it survives logout, TMOUT and a closed laptop lid.
if [ "$DETACH" -eq 1 ]; then
  need_root
  command -v systemd-run >/dev/null 2>&1 || die "systemd-run not available"
  self="$(readlink -f "$0")"
  unit="vm-backup-manual-$(date -u +%H%M%S)"
  systemd-run --unit="$unit" --description="manual VM backup: $*" \
    --property=Nice=10 --property=IOSchedulingClass=idle \
    --property=TimeoutStartSec=12h \
    "$self" "$@" >/dev/null 2>&1 \
    || die "could not start $unit"
  ok "running detached as $unit - this shell is free, and logout will not kill it"
  say "   watch:   journalctl -u $unit -f"
  say "   status:  systemctl status $unit"
  say "   stop:    systemctl stop $unit"
  exit 0
fi

# ---------------------------------------------------------------- facts
# PUBLISH THE BACKUP STATE AS METRICS, for node-exporter's textfile collector.
#
# This job runs unattended at 02:00 onto a USB disk that is LUKS-encrypted and sits behind a
# STIG usb-storage block. Every one of those is a way for it to stop working without anyone
# noticing, and the failure is only discovered when a restore is needed - which is the worst
# possible moment to discover it.
#
# `monitoring.sh facts` calls this; it is not on a timer of its own. vm-backup.sh owns the
# on-disk layout, so it is the thing that should read it - teaching monitoring.sh where a
# backup set lives would put that knowledge in two places.
#
# MANIFEST.sha256 IS THE COMPLETION MARKER. It is written only after every disk in a set has
# been copied (see backup_one), so a set directory WITHOUT one is an interrupted run - which
# is exactly what a TMOUT-killed full backup leaves behind. Counting directories would call
# that a success.
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"

cmd_facts() {
  need_root
  local out="$TEXTFILE_DIR/enclave-backup.prom" tmp
  [ -d "$TEXTFILE_DIR" ] || { warn "no $TEXTFILE_DIR - run: monitoring.sh exporter"; return 1; }
  tmp="$(mktemp "$TEXTFILE_DIR/.backup.XXXXXX")" || { warn "cannot write in $TEXTFILE_DIR"; return 1; }

  {
    printf '# HELP enclave_backup_source_ok 1 if the backup destination could be read\n'
    printf '# TYPE enclave_backup_source_ok gauge\n'
    printf '# HELP enclave_backup_dest_mounted 1 if the backup destination is a mounted filesystem\n'
    printf '# TYPE enclave_backup_dest_mounted gauge\n'

    local mounted=0
    [ -n "$DEST" ] && mountpoint -q "$DEST" 2>/dev/null && mounted=1
    printf 'enclave_backup_dest_mounted %s\n' "$mounted"

    # THE TIMER IS A FACT ABOUT THE SCHEDULE, NOT ABOUT THE DISK - report it either way.
    printf '# HELP enclave_backup_timer_enabled 1 if the nightly backup timer is active\n'
    printf '# TYPE enclave_backup_timer_enabled gauge\n'
    printf 'enclave_backup_timer_enabled %s\n' \
      "$(systemctl is-active "$SVC_NAME.timer" >/dev/null 2>&1 && echo 1 || echo 0)"

    # AN UNMOUNTED DESTINATION MUST NOT REPORT ZERO BACKUPS.
    # $DEST still exists as an empty directory when the USB volume is not attached, so
    # counting sets there would publish "0 complete sets" for every domain - identical to a
    # machine that has never been backed up, and identical to one whose backups were deleted.
    # Emit nothing per-domain instead; "No data" is the honest answer.
    if [ "$mounted" -ne 1 ]; then
      printf 'enclave_backup_source_ok 0\n'
      printf '# HELP enclave_backup_facts_generated_seconds unix time these facts were written\n'
      printf '# TYPE enclave_backup_facts_generated_seconds gauge\n'
      printf 'enclave_backup_facts_generated_seconds %s\n' "$(date +%s)"
      return 0
    fi
    printf 'enclave_backup_source_ok 1\n'

    printf '# HELP enclave_backup_dest_avail_bytes free space at the backup destination\n'
    printf '# TYPE enclave_backup_dest_avail_bytes gauge\n'
    printf 'enclave_backup_dest_avail_bytes %s\n' \
      "$(df -B1 --output=avail "$DEST" 2>/dev/null | tail -1 | tr -d ' ')"
    printf '# HELP enclave_backup_dest_size_bytes total size of the backup destination\n'
    printf '# TYPE enclave_backup_dest_size_bytes gauge\n'
    printf 'enclave_backup_dest_size_bytes %s\n' \
      "$(df -B1 --output=size "$DEST" 2>/dev/null | tail -1 | tr -d ' ')"

    printf '# HELP enclave_backup_last_success_seconds unix time of the newest COMPLETE backup set\n'
    printf '# TYPE enclave_backup_last_success_seconds gauge\n'
    printf '# HELP enclave_backup_last_attempt_seconds unix time of the newest set of any kind\n'
    printf '# TYPE enclave_backup_last_attempt_seconds gauge\n'
    printf '# HELP enclave_backup_sets_complete backup sets carrying a MANIFEST.sha256\n'
    printf '# TYPE enclave_backup_sets_complete gauge\n'
    printf '# HELP enclave_backup_sets_incomplete set directories with NO manifest - interrupted runs\n'
    printf '# TYPE enclave_backup_sets_incomplete gauge\n'
    printf '# HELP enclave_backup_last_set_bytes size of the newest complete set\n'
    printf '# TYPE enclave_backup_last_set_bytes gauge\n'
    printf '# HELP enclave_backup_checkpoints libvirt checkpoints - what an incremental builds on\n'
    printf '# TYPE enclave_backup_checkpoints gauge\n'
    printf '# HELP enclave_backup_job_active 1 if a backup job is running on this domain right now\n'
    printf '# TYPE enclave_backup_job_active gauge\n'

    local d dir newest_ok newest_any nc ni sz jt protected=0 defined=0 total=0
    for d in $(domains); do
      defined=$((defined + 1))

      # newest COMPLETE: the manifest's own mtime is when the set finished, which is the
      # number that matters - a set that began yesterday and finished today is today's.
      newest_ok="$(find "$DEST/$d" -mindepth 2 -maxdepth 2 -name MANIFEST.sha256 \
                    -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
      newest_any="$(find "$DEST/$d" -mindepth 1 -maxdepth 1 -type d \
                    -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)"
      nc="$(find "$DEST/$d" -mindepth 2 -maxdepth 2 -name MANIFEST.sha256 2>/dev/null | wc -l)"
      ni="$(( $(find "$DEST/$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) - nc ))"
      [ "$ni" -lt 0 ] && ni=0

      [ -n "$newest_ok" ] && { printf 'enclave_backup_last_success_seconds{domain="%s"} %s\n' "$d" "$newest_ok"; protected=$((protected + 1)); }
      [ -n "$newest_any" ] && printf 'enclave_backup_last_attempt_seconds{domain="%s"} %s\n' "$d" "$newest_any"
      printf 'enclave_backup_sets_complete{domain="%s"} %s\n'   "$d" "$nc"
      printf 'enclave_backup_sets_incomplete{domain="%s"} %s\n' "$d" "$ni"

      # SUM FILE SIZES, DO NOT `du` THE TREE. du walks and stats every block on a USB disk,
      # every 15 minutes, on a volume holding hundreds of GB. A set holds a handful of qcow2
      # files, so one stat each is the same answer for none of the cost.
      dir="$(find "$DEST/$d" -mindepth 2 -maxdepth 2 -name MANIFEST.sha256 \
              -printf '%T@ %h\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
      if [ -n "$dir" ]; then
        sz="$(find "$dir" -maxdepth 1 -type f -printf '%s\n' 2>/dev/null | awk '{t+=$1} END{print t+0}')"
        printf 'enclave_backup_last_set_bytes{domain="%s"} %s\n' "$d" "$sz"
        total=$((total + sz))
      fi

      printf 'enclave_backup_checkpoints{domain="%s"} %s\n' "$d" \
        "$(virsh checkpoint-list "$d" --name 2>/dev/null | sed '/^$/d' | wc -l)"

      # `virsh domjobinfo` PADS ITS FIELDS, and matching the line exactly once printed idle
      # domains as in-progress. Strip whitespace from the value, then compare.
      jt="$(virsh domjobinfo "$d" 2>/dev/null | awk -F: '/^Job type/{gsub(/[[:space:]]/,"",$2); print $2}')"
      printf 'enclave_backup_job_active{domain="%s"} %s\n' "$d" \
        "$([ -n "$jt" ] && [ "$jt" != None ] && echo 1 || echo 0)"
    done

    printf '# HELP enclave_backup_domains_defined domains libvirt knows about here\n'
    printf '# TYPE enclave_backup_domains_defined gauge\n'
    printf 'enclave_backup_domains_defined %s\n' "$defined"
    printf '# HELP enclave_backup_domains_protected domains with at least one COMPLETE set\n'
    printf '# TYPE enclave_backup_domains_protected gauge\n'
    printf 'enclave_backup_domains_protected %s\n' "$protected"
    printf '# HELP enclave_backup_total_bytes newest complete set summed across all domains\n'
    printf '# TYPE enclave_backup_total_bytes gauge\n'
    printf 'enclave_backup_total_bytes %s\n' "$total"
    printf '# HELP enclave_backup_facts_generated_seconds unix time these facts were written\n'
    printf '# TYPE enclave_backup_facts_generated_seconds gauge\n'
    printf 'enclave_backup_facts_generated_seconds %s\n' "$(date +%s)"
  } > "$tmp"

  if [ ! -s "$tmp" ]; then rm -f "$tmp"; warn "backup facts produced NO output - $out left alone"; return 1; fi
  chmod 0644 "$tmp"; mv -f "$tmp" "$out"
  ok "wrote $out ($(grep -vc '^#' "$out") samples)"
}

case "${1:-status}" in
  status)       cmd_status ;;
  facts)        cmd_facts ;;
  full)         shift || true; cmd_backup full "${1:-all}" ;;
  incr)         shift || true; cmd_backup incr "${1:-all}" ;;
  progress)     cmd_progress ;;
  # `shift || true; ... "$@"` IS LOAD-BEARING, NOT STYLE. Both of these read `verify)
  # cmd_verify ;;` until 2026-09-17, so the flags never reached the functions that parse
  # them - and because the functions only `die` on an argument they do not recognise, an
  # argument that never arrives is silent. Two live consequences, both found by running them:
  #
  #   verify --all   re-read NOTHING, ever. It skipped every set on its stamps and finished in
  #                  0.277s. The weekly deep verify - the ONLY thing that can catch silent
  #                  decay, because decay does not change an mtime - had never read a byte.
  #   prune --dry-run  WAS NOT A DRY RUN. It was a live prune. It freed 0B only because
  #                  nothing needed pruning; on a different chain state this is the same
  #                  function that has already deleted every full backup in this enclave once.
  #
  # If a subcommand takes arguments, forward them. If it takes none, do not add a shift.
  verify)       shift || true; cmd_verify "$@" ;;
  prune)        shift || true; cmd_prune "$@" ;;
  keyfile)      cmd_keyfile ;;
  reattach)     cmd_reattach ;;
  schedule)     shift || true; cmd_schedule "${1:-02:00}" ;;
  unschedule)   cmd_unschedule ;;
  restore-plan) shift || true; cmd_restore_plan "${1:-}" ;;
  restore-test) shift || true; cmd_restore_test "$@" ;;
  *) printf 'usage: %s {status|facts|full [vm]|incr [vm]|progress|verify [--all]|prune [--dry-run]|keyfile|reattach|schedule [HH:MM]|unschedule|restore-plan <vm>|restore-test <vm> [--set S] [--keep] [-n]}\n' "$0" >&2; exit 2 ;;
esac
