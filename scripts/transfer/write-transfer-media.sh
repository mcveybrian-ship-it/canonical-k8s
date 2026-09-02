#!/usr/bin/env bash
#
# write-transfer-media.sh - step 2 of 3. RUNS ON build-01.
#
# Pulls the mirror tree and the extras from STAGE-01 and writes them onto the transfer
# SSD. build-01 exists because STAGE-01 is a Hyper-V guest and Hyper-V has no casual USB
# passthrough - see docs/airgap-media.md section 6.
#
# rsync, never tar. Later trips carry only the delta because rsync compares against what
# is already on the drive; a tarball destroys that, and tarring 300+ GB of already
# compressed .debs costs hours for nothing.
#
# NO checksum pass over the mirror. An apt repository is a signed hash chain already -
# `apt-get update` on the far side is the integrity check, and restore-mirror.sh runs it.
# Only the extras are hashed, by build-transfer-bundle.sh.
#
#   ./write-transfer-media.sh [-p params] [-n] [-m /mnt/transfer]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PARAMS="$SCRIPT_DIR/transfer-params.env"
DRY=0
MOUNT_OVERRIDE=""

usage() {
  cat <<'USAGE'
usage: write-transfer-media.sh [-p <params>] [-n] [-m <mountpoint>]

  -p <file>  parameters file (default: transfer-params.env beside this script)
  -n         dry run - rsync --dry-run, nothing written
  -m <path>  override MEDIA_MOUNT from the params file
USAGE
}

while getopts ':p:nm:h' o; do
  case "$o" in
    p) PARAMS="$OPTARG" ;;
    n) DRY=1 ;;
    m) MOUNT_OVERRIDE="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
head2() { printf '\n== %s ==\n' "$*"; }

[ -r "$PARAMS" ] || die "no params file: $PARAMS"
set -a
# shellcheck disable=SC1090
. "$PARAMS"
set +a

: "${STAGE_HOST:?}" "${STAGE_USER:?}" "${SSH_KEY:?}"
: "${MIRROR_BASE:?}" "${STAGING_DIR:?}"
MEDIA_MOUNT="${MOUNT_OVERRIDE:-${MEDIA_MOUNT:?}}"
RSYNC_BWLIMIT="${RSYNC_BWLIMIT:-0}"

SSH_CMD="ssh -i $SSH_KEY -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
REMOTE="$STAGE_USER@$STAGE_HOST"

# --- 1. the target must be a REAL mounted filesystem ------------------------------------------
# Writing 320 GB into an unmounted mount point fills the root filesystem instead of the
# SSD, and you find out when the box wedges. Refuse rather than warn.
head2 "checking the target"
[ -d "$MEDIA_MOUNT" ] || die "$MEDIA_MOUNT does not exist - create and mount the SSD first"
mountpoint -q "$MEDIA_MOUNT" \
  || die "$MEDIA_MOUNT is NOT a mount point. Mount the transfer SSD there first, by label:
         sudo mkdir -p $MEDIA_MOUNT && sudo mount LABEL=${MEDIA_LABEL:-enclave-xfer} $MEDIA_MOUNT"

# -P and --output are mutually exclusive in GNU coreutils; --output already gives one
# clean column, so -P has nothing to add.
avail=$(df -BG --output=avail "$MEDIA_MOUNT" | tail -1 | tr -dc '0-9')
note "target : $MEDIA_MOUNT"
note "free   : ${avail} GB"
note "fstype : $(findmnt -no FSTYPE "$MEDIA_MOUNT")"

[ -w "$MEDIA_MOUNT" ] || die "$MEDIA_MOUNT is not writable by $(id -un)"

