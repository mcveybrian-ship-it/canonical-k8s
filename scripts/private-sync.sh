#!/usr/bin/env bash
#
# private-sync.sh - carry client-private engagement material between working machines.
#
# These paths are gitignored, so git will never move them for you. They live only on the
# machines you put them on. This packs them into a tarball written OUTSIDE the repo, and
# unpacks them back into the right locations in a clone.
#
# Same script on both ends: native on Ubuntu, Git Bash on Windows.
#
#   ./scripts/private-sync.sh pack                      # on the machine that has them
#   ./scripts/private-sync.sh unpack -i <tarball>       # on the machine that needs them
#
# After unpack it verifies every restored path is still ignored by git, so the material
# cannot be committed to the public origin by accident. That check is the point of the
# script; the tar part is incidental.
#
set -euo pipefail

# Paths that must travel. Directories are taken whole.
PRIVATE_PATHS="HANDOFF.md docs/open-questions.md docs/runbook.md artifact archive"

# Credentials. Excluded unless --with-secrets is passed, and warned about loudly when it is.
SECRET_PATHS="scripts/install/02-host-autoinstall/host-params.env"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

# GNU tar reads "c:/path" as host:path and tries to resolve "c" as a hostname. Under Git
# Bash a drive-letter path is the natural thing to type, so normalise every user-supplied
# path to a real absolute path (/c/path) before tar ever sees it.
abspath() {
  local p="$1" d b
  d="$(dirname "$p")"
  b="$(basename "$p")"
  ( cd "$d" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$b" ) \
    || die "directory does not exist: $d"
}

usage() {
  cat <<'USAGE'
usage:
  private-sync.sh pack   [-o <tarball>] [--with-secrets]
  private-sync.sh unpack -i <tarball>  [-f]

  pack     collect the private paths into a tarball outside the repo
  unpack   restore them into this repo, then verify git still ignores them

options:
  -o <tarball>     output path for pack. Default ../canonical-k8s-private-<date>.tar.gz
  -i <tarball>     input tarball for unpack. Required
  -f               overwrite existing files on unpack. Without it, existing files are
                   backed up to <name>.bak-<timestamp> first
  --with-secrets   also include host-params.env, which holds the password hash, the LUKS
                   passphrase and SSH keys. Off by default and never silent
USAGE
}

# --- locate the repo root, and refuse to run anywhere else ---------------------------------
repo_root() {
  local d
  d="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
  # Git Bash reports C:/... ; normalise so prefix comparisons work
  ( cd "$d" && pwd -P )
}

MODE="${1:-}"
[ -n "$MODE" ] || { usage; exit 1; }
shift || true

OUT=""
IN=""
FORCE=0
WITH_SECRETS=0

while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="${2:-}"; shift 2 ;;
    -i) IN="${2:-}"; shift 2 ;;
    -f) FORCE=1; shift ;;
    --with-secrets) WITH_SECRETS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

ROOT="$(repo_root)"
cd "$ROOT"

[ -f "START-HERE.md" ] || die "this does not look like the canonical-k8s repo (no START-HERE.md)"

