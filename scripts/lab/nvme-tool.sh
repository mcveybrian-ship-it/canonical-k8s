#!/usr/bin/env bash
# =========================================================================================
# nvme-tool.sh - vet an NVMe drive before it goes into the lab NAS: health, self-test, a full
# read, and a wipe of whatever its last owner left on it. LAB ONLY (docs/lab-network.md 9.3) -
# not part of the product.
#
#     MACHINE: build-01. Linux only: it drives nvme-cli, smartctl and the kernel's block layer.
#     There is no Windows version; the NAS's TrueNAS shell has the same tools if a drive is
#     tested there instead.
#
#     sudo ./nvme-tool.sh list                          every NVMe drive, in a slot or a USB enclosure,
#                                                       and every disk this script will never wipe
#     sudo ./nvme-tool.sh health   <dev>                SMART health + "is it really new?"
#     sudo ./nvme-tool.sh selftest <dev> [short|long]   the drive's own self-test
#     sudo ./nvme-tool.sh readtest <dev>                read every block, report errors and speed
#     sudo ./nvme-tool.sh wipe     <dev> [--method M]   destroy everything on it (asks for the serial)
#     sudo ./nvme-tool.sh full     <dev>                health -> short self-test -> wipe -> health
#
#   <dev>: nvme0 / nvme0n1 / /dev/nvme0n1 for a drive in an M.2 slot; sdb / /dev/sdb for one in a
#   USB enclosure. Reports: $NVME_REPORT_DIR/<serial>-<time>-<command>.txt
#
# IN A USB ENCLOSURE (2026-09-29 - the first PM9A1 arrived in an RTL9210 enclosure on build-01):
#   The bridge passes SMART reads (smartctl -d sntrealtek / sntjmicron / sntasmedia), so health
#   and the read test work. It does NOT pass the admin commands a secure erase needs - NVMe
#   sanitize and format need an M.2 slot. Over USB the wipe OVERWRITES every block with zeros
#   (--method overwrite, the default there) or discards it (--method discard). A USB 2 link
#   (480 Mb/s, ~40 MB/s) makes a 2 TB read or overwrite ~14 hours: the script says so first.
#
# WHAT WIPE REFUSES, BEFORE ANYTHING ELSE, and again after the serial is typed: a disk under /,
#   /boot or /boot/efi (resolved through LUKS and LVM, not by partition name), a disk with any
#   mounted filesystem, swap, or a holder anywhere on it (an open LUKS mapping, LVM, md). On
#   build-01 that is sda (the system) and nvme0n1 (/srv/bundle). A drive that reports no serial
#   is refused too - there would be nothing to confirm against.
#
# Parameters (environment): NVME_REPORT_DIR (./nvme-reports), NVME_MAX_USED_PCT (10 - the NAS
#   plan's return limit), NVME_NEW_MAX_HOURS (48), NVME_NEW_MAX_GB (200), NVME_NEW_MAX_CYCLES (30),
#   NVME_NEW_MAX_UNSAFE (10), NVME_HOT_C (70), NVME_SELFTEST_MAX_MIN (240).
#
# Requires nvme-cli, smartmontools 7.3+, jq, util-linux - all on build-01 (checked 2026-09-29).
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
BRIDGES="sntrealtek sntjmicron sntasmedia"

RED=$'\e[31m'; YEL=$'\e[33m'; GRN=$'\e[32m'; BLD=$'\e[1m'; RST=$'\e[0m'
[[ -t 1 ]] || { RED=; YEL=; GRN=; BLD=; RST=; }

die()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }
ok()   { echo "  ${GRN}[ OK ]${RST} $*"; }
warn() { echo "  ${YEL}[WARN]${RST} $*"; WARNS=$((WARNS+1)); }
bad()  { echo "  ${RED}[FAIL]${RST} $*"; FAILS=$((FAILS+1)); }
info() { echo "  [info] $*"; }
hdr()  { echo; echo "${BLD}== $* ==${RST}"; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; }

WARNS=0; FAILS=0

check_deps() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo)"
  local missing=() c
  for c in nvme smartctl jq lsblk blockdev blkdiscard dd findmnt numfmt; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]}  (apt install nvme-cli smartmontools jq)"
}

human_bytes() { numfmt --to=si --suffix=B "$1" 2>/dev/null || echo "$1 B"; }

