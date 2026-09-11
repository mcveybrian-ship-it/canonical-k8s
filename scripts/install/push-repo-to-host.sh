#!/usr/bin/env bash
# =========================================================================================
# push-repo-to-host.sh - copy this repository onto an air-gapped host.
#
#     MACHINE: runs on stage-01 (or wherever the repo lives). NOT on the target.
#
#     ./push-repo-to-host.sh 10.0.20.158
#     ./push-repo-to-host.sh 10.0.20.155 -k ~/.ssh/build01 -d ~/canonical-k8s
#     ./push-repo-to-host.sh 10.2.20.162 --allow-dirty   # send HEAD even with local edits
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
ALLOW_DIRTY=0

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
die()   { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -k) KEY="$2"; shift 2 ;;
    -d) DEST="$2"; shift 2 ;;
    -u) USER_NAME="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option $1" ;;
    *)  TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || usage
[ -r "$KEY" ] || die "no ssh key at $KEY (use -k, or set REPO_PUSH_KEY)"

cd "$(git rev-parse --show-toplevel)" || die "not inside a git repository"

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

SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=10)
ssh "${SSH_OPTS[@]}" "$USER_NAME@$TARGET" true 2>/dev/null \
  || die "cannot ssh to $USER_NAME@$TARGET with $KEY"

N=$(git archive --format=tar HEAD | tar -t | grep -cv '/$')
HEAD_SHA=$(git rev-parse --short HEAD)
HEAD_WHEN=$(git log -1 --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)
echo "  sending $N tracked file(s) at $HEAD_SHA ($HEAD_WHEN UTC) to $USER_NAME@$TARGET:~/$DEST"

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
  && echo "  [ok] target stamped: $HEAD_SHA -> ~/$DEST/.pushed-from"
ssh "${SSH_OPTS[@]}" "$USER_NAME@$TARGET" \
  "test -x '$DEST/scripts/install/03-host-services.sh'" \
  && echo "  [ok] scripts are executable on the target"
echo
echo "  next, ON $TARGET:"
echo "    cd ~/$DEST/scripts/install"
echo "    cp 03-host-services/services-params.env.example 03-host-services/services-params.env"
