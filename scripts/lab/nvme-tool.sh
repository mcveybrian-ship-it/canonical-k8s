#!/usr/bin/env bash
# =========================================================================================
# nvme-tool.sh - vet a drive before it goes into the lab NAS - NVMe or SATA, in a slot, on a port
# or behind USB: health, self-test, a full read, and a wipe of whatever its last owner left on it.
# LAB ONLY (docs/lab-network.md 9.3) - not part of the product. The name is from before SATA
# support (2026-10-06); it is kept so the commands already in the docs still work.
#
#     MACHINE: build-01. Linux only: it drives nvme-cli, smartctl, hdparm and the kernel's block
#     layer. There is no Windows version; the NAS's TrueNAS shell has the same tools if a drive is
#     tested there instead.
#
#     sudo ./nvme-tool.sh list                          every NVMe and SATA drive - slot, port or USB -
#                                                       and every disk this script will never wipe
#     sudo ./nvme-tool.sh health   <dev>                SMART health + "is it really new?"
#     sudo ./nvme-tool.sh selftest <dev> [short|long]   the drive's own self-test
#     sudo ./nvme-tool.sh readtest <dev>                read every block, report errors and speed
#     sudo ./nvme-tool.sh wipe     <dev> [--method M]   destroy everything on it (asks for the serial)
#     sudo ./nvme-tool.sh full     <dev>                health -> short self-test -> wipe -> health
#
#   <dev>: nvme0 / nvme0n1 / /dev/nvme0n1 for an NVMe drive in an M.2 slot; sdb / /dev/sdb for a
#   SATA drive (on a port or a USB adapter) or an NVMe drive in a USB enclosure - the script asks
#   the bridge which it is. Reports: $NVME_REPORT_DIR/<serial>-<time>-<command>.txt
#
# NVMe IN A USB ENCLOSURE (2026-09-29 - the first PM9A1 arrived in an RTL9210 enclosure on build-01):
#   The bridge passes SMART reads (smartctl -d sntrealtek / sntjmicron / sntasmedia), so health
#   and the read test work. It does NOT pass the admin commands a secure erase needs - NVMe
#   sanitize and format need an M.2 slot. Over USB the wipe OVERWRITES every block with zeros
#   (--method overwrite, the default there) or discards it (--method discard). A USB 2 link
#   (480 Mb/s, ~40 MB/s) makes a 2 TB read or overwrite ~14 hours: the script says so first.
#
# SATA (2026-10-06 - two Samsung MZ7LH3T8HMLT 3.84 TB SSDs on a USB-SATA adapter on build-01):
#   smartctl -d sat reaches the drive through the adapter (the SMART read passed that day). The
#   adapter does NOT hand back the ATA output registers - smartctl says "SMART Status not
#   supported: ... ATA output registers missing" and judges the overall status from the
#   attributes instead; the report says which basis it used. Health reads the Device Statistics
#   log first (Percentage Used, sectors written and read) and the vendor attributes second, and
#   reports every error counter - reallocated, pending, uncorrectable, interface CRC. A counter
#   the drive does not report is said to be missing, never shown as zero. A spinning disk gets
#   the same checks without the wear line.
#   Over USB the wipe overwrites (default) or discards. ATA SANITIZE (--method block|crypto, via
#   hdparm) runs only on a native SATA port: a sanitize reports its progress and its result in
#   those same output registers, so through a bridge the script could not tell a finished erase
#   from one that never ran. ATA Security Erase is deliberately not offered: it sets a drive
#   password first, and an interruption leaves the drive locked behind that password.
#   NOT YET RUN ON A REAL SATA DRIVE: both Samsungs went into the NAS before it was tried
#   (2026-10-13). It is fixture-tested only - health against those drives' own smartctl numbers,
#   the self-test and wipe paths with stubs. Treat its first real run as its test.
#
# WHAT WIPE REFUSES, BEFORE ANYTHING ELSE, and again after the serial is typed: a disk under /,
#   /boot or /boot/efi (resolved through LUKS and LVM, not by partition name), a disk with any
#   mounted filesystem, swap, or a holder anywhere on it (an open LUKS mapping, LVM, md). On
#   build-01 that is sda (the system) and nvme0n1 (/srv/bundle). A drive that reports no serial
#   is refused too - there would be nothing to confirm against.
#
# Parameters (environment): NVME_REPORT_DIR (./nvme-reports), NVME_MAX_USED_PCT (10 - the NAS
#   plan's return limit), NVME_NEW_MAX_HOURS (48), NVME_NEW_MAX_GB (200), NVME_NEW_MAX_CYCLES (30),
#   NVME_NEW_MAX_UNSAFE (10), NVME_HOT_C (70), NVME_SELFTEST_MAX_MIN (240 - raised to twice the
#   drive's own estimate when that is longer). The NVME_ names apply to SATA drives too.
#
# Requires nvme-cli, smartmontools 7.3+, jq, util-linux - all on build-01 (checked 2026-09-29);
#   hdparm only for a sanitize on a native SATA port (apt install hdparm).
# Adapted 2026-09-29 from a script brought in that day: USB enclosures, the guards above, no
# swallowed errors, parameters.
# =========================================================================================
set -uo pipefail

NVME_REPORT_DIR="${NVME_REPORT_DIR:-./nvme-reports}"
NVME_MAX_USED_PCT="${NVME_MAX_USED_PCT:-10}"
NVME_NEW_MAX_HOURS="${NVME_NEW_MAX_HOURS:-48}"
NVME_NEW_MAX_GB="${NVME_NEW_MAX_GB:-200}"
NVME_NEW_MAX_CYCLES="${NVME_NEW_MAX_CYCLES:-30}"
NVME_NEW_MAX_UNSAFE="${NVME_NEW_MAX_UNSAFE:-10}"
NVME_HOT_C="${NVME_HOT_C:-70}"
NVME_SELFTEST_MAX_MIN="${NVME_SELFTEST_MAX_MIN:-240}"
BRIDGES="sntrealtek sntjmicron sntasmedia"   # smartctl -d types for NVMe behind USB
ATA_BRIDGES="sat sat,12"                       # ... and for SATA behind USB

RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; BLD=$'\e[1m'; RST=$'\e[0m'
[[ -t 1 ]] || { RED=; YEL=; GRN=; BLD=; RST=; }

