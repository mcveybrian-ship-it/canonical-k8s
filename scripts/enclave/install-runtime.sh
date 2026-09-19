#!/usr/bin/env bash
# =========================================================================================
# install-runtime.sh - a root-owned copy of scripts/enclave/ for systemd units to execute.
#
#     sudo ./install-runtime.sh          MACHINE: any in-gap machine. Called by the timer
#                                        installers (monitoring.sh facts-timer,
#                                        vm-backup.sh schedule); rarely run by hand.
#     ./install-runtime.sh --print-dir   prints where the copy lives, nothing else.
#
# WHY THIS EXISTS - backlog 3.11, found 2026-09-19:
#
#   The facts and backup timers ran /home/encadmin/canonical-k8s/scripts/enclave/*.sh AS ROOT,
#   and those files are encadmin:encadmin 770. Anything able to write as encadmin got root on
#   the next timer tick - no sudo password, and no sudo audit record. That is a privilege
#   escalation path built by our own tooling, on every machine that had the timers.
#
#   A unit must only execute code that only root can change. So the timers now run a copy
#   under RUNTIME_DIR, owned root:root and writable by nobody else. Refreshing that copy
#   needs sudo - which is the point: changing what root runs on a schedule is a privileged
#   act and should leave the same record as any other.
#
# WHAT IS COPIED: the scripts, the tracked .env files and the dashboards - what the timers
# load relative to their own location. NOT *-params.env: those are gitignored, may hold
# secrets, and no timer reads them.
#
# THE COPY GOES STALE WHEN THE REPO IS UPDATED, deliberately. Re-run the timer installer (or
# this script) after pushing a new version. The copy records the commit it came from, so
# `cat $RUNTIME_DIR/.source` answers "which code is root running".
# =========================================================================================
set -euo pipefail

RUNTIME_DIR="${ENCLAVE_RUNTIME_DIR:-/usr/local/lib/enclave}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
die()  { printf '  [!!] %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = --print-dir ]; then printf '%s\n' "$RUNTIME_DIR"; exit 0; fi
[ "$(id -u)" -eq 0 ] || die "needs root - run with sudo"

# THE DESTINATION IS CHECKED FIRST, before anything is written. It is replaced wholesale, so
# a wrong value here would delete whatever it points at. Only a dedicated directory under a
# root-owned system prefix is accepted - a parameter is allowed, a dangerous one is not.
case "$RUNTIME_DIR" in
  /usr/local/lib/?*|/opt/?*) : ;;
  *) die "ENCLAVE_RUNTIME_DIR='$RUNTIME_DIR' - must be a directory under /usr/local/lib/ or /opt/" ;;
esac
case "$RUNTIME_DIR" in *..*|*//*) die "ENCLAVE_RUNTIME_DIR='$RUNTIME_DIR' is not a plain path" ;; esac
# The copy is only as safe as its parent: a root-owned file inside a user-writable directory
# can be renamed away and replaced.
parent="$(dirname "$RUNTIME_DIR")"
[ -d "$parent" ] || die "$parent does not exist"
[ "$(stat -c %u "$parent")" -eq 0 ] || die "$parent is not owned by root - refusing"
case "$(stat -c %A "$parent")" in ?????w????|????????w?) die "$parent is writable by non-root - refusing" ;; esac
[ "$RUNTIME_DIR" != "$HERE" ] || die "source and destination are the same directory"

stage="$(mktemp -d "$parent/.enclave-runtime.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

# Scripts, tracked env files, dashboards, and the small support directories. Listed rather
# than "everything but secrets": a new gitignored file must not start travelling by default.
shopt -s nullglob
for f in "$HERE"/*.sh "$HERE"/*.py "$HERE"/*.env "$HERE"/*.tsv; do
  case "$(basename "$f")" in *-params.env) continue ;; esac
  cp -p "$f" "$stage/"
done
for d in dashboards trust-anchors csr-profiles; do
  [ -d "$HERE/$d" ] && cp -rp "$HERE/$d" "$stage/"
done
shopt -u nullglob

src="unknown"
[ -r "$HERE/../../.pushed-from" ] && src="$(head -1 "$HERE/../../.pushed-from")"
command -v git >/dev/null 2>&1 && git -C "$HERE" rev-parse --short HEAD >/dev/null 2>&1 \
  && src="$(git -C "$HERE" rev-parse --short HEAD)$(git -C "$HERE" diff --quiet HEAD -- . || echo '-dirty')"
printf '%s\ninstalled %s from %s\n' "$src" "$(date -u +%FT%TZ)" "$HERE" > "$stage/.source"

chown -R root:root "$stage"
chmod -R u=rwX,go=rX "$stage"
chmod 0755 "$stage"

# Swap in place of the old copy. mv of a directory onto an existing one fails, so move the
# old one aside first; the window is two renames.
if [ -e "$RUNTIME_DIR" ]; then
  old="$RUNTIME_DIR.old.$$"
  mv "$RUNTIME_DIR" "$old"
  mv "$stage" "$RUNTIME_DIR"
  rm -rf "$old"
else
  mv "$stage" "$RUNTIME_DIR"
fi
trap - EXIT

# PROVE IT rather than assert it: nothing under the copy may be writable by anyone but root.
bad="$(find "$RUNTIME_DIR" \( ! -user root -o -perm /022 \) -print | head -5)"
[ -z "$bad" ] || die "copy is NOT root-only - first offenders:
$bad"
ok "runtime copy at $RUNTIME_DIR ($(find "$RUNTIME_DIR" -type f | wc -l) files, root-only) - source: $(head -1 "$RUNTIME_DIR/.source")"
