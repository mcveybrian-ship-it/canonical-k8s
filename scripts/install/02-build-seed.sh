#!/usr/bin/env bash
#
# 02 - Write an autoinstall seed to a USB stick. Linux/macOS version.
#
# One template, one stick, rewritten per host. The seed is a FAT32 stick labelled CIDATA
# holding user-data and meta-data; cloud-init's NoCloud datasource finds it by that label.
# The Windows equivalent is 02-build-seed.ps1.
#
# Format the stick once - this is also where the label gets set:
#     lsblk -o NAME,SIZE,TRAN,RM,LABEL,FSTYPE      # confirm TRAN=usb, RM=1
#     sudo mkfs.vfat -F 32 -n CIDATA /dev/sdX1     # CHECK THE DEVICE
#     sudo mount /dev/sdX1 /mnt
#
# Then, once per host:
#     ./02-build-seed.sh -H h1 -a 10.0.20.115 -d /mnt
#
# Options:
#   -H HOST    hostname, e.g. h1
#   -a ADDR    IPv4 address without prefix, e.g. 10.0.20.115
#   -d DIR     mount point of the FAT32 stick
#   -o DIR     write user-data/meta-data to a plain DIRECTORY instead, skipping the
#              removable-media checks. For building the seed on a machine with no USB
#              (stage-01 is a Hyper-V guest) and copying the two files to media later.
#              THE OUTPUT CONTAINS THE LUKS PASSPHRASE IN PLAINTEXT - treat as a credential.
#   -p FILE    params file (default: 02-host-autoinstall/host-params.env)
#   -t FILE    template (default: 02-host-autoinstall/user-data.template)
#   -n         dry run - print the resolved values and exit without writing
#
set -euo pipefail

HOST=""; ADDR=""; DEST=""; DRYRUN=0; OUTDIR=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS="$HERE/02-host-autoinstall/host-params.env"
TEMPLATE="$HERE/02-host-autoinstall/user-data.template"

while getopts ":H:a:d:o:p:t:nh" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    a) ADDR="$OPTARG" ;;
    d) DEST="$OPTARG" ;;
    p) PARAMS="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    t) TEMPLATE="$OPTARG" ;;
    n) DRYRUN=1 ;;
    h) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

die() { echo "[x] $*" >&2; exit 1; }

