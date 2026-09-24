#!/usr/bin/env bash
# =========================================================================================
# push-repo-to-host.sh - copy this repository onto an air-gapped host.
#
#     MACHINE: runs on stage-01 (or wherever the repo lives). NOT on the target.
#
#     ./push-repo-to-host.sh 10.0.20.158
#     ./push-repo-to-host.sh 10.0.20.155 -k ~/.ssh/build01 -d ~/canonical-k8s
#     ./push-repo-to-host.sh 10.2.20.162 --allow-dirty   # send HEAD even with local edits
#     ./push-repo-to-host.sh 10.2.20.162 --allow-untracked   # leave uncommitted new scripts behind
#     -u USER sets the remote account (default encadmin); REPO_PUSH_KEY replaces the -k default
#
# WHY THIS EXISTS RATHER THAN 'rsync -a' OR 'git clone':
#
#   An in-gap host cannot reach github.com, so it cannot clone. The obvious alternative is
#   to rsync the working tree - and that would carry host-params.env, which holds the LUKS
#   passphrase and the password hash, onto every host in the enclave. It would also carry
#   HANDOFF.md, docs/open-questions.md, docs/runbook.md, artifact/ and archive/, none of
#   which belong on a target machine.
#
#   'git archive HEAD' emits ONLY files tracked at HEAD. Anything gitignored is by
#   definition not tracked, so the secrets cannot ride along even by mistake. That is a
#   property of the mechanism, not of remembering to pass --exclude.
#
#   The check below proves it on every run rather than trusting the explanation above.
# =========================================================================================
set -euo pipefail

TARGET=""; KEY="${REPO_PUSH_KEY:-$HOME/.ssh/build01}"; DEST="canonical-k8s"; USER_NAME="encadmin"
ALLOW_DIRTY=0; ALLOW_UNTRACKED=0

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die()   { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -k) KEY="$2"; shift 2 ;;
    -d) DEST="$2"; shift 2 ;;
    -u) USER_NAME="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --allow-untracked) ALLOW_UNTRACKED=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *)  TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
