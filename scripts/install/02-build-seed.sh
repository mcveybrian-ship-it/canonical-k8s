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
# MACHINE: stage-01 with -o (it has no USB - copy the two files to the stick afterwards), or
# any Linux machine with the CIDATA stick mounted, with -d. It needs host-params.env, which is
# gitignored and holds secrets, so it runs where that file lives - not on an enclave host.

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

# BASH GOTCHA, found 2026-09-02: in ${var//pattern/replacement}, an '&' in the REPLACEMENT
# means "the text that was matched" - the same rule sed uses. So substituting a value
# containing '2>&1' silently produced '2>@@PLACEHOLDER@@1'. Any free-text value can hit this:
# a LUKS passphrase or an SSH key comment containing '&' would corrupt the seed with no error.
# Escape every replacement that is not a fixed literal.
esc() { printf '%s' "${1//&/\\&}"; }

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

# ---- DRIFT CHECK: your params file vs the example ---------------------------------------
# WHY THIS EXISTS. host-params.env is gitignored, because it holds the LUKS passphrase and the
# password hash. So every parameter added to host-params.env.example afterwards is ABSENT from
# the real file, and the script quietly falls back to a default that may be wrong for this
# host. Nothing compares the two.
#
# On 2026-09-17 that cost a build: DATA_VG_SIZE had been added to the example that morning and
# was missing from the live file. Its default is -1, meaning "the whole data disk becomes
# vg-data" - which on host-1..3 would have consumed the 1 TB that must be SPLIT, leaving
# nothing raw for the Ceph OSD. Partitioning is install-time and not retrofittable: the cost
# of that default being silently wrong is rebuilding the host, and later the OSD with it.
#
# So: REFUSE on a missing parameter that changes the disk layout or the security posture, WARN
# on the rest. A default is only safe when it is also correct.
_example="$HERE/02-host-autoinstall/host-params.env.example"
if [[ -r "$_example" ]]; then
  # Keys only - never values. This file holds secrets and nothing here may print one.
  _missing="$(comm -23 \
      <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$_example" | tr -d '=' | sort -u) \
      <(grep -oE '^[A-Z_][A-Z0-9_]*=' "$PARAMS"   | tr -d '=' | sort -u))"
  if [[ -n "$_missing" ]]; then
    # Anything here silently changes the disk layout or the crypto posture when defaulted.
    _critical="DATA_VG_SIZE ENCRYPT_DISKS LUKS_UNLOCK OS_DISK_MATCH DATA_DISK_MATCH"
    _blocking=""
    for _k in $_missing; do
      case " $_critical " in *" $_k "*) _blocking="$_blocking $_k" ;; esac
    done
    printf '\n  [!]  %s is missing parameters that %s has:\n' "$(basename "$PARAMS")" "$(basename "$_example")" >&2
    for _k in $_missing; do printf '         %s\n' "$_k" >&2; done
    if [[ -n "$_blocking" ]]; then
      die "refusing to build a seed with these defaulted:$_blocking

       Each one silently changes the disk layout or the crypto posture, and both are
       INSTALL-TIME - a wrong default here means rebuilding the host, not editing a file.
       Add them to $PARAMS. The example explains what each value means and why."
    fi
    printf '         none of these change the disk layout - defaults will be used\n\n' >&2
  fi
fi

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

# HOW the volume unlocks, recorded now and acted on after first boot. Validated here so a
# typo is caught while building the stick rather than discovered at a console in a rack.
LUKS_UNLOCK="${LUKS_UNLOCK:-passphrase}"
case "$LUKS_UNLOCK" in
  passphrase|tpm2) : ;;
  *) die "LUKS_UNLOCK must be passphrase or tpm2, got '$LUKS_UNLOCK'" ;;
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
# HOW MUCH OF THE DATA DISK BECOMES vg-data. -1 is the whole disk (host-4); a sized value
# leaves the remainder UNPARTITIONED for Ceph to own (host-1..3). Validated here rather than
# discovered by subiquity: a storage error surfaces 40 seconds into an unattended install,
# on a console that on these machines does not exist remotely.
# PRINTED IN THE SUMMARY TOO, not just validated. On 2026-09-21 this dry run showed every LV
# size and said nothing about DATA_VG_SIZE - the one parameter being changed for that host, and
# the one whose silent default cost a build on 2026-09-17. A summary that omits the value under
# review invites approval of something nobody looked at.
DATA_VG_SIZE="${DATA_VG_SIZE:--1}"
case "$DATA_VG_SIZE" in
  -1) : ;;
  *[0-9][KMGTkmgt]) : ;;
  *[0-9]) die "DATA_VG_SIZE='$DATA_VG_SIZE' has no unit suffix. subiquity reads a bare number
       as BYTES, so '500' is 500 bytes and the install fails in a way that does not say so.
       Write it as 500G, or -1 for the whole disk." ;;
  *) die "DATA_VG_SIZE must be -1 or a size with a K/M/G/T suffix, got '$DATA_VG_SIZE'" ;;
esac