[[ -n "$HOST" ]] || die "-H <hostname> is required"
[[ -n "$ADDR" ]] || die "-a <address> is required, e.g. -a 10.0.20.115"
[[ "$ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "-a must be a bare IPv4 address, no prefix: $ADDR"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
# Sanity-check the params file BEFORE sourcing it. Sourcing a file with an unbalanced
# quote produces a baffling error from whatever text the open quote swallowed - on
# 2026-09-01 an unquoted PASSWORD_HASH turned a comment three lines later into a command
# and the script died with "ssh.exe: command not found", which points at nothing useful.
_paramcheck() {
  local f="$1" n=0 bad=0
  while IFS= read -r l; do
    n=$((n+1))
    case "$l" in \#*|"") continue ;; esac
    local q="${l//[^\']/}"
    if (( ${#q} % 2 )); then
      echo "  line $n: unbalanced single quote -> ${l%%=*}=..." >&2
      bad=1
    fi
  done < "$f"
  # The hash MUST be single-quoted: unquoted $6$... lets the shell expand $6 to nothing,
  # the account is created with a garbage password, and NOTHING errors. See README section 8.
  if grep -qE "^PASSWORD_HASH=[^']" "$f"; then
    echo "  PASSWORD_HASH is not single-quoted. It contains \$ characters that the shell will" >&2
    echo "  expand, silently mangling the hash. Wrap the whole value in single quotes:" >&2
    echo "    PASSWORD_HASH='\$6\$...'" >&2
    bad=1
  fi
  return $bad
}
_paramcheck "$PARAMS" || die "$PARAMS has quoting errors - see above. Nothing was written."

[[ -f "$PARAMS" ]] || die "params file not found: $PARAMS
    Copy host-params.env.example to host-params.env and fill it in."

# shellcheck disable=SC1090
set -a
# shellcheck disable=SC1090
. "$PARAMS"
set +a
for v in NIC_MATCH PREFIX PASSWORD_HASH; do
  [[ -n "${!v:-}" ]] || die "$v is unset in $PARAMS"
done

USERNAME="${USERNAME:-encadmin}"
LV_ROOT="${LV_ROOT:-40G}"; LV_HOME="${LV_HOME:-10G}"; LV_VAR="${LV_VAR:-30G}"
LV_VARLOG="${LV_VARLOG:-20G}"; LV_VARLOGAUDIT="${LV_VARLOGAUDIT:-20G}"; LV_TMP="${LV_TMP:-10G}"

# --- disk encryption -------------------------------------------------------------------------
# LUKS sits between each partition and its volume group, so both VGs are encrypted at rest.
ENCRYPT_DISKS="${ENCRYPT_DISKS:-true}"
case "$ENCRYPT_DISKS" in
  true|false) : ;;
  *) die "ENCRYPT_DISKS must be true or false, got '$ENCRYPT_DISKS'" ;;
esac

if [[ "$ENCRYPT_DISKS" == "true" ]]; then
  [[ -n "${LUKS_PASSPHRASE:-}" ]] || die "ENCRYPT_DISKS=true but LUKS_PASSPHRASE is unset in $PARAMS"
  [[ "$LUKS_PASSPHRASE" != *REPLACE-ME* ]] || die "LUKS_PASSPHRASE still holds a placeholder"

# Disk matching decides which device gets wiped. Refuse the two ways it goes wrong.
: "${OS_DISK_MATCH:?OS_DISK_MATCH not set in host-params.env}"
: "${DATA_DISK_MATCH:?DATA_DISK_MATCH not set in host-params.env}"
for _m in "$OS_DISK_MATCH" "$DATA_DISK_MATCH"; do
  case "$_m" in
    *usb*) die "disk match '$_m' can match a USB device. Subiquity does not exclude removable
       media, and on the pathfinder that destroyed the seed stick mid-install." ;;
    ""|"*") die "disk match '$_m' is too broad - it would match every disk on the host" ;;
  esac
done
[ "$OS_DISK_MATCH" != "$DATA_DISK_MATCH" ] ||   die "OS_DISK_MATCH and DATA_DISK_MATCH are identical ('$OS_DISK_MATCH') - they would both
       resolve to the same disk. On an all-NVMe host, disambiguate by PCI address:
         ls -l /dev/disk/by-path/ | grep -v part"
  (( ${#LUKS_PASSPHRASE} >= 12 )) || die "LUKS_PASSPHRASE is under 12 characters"
  CRYPT_OS=$'      - id: crypt-os\n        type: dm_crypt\n        dm_name: crypt-os\n        volume: p-pv\n        key: \''"$LUKS_PASSPHRASE"$'\'\n'
  CRYPT_DATA=$'      - id: crypt-data\n        type: dm_crypt\n        dm_name: crypt-data\n        volume: p-data\n        key: \''"$LUKS_PASSPHRASE"$'\'\n'
  VG0_DEV="crypt-os"
  VGDATA_DEV="crypt-data"
  ENC_SUMMARY="LUKS on both volume groups"
else
  CRYPT_OS=""
  CRYPT_DATA=""
  VG0_DEV="p-pv"
  VGDATA_DEV="p-data"
  ENC_SUMMARY="NONE - plaintext disks"
fi
[[ "$PASSWORD_HASH" == \$6\$* ]] || die "PASSWORD_HASH does not look like a SHA-512 crypt hash"

ALLOW_PW="${ALLOW_PW:-true}"
case "$ALLOW_PW" in true|false) : ;; *) die "ALLOW_PW must be true or false, got '$ALLOW_PW'" ;; esac

# Collect SSH_KEY_1..N, plus a legacy bare SSH_KEY. Each becomes one authorized-keys entry.
SSH_KEYS_YAML=""
KEY_COUNT=0
KEY_SUMMARY=""
for var in SSH_KEY SSH_KEY_1 SSH_KEY_2 SSH_KEY_3 SSH_KEY_4 SSH_KEY_5 SSH_KEY_6 SSH_KEY_7 SSH_KEY_8; do
  k="${!var:-}"
  [[ -n "$k" ]] || continue
  case "$k" in
    ssh-rsa*|ecdsa-*) : ;;
    ssh-ed25519*) die "$var is Ed25519. FIPS mode refuses those - use RSA 3072+ or ECDSA." ;;
    *) die "$var does not look like an OpenSSH public key" ;;
  esac
  SSH_KEYS_YAML+="      - '$k'"$'\n'
  KEY_COUNT=$((KEY_COUNT + 1))
  KEY_SUMMARY+="             ${k%% *}  ${k##* }"$'\n'