# bridge_type /dev/sdX -> the smartctl -d type that reaches an NVMe drive behind this USB bridge.
# A probe: every type but the right one fails, so its errors are not the answer - the die says
# what to run to see them.
bridge_type() {
  local t j
  for t in $BRIDGES; do
    j=$(smartctl -i -j -d "$t" "$1" 2>/dev/null)
    [[ "$(jq -r '.device.protocol // empty' <<<"$j" 2>/dev/null)" == NVMe ]] && { echo "$t"; return 0; }
  done
  return 1
}

# Sets KIND (nvme|usb), CTRL (nvme only), NS (the block device), DISK (its kernel name), SMART (the
# smartctl arguments that reach the drive), ID_JSON (nvme only), MODEL SERIAL FW.
resolve_dev() {
  local in="${1:-}" t j
  [[ -n $in ]] || die "no device given (try: $0 list)"
  if [[ $in =~ ^(/dev/)?(nvme[0-9]+)(n[0-9]+)?(p[0-9]+)?$ ]]; then
    KIND=nvme
    CTRL="/dev/${BASH_REMATCH[2]}"; NS="/dev/${BASH_REMATCH[2]}${BASH_REMATCH[3]:-n1}"
    [[ -c $CTRL ]] || die "$CTRL not found"
    [[ -b $NS ]]   || die "$NS not found"
    ID_JSON=$(nvme id-ctrl "$CTRL" -o json 2>&1) || die "nvme id-ctrl failed on $CTRL: $ID_JSON"
    SMART=("$CTRL")
  elif [[ $in =~ ^(/dev/)?(sd[a-z]+)[0-9]*$ ]]; then
    KIND=usb; CTRL=""; ID_JSON="{}"; NS="/dev/${BASH_REMATCH[2]}"
    [[ -b $NS ]] || die "$NS not found"
    [[ "$(lsblk -dno TRAN "$NS")" == usb ]] || die "$NS is not on USB - this tool takes NVMe drives, in an M.2 slot or a USB enclosure"
    t=$(bridge_type "$NS") || die "no NVMe drive answers through the USB bridge on $NS (tried $BRIDGES) - 'smartctl -i -d auto $NS' shows what it does see"
    SMART=(-d "$t" "$NS")
  else
    die "not an NVMe or USB disk name: $in (try: $0 list)"
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
  echo "Device: $NS (${KIND}${CTRL:+, controller $CTRL}${SMART[0]:+, smartctl ${SMART[*]}})  Model: $MODEL  Serial: $SERIAL  FW: $FW"
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
    warn "USB 2 link (${s} Mb/s, ~40 MB/s): reading or writing all $(human_bytes "$size") takes ~$(( size / 40000000 / 3600 )) h - move the enclosure to a USB 3 port (blue or red) first"
  else ok "USB link ${s} Mb/s"; fi
}

# ---------------------------------------------------------------- list
cmd_list() {
  local d t
  hdr "NVMe drives in M.2 slots"
  nvme list 2>&1 || true
  hdr "NVMe drives in USB enclosures"
  local found=0
  for d in $(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1}'); do
    if t=$(bridge_type "/dev/$d"); then
      DISK=$d; KIND=usb
      printf '  /dev/%-6s %-28s serial %-20s via %s, USB link %s Mb/s\n' "$d" \
        "$(smartctl -i -j -d "$t" "/dev/$d" 2>/dev/null | jq -r '.model_name // "?"')" \
        "$(smartctl -i -j -d "$t" "/dev/$d" 2>/dev/null | jq -r '.serial_number // "?"')" "$t" "$(usb_speed || echo '?')"
      found=1
    fi
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
  hdr "Health: $MODEL ($SERIAL)"
  local j; j=$(smartctl -a -j "${SMART[@]}" 2>&1)
  jq -e . >/dev/null 2>&1 <<<"$j" || { echo "$j" | head -20 | sed 's/^/     /'; die "smartctl did not return JSON for ${SMART[*]} - its answer is above"; }
  local L='.nvme_smart_health_information_log'
  g() { jq -r "$L.$1 // empty" <<<"$j"; }

  local passed cw temp spare spare_th used dur duw poh pcyc unsafe merr elog cap parts
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

  hdr "Is it really new?"
  local gb=$(( wbytes / 1000000000 )) suspect=0
  (( poh > NVME_NEW_MAX_HOURS ))     && { warn "Power-on hours = $poh (new drives are usually < 10)"; suspect=1; }
  (( gb > NVME_NEW_MAX_GB ))         && { warn "${gb} GB already written (new drives: a few GB from factory testing)"; suspect=1; }
  (( pcyc > NVME_NEW_MAX_CYCLES ))   && { warn "Power cycles = $pcyc"; suspect=1; }
  (( unsafe > NVME_NEW_MAX_UNSAFE )) && { warn "Unsafe shutdowns = $unsafe"; suspect=1; }
  parts=$(lsblk -nro NAME "$NS" | tail -n +2 | wc -l)
  (( parts > 0 )) && { warn "It carries $parts partition(s) from a previous life - someone's data; wipe it before use"; suspect=1; }
  (( suspect == 0 )) && ok "Usage counters look consistent with a new drive"

  local st; st=$(jq -r '.nvme_self_test_log.table[0] | select(.) | "\(.self_test_code.string): \(.self_test_result.string) at \(.power_on_hours)h"' <<<"$j" 2>/dev/null)
  [[ -n $st ]] && info "Last self-test: $st"
  link_check
}