die()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }
ok()   { echo "  ${GRN}[ OK ]${RST} $*"; }
warn() { echo "  ${YEL}[WARN]${RST} $*"; WARNS=$((WARNS+1)); }
bad()  { echo "  ${RED}[FAIL]${RST} $*"; FAILS=$((FAILS+1)); }
info() { echo "  [info] $*"; }
hdr()  { echo; echo "${BLD}== $* ==${RST}"; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

WARNS=0; FAILS=0

check_deps() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo)"
  local missing=() c
  for c in nvme smartctl jq lsblk blockdev blkdiscard dd findmnt numfmt; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]}  (apt install nvme-cli smartmontools jq)"
}

human_bytes() { numfmt --to=si --round=nearest --format='%.2f' --suffix=B "$1" 2>/dev/null || echo "$1 B"; }   # nearest: the default rounds 24.2 TB up to 25

# probe_type /dev/sdX PROTOCOL TYPE... -> the first smartctl -d type that reaches a drive speaking
# PROTOCOL (NVMe or ATA) behind this USB bridge. A probe: every type but the right one fails, so its
# errors are not the answer - the die says what to run to see them.
probe_type() {
  local dev=$1 want=$2 t j; shift 2
  for t in "$@"; do
    j=$(smartctl -i -j -d "$t" "$dev" 2>/dev/null)
    [[ "$(jq -r '.device.protocol // empty' <<<"$j" 2>/dev/null)" == "$want" ]] && { echo "$t"; return 0; }
  done
  return 1
}
# shellcheck disable=SC2086   # the type lists split on spaces by design
bridge_type() { probe_type "$1" NVMe $BRIDGES; }
# shellcheck disable=SC2086
ata_type()    { probe_type "$1" ATA $ATA_BRIDGES; }

# Sets PROTO (nvme|ata), KIND (nvme = M.2 slot | usb | sata = native SATA port), WHERE (the two in
# words), CTRL (M.2 only), NS (the block device), DISK (its kernel name), SMART (the smartctl
# arguments that reach the drive), ID_JSON (M.2 only), MODEL SERIAL FW.
resolve_dev() {
  local in="${1:-}" t j tran
  [[ -n $in ]] || die "no device given (try: $0 list)"
  if [[ $in =~ ^(/dev/)?(nvme[0-9]+)(n[0-9]+)?(p[0-9]+)?$ ]]; then
    PROTO=nvme; KIND=nvme; WHERE="NVMe, M.2 slot"
    CTRL="/dev/${BASH_REMATCH[2]}"; NS="/dev/${BASH_REMATCH[2]}${BASH_REMATCH[3]:-n1}"
    [[ -c $CTRL ]] || die "$CTRL not found"
    [[ -b $NS ]]   || die "$NS not found"
    ID_JSON=$(nvme id-ctrl "$CTRL" -o json 2>&1) || die "nvme id-ctrl failed on $CTRL: $ID_JSON"
    SMART=("$CTRL")
  elif [[ $in =~ ^(/dev/)?(sd[a-z]+)[0-9]*$ ]]; then
    CTRL=""; ID_JSON="{}"; NS="/dev/${BASH_REMATCH[2]}"
    [[ -b $NS ]] || die "$NS not found"
    tran=$(lsblk -dno TRAN "$NS")
    case $tran in
      usb)
        KIND=usb
        if   t=$(bridge_type "$NS"); then PROTO=nvme; WHERE="NVMe, USB enclosure"
        elif t=$(ata_type "$NS");    then PROTO=ata;  WHERE="SATA, USB adapter"
        else die "no NVMe or SATA drive answers through the USB bridge on $NS (tried $BRIDGES $ATA_BRIDGES) - 'smartctl -i -d auto $NS' shows what it does see"
        fi
        SMART=(-d "$t" "$NS") ;;
      sata)
        PROTO=ata; KIND=sata; WHERE="SATA, native port"; SMART=(-d sat "$NS")
        j=$(smartctl -i -j "${SMART[@]}" 2>/dev/null)
        [[ "$(jq -r '.device.protocol // empty' <<<"$j" 2>/dev/null)" == ATA ]] \
          || die "$NS is on a SATA port but does not answer as an ATA drive - 'smartctl -i $NS' shows what it does see" ;;
      *)
        die "$NS is on '${tran:-unknown}', not USB or SATA - this tool takes NVMe and SATA drives" ;;
    esac
  else
    die "not an NVMe or sdX disk name: $in (try: $0 list)"
  fi
  DISK="$(basename "$NS")"
  j=$(smartctl -i -j "${SMART[@]}" 2>/dev/null)
  MODEL=$(jq -r '.model_name // "?"' <<<"$j" | xargs)
  SERIAL=$(jq -r '.serial_number // "?"' <<<"$j" | xargs)
  FW=$(jq -r '.firmware_version // "?"' <<<"$j" | xargs)
}

start_report() {
  mkdir -p "$NVME_REPORT_DIR" || die "cannot create $NVME_REPORT_DIR"
  REPORT="$NVME_REPORT_DIR/${SERIAL// /_}-$(date +%Y%m%d-%H%M%S)-$1.txt"
  exec > >(tee -a "$REPORT") 2>&1
  echo "nvme-tool report - $(date)"
  echo "Device: $NS (${WHERE}${CTRL:+, controller $CTRL}, smartctl ${SMART[*]})  Model: $MODEL  Serial: $SERIAL  FW: $FW"
}

# ---------------------------------------------------------------- what may never be wiped
system_disks() {   # every disk under / /boot /boot/efi, through LUKS and LVM
  local m src
  for m in / /boot /boot/efi; do
    src=$(findmnt -no SOURCE "$m" 2>/dev/null) || continue
    lsblk -s -l -no NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}'
  done | sort -u
}