# --- 1a. one at a time -------------------------------------------------------------------------
# Two concurrent runs against the same target is not a theoretical problem: it happened on
# 2026-09-02. The script was started in a tmux window, tmux was detached, and it was started
# again in the plain ssh shell - two rsyncs writing /mnt/transfer/mirror/ with --delete, each
# able to remove files the other was mid-write on, pulling the same 317 GB twice over one link.
#
# flock on the target, not on /var/lock, so the guard follows the DISK. Two different mount
# points can run at once, which is legitimate; two runs at the same one cannot.
#
# This runs AFTER the mountpoint and writability checks, deliberately. Locking first would
# create the lock file on the ROOT filesystem whenever the SSD was not mounted - writing to
# the very place the mountpoint check exists to protect.
exec 9>"${MEDIA_MOUNT%/}/.write-transfer.lock" 2>/dev/null || true
if ! flock -n 9; then
  die "another write-transfer-media.sh is already writing to $MEDIA_MOUNT.
       Check it:   ps -eo pid,etime,cmd | grep [w]rite-transfer
       If you started one in tmux, reattach instead:   tmux attach -t xfer"
fi


# --- 2. reachability and size -------------------------------------------------------------------
head2 "checking STAGE-01"
$SSH_CMD "$REMOTE" true 2>/dev/null || die "cannot ssh to $REMOTE with $SSH_KEY"
note "ssh    : ok"

need=$($SSH_CMD "$REMOTE" "du -sBG '$MIRROR_BASE/mirror' 2>/dev/null | cut -f1 | tr -dc '0-9'")
extras=$($SSH_CMD "$REMOTE" "du -sBG '$STAGING_DIR' 2>/dev/null | cut -f1 | tr -dc '0-9'" || echo 0)
total=$(( need + extras ))
note "mirror : ${need} GB"
note "extras : ${extras} GB"
note "total  : ${total} GB"

if [ "$avail" -lt "$total" ]; then
  die "not enough space: need ${total} GB, have ${avail} GB on $MEDIA_MOUNT"
fi

# --- 3. pull ---------------------------------------------------------------------------------
RSYNC_OPTS=(-a --delete --human-readable "--info=progress2,stats1")
[ "$RSYNC_BWLIMIT" -gt 0 ] && RSYNC_OPTS+=(--bwlimit="$RSYNC_BWLIMIT")
[ "$DRY" -eq 1 ] && RSYNC_OPTS+=(--dry-run)

head2 "pulling the mirror  (this is the long one)"
note "expect roughly an hour on a 1 Gb link - 90,000 files, so per-file overhead dominates"
# A dry run must not touch the target at all - the point of -n is to answer "would this
# work" without leaving anything behind to explain later.
[ "$DRY" -eq 0 ] && mkdir -p "$MEDIA_MOUNT/mirror"
rsync "${RSYNC_OPTS[@]}" -e "$SSH_CMD" "$REMOTE:$MIRROR_BASE/mirror/" "$MEDIA_MOUNT/mirror/"

head2 "pulling the extras"
[ "$DRY" -eq 0 ] && mkdir -p "$MEDIA_MOUNT/bundle"
rsync "${RSYNC_OPTS[@]}" -e "$SSH_CMD" "$REMOTE:$STAGING_DIR/" "$MEDIA_MOUNT/bundle/"

# --- 4. verify the extras against their manifest ------------------------------------------------
head2 "verifying extras"
if [ "$DRY" -eq 1 ]; then
  note "DRY RUN - skipped"
elif [ -f "$MEDIA_MOUNT/bundle/MANIFEST.sha256" ]; then
  ( cd "$MEDIA_MOUNT/bundle" && sha256sum -c --quiet MANIFEST.sha256 ) \
    && note "manifest: all items verified" \
    || die "MANIFEST MISMATCH - do not carry this disk"
else
  note "no manifest found - did build-transfer-bundle.sh run?"
fi

# --- 5. flush --------------------------------------------------------------------------------
if [ "$DRY" -eq 0 ]; then
  head2 "flushing to disk"
  sync
  note "safe to unmount:  sudo umount $MEDIA_MOUNT"
fi

head2 "done"
note "on disk : $(du -sh "$MEDIA_MOUNT" 2>/dev/null | cut -f1)"
note "next    : carry the SSD across, then run bundle/scripts/restore-mirror.sh on svc-repo-01"