[ -r "$KEY" ] || die "no ssh key at $KEY (use -k, or set REPO_PUSH_KEY)"
# For display only. -d takes a path relative to the remote home OR an absolute one; printing
# "~/$DEST" for an absolute path showed "~//home/encadmin/..." (2026-09-23), which reads like
# the files went somewhere wrong. They had not - but a message that looks wrong costs a check.
# shellcheck disable=SC2088  # the tilde is text for the reader, never expanded
case "$DEST" in /*) DEST_SHOW="$DEST" ;; *) DEST_SHOW="~/$DEST" ;; esac

cd "$(git rev-parse --show-toplevel)" || die "not inside a git repository"

# ---- REFUSE TO PUSH TO YOURSELF ---------------------------------------------------------
# The header says this runs on stage-01 and NOT on the target, and a header refuses nothing -
# proven on 2026-09-17 when 03-host-services.sh was run on stage-01 because its own header
# said not to. Pasted on the target, this would git-archive that machine's repo over itself
# WHILE something from it may be executing. That is the failure that invalidated a 58-minute
# verify run on host-4: the code changed underneath a running script and the result could not
# be trusted.
_mine="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')"
case " $_mine " in
  *" $TARGET "*)
    die "REFUSING: $TARGET is THIS machine ($(hostname -s)).
       This pushes the repository FROM the machine that owns it TO an enclave host. Run it on
       stage-01 and name the host you want it sent to:
         ./scripts/install/push-repo-to-host.sh <host address>" ;;
esac

# ---- prove the archive is clean BEFORE sending it ---------------------------------------
# These are the five paths git cannot carry (CLAUDE.md), plus any live params file. If the
# gitignore is ever loosened, this stops the leak instead of discovering it on the target.
echo "  checking the archive carries nothing private ..."
LEAK=$(git archive --format=tar HEAD | tar -t 2>/dev/null | grep -E \
  '^(HANDOFF\.md|docs/open-questions\.md|docs/runbook\.md|artifact/|archive/)|params\.env$' || true)
[ -z "$LEAK" ] && echo "  [ok] tracked files only - no private paths, no live params" \
  || die "the archive contains private paths. Nothing was sent:
$LEAK"

# ---- refuse to ship yesterday's code ----------------------------------------------------
# THIS SENDS HEAD, NOT THE WORKING TREE. That is deliberate - it is what keeps the secrets
# off the target - but it means an edit you have not committed DOES NOT TRAVEL, silently.
#
# On 2026-09-10 svc-repo-01 ran a copy of stig-tailor.sh from before `preflight` existed.
# The tool printed its usage; that reads like a wrong command, not like an old file, and the
# next hour went into the wrong question. The script knew, and did not say.
DIRTY=$(git diff --name-only HEAD -- . 2>/dev/null || true)
if [ -n "$DIRTY" ]; then
  if [ "$ALLOW_DIRTY" -eq 1 ]; then
    echo "  [!]  tracked files differ from HEAD - sending HEAD ANYWAY (--allow-dirty):"
    echo "$DIRTY" | sed 's/^/         /'
  else
    die "tracked files are modified and WILL NOT BE SENT - git archive ships HEAD:
$(echo "$DIRTY" | sed 's/^/       /')

       commit them, or re-run with --allow-dirty to send HEAD as-is."
  fi
fi

# ---- and refuse to LEAVE BEHIND a script git has never seen -----------------------------
# The second face of the same fault (backlog 3.22). A brand-new, uncommitted script is not
# tracked, so git archive does not carry it - and every line below still says [ok]. Caught
# 2026-09-23 pushing audit-offload.sh to svc-obs-01: the push succeeded, the file was not there.
# --allow-dirty does NOT cover this. It sends HEAD despite edits; it cannot send what git has
# never seen. Only scripts/ refuses - that is what the targets execute.
UNTRACKED=$(git ls-files --others --exclude-standard -- scripts/ 2>/dev/null || true)
if [ -n "$UNTRACKED" ]; then
  if [ "$ALLOW_UNTRACKED" -eq 1 ]; then
    echo "  [!]  $(echo "$UNTRACKED" | wc -l) untracked file(s) under scripts/ NOT SENT (--allow-untracked):"
    echo "$UNTRACKED" | sed 's/^/         /'
  else
    die "$(echo "$UNTRACKED" | wc -l) untracked file(s) under scripts/ WILL NOT BE SENT - git archive ships tracked files only:
$(echo "$UNTRACKED" | sed 's/^/       /')

       commit them and re-push, or re-run with --allow-untracked to leave them behind.
       --allow-dirty does not send these."
  fi
fi
OTHER=$(git ls-files --others --exclude-standard -- . ':!scripts/' 2>/dev/null | wc -l)
[ "$OTHER" -eq 0 ] || echo "  [i]  $OTHER untracked file(s) outside scripts/ not sent - 'git status' lists them"

# ONE TCP CONNECTION FOR THE WHOLE RUN, because the targets are firewalled now.
#
# This script makes five separate ssh calls: reachability, the tar stream, the file count,
# the executable test, and the version stamp. `ufw limit 22/tcp` - which stig-tailor.sh puts
# on every machine with a rule table - REJECTS a source after six connections in thirty
# seconds. On 2026-09-11 that locked stage-01 out of svc-repo-01 immediately after the push,
# and "Connection refused" reads like the host is down rather than like the firewall doing
# exactly what it was configured to do.
#
# ControlMaster collapses all five onto one connection, so the limiter never sees a burst.
# The socket lives in a private directory and is closed on exit, including on failure.
CTL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/push-repo.XXXXXX")"
CTL="$CTL_DIR/ctl-%%C"
cleanup() {
  ssh -o ControlPath="$CTL" -O exit "$USER_NAME@$TARGET" 2>/dev/null || true
  rm -rf "$CTL_DIR"
}
trap cleanup EXIT
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=10
          -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=60)
# 2>&1 CAPTURED, NOT DISCARDED. This said only "cannot ssh" for every cause - wrong key,
# machine down, or the one that actually happens: a REBUILT host presents a new host key and
# ssh refuses on the stale known_hosts entry. That is expected after every rebuild (host-3,
# 2026-09-21) and it will happen four times during the from-scratch run, so the message names
# the fix instead of sending someone to go and find it.
if ! _ssh_err="$(ssh "${SSH_OPTS[@]}" "$USER_NAME@$TARGET" true 2>&1)"; then
  case "$_ssh_err" in
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
      die "$TARGET presents a DIFFERENT host key than known_hosts records.
       Expected after a rebuild of that machine. Drop the stale entries and retry:
         ssh-keygen -R $TARGET
       If that machine was NOT rebuilt, stop and find out why its identity changed." ;;
    *"Permission denied"*)
      die "$TARGET refused $KEY (publickey). Is the key in its authorized_keys?
       A freshly installed host gets them from the seed - check the seed carried both keys." ;;
    *)
      die "cannot ssh to $USER_NAME@$TARGET with $KEY. ssh said:
       ${_ssh_err:-<no output>}" ;;
  esac
fi

# Regular files only (tar entries not ending in /), so it compares with `find -type f` below.
N=$(git archive --format=tar HEAD | tar -t | grep -cv '/$')
HEAD_SHA=$(git rev-parse --short HEAD)
HEAD_WHEN=$(git log -1 --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)
echo "  sending $N tracked file(s) at $HEAD_SHA ($HEAD_WHEN UTC) to $USER_NAME@$TARGET:$DEST_SHOW"

# Streamed: the tar goes straight into ssh and is never written to local disk. It extracts
# OVER the existing copy - changed files are replaced, but a file deleted from git stays on
# the target until someone removes it.
git archive --format=tar HEAD \
  | ssh "${SSH_OPTS[@]}" "$USER_NAME@$TARGET" \
      "mkdir -p '$DEST' && tar -x -C '$DEST'" \
  || die "transfer failed"

# ---- verify what landed, rather than trusting the exit code -----------------------------
# build-transfer-bundle.sh shipped a bug once where a copy reported success having copied
# nothing. Count what actually arrived.
GOT=$(ssh "${SSH_OPTS[@]}" "$USER_NAME@$TARGET" "find '$DEST' -type f | wc -l")
[ "$GOT" -ge "$N" ] || die "sent $N files but only $GOT arrived on $TARGET"
echo "  [ok] $GOT file(s) on $TARGET"
# ANSWERABLE ON THE TARGET, not just here. `cat ~/canonical-k8s/.pushed-from` on the box tells
# you what it is running without trusting anyone's memory of when they last pushed.
ssh "${SSH_OPTS[@]}" "$USER_NAME@$TARGET" \
  "printf '%s  %s  from %s by %s\\n' '$HEAD_SHA' '$HEAD_WHEN' \"$(hostname -s)\" '$USER' > '$DEST/.pushed-from'" \
  && echo "  [ok] target stamped: $HEAD_SHA -> $DEST_SHOW/.pushed-from"
ssh "${SSH_OPTS[@]}" "$USER_NAME@$TARGET" \
  "test -x '$DEST/scripts/install/03-host-services.sh'" \
  && echo "  [ok] scripts are executable on the target"
echo
echo "  next, ON $TARGET:"
echo "    cd $DEST_SHOW/scripts/install"
echo "    cp 03-host-services/services-params.env.example 03-host-services/services-params.env"