# in_use_reason DISK -> why it must not be wiped, or nothing
in_use_reason() {
  local disk="$1" p h mnts s
  system_disks | grep -qx "$disk" && { echo "it holds the running system (/, /boot or /boot/efi)"; return; }
  mnts=$(lsblk -no MOUNTPOINTS "/dev/$disk" 2>/dev/null | grep -v '^$' | tr '\n' ' ')
  [[ -n $mnts ]] && { echo "mounted: $mnts"; return; }
  for p in "/sys/block/$disk" "/sys/block/$disk/$disk"*; do
    [[ -d $p/holders ]] || continue
    h=$(ls "$p/holders" 2>/dev/null | tr '\n' ' ')
    [[ -n $h ]] && { echo "$(basename "$p") is held by ${h}- an open LUKS mapping, LVM or md"; return; }
  done
  while read -r s _; do
    [[ $s == /dev/* ]] || continue
    lsblk -s -l -no NAME,TYPE "$s" 2>/dev/null | awk '$2=="disk"{print $1}' | grep -qx "$disk" && { echo "swap is on it"; return; }
  done < /proc/swaps
}

# ---------------------------------------------------------------- the USB link
usb_speed() {   # link speed in Mb/s of the USB device holding $DISK
  local d; d=$(readlink -f "/sys/block/$DISK/device")
  while [[ $d != / && ! -f $d/speed ]]; do d=$(dirname "$d"); done
  [[ -f $d/speed ]] && cat "$d/speed"
}
link_check() {
  [[ $KIND == usb ]] || return 0
  local s size; s=$(usb_speed); size=$(blockdev --getsize64 "$NS")
  if [[ -z $s ]]; then info "USB link speed: unknown"
  elif (( ${s%.*} < 5000 )); then
    warn "USB 2 link (${s} Mb/s, ~40 MB/s): reading or writing all $(human_bytes "$size") takes ~$(( size / 40000000 / 3600 )) h - move the enclosure or adapter to a USB 3 port (blue or red) first"
  else ok "USB link ${s} Mb/s"; fi
}

# ---------------------------------------------------------------- list
list_line() {   # list_line DEV NOTE SMARTCTL-ARGS...
  local dev=$1 note=$2 j; shift 2
  j=$(smartctl -i -j "$@" 2>/dev/null)
  printf '  %-10s %-28s serial %-20s %s\n' "$dev" "$(jq -r '.model_name // "?"' <<<"$j")" \
    "$(jq -r '.serial_number // "?"' <<<"$j")" "$note"
}

cmd_list() {
  local d t what
  hdr "NVMe drives in M.2 slots"
  nvme list 2>&1 || true
  hdr "Drives behind USB - NVMe enclosures and SATA adapters"
  local found=0
  for d in $(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1}'); do
    if   t=$(bridge_type "/dev/$d"); then what=NVMe
    elif t=$(ata_type "/dev/$d");    then what=SATA
    else info "/dev/$d answers neither as NVMe nor as SATA (a flash stick, or a bridge smartctl cannot see through)"; continue
    fi
    DISK=$d
    list_line "/dev/$d" "$what via $t, USB link $(usb_speed || echo '?') Mb/s" -d "$t" "/dev/$d"
    found=1
  done
  (( found )) || info "none"
  hdr "SATA drives on native ports"
  found=0
  for d in $(lsblk -dno NAME,TRAN | awk '$2=="sata"{print $1}'); do
    list_line "/dev/$d" "SATA port" -d sat "/dev/$d"; found=1
  done
  (( found )) || info "none"
  hdr "All disks"
  lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINTS
  hdr "Never wiped by this script"
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    t=$(in_use_reason "$d"); [[ -n $t ]] && printf '  /dev/%-8s %s\n' "$d" "$t"
  done
}

# ---------------------------------------------------------------- health
cmd_health() {
  [[ $PROTO == ata ]] && { health_ata; return; }
  hdr "Health: $MODEL ($SERIAL)"
  local j; j=$(smartctl -a -j "${SMART[@]}" 2>&1)
  jq -e . >/dev/null 2>&1 <<<"$j" || { echo "$j" | head -20 | sed 's/^/     /'; die "smartctl did not return JSON for ${SMART[*]} - its answer is above"; }
  local L='.nvme_smart_health_information_log'
  g() { jq -r "$L.$1 // empty" <<<"$j"; }

  local passed cw temp spare spare_th used dur duw poh pcyc unsafe merr elog cap
  passed=$(jq -r '.smart_status.passed // empty' <<<"$j")
  cw=$(g critical_warning); temp=$(g temperature)
  spare=$(g available_spare); spare_th=$(g available_spare_threshold)
  used=$(g percentage_used); dur=$(g data_units_read); duw=$(g data_units_written)
  poh=$(g power_on_hours); pcyc=$(g power_cycles); unsafe=$(g unsafe_shutdowns)
  merr=$(g media_errors); elog=$(g num_err_log_entries)
  cap=$(jq -r '.user_capacity.bytes // .nvme_total_capacity // empty' <<<"$j")

  [[ -n $cw ]] || { jq -r '.smartctl.messages[]?.string' <<<"$j" | sed 's/^/     /'; die "no NVMe health log in smartctl's answer (above)"; }
  : "${temp:=0}" "${spare:=100}" "${spare_th:=0}" "${used:=0}" "${dur:=0}" "${duw:=0}" \
    "${poh:=0}" "${pcyc:=0}" "${unsafe:=0}" "${merr:=0}" "${elog:=0}"

  local wbytes=$(( ${duw%.*} * 512000 )) rbytes=$(( ${dur%.*} * 512000 ))   # 1 data unit = 512,000 bytes
  printf '  %-22s %s\n' "Capacity" "$(human_bytes "${cap:-0}")" \
    "Temperature" "${temp} C" "Percentage used" "${used}%" \
    "Available spare" "${spare}% (threshold ${spare_th}%)" \
    "Data written" "$(human_bytes $wbytes)" "Data read" "$(human_bytes $rbytes)" \
    "Power-on hours" "$poh" "Power cycles" "$pcyc" "Unsafe shutdowns" "$unsafe" \
    "Media errors" "$merr" "Error log entries" "$elog"
  echo

  [[ $passed == false ]] && bad "SMART overall status: FAILED" || ok "SMART overall status: PASSED"
  if (( cw != 0 )); then
    local w=()
    ((cw & 1))  && w+=("spare below threshold")
    ((cw & 2))  && w+=("temperature out of range")
    ((cw & 4))  && w+=("reliability degraded")
    ((cw & 8))  && w+=("read-only mode")
    ((cw & 16)) && w+=("volatile backup failed")
    bad "Critical warning 0x$(printf %02x "$cw"): ${w[*]}"
  else ok "No critical warnings"; fi
  (( merr > 0 )) && bad "Media/data integrity errors: $merr - return it" || ok "No media errors"
  (( spare < spare_th )) && bad "Available spare below threshold" \
    || { (( spare < 100 )) && warn "Available spare is ${spare}% (new drives are 100%)" || ok "Spare at 100%"; }
  if   (( used > NVME_MAX_USED_PCT )); then bad "Wear ${used}% - above the ${NVME_MAX_USED_PCT}% the NAS plan accepts: return it"
  elif (( used > 0 )); then warn "Wear ${used}% - used, within the ${NVME_MAX_USED_PCT}% limit"
  else ok "Wear 0%"; fi
  (( temp >= NVME_HOT_C )) && warn "Running hot (${temp} C)"
  (( elog > 0 )) && info "Error log has $elog entries (often harmless host/driver noise${CTRL:+; see: nvme error-log $CTRL})"

  new_check "$poh" "$wbytes" "$pcyc" "$unsafe"

  local st; st=$(jq -r '.nvme_self_test_log.table[0] | select(.) | "\(.self_test_code.string): \(.self_test_result.string) at \(.power_on_hours)h"' <<<"$j" 2>/dev/null)
  [[ -n $st ]] && info "Last self-test: $st"
  link_check
}

# new_check POWER_ON_HOURS BYTES_WRITTEN POWER_CYCLES [UNSAFE_SHUTDOWNS] - the counters a new drive
# cannot have. An empty UNSAFE is a drive that does not count them.
new_check() {
  hdr "Is it really new?"
  local poh=$1 gb=$(( $2 / 1000000000 )) pcyc=$3 unsafe=${4:-} parts suspect=0
  (( poh > NVME_NEW_MAX_HOURS ))     && { warn "Power-on hours = $poh (new drives are usually < 10)"; suspect=1; }
  (( gb > NVME_NEW_MAX_GB ))         && { warn "${gb} GB already written (new drives: a few GB from factory testing)"; suspect=1; }
  (( pcyc > NVME_NEW_MAX_CYCLES ))   && { warn "Power cycles = $pcyc"; suspect=1; }
  [[ -n $unsafe ]] && (( unsafe > NVME_NEW_MAX_UNSAFE )) && { warn "Unsafe shutdowns = $unsafe"; suspect=1; }
  parts=$(lsblk -nro NAME "$NS" | tail -n +2 | wc -l)
  (( parts > 0 )) && { warn "It carries $parts partition(s) from a previous life - someone's data; wipe it before use"; suspect=1; }
  (( suspect == 0 )) && ok "Usage counters look consistent with a new drive"
}

# The facts health_ata judges, one "key<TAB>value" per line; a fact the drive does not report is
# left out, so the shell sees it as missing rather than zero. Device Statistics (ACS, the same on
# every vendor) come first; vendor attributes are the fallback, matched by the name smartctl's
# drive database gives them, because the same attribute number means different things per vendor.
# shellcheck disable=SC2016   # $-names are jq variables, not shell ones
ATA_FACTS='
def ds($n):  [.ata_device_statistics.pages[]?.table[]? | select(.name == $n and (.flags.valid // false)) | .value][0];
def raw($n): [.ata_smart_attributes.table[]? | select(.name == $n) | .raw.value][0];
def aid($i): [.ata_smart_attributes.table[]? | select(.id == $i) | .raw.value][0];
def most(a): [a | select(. != null)] | max;
def nz:      if . == "" then null else . end;
(ds("Percentage Used Endurance Indicator")) as $du
| ([.ata_smart_attributes.table[]? | select(.name | IN("Wear_Leveling_Count", "Media_Wearout_Indicator", "SSD_Life_Left", "Percent_Lifetime_Remain"))
    | select(.value != null and .value <= 100)][0]) as $wa
| ([.ata_smart_attributes.table[]? | select(.name | IN("Unexpect_Power_Loss_Ct", "POR_Recovery_Count", "Unsafe_Shutdown_Count"))][0]) as $us
| ((.ata_smart_self_test_log.extended.table // .ata_smart_self_test_log.standard.table // [])[0]) as $st
| {
    attrs:     (.ata_smart_attributes.table // [] | length),
    passed:    .smart_status.passed,
    basis:     (if any(.smartctl.messages[]?.string; test("based on an Attribute check")) then "attributes" else null end),
    cap:       .user_capacity.bytes,
    lbs:       .logical_block_size,
    rpm:       .rotation_rate,
    temp:      .temperature.current,
    tmax:      .temperature.lifetime_max,
    used:      (if $du != null then $du elif $wa != null then 100 - $wa.value else null end),
    used_src:  (if $du != null then "Device Statistics" elif $wa != null then "\($wa.name), normalized \($wa.value)" else null end),
    wsec:      (ds("Logical Sectors Written") // raw("Total_LBAs_Written")),
    rsec:      (ds("Logical Sectors Read") // raw("Total_LBAs_Read")),
    poh:       .power_on_time.hours,
    pcyc:      .power_cycle_count,
    unsafe:    $us.raw.value,
    unsafe_n:  $us.name,
    realloc:   aid(5),
    pending:   aid(197),
    offunc:    aid(198),
    unc:       most(ds("Number of Reported Uncorrectable Errors"), aid(187)),
    crc:       most(ds("Number of Interface CRC Errors"), aid(199)),
    badblk:    ([.ata_smart_attributes.table[]? | select(.name | IN("Reallocated_Event_Count", "Used_Rsvd_Blk_Cnt_Tot",
                 "Used_Rsvd_Blk_Cnt_Chip", "Runtime_Bad_Block", "Program_Fail_Cnt_Total", "Program_Fail_Count",
                 "Erase_Fail_Count_Total", "Erase_Fail_Count")) | select(.raw.value > 0) | "\(.name)=\(.raw.value)"] | join(", ") | nz),
    fail_now:  ([.ata_smart_attributes.table[]? | select(.when_failed == "now") | "\(.id) \(.name) (value \(.value), threshold \(.thresh))"] | join("; ") | nz),
    fail_past: ([.ata_smart_attributes.table[]? | select(.when_failed == "past") | "\(.id) \(.name)"] | join("; ") | nz),
    errlog:    (.ata_smart_error_log.extended.count // .ata_smart_error_log.summary.count),
    lasttest:  (if $st then "\($st.type.string): \($st.status.string) at \($st.lifetime_hours)h" else null end)
  }
| to_entries[] | select(.value != null) | "\(.key)\t\(.value)"'

health_ata() {
  hdr "Health: $MODEL ($SERIAL)"
  # -x, not -a: the Device Statistics log and the SCT temperature are only read by -x
  local j; j=$(smartctl -x -j "${SMART[@]}" 2>&1)
  jq -e . >/dev/null 2>&1 <<<"$j" || { echo "$j" | head -20 | sed 's/^/     /'; die "smartctl did not return JSON for ${SMART[*]} - its answer is above"; }
  local -A v; local k val facts
  facts=$(jq -r "$ATA_FACTS" <<<"$j" 2>&1) || { echo "$facts" | sed 's/^/     /'; die "could not read the facts out of smartctl's answer (jq's error above)"; }
  while IFS=$'\t' read -r k val; do [[ -n $k ]] && v[$k]=$val; done <<<"$facts"
  (( ${v[attrs]:-0} > 0 )) || { jq -r '.smartctl.messages[]?.string' <<<"$j" | sed 's/^/     /'; die "no SMART attributes in smartctl's answer (above)"; }

  local lbs=${v[lbs]:-512} temp=${v[temp]:-} used=${v[used]:-} poh=${v[poh]:-0} pcyc=${v[pcyc]:-0}
  local ssd=1; [[ -n ${v[rpm]:-} && ${v[rpm]} != 0 ]] && ssd=0
  local wbytes=0 s_wr="not reported" s_rd="not reported" s_used="not reported" s_tmp="not reported" s_us="not counted"
  [[ -n ${v[wsec]:-} ]] && { wbytes=$(( ${v[wsec]} * lbs )); s_wr=$(human_bytes "$wbytes"); }
  [[ -n ${v[rsec]:-} ]] && s_rd=$(human_bytes $(( ${v[rsec]} * lbs )))
  [[ -n $used ]] && s_used="${used}% (${v[used_src]})"
  [[ -n $temp ]] && s_tmp="${temp} C${v[tmax]:+ (lifetime max ${v[tmax]} C)}"
  [[ -n ${v[unsafe]:-} ]] && s_us="${v[unsafe]} (${v[unsafe_n]})"
  nr() { echo "${v[$1]:-not reported}"; }
  printf '  %-22s %s\n' "Capacity" "$(human_bytes "${v[cap]:-0}")" \
    "Type" "$( ((ssd)) && echo SSD || echo "${v[rpm]} rpm disk")" \
    "Temperature" "$s_tmp" "Percentage used" "$s_used" \
    "Data written" "$s_wr" "Data read" "$s_rd" \
    "Power-on hours" "$(nr poh)" "Power cycles" "$(nr pcyc)" "Unsafe shutdowns" "$s_us" \
    "Reallocated sectors" "$(nr realloc)" "Pending sectors" "$(nr pending)" \
    "Uncorrectable errors" "$(nr unc)" "Interface CRC errors" "$(nr crc)" "Error log entries" "$(nr errlog)"
  echo

  case ${v[passed]:-} in
    true)  if [[ ${v[basis]:-} == attributes ]]; then
             ok "SMART overall status: PASSED - judged on the attributes; this $([[ $KIND == usb ]] && echo adapter || echo port) does not return the drive's own verdict"
           else ok "SMART overall status: PASSED"; fi ;;
    false) bad "SMART overall status: FAILED" ;;
    *)     warn "SMART overall status could not be read - judge the drive on the counters below" ;;
  esac
  [[ -n ${v[fail_now]:-} ]]  && bad "At or below the failure threshold NOW: ${v[fail_now]} - return it"
  [[ -n ${v[fail_past]:-} ]] && warn "Crossed the failure threshold in the past: ${v[fail_past]}"

  if [[ -z ${v[unc]:-}${v[pending]:-}${v[offunc]:-} ]]; then
    warn "The drive reports no uncorrectable or pending-sector counter - nothing to judge media errors by; rely on the read test"
  elif (( ${v[unc]:-0} + ${v[pending]:-0} + ${v[offunc]:-0} > 0 )); then
    bad "Unreadable data: ${v[unc]:-0} uncorrectable, ${v[pending]:-0} pending, ${v[offunc]:-0} offline-uncorrectable - return it"
  else ok "No uncorrectable, pending or offline-uncorrectable sectors"; fi
  if   [[ -z ${v[realloc]:-} ]]; then info "Reallocated sectors: not reported by this drive"
  elif (( ${v[realloc]} > 0 )); then warn "${v[realloc]} reallocated sectors - it has retired bad blocks; re-run health later and check the number has not grown"
  else ok "No reallocated sectors"; fi
  [[ -n ${v[badblk]:-} ]] && warn "Bad-block counters above zero: ${v[badblk]}"
  if [[ -n ${v[crc]:-} ]]; then
    if (( ${v[crc]} > 0 )); then warn "${v[crc]} interface CRC errors over its life - a cable, port or adapter fault, not the media; note the number and compare on the next run"
    else ok "No interface CRC errors"; fi
  fi
  if   (( ! ssd )); then info "Spinning disk - no wear indicator; the error counters above are its health"
  elif [[ -z $used ]]; then warn "No wear indicator - neither Device Statistics nor a known wear attribute"
  elif (( used > NVME_MAX_USED_PCT )); then bad "Wear ${used}% - above the ${NVME_MAX_USED_PCT}% the NAS plan accepts: return it"
  elif (( used > 0 )); then warn "Wear ${used}% - used, within the ${NVME_MAX_USED_PCT}% limit"
  else ok "Wear 0%"; fi
  [[ -n $temp ]] && (( temp >= NVME_HOT_C )) && warn "Running hot (${temp} C)"
  [[ -n ${v[errlog]:-} ]] && (( ${v[errlog]} > 0 )) && info "Error log has ${v[errlog]} entries - smartctl -l xerror ${SMART[*]}"

  new_check "$poh" "$wbytes" "$pcyc" "${v[unsafe]:-}"

  if [[ -n ${v[lasttest]:-} ]]; then info "Last self-test: ${v[lasttest]}"
  else info "No self-test has ever been logged on it - run: selftest $DISK short, then long"; fi
  link_check
}

# ---------------------------------------------------------------- self-test
native_home() { [[ $PROTO == ata ]] && echo "on a native SATA port" || echo "in an M.2 slot"; }

# ata_test_sig -> the newest ATA self-test log entry and the entry count: it changes when a test is
# logged, which is how a test that finished between two polls is told from one that never ran.
ata_test_sig() {
  smartctl -l selftest -j "${SMART[@]}" 2>/dev/null | jq -r '.ata_smart_self_test_log.standard
    | "\(.count // 0) \(.table[0].type.value // "-") \(.table[0].status.value // "-") \(.table[0].lifetime_hours // "-")"' 2>/dev/null
}

cmd_selftest() {
  local kind="${1:-short}" flag out rc before=""
  case $kind in short) flag=short;; long|extended) flag=long;; *) die "selftest type: short|long";; esac
  hdr "Self-test ($kind): $MODEL ($SERIAL)"
  [[ $PROTO == ata ]] && before=$(ata_test_sig)
  out=$(smartctl -t "$flag" "${SMART[@]}" 2>&1); rc=$?
  if (( rc & 7 )); then   # smartctl exit bits 0-2: bad arguments, device not opened, command failed
    echo "$out" | sed 's/^/     /'
    if [[ $KIND == usb ]]; then
      warn "the self-test did not start through this USB bridge - it passes SMART reads, not every command. Run it $(native_home), or rely on the read test"
      return 0
    fi
    bad "the drive did not start a self-test - smartctl's answer is above"; return 1
  fi
  [[ $PROTO == ata ]] && { selftest_wait_ata "$flag" "$before"; return; }
  sleep 3
  local j op pct deadline=$(( SECONDS + NVME_SELFTEST_MAX_MIN * 60 ))
  while :; do
    j=$(smartctl -l selftest -j "${SMART[@]}" 2>/dev/null)
    op=$(jq -r '.nvme_self_test_log.current_self_test_operation.value // 0' <<<"$j")
    pct=$(jq -r '.nvme_self_test_log.current_self_test_completion_percent // 0' <<<"$j")
    (( op == 0 )) && break
    (( SECONDS > deadline )) && { echo; bad "still running after $NVME_SELFTEST_MAX_MIN min - smartctl -l selftest ${SMART[*]}"; return 1; }
    printf '\r  running... %3s%%' "$pct"
    sleep 10
  done
  echo
  local res code str
  res=$(jq -r '.nvme_self_test_log.table[0]' <<<"$j")
  code=$(jq -r '.self_test_result.value // 99' <<<"$res")
  str=$(jq -r '.self_test_result.string // "unknown"' <<<"$res")
  (( code == 0 )) && ok "Self-test passed ($str)" || bad "Self-test result: $str"
}

# ATA: the self-test execution status byte (smartctl -c) - high nibble 15 = running, low nibble =
# tenths still to do; 0 = completed without error, 1-2 = aborted or interrupted by the host.
selftest_wait_ata() {
  local flag=$1 before=$2 j st est max poll=10 seen=0 deadline str entry
  j=$(smartctl -c -j "${SMART[@]}" 2>&1)
  est=$(jq -r --arg k "$([[ $flag == long ]] && echo extended || echo short)" \
    '.ata_smart_data.self_test.polling_minutes[$k] // 0' <<<"$j" 2>/dev/null)
  est=${est:-0}
  max=$NVME_SELFTEST_MAX_MIN; (( est * 2 > max )) && max=$(( est * 2 ))
  [[ $flag == long ]] && poll=60
  (( est > 0 )) && info "The drive estimates $est min; checking every $poll s, giving up after $max min"
  deadline=$(( SECONDS + max * 60 ))
  sleep 3
  while :; do
    j=$(smartctl -c -j "${SMART[@]}" 2>&1)
    st=$(jq -r '.ata_smart_data.self_test.status.value // empty' <<<"$j" 2>/dev/null)
    [[ -n $st ]] || { echo; echo "$j" | head -20 | sed 's/^/     /'; bad "cannot read the self-test status - smartctl's answer is above"; return 1; }
    (( (st >> 4) == 15 )) || break
    seen=1
    (( SECONDS > deadline )) && { echo; bad "still running after $max min - smartctl -c ${SMART[*]}"; return 1; }
    printf '\r  running... %3s%% done' "$(( 100 - (st & 15) * 10 ))"
    sleep "$poll"
  done
  echo
  if (( ! seen )) && [[ "$(ata_test_sig)" == "$before" ]]; then
    warn "no sign the self-test ran: never seen running, and the self-test log did not change - smartctl -l selftest ${SMART[*]}"
    return 0
  fi
  str=$(jq -r '.ata_smart_data.self_test.status.string // "status unknown"' <<<"$j")
  case $(( st >> 4 )) in
    0)   ok "Self-test passed ($str)" ;;
    1|2) warn "Self-test $str - not a verdict on the drive; run it again" ;;
    *)   bad "Self-test $str" ;;
  esac
  entry=$(smartctl -l selftest -j "${SMART[@]}" 2>/dev/null | jq -r '.ata_smart_self_test_log.standard.table[0]
    | select(.) | "\(.type.string): \(.status.string) at \(.lifetime_hours)h"' 2>/dev/null)
  [[ -n $entry ]] && info "Logged: $entry"
}

# ---------------------------------------------------------------- read test
cmd_readtest() {
  hdr "Full surface read test: $NS"
  link_check
  local size t0 secs; size=$(blockdev --getsize64 "$NS")
  info "Reading $(human_bytes "$size") - this can take a while"
  t0=$SECONDS
  if dd if="$NS" of=/dev/null bs=16M iflag=direct status=progress; then
    secs=$(( SECONDS - t0 )); ((secs == 0)) && secs=1
    ok "Read the entire drive with no errors ($(human_bytes $(( size / secs )))/s average)"
  else
    bad "Read errors - dmesg | tail -50"
  fi
}

# ---------------------------------------------------------------- wipe
sanitize_status() {  # prints "<sstat&7> <progress%>"
  local j sstat sprog; j=$(nvme sanitize-log "$CTRL" -o json 2>/dev/null)
  sstat=$(jq '[.. | objects | select(has("sstat")) | .sstat][0] // 0' <<<"$j")
  sprog=$(jq '[.. | objects | select(has("sprog")) | .sprog][0] // 0' <<<"$j")
  echo "$(( sstat & 7 )) $(( sprog * 100 / 65535 ))"
}

# ata_sanitize_status -> "<SDn> <progress%> <ok>" from hdparm --sanitize-status; ok=1 when the drive
# says its last sanitize completed without error. Fails, with hdparm's answer on stderr, when the
# state cannot be read. States (hdparm 9.65): SD0 idle, SD1 frozen, SD2 in process.
ata_sanitize_status() {
  local out sd pct okf=0
  out=$(hdparm --sanitize-status "$NS" 2>&1) || { echo "$out" | sed 's/^/     /' >&2; return 1; }
  sd=$(sed -n 's/^ *State: *\(SD[0-9]\).*/\1/p' <<<"$out")
  pct=$(sed -n 's/^ *Progress:.*(\([0-9]*\)%).*/\1/p' <<<"$out")
  [[ $out == *"Last Sanitize Operation Completed Without Error"* ]] && okf=1
  [[ -n $sd ]] || { echo "$out" | sed 's/^/     /' >&2; return 1; }
  echo "$sd ${pct:-0} $okf"
}

cmd_wipe() {
  local method=auto reason ans t0
  [[ ${1:-} == --method ]] && method="${2:-auto}"
  hdr "Wipe: $MODEL ($SERIAL) on $NS"
  # ---- the guards FIRST: nothing below runs on a disk in use ----
  reason=$(in_use_reason "$DISK")
  [[ -z $reason ]] || die "$NS: $reason - refusing, nothing changed"
  [[ -n $SERIAL && $SERIAL != "?" ]] || die "$NS reports no serial number - refusing: there would be nothing to confirm against"

  local can_block=0 can_crypto=0 can_fmt=0 fmt_crypto=0 sup="by the drive" idf
  yn() { (( $1 )) && echo yes || echo no; }
  if [[ $KIND == nvme ]]; then
    local sanicap fna oacs
    sanicap=$(jq '.sanicap // 0' <<<"$ID_JSON"); fna=$(jq '.fna // 0' <<<"$ID_JSON"); oacs=$(jq '.oacs // 0' <<<"$ID_JSON")
    can_block=$(( sanicap & 2 )); can_crypto=$(( sanicap & 1 )); can_fmt=$(( oacs & 2 )); fmt_crypto=$(( fna & 4 ))
    info "Supported: sanitize-block=$(yn $can_block) sanitize-crypto=$(yn $can_crypto) format=$(yn $can_fmt) (crypto: $(yn $fmt_crypto))"
  elif [[ $KIND == sata ]]; then
    if ! command -v hdparm >/dev/null; then
      sup="- hdparm is not installed (apt install hdparm)"; info "No ATA sanitize: hdparm is not installed - overwrite or discard only"
    else
      idf=$(hdparm -I "$NS" 2>&1) || { echo "$idf" | head -10 | sed 's/^/     /'; die "hdparm -I failed on $NS (above) - nothing changed"; }
      # hdparm -I marks a supported feature with '*': "   *   BLOCK_ERASE_EXT command"
      [[ $idf =~ $'\n'[[:blank:]]*\*[[:blank:]]+BLOCK_ERASE_EXT\ command ]]     && can_block=1
      [[ $idf =~ $'\n'[[:blank:]]*\*[[:blank:]]+CRYPTO_SCRAMBLE_EXT\ command ]] && can_crypto=1
      info "Supported (ATA SANITIZE): block-erase=$(yn $can_block) crypto-scramble=$(yn $can_crypto)"
    fi
  elif [[ $PROTO == nvme ]]; then
    info "In a USB enclosure: sanitize and format cannot pass the bridge - overwrite or discard only"
  else
    info "On a USB adapter: an ATA sanitize reports its progress in registers the bridge drops - overwrite or discard only"
  fi

  if [[ $method == auto ]]; then
    if   [[ $KIND == usb ]]; then method=overwrite
    elif (( can_block ));  then method=block
    elif (( can_crypto )); then method=crypto
    elif (( can_fmt ));    then method=format
    else method=overwrite; fi
  fi
  local nousb; nousb="not through a USB bridge - it needs $(native_home)"
  [[ $PROTO == ata ]] && nousb="not through a USB bridge - a sanitize reports its progress and its result in ATA registers the bridge drops, so a finished erase could not be told from one that never ran: it needs a native SATA port"
  case $method in
    block)  [[ $KIND != usb ]] || die "sanitize: $nousb";  (( can_block ))  || die "sanitize block erase not supported $sup";;
    crypto) [[ $KIND != usb ]] || die "sanitize: $nousb";  (( can_crypto )) || die "sanitize crypto erase not supported $sup";;
    format) [[ $PROTO == nvme ]] || die "format is an NVMe command - for a SATA drive: --method block or crypto (native port), overwrite or discard"
            [[ $KIND == nvme ]] || die "format: $nousb";    (( can_fmt ))    || die "format not supported by the drive";;
    overwrite|discard) ;;
    *) die "method must be auto|block|crypto|format|overwrite|discard";;
  esac
  [[ $method == overwrite ]] && link_check
  [[ $method == overwrite ]] && info "An overwrite reaches every block the system can address; an SSD's spare area keeps what it held. Fine for reuse here - a drive leaving the program needs a sanitize, $(native_home)"
  if [[ $PROTO == ata && $method =~ ^(block|crypto)$ ]]; then
    local pre; pre=$(ata_sanitize_status) || die "cannot read the sanitize state of $NS (hdparm's answer is above) - nothing changed"
    case ${pre%% *} in
      SD1) die "sanitize is FROZEN on $NS - the firmware or BIOS locked it at power-on, and only a power cycle of the drive clears it - nothing changed" ;;
      SD2) die "a sanitize is already running on $NS - follow it with: hdparm --sanitize-status $NS" ;;
    esac
  fi

  echo
  lsblk -o NAME,SIZE,FSTYPE,LABEL "$NS"
  echo
  echo "${RED}${BLD}This will PERMANENTLY destroy all data on $NS ($MODEL, serial $SERIAL).${RST}"
  echo "Method: $method"
  read -r -p "Type the drive serial number to confirm: " ans
  [[ "$ans" == "$SERIAL" ]] || die "serial mismatch - aborted, nothing changed"
  # again: nothing may have been mounted or opened while the prompt waited
  reason=$(in_use_reason "$DISK")
  [[ -z $reason ]] || die "$NS: $reason - refusing, nothing changed"

  t0=$SECONDS
  case $method in
    block|crypto)
      if [[ $PROTO == ata ]]; then ata_sanitize "$method" "$t0" || return 1; else
      local act=2 st pct; [[ $method == crypto ]] && act=4
      info "Starting sanitize (action $act). Do NOT power off - it resumes after a reboot anyway."
      nvme sanitize "$CTRL" --sanact=$act || die "sanitize command failed"
      sleep 2
      while read -r st pct < <(sanitize_status); (( st == 2 )); do
        printf '\r  sanitizing... %3s%%' "$pct"; sleep 5
      done
      echo
      case $st in
        1|4) ok "Sanitize completed in $(( SECONDS - t0 ))s";;
        3)   bad "Sanitize FAILED (see: nvme sanitize-log $CTRL)"; return 1;;
        *)   warn "Sanitize status unclear (sstat=$st) - check: nvme sanitize-log $CTRL";;
      esac
      fi
      ;;
    format)
      local ses=1 force=; (( fmt_crypto )) && ses=2
      nvme format --help 2>&1 | grep -q -- '--force' && force=--force
      info "Running nvme format with secure erase setting $ses"
      nvme format "$NS" --ses=$ses $force || die "format failed"
      ok "Format completed in $(( SECONDS - t0 ))s"
      ;;
    overwrite)
      local size; size=$(blockdev --getsize64 "$NS")
      info "Writing zeros over all $(human_bytes "$size")"
      # count in BYTES: an unbounded dd to a block device ends in 'No space left' and a failure status
      if dd if=/dev/zero of="$NS" bs=16M count="$size" iflag=count_bytes oflag=direct conv=fsync status=progress; then
        ok "Overwrote every block in $(( SECONDS - t0 ))s"
      else
        bad "the overwrite stopped early - a disconnect, or the drive refused a write: dmesg | tail -50, then run the wipe again"; return 1
      fi
      ;;
    discard)
      local out
      # A refused discard is the BRIDGE's limit, not the drive's fault: stop, and do not count it
      # against the drive (the first RTL9210 enclosure refuses it - 'Operation not supported').
      out=$(blkdiscard -f "$NS" 2>&1) || { echo "$out" | sed 's/^/     /'; die "the discard was refused (above) - nothing was changed. Not the drive's fault: use --method overwrite"; }
      ok "Discarded every block in $(( SECONDS - t0 ))s"
      ;;
  esac

  [[ $KIND == nvme ]] && { nvme ns-rescan "$CTRL" >/dev/null 2>&1 || true; }
  blockdev --rereadpt "$NS" >/dev/null 2>&1 || true
  sleep 1
  verify_wipe "$method"
}