case "$MODE" in

  pack)
    [ -n "$OUT" ] || OUT="../canonical-k8s-private-$(date +%F).tar.gz"

    # The archive must not land inside the repo, or the next pack sweeps up the last one
    # and a stray tarball sits in the working tree holding the whole engagement record.
    outdir="$( cd "$(dirname "$OUT")" 2>/dev/null && pwd -P )" \
      || die "output directory does not exist: $(dirname "$OUT")"
    case "$outdir/" in
      "$ROOT"/*|"$ROOT"/) die "refusing to write the archive inside the repo: $outdir" ;;
    esac
    OUT="$outdir/$(basename "$OUT")"

    included=""
    missing=""
    for p in $PRIVATE_PATHS; do
      if [ -e "$p" ]; then included="$included $p"; else missing="$missing $p"; fi
    done

    if [ "$WITH_SECRETS" -eq 1 ]; then
      for p in $SECRET_PATHS; do
        [ -e "$p" ] && included="$included $p"
      done
      echo "WARNING: --with-secrets includes host-params.env (password hash, LUKS"
      echo "         passphrase, SSH keys). Treat the tarball as a credential."
      echo
    fi

    [ -n "$included" ] || die "none of the private paths exist here - nothing to pack"

    echo "packing:"
    for p in $included; do note "$p"; done
    if [ -n "$missing" ]; then
      echo "not present, skipped:"
      for p in $missing; do note "$p"; done
    fi

    tar -czf "$OUT" $included
    echo
    echo "wrote   $OUT"
    echo "size    $(du -h "$OUT" | cut -f1)"
    if command -v sha256sum >/dev/null 2>&1; then
      echo "sha256  $(sha256sum "$OUT" | cut -d' ' -f1)"
    fi
    ;;

  unpack)
    [ -n "$IN" ] || die "unpack needs -i <tarball>"
    [ -f "$IN" ] || die "no such tarball: $IN"
    IN="$(abspath "$IN")"

    tar -tzf "$IN" >/dev/null 2>&1 || die "not a readable gzip tarball: $IN"

    # The tarball holds the whole engagement record. If it is sitting inside the working
    # tree it is one stray "git add -A" away from the public origin. .gitignore carries a
    # backstop pattern, but say so out loud rather than relying on it.
    case "$IN/" in
      "$ROOT"/*)
        echo "WARNING: the tarball is inside the repo working tree:"
        echo "           $IN"
        echo "         It contains all of the client-private material. Move it out when"
        echo "         you are done - origin is public."
        echo
        ;;
    esac

    # Running this as root leaves every restored file owned by root inside someone else's
    # home directory, and the next ordinary edit fails. Catch it before extracting.
    if [ "$(id -u)" -eq 0 ]; then
      owner="$(stat -c '%U' "$ROOT" 2>/dev/null || echo root)"
      if [ "$owner" != "root" ]; then
        echo "WARNING: running as root, but $ROOT is owned by '$owner'."
        echo "         Restored files will be owned by root and '$owner' will not be able"
        echo "         to edit them. Either re-run as $owner, or afterwards:"
        echo "           chown -R $owner:$owner $ROOT"
        echo
      fi
    fi

    echo "tarball contains:"
    tar -tzf "$IN" | sed 's/^/  /'
    echo

    # Back up anything we are about to land on, unless -f says do not bother.
    if [ "$FORCE" -eq 0 ]; then
      stamp="$(date +%Y%m%d-%H%M%S)"
      for p in $(tar -tzf "$IN" | grep -v '/$'); do
        if [ -e "$p" ]; then
          cp -a "$p" "$p.bak-$stamp"
          note "backed up $p -> $p.bak-$stamp"
        fi
      done
    fi

    tar -xzf "$IN" -C "$ROOT"
    echo "extracted into $ROOT"

    # tar preserves the modes from wherever this was packed. Packed on Windows that means
    # 644 - world-readable client-private material. Tighten to owner-only on the way in.
    echo "tightening permissions to owner-only:"
    for p in $PRIVATE_PATHS; do
      [ -e "$p" ] || continue
      if [ -d "$p" ]; then
        chmod -R go-rwx "$p"
        find "$p" -type d -exec chmod u+rwx {} +
      else
        chmod 600 "$p"
      fi
      note "$(ls -ld "$p" | awk '{print $1, $3, $9}')"
    done
    echo

    # The whole reason this script exists: prove the restored files are still ignored,
    # so they cannot be pushed to the public origin from this machine.
    echo "verifying git still ignores the restored paths:"
    bad=0
    for p in $(tar -tzf "$IN" | grep -v '/$'); do
      if git check-ignore -q "$p"; then
        note "ignored  $p"
      else
        echo "  NOT IGNORED  $p" >&2
        bad=1
      fi
    done

    if [ "$bad" -ne 0 ]; then
      echo >&2
      die "at least one restored path is NOT gitignored on this machine. Fix .gitignore before committing anything - origin is public."
    fi

    echo
    echo "all restored paths are ignored. git status should be unchanged:"
    git status --short || true
    ;;

  *)
    usage
    exit 1
    ;;
esac
