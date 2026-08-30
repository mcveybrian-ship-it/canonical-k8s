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
#   -p FILE    params file (default: 02-host-autoinstall/host-params.env)
#   -t FILE    template (default: 02-host-autoinstall/user-data.template)
#   -n         dry run - print the resolved values and exit without writing
#
set -euo pipefail

HOST=""; ADDR=""; DEST=""; DRYRUN=0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS="$HERE/02-host-autoinstall/host-params.env"
TEMPLATE="$HERE/02-host-autoinstall/user-data.template"

while getopts ":H:a:d:p:t:nh" opt; do
  case "$opt" in
    H) HOST="$OPTARG" ;;
    a) ADDR="$OPTARG" ;;
    d) DEST="$OPTARG" ;;
    p) PARAMS="$OPTARG" ;;
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
[[ -f "$PARAMS" ]] || die "params file not found: $PARAMS
    Copy host-params.env.example to host-params.env and fill it in."

# shellcheck disable=SC1090
set -a; . "$PARAMS"; set +a
for v in NIC_MATCH PREFIX GATEWAY DNS PASSWORD_HASH; do
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
content="${content//@@PREFIX@@/$PREFIX}"
content="${content//@@GATEWAY@@/$GATEWAY}"
content="${content//@@DNS@@/$DNS}"
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
  gateway    $GATEWAY
  dns        $DNS
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