[ "$OS_DISK_MATCH" != "$DATA_DISK_MATCH" ] ||   die "OS_DISK_MATCH and DATA_DISK_MATCH are identical ('$OS_DISK_MATCH') - they would both
       resolve to the same disk. On an all-NVMe host, disambiguate by PCI address:
         ls -l /dev/disk/by-path/ | grep -v part"
  (( ${#LUKS_PASSPHRASE} >= 12 )) || die "LUKS_PASSPHRASE is under 12 characters"
  # curtin storage-config dm_crypt actions, one per volume group. key: is the LUKS passphrase
  # IN PLAINTEXT inside user-data - why every seed is a credential (backlog 2.6).
  CRYPT_OS=$'      - id: crypt-os\n        type: dm_crypt\n        dm_name: crypt-os\n        volume: p-pv\n        key: \''"$LUKS_PASSPHRASE"$'\'\n'
  CRYPT_DATA=$'      - id: crypt-data\n        type: dm_crypt\n        dm_name: crypt-data\n        volume: p-data\n        key: \''"$LUKS_PASSPHRASE"$'\'\n'
  VG0_DEV="crypt-os"
  VGDATA_DEV="crypt-data"
  ENC_SUMMARY="LUKS on both volume groups"
  # An installer late-command: add a random keyfile as a SECOND keyslot on crypt-data and list
  # it in crypttab, so only the OS volume asks for a passphrase at boot (START-HERE step 02).
  KEYFILE_LATECMD=$(cat <<'KFEOF'
    - |
      set -e
      # Only act if a separate data volume actually exists on this host.
      if cryptsetup status crypt-data >/dev/null 2>&1; then
        DEV=$(cryptsetup status crypt-data | awk '/device:/{print $2}')
        UUID=$(blkid -s UUID -o value "$DEV")

        install -d -m 0700 /target/etc/luks
        dd if=/dev/urandom of=/target/etc/luks/crypt-data.key bs=512 count=8 status=none
        chmod 0400 /target/etc/luks/crypt-data.key

        # Add the keyfile as an ADDITIONAL keyslot. The passphrase slot is never removed,
        # so a keyfile problem still leaves you able to unlock by hand.
        printf '%s' "__LUKS_PASSPHRASE__" | \
          cryptsetup luksAddKey "$DEV" /target/etc/luks/crypt-data.key --key-file=-

        # nofail: a keyfile problem then degrades to "data volume not mounted" instead of
        # blocking boot for six minutes with no sshd.
        sed -i '/^crypt-data/d' /target/etc/crypttab 2>/dev/null || true
        echo "crypt-data UUID=$UUID /etc/luks/crypt-data.key luks,discard,nofail" \
          >> /target/etc/crypttab
      fi
    - curtin in-target --target=/target -- update-initramfs -u -k all
KFEOF
)
  KEYFILE_LATECMD="${KEYFILE_LATECMD//__LUKS_PASSPHRASE__/$LUKS_PASSPHRASE}"
else
  CRYPT_OS=""
  CRYPT_DATA=""
  VG0_DEV="p-pv"
  VGDATA_DEV="p-data"
  ENC_SUMMARY="NONE - plaintext disks"
  KEYFILE_LATECMD=""
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
content="${content//@@NIC_MATCH@@/$(esc "$NIC_MATCH")}"
# SERIAL_CONSOLE=true puts ttyS0 last, so prompts go to serial - correct for a racked
# host reached over BMC serial-over-LAN. false puts tty0 last so prompts appear on an
# attached monitor. Getting this backwards makes a LUKS host look hung at boot.
if [[ "${SERIAL_CONSOLE:-false}" == "true" ]]; then
  CONSOLE_CMDLINE="console=tty0 console=ttyS0,115200n8"
else
  CONSOLE_CMDLINE="console=ttyS0,115200n8 console=tty0"
fi
content="${content//@@CONSOLE_CMDLINE@@/$CONSOLE_CMDLINE}"
content="${content//@@KEYFILE_LATECMD@@/$(esc "$KEYFILE_LATECMD")}"
content="${content//@@LUKS_UNLOCK@@/$LUKS_UNLOCK}"
content="${content//@@OS_DISK_MATCH@@/$(esc "$OS_DISK_MATCH")}"
content="${content//@@DATA_DISK_MATCH@@/$(esc "$DATA_DISK_MATCH")}"
content="${content//@@DATA_VG_SIZE@@/$DATA_VG_SIZE}"
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
content="${content//@@PASSWORD_HASH@@/$(esc "$PASSWORD_HASH")}"
content="${content//@@ALLOW_PW@@/$ALLOW_PW}"
content="${content//@@SSH_KEYS@@/$(esc "$SSH_KEYS_YAML")}"
content="${content//@@USERNAME@@/$USERNAME}"
content="${content//@@LV_ROOT@@/$LV_ROOT}"
content="${content//@@LV_HOME@@/$LV_HOME}"
content="${content//@@LV_VAR@@/$LV_VAR}"
content="${content//@@LV_VARLOG@@/$LV_VARLOG}"
content="${content//@@LV_VARLOGAUDIT@@/$LV_VARLOGAUDIT}"
content="${content//@@LV_TMP@@/$LV_TMP}"
content="${content//@@CRYPT_OS@@/$(esc "$CRYPT_OS")}"
content="${content//@@CRYPT_DATA@@/$(esc "$CRYPT_DATA")}"
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
  data VG    $(if [ "$DATA_VG_SIZE" = -1 ]; then printf 'the WHOLE data disk (nothing left raw for a Ceph OSD)'; else printf '%s - the remainder of the data disk is left UNPARTITIONED' "$DATA_VG_SIZE"; fi)
  unlock     $LUKS_UNLOCK$([ "$LUKS_UNLOCK" = passphrase ] && printf ' (a human types it at the console on every boot)')

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
  # 0700 dir, 0600 user-data: it holds the LUKS passphrase and the admin password hash.
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