# ---------------------------------------------------------------- self-test
cmd_selftest() {
  local kind="${1:-short}" flag out rc
  case $kind in short) flag=short;; long|extended) flag=long;; *) die "selftest type: short|long";; esac
  hdr "Self-test ($kind): $MODEL ($SERIAL)"
  out=$(smartctl -t "$flag" "${SMART[@]}" 2>&1); rc=$?
  if (( rc & 7 )); then   # smartctl exit bits 0-2: bad arguments, device not opened, command failed
    echo "$out" | sed 's/^/     /'
    if [[ $KIND == usb ]]; then
      warn "the self-test did not start through this USB bridge - it passes SMART reads, not every command. Run it in an M.2 slot, or rely on the read test"
      return 0
    fi
    bad "the drive did not start a self-test - smartctl's answer is above"; return 1
  fi
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

cmd_wipe() {
  local method=auto reason ans t0
  [[ ${1:-} == --method ]] && method="${2:-auto}"
  hdr "Wipe: $MODEL ($SERIAL) on $NS"
  # ---- the guards FIRST: nothing below runs on a disk in use ----
  reason=$(in_use_reason "$DISK")
  [[ -z $reason ]] || die "$NS: $reason - refusing, nothing changed"
  [[ -n $SERIAL && $SERIAL != "?" ]] || die "$NS reports no serial number - refusing: there would be nothing to confirm against"

  local sanicap=0 fna=0 oacs=0
  if [[ $KIND == nvme ]]; then
    sanicap=$(jq '.sanicap // 0' <<<"$ID_JSON"); fna=$(jq '.fna // 0' <<<"$ID_JSON"); oacs=$(jq '.oacs // 0' <<<"$ID_JSON")
  fi
  local can_block=$(( sanicap & 2 )) can_crypto=$(( sanicap & 1 )) can_fmt=$(( oacs & 2 )) fmt_crypto=$(( fna & 4 ))
  yn() { (( $1 )) && echo yes || echo no; }
  if [[ $KIND == usb ]]; then
    info "In a USB enclosure: sanitize and format cannot pass the bridge - overwrite or discard only"
  else
    info "Supported: sanitize-block=$(yn $can_block) sanitize-crypto=$(yn $can_crypto) format=$(yn $can_fmt) (crypto: $(yn $fmt_crypto))"
  fi

  if [[ $method == auto ]]; then
    if   [[ $KIND == usb ]]; then method=overwrite
    elif (( can_block ));  then method=block
    elif (( can_crypto )); then method=crypto
    elif (( can_fmt ));    then method=format
    else method=overwrite; fi
  fi
  local nousb="not through a USB bridge - it needs an M.2 slot"
  case $method in
    block)  [[ $KIND == nvme ]] || die "sanitize: $nousb";  (( can_block ))  || die "sanitize block erase not supported by the drive";;
    crypto) [[ $KIND == nvme ]] || die "sanitize: $nousb";  (( can_crypto )) || die "sanitize crypto erase not supported by the drive";;
    format) [[ $KIND == nvme ]] || die "format: $nousb";    (( can_fmt ))    || die "format not supported by the drive";;
    overwrite|discard) ;;
    *) die "method must be auto|block|crypto|format|overwrite|discard";;
  esac
  [[ $method == overwrite ]] && link_check

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