# ata_sanitize block|crypto T0 - native SATA port only (cmd_wipe refuses USB first). The block erase
# runs in the background on the drive; its status is polled until it leaves SD2.
ata_sanitize() {
  local method=$1 t0=$2 flag=--sanitize-block-erase out st sd pct okf
  [[ $method == crypto ]] && flag=--sanitize-crypto-scramble
  info "Starting ATA sanitize ($method). Do NOT power off - the drive resumes it at power-on anyway."
  out=$(hdparm --yes-i-know-what-i-am-doing "$flag" "$NS" 2>&1) || { echo "$out" | sed 's/^/     /'; die "the sanitize command was refused (above)"; }
  echo "$out" | sed 's/^/     /'
  sleep 2
  while :; do
    st=$(ata_sanitize_status) || { echo; bad "lost the sanitize status (hdparm's answer is above) - check: hdparm --sanitize-status $NS"; return 1; }
    read -r sd pct okf <<<"$st"
    [[ $sd == SD2 ]] || break
    printf '\r  sanitizing... %3s%%' "$pct"; sleep 5
  done
  echo
  if (( okf )); then ok "Sanitize completed in $(( SECONDS - t0 ))s"
  else bad "Sanitize did not report success (state $sd) - check: hdparm --sanitize-status $NS"; return 1; fi
}

