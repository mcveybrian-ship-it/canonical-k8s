#!/usr/bin/env bash
#
# 01 — Hardware inventory capture.
#
# Run on the bare-metal pathfinder machine during step 01. Collects the facts needed to fill
# in the step 02 autoinstall template, plus a baseline hardware record for the ATO package.
#
# Two things here directly resolve [VERIFY] markers in 02-host-autoinstall/user-data:
#   * disk serials   -> replaces 'match: {size: smallest}' if disks are identically sized
#   * interface name -> replaces REPLACE-ME-interface in the network block
#
# Usage:
#   sudo ./01-hw-inventory.sh [-o REPORT]
#
set -uo pipefail

REPORT="hw-inventory-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).txt"
while getopts ":o:h" opt; do
  case "$opt" in
    o) REPORT="$OPTARG" ;;
    h) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run with sudo — some probes need root" >&2; exit 1; }
exec > >(tee "$REPORT") 2>&1

rule() { printf '\n%s\n%s\n' "$1" "$(printf '=%.0s' $(seq ${#1}))"; }

rule "Hardware inventory — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hostname: $(hostname)"
echo "release:  $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "kernel:   $(uname -r)"

rule "System identity"
for f in sys_vendor product_name product_serial board_name; do
  printf '%-16s %s\n' "$f:" "$(cat "/sys/class/dmi/id/$f" 2>/dev/null || echo n/a)"
done

rule "CPU and memory"
lscpu | grep -E '^(Model name|Socket|Core|Thread|CPU\(s\)):' || true
echo
free -h

rule "Firmware mode"
if [[ -d /sys/firmware/efi ]]; then
  echo "boot mode: UEFI"
else
  echo "boot mode: BIOS/legacy  <-- the autoinstall template assumes UEFI (ESP + grub_device)"
fi
if command -v mokutil >/dev/null; then
  mokutil --sb-state 2>/dev/null || echo "secure boot: could not read"
else
  echo "secure boot: mokutil not installed (apt install mokutil)"
fi

# ---------------------------------------------------------------------------- disks --------
rule "Disks — for the autoinstall storage 'match' block"
lsblk -d -o NAME,SIZE,ROTA,TYPE,MODEL,SERIAL
echo
echo "-- stable by-id paths (prefer these over device names, which are not stable) --"
ls -l /dev/disk/by-id/ 2>/dev/null | grep -vE 'part[0-9]|dm-|lvm-' | awk '{print $9, "->", $11}'

echo
echo "-- sizes in bytes, smallest first --"
lsblk -b -d -n -o NAME,SIZE,MODEL | sort -k2 -n

# Candidate install targets only: real disks, non-removable, not USB, not loop/ram devices.
# Counting raw 'lsblk -d' output is wrong - it includes snap loop devices and the USB stick
# you booted from, so the "smallest" is not the disk you meant.
echo
echo "-- candidate install targets (fixed, non-removable disks only) --"
CANDIDATES=$(lsblk -b -d -n -o NAME,SIZE,RM,TYPE,TRAN   | awk '$4=="disk" && $3==0 && $5!="usb" {print $2, $1}' | sort -n)
if [[ -z "$CANDIDATES" ]]; then
  echo "  none found - check the disk table above by hand"
else
  echo "$CANDIDATES" | awk '{printf "  %-12s %s bytes
", $2, $1}'
fi

SMALLEST_SIZE=$(echo "$CANDIDATES" | head -1 | awk '{print $1}')
SMALLEST_NAME=$(echo "$CANDIDATES" | head -1 | awk '{print $2}')
SMALLEST_COUNT=$(echo "$CANDIDATES" | awk -v s="$SMALLEST_SIZE" '$1==s' | wc -l)
TOTAL_CANDIDATES=$(echo "$CANDIDATES" | grep -c . || echo 0)

echo
if [[ "${TOTAL_CANDIDATES:-0}" -lt 2 ]]; then
  echo "Only one fixed disk. 'match: {size: smallest}' is unambiguous, but with a single disk"
  echo "there is nothing to protect from - the NVMe for Ceph OSDs must be a SEPARATE device."
elif [[ "${SMALLEST_COUNT:-0}" -gt 1 ]]; then
  echo "!! WARNING: $SMALLEST_COUNT fixed disks share the smallest size ($SMALLEST_SIZE bytes)."
  echo "!! 'match: {size: smallest}' is AMBIGUOUS here and could wipe the wrong device."
  echo "!! Use an explicit serial instead - see the by-id table above:"
  echo "!!     match: {serial: \"<serial>\"}"
else
  echo "Smallest fixed disk is /dev/$SMALLEST_NAME ($SMALLEST_SIZE bytes) and it is unique."
  echo
  echo "!! Confirm this is really your intended OS disk before trusting 'size: smallest'."
  echo "!! It selects the smallest FIXED disk - which may hold an existing OS you care about."
  echo "!! For production hosts, prefer an explicit serial from the by-id table above:"
  echo "!!     match: {serial: \"<serial>\"}"
fi

echo
echo "-- NVMe detail (these must survive the host install RAW for Ceph OSDs) --"
if command -v nvme >/dev/null; then
  nvme list 2>/dev/null
else
  echo "nvme-cli not installed (apt install nvme-cli)"
  lsblk -d -o NAME,SIZE,MODEL | grep -i nvme || echo "no nvme devices seen by lsblk"
fi

echo
echo "-- existing partitions / filesystems (should be empty or scratch on a pathfinder) --"
lsblk -f

echo
echo "-- hardware RAID check --"
lspci 2>/dev/null | grep -iE 'raid|megaraid|smart array' \
  && echo "!! RAID controller present. Ceph wants bare devices — confirm HBA/JBOD passthrough." \
  || echo "no RAID controller seen on the PCI bus"

# ---------------------------------------------------------------------------- network ------
rule "Network — for the autoinstall network block"
ip -br link
echo
echo "-- predictable names, MACs and current addresses --"
for i in $(ls /sys/class/net | grep -v '^lo$'); do
  printf '%-12s mac=%-18s state=%-6s speed=%s\n' \
    "$i" \
    "$(cat "/sys/class/net/$i/address" 2>/dev/null)" \
    "$(cat "/sys/class/net/$i/operstate" 2>/dev/null)" \
    "$(cat "/sys/class/net/$i/speed" 2>/dev/null || echo n/a)"
done
echo
ip -br a
echo
echo "-- default route --"
ip route show default || echo "no default route"

# ---------------------------------------------------------------------------- summary ------
rule "Values to paste into 02-host-autoinstall/user-data"
PRIMARY_IF="$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)"
echo "REPLACE-ME-interface   ->  ${PRIMARY_IF:-<no default route; pick from the list above>}"
echo "REPLACE-ME-address     ->  from the runbook section 3 IP plan"
echo "REPLACE-ME-gateway     ->  $(ip route show default 2>/dev/null | awk '{print $3}' | head -1 || echo '<from IP plan>')"
echo "REPLACE-ME-dns         ->  from the IP plan (enclave DNS, not a public resolver)"
echo "REPLACE-ME-hostname    ->  h1 | h2 | h3"
echo
echo "storage match block    ->  see the disk warning above"

rule "Reminder"
cat <<'EOF'
This machine is a PATHFINDER. Once you have run usg fix on it, it is no longer a fresh
install and must not become a production host without a wipe and rebuild. See
docs/02-host-install.md section 1.

Keep this report — it is the hardware baseline for the ATO package, and it is what you
diff against when a host is replaced.
EOF

echo
echo "Report written to: $REPORT"