done
(( KEY_COUNT > 0 )) || die "no SSH keys set in $PARAMS - define SSH_KEY_1"
SSH_KEYS_YAML="${SSH_KEYS_YAML%$'\n'}"

# --- substitute ------------------------------------------------------------------------------
# Bash parameter expansion, not sed: the password hash contains $ and / which sed would mangle.
content="$(cat "$TEMPLATE")"
content="${content//@@HOSTNAME@@/$HOST}"
content="${content//@@ADDRESS@@/$ADDR}"
content="${content//@@NIC_MATCH@@/$NIC_MATCH}"
# SERIAL_CONSOLE=true puts ttyS0 last, so prompts go to serial - correct for a racked
# host reached over BMC serial-over-LAN. false puts tty0 last so prompts appear on an
# attached monitor. Getting this backwards makes a LUKS host look hung at boot.
if [[ "${SERIAL_CONSOLE:-false}" == "true" ]]; then
  CONSOLE_CMDLINE="console=tty0 console=ttyS0,115200n8"
else
  CONSOLE_CMDLINE="console=ttyS0,115200n8 console=tty0"
fi
content="${content//@@CONSOLE_CMDLINE@@/$CONSOLE_CMDLINE}"
content="${content//@@OS_DISK_MATCH@@/$OS_DISK_MATCH}"
content="${content//@@DATA_DISK_MATCH@@/$DATA_DISK_MATCH}"
content="${content//@@PREFIX@@/$PREFIX}"
# An air-gapped host declares no default route at all. Empty GATEWAY means the routes block
# is omitted entirely, so the host reaches its own subnet and has no path off it - not a
# firewall rule that can be undone, an absent route. Same for DNS: nothing outside resolves,
# so configuring a resolver only invites timeouts.
if [[ -n "${GATEWAY:-}" && "${GATEWAY,,}" != none ]]; then
  ROUTES_BLOCK=$'        routes:\n          - to: default\n            via: '"$GATEWAY"$'\n'
else
  ROUTES_BLOCK=""
fi
if [[ -n "${DNS:-}" && "${DNS,,}" != none ]]; then
  NS_BLOCK=$'        nameservers:\n          addresses:\n            - '"$DNS"$'\n'
else
  NS_BLOCK=""
fi
# The build-info record on the installed host should state the air-gap posture explicitly,
# so anyone inspecting it later sees a deliberate choice rather than a missing field.
content="${content//@@GATEWAY_RECORD@@/${GATEWAY:-none-airgapped-no-default-route}}"
content="${content//@@ROUTES@@/$ROUTES_BLOCK}"
content="${content//@@NAMESERVERS@@/$NS_BLOCK}"
content="${content//@@PASSWORD_HASH@@/$PASSWORD_HASH}"
content="${content//@@ALLOW_PW@@/$ALLOW_PW}"
content="${content//@@SSH_KEYS@@/$SSH_KEYS_YAML}"
content="${content//@@USERNAME@@/$USERNAME}"
content="${content//@@LV_ROOT@@/$LV_ROOT}"
content="${content//@@LV_HOME@@/$LV_HOME}"
content="${content//@@LV_VAR@@/$LV_VAR}"
content="${content//@@LV_VARLOG@@/$LV_VARLOG}"
content="${content//@@LV_VARLOGAUDIT@@/$LV_VARLOGAUDIT}"
content="${content//@@LV_TMP@@/$LV_TMP}"
content="${content//@@CRYPT_OS@@/$CRYPT_OS}"
content="${content//@@CRYPT_DATA@@/$CRYPT_DATA}"
content="${content//@@VG0_DEV@@/$VG0_DEV}"
content="${content//@@VGDATA_DEV@@/$VGDATA_DEV}"

leftover="$(printf '%s\n' "$content" | awk '/@@[A-Z0-9_]+@@/ {print NR": "$0}')"
[[ -z "$leftover" ]] || die "unsubstituted placeholders remain:
$leftover"