verify_wipe() {
  hdr "Verify wipe"
  local method="$1" size mib zeros=0 ffs=0 other=0 n=32 i off chunk
  size=$(blockdev --getsize64 "$NS"); mib=$(( size / 1048576 ))
  for ((i = 0; i < n; i++)); do
    off=$(( i == n-1 ? mib - 1 : (mib - 1) * i / (n - 1) ))
    chunk=$(dd if="$NS" bs=1M skip="$off" count=1 iflag=direct 2>/dev/null | od -An -v -tx1 | tr -d ' \n' | tr -s '0-9a-f')
    case $chunk in 0|00) zeros=$((zeros+1));; f|ff) ffs=$((ffs+1));; *) other=$((other+1));; esac
  done
  info "Sampled $n x 1 MiB regions: $zeros all-zero, $ffs all-0xFF, $other mixed"
  if (( other == 0 )); then ok "All sampled regions are blank"
  elif [[ $method == crypto ]]; then info "Mixed data is expected after a crypto erase (the old data is now unreadable ciphertext)"
  else bad "$other sampled regions still hold data after a $method wipe"; fi
  if blkid -p "$NS" >/dev/null 2>&1 || lsblk -nro NAME "$NS" | tail -n +2 | grep -q .; then
    warn "A partition table / filesystem signature is still visible"
  else ok "No partition table or filesystem signatures found"; fi
}

# ---------------------------------------------------------------- main
cmd="${1:-}"; shift || true
case $cmd in list|health|selftest|readtest|wipe|full) ;; *) usage; exit 1 ;; esac
check_deps
case $cmd in
  list)     cmd_list ;;
  health)   resolve_dev "${1:-}"; start_report health;   cmd_health ;;
  selftest) resolve_dev "${1:-}"; start_report selftest; cmd_selftest "${2:-short}" ;;
  readtest) resolve_dev "${1:-}"; start_report readtest; cmd_readtest ;;
  wipe)     resolve_dev "${1:-}"; start_report wipe;     shift; cmd_wipe "$@" ;;
  full)     resolve_dev "${1:-}"; start_report full
            cmd_health; cmd_selftest short; cmd_wipe; hdr "Post-wipe health"; cmd_health ;;
esac

hdr "Summary"
if   (( FAILS > 0 )); then echo "  ${RED}${BLD}$FAILS failure(s), $WARNS warning(s)${RST} - read them above: a failed health or read check is grounds to return the drive."
elif (( WARNS > 0 )); then echo "  ${YEL}${BLD}$WARNS warning(s)${RST} - review above."
else echo "  ${GRN}${BLD}All checks passed.${RST}"; fi
if [[ -n ${REPORT:-} ]]; then
  echo "  Report saved: $REPORT"
  [[ -n ${SUDO_USER:-} ]] && chown "$SUDO_USER:" "$NVME_REPORT_DIR" "$REPORT" 2>/dev/null
fi
exit $(( FAILS > 0 ))