# --- pre-flight: show what will be written ----------------------------------------------------
cat <<PREFLIGHT

  Resolved values
  ---------------
  hostname   $HOST
  address    $ADDR/$PREFIX
  gateway    ${GATEWAY:-<none - no default route, air-gapped>}
  dns        ${DNS:-<none>}
  nic match  $NIC_MATCH
  username   $USERNAME
  password   SET (sha512 crypt)
  allow-pw   $ALLOW_PW
  encryption $ENC_SUMMARY
  ssh keys   $KEY_COUNT
${KEY_SUMMARY%$'\n'}
  OS disk    id_path *-ata-*   (SATA; never USB)
  data disk  id_path *-nvme-*  (NVMe)
  LV sizes   root=$LV_ROOT home=$LV_HOME var=$LV_VAR varlog=$LV_VARLOG audit=$LV_VARLOGAUDIT tmp=$LV_TMP

PREFLIGHT

if (( DRYRUN )); then
  echo "Dry run - nothing written."
  exit 0
fi

# -o writes the two files to an ordinary directory. The media checks below exist to stop
# you writing onto a system disk; they do not apply when the target is explicitly a staging
# directory you name yourself. The files still have to reach a FAT32 volume labelled CIDATA.
if [[ -n "$OUTDIR" ]]; then
  [[ -d "$OUTDIR" ]] || mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
  chmod 700 "$OUTDIR" 2>/dev/null || true
  printf '%s\n' "$content" > "$OUTDIR/user-data"
  : > "$OUTDIR/meta-data"
  chmod 600 "$OUTDIR/user-data"
  sync
  echo "Wrote user-data and meta-data to $OUTDIR"
  ls -l "$OUTDIR"
  cat <<OUTNEXT

These two files ARE the seed. To finish, on a machine with USB:
  1. Format the stick:   sudo mkfs.vfat -F 32 -n CIDATA /dev/sdX1     <- CHECK THE DEVICE
  2. Copy BOTH files to the root of that stick.
  3. VERIFY LINE ENDINGS AFTER COPYING - they must stay LF. A single CR breaks
     cloud-init parsing, and you find out on the enclave floor:
         file <stick>/user-data        # must NOT say "CRLF line terminators"
     Copying via Windows is the usual way this happens.
  4. user-data contains the LUKS passphrase in PLAINTEXT. Treat the stick as a
     credential and wipe it when the build is done.
OUTNEXT
  exit 0
fi

[[ -n "$DEST" ]] || die "-d <mount point> is required (or use -n for a dry run)"
[[ -d "$DEST" ]] || die "not a directory: $DEST"

# --- safety: removable target, right filesystem, right label ----------------------------------
SRCDEV="$(findmnt -n -o SOURCE --target "$DEST" 2>/dev/null || true)"
FSTYPE="$(findmnt -n -o FSTYPE --target "$DEST" 2>/dev/null || true)"
LABEL="$(lsblk -n -o LABEL "$SRCDEV" 2>/dev/null | head -1 | tr -d ' ' || true)"
RM_FLAG="$(lsblk -n -o RM "$SRCDEV" 2>/dev/null | head -1 | tr -d ' ' || true)"

echo "  Target     $DEST  device=$SRCDEV  fs=$FSTYPE  label=${LABEL:-<none>}  removable=${RM_FLAG:-?}"
echo

[[ "$RM_FLAG" == "1" ]] || die "$SRCDEV is not removable. Point -d at the USB stick's mount point."
[[ "$FSTYPE" == "vfat" ]] || die "filesystem is '$FSTYPE', expected vfat:
    sudo mkfs.vfat -F 32 -n CIDATA $SRCDEV"
# cloud-init accepts 'cidata' or 'CIDATA' - case does not matter.
[[ "${LABEL,,}" == "cidata" ]] || die "volume label is '${LABEL:-<none>}', must be CIDATA:
    sudo umount $DEST && sudo fatlabel $SRCDEV CIDATA && sudo mount $SRCDEV $DEST"

printf '%s\n' "$content" > "$DEST/user-data"
: > "$DEST/meta-data"
sync

echo "Wrote user-data and meta-data to $DEST"
ls -l "$DEST"
cat <<NEXT

Next:
  1. sudo umount $DEST
  2. Insert BOTH sticks (Ubuntu installer + this one) and boot the installer.
  3. At GRUB press 'e', append "autoinstall" to the linux line, Ctrl-X.
     First run: omit "autoinstall" for a dry run that stops before touching disks.
  4. For the next host, re-run this with -H h2 -a <its address> and rewrite the same stick.
NEXT
