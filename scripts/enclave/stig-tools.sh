#!/usr/bin/env bash
# =========================================================================================
# stig-tools.sh - put Evaluate-STIG and PowerShell where every in-gap machine can reach them.
#
#     sudo ./stig-tools.sh publish      MACHINE: stage-01. Pushes the tools to the mirror.
#     sudo ./stig-tools.sh answers      MACHINE: stage-01. Pushes the Answer File, ssh only.
#     sudo ./stig-tools.sh fetch        MACHINE: any in-gap machine. Pulls from the mirror.
#     ./stig-tools.sh status            MACHINE: any. What is here and what is served.
#
# WHY THIS EXISTS:
#
#   Evaluate-STIG is needed on every machine that gets hardened, and it arrived on the first
#   two by hand. That is how it ended up installed on two machines out of four, with no record
#   of which version is on which. The mirror is the one service every in-gap machine can
#   already reach over 443, so the tooling belongs there alongside /keys/, /debs/ and /snaps/.
#
# THE ANSWER FILE IS NOT PUBLISHED, AND THAT IS THE POINT OF SPLITTING THE COMMANDS.
#
#   Ubuntu24_AnswerFile.xml records security posture - which accounts are locked, which
#   NOPASSWD grants are accepted and the justification for each. The mirror vhost has no
#   authentication, deliberately (entitlement is enforced by the contracts server, not the
#   repo). So `publish` carries the scanner, which is public software, and `answers` carries
#   the answers point-to-point over ssh to one named machine.
#
# NOTHING IS FETCHED FROM THE INTERNET BY ANY SUBCOMMAND. `publish` reads a staging directory
# that already exists on stage-01; `fetch` reads the mirror.
# =========================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
[ -f "$HERE/enclave-addresses.env" ] && . "$HERE/enclave-addresses.env"

MIRROR="${STIG_TOOLS_MIRROR:-${SVC_REPO_01:-10.2.20.162}}"
MIRROR_USER="${STIG_TOOLS_USER:-encadmin}"
REPO_ROOT="${REPO_ROOT:-/srv/repo}"
STAGING="${STIG_TOOLS_STAGING:-/srv/bundle-staging/tools}"
DEST="${STIG_TOOLS_DEST:-/srv/stig-tools}"
EVIDENCE="${STIG_EVIDENCE:-/srv/stig-evidence}"
PWSH_TARBALL="${STIG_PWSH_TARBALL:-powershell-7.4.20-linux-x64.tar.gz}"
PWSH_DIR="${STIG_PWSH_DIR:-powershell-7.4.20}"
ANSWERFILE="${STIG_ANSWERFILE:-$STAGING/answerfiles/Ubuntu24_AnswerFile.xml}"
CA="${STIG_TOOLS_CA:-$HERE/trust-anchors/enclave-root.crt}"

# BARE SSH FROM stage-01 INTO THE GAP FAILS. The agent key is not authorised there; the key
# that is, is build01 - the same one push-repo-to-host.sh uses. Defaulting to the agent and
# hoping is how this script's first run died on "Permission denied (publickey)".
SSH_KEY="${REPO_PUSH_KEY:-$HOME/.ssh/build01}"

# TWO KINDS OF REMOTE CALL, AND THE DIFFERENCE IS NOT COSMETIC.
#
# After `usg fix` there is no NOPASSWD anywhere, so `ssh host "sudo ..."` gets a password
# prompt with no terminal to type into and hangs or fails. Anything privileged needs -t.
# Anything unprivileged must NOT use -t, or its output is polluted with the DoD banner and
# terminal escapes - which is exactly what makes a captured value unusable later.
rsh()    { ssh -i "$SSH_KEY" -o ConnectTimeout=10 "$@"; }
rsh_t()  { ssh -t -i "$SSH_KEY" -o ConnectTimeout=10 "$@"; }
rscp()   { scp -q -i "$SSH_KEY" -o ConnectTimeout=10 "$@"; }

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# NEVER -k. The enclave has a root CA precisely so that a fetch can be verified; -k turns the
# one transfer that carries a compliance scanner into an unauthenticated download.
curl_v() { curl --cacert "$CA" "$@"; }

# --------------------------------------------------------------------------------- publish
cmd_publish() {
  local me; me="$(hostname -s)"
  [ "$me" = stage-01 ] || die "publish runs on stage-01, not $me.
       It reads $STAGING, which only exists outside the gap."
  [ -d "$STAGING/Evaluate-STIG" ] || die "no $STAGING/Evaluate-STIG"
  [ -f "$STAGING/$PWSH_TARBALL" ] || die "no $STAGING/$PWSH_TARBALL"

  # THE TARBALL, NOT THE EXTRACTION. 70 MB over the wire instead of 178 MB, and the extracted
  # tree carries execute bits that rsync-over-ssh would have to preserve exactly for pwsh to
  # run at all. A tarball either verifies or it does not.
  local n_es; n_es=$(find "$STAGING/Evaluate-STIG" -type f | wc -l)
  say "publishing to $MIRROR_USER@$MIRROR:$REPO_ROOT/tools/"
  say "  Evaluate-STIG   $n_es file(s), $(du -sh "$STAGING/Evaluate-STIG" | cut -f1)"
  say "  $PWSH_TARBALL   $(du -sh "$STAGING/$PWSH_TARBALL" | cut -f1)"
  say ""
  warn "NOT publishing $(basename "$ANSWERFILE") - it records security posture and this vhost"
  say "     has no authentication. Use: sudo $0 answers <machine>"
  say ""

  # STAGE INTO THE USER'S HOME, THEN ONE PRIVILEGED CALL.
  #
  # rsync --rsync-path="sudo rsync" needs a passwordless sudo on the far end, and `usg fix`
  # removed every NOPASSWD grant in the enclave. So the bulk transfer runs unprivileged into
  # a staging directory, and exactly one interactive sudo puts it in place. One prompt, and
  # nothing half-written under $REPO_ROOT if the transfer dies.
  local STAGE_REMOTE=".stig-tools-staging"
  rsh "$MIRROR_USER@$MIRROR" "mkdir -p '$STAGE_REMOTE'" \
    || die "cannot ssh to $MIRROR_USER@$MIRROR with $SSH_KEY.
       Bare ssh from stage-01 into the gap is not authorised - build01 is the key that is.
       Override with REPO_PUSH_KEY=<path>."

  rsync -a --delete --info=progress2 -e "ssh -i $SSH_KEY" \
    "$STAGING/Evaluate-STIG" "$MIRROR_USER@$MIRROR:$STAGE_REMOTE/" \
    || die "Evaluate-STIG transfer failed"
  rsync -a --info=progress2 -e "ssh -i $SSH_KEY" \
    "$STAGING/$PWSH_TARBALL" "$MIRROR_USER@$MIRROR:$STAGE_REMOTE/" \
    || die "$PWSH_TARBALL transfer failed"

  # The checksum is generated HERE, on the source, so `fetch` verifies against what was
  # published and not against whatever happens to be sitting on the mirror.
  ( cd "$STAGING" && sha256sum "$PWSH_TARBALL" ) \
    | rsh "$MIRROR_USER@$MIRROR" "cat > '$STAGE_REMOTE/SHA256SUMS'" \
    || die "could not write SHA256SUMS"

  say ""
  say "installing into $REPO_ROOT/tools - this asks for the sudo password on $MIRROR:"
  rsh_t "$MIRROR_USER@$MIRROR" \
    "sudo install -d -m 0755 '$REPO_ROOT/tools' \
     && sudo rsync -a --delete '$STAGE_REMOTE/Evaluate-STIG' '$REPO_ROOT/tools/' \
     && sudo install -m 0644 '$STAGE_REMOTE/$PWSH_TARBALL' '$REPO_ROOT/tools/' \
     && sudo install -m 0644 '$STAGE_REMOTE/SHA256SUMS' '$REPO_ROOT/tools/' \
     && sudo chown -R root:root '$REPO_ROOT/tools' \
     && sudo chmod -R a+rX '$REPO_ROOT/tools' \
     && rm -rf '$STAGE_REMOTE'" \
    || die "install on $MIRROR failed - the staged copy is still at ~/$STAGE_REMOTE there"

  # PROVE IT SERVES, rather than trusting that the files landed. A file on disk that nginx
  # does not have a location for is a file nobody can fetch, and that failure is silent until
  # the next machine tries.
  say ""
  # RETRY, BECAUSE nginx reload IS ASYNCHRONOUS. A single curl straight after a reload can be
  # answered by a worker still running the old config - that is how /tools/ read as 404 on
  # 2026-09-11 when the location was present and correct. restore-mirror.sh already carries a
  # wait for the same reason. A check that races the thing it is checking reports a failure
  # that never happened.
  local code tries=0
  while :; do
    code=$(curl_v -sI -o /dev/null -w '%{http_code}' "https://$MIRROR/tools/$PWSH_TARBALL" || echo 000)
    [ "$code" = 200 ] && break
    tries=$((tries + 1)); [ "$tries" -ge 5 ] && break
    say "  serving check: $code - retrying (nginx reload is asynchronous) $tries/5"
    sleep 2
  done
  if [ "$code" = 200 ]; then
    ok "https://$MIRROR/tools/$PWSH_TARBALL -> $code"
  else
    warn "https://$MIRROR/tools/$PWSH_TARBALL -> $code"
    warn "  the files are on disk but nginx is not serving them. The vhost needs:"
    warn "    location ^~ /tools/ { alias $REPO_ROOT/tools/; autoindex on; }"
    warn "  see scripts/transfer/nginx-apt-mirror.conf, then: sudo nginx -t && systemctl reload nginx"
    return 1
  fi
  code=$(curl_v -sI -o /dev/null -w '%{http_code}' \
           "https://$MIRROR/tools/Evaluate-STIG/Evaluate-STIG_Bash.sh" || echo 000)
  [ "$code" = 200 ] && ok "https://$MIRROR/tools/Evaluate-STIG/ -> $code" \
                    || warn "Evaluate-STIG_Bash.sh -> $code"
  say ""
  ok "any in-gap machine can now run:  sudo ./stig-tools.sh fetch"
}

# --------------------------------------------------------------------------------- answers
cmd_answers() {
  local target="${1:-}"
  [ -n "$target" ] || die "usage: sudo $0 answers <address|hostname>
       The Answer File goes point-to-point, to one named machine, over ssh."
  [ -f "$ANSWERFILE" ] || die "no Answer File at $ANSWERFILE"
  say "sending $(basename "$ANSWERFILE") to $MIRROR_USER@$target:$DEST/"
  say "  $(wc -l < "$ANSWERFILE") lines, $(grep -c '<Vuln ' "$ANSWERFILE" 2>/dev/null || echo '?') vuln entries"
  local BASE; BASE="$(basename "$ANSWERFILE")"
  rscp "$ANSWERFILE" "$MIRROR_USER@$target:/tmp/$BASE" \
    || die "scp failed - is $SSH_KEY authorised on $target?"
  say "installing - this asks for the sudo password on $target:"
  # 0640 root:root. Not secret from the operator, but it has no business being world-readable
  # on a machine with other accounts.
  rsh_t "$MIRROR_USER@$target" \
    "sudo install -d -m 0755 '$DEST' \
     && sudo install -o root -g root -m 0640 '/tmp/$BASE' '$DEST/$BASE' \
     && rm -f '/tmp/$BASE'" || die "install on $target failed"
  ok "$DEST/$(basename "$ANSWERFILE") on $target, 0640 root:root"
  say "   use it with:  --AFPath $DEST"
}

# ----------------------------------------------------------------------------------- fetch
cmd_fetch() {
  # THE MACHINE CHECK COMES BEFORE THE PRIVILEGE CHECK, DELIBERATELY.
  # With need_root first, pasting this on stage-01 answers "run with sudo" - which invites the
  # operator to re-run it privileged on the wrong machine. Same shape as the build-transfer
  # clean step that rejected /etc only because the caller happened to be unprivileged.
  local me; me="$(hostname -s)"
  # REFUSE OUTSIDE THE BOUNDARY. This block was pasted into stage-01 on its first outing,
  # under a heading that said svc-repo-01. The heading refused nothing. stage-01 and build-01
  # are outside the ATO boundary and already hold the staging copy this publishes FROM -
  # fetching it back would install a second, unversioned copy of the scanner there.
  case "$me" in
    stage-01|build-01)
      die "fetch does not run on $me - it is outside the boundary and already has the
       staging copy at $STAGING. Run this ON the machine being scanned." ;;
  esac
  need_root
  [ -f "$CA" ] || die "no enclave root CA at $CA - this script will not fetch over an
       unverified connection. Copy the repo, or set STIG_TOOLS_CA."

  install -d -m 0755 "$DEST" "$EVIDENCE"
  say "fetching from https://$MIRROR/tools/ onto $me"

  # 1. Evaluate-STIG. A directory tree over HTTP means walking the autoindex, which is
  # fragile. The scanner ships as a tree, so mirror it with wget's recursive mode and cut the
  # served prefix off - and FAIL rather than half-copy.
  command -v wget >/dev/null 2>&1 || die "wget is not installed - apt-get install -y wget"
  ( cd "$DEST" && wget -q --show-progress --no-verbose \
      --ca-certificate="$CA" \
      -r -np -nH --cut-dirs=2 -R 'index.html*' \
      "https://$MIRROR/tools/Evaluate-STIG/" ) \
    || die "Evaluate-STIG fetch failed - nothing was left half-installed at $DEST"
  [ -f "$DEST/Evaluate-STIG/Evaluate-STIG_Bash.sh" ] \
    || die "fetched, but $DEST/Evaluate-STIG/Evaluate-STIG_Bash.sh is missing"
  ok "Evaluate-STIG: $(find "$DEST/Evaluate-STIG" -type f | wc -l) file(s)"

  # 2. PowerShell, verified against the checksum written at publish time.
  if [ -d "$DEST/$PWSH_DIR" ] && [ -x "$DEST/$PWSH_DIR/pwsh" ]; then
    ok "PowerShell already at $DEST/$PWSH_DIR ($("$DEST/$PWSH_DIR/pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo 'will not run'))"
  else
    curl_v -fsS -o "$DEST/$PWSH_TARBALL" "https://$MIRROR/tools/$PWSH_TARBALL" \
      || die "PowerShell tarball fetch failed"
    curl_v -fsS -o "$DEST/SHA256SUMS" "https://$MIRROR/tools/SHA256SUMS" \
      || die "SHA256SUMS fetch failed - refusing to extract an unverified tarball"
    ( cd "$DEST" && sha256sum -c --ignore-missing SHA256SUMS ) \
      || die "CHECKSUM MISMATCH on $PWSH_TARBALL - not extracting. Re-publish from stage-01."
    ok "checksum verified"
    install -d -m 0755 "$DEST/$PWSH_DIR"
    tar -xzf "$DEST/$PWSH_TARBALL" -C "$DEST/$PWSH_DIR"
    chmod +x "$DEST/$PWSH_DIR/pwsh"
    rm -f "$DEST/$PWSH_TARBALL"
    # RUN IT, do not assume it runs. A tarball that extracts is not a runtime that starts -
    # and on a FIPS kernel that is a real question, not a formality.
    local v
    v="$("$DEST/$PWSH_DIR/pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1)" \
      || die "pwsh extracted but will not run: $v"
    ok "PowerShell $v (fips_enabled=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo '?'))"
  fi

  say ""
  ok "ready. Scan with:"
  say "   cd $DEST/Evaluate-STIG"
  say "   sudo bash Evaluate-STIG_Bash.sh --NoUpstream \\"
  say "     --PSPath $DEST/$PWSH_DIR \\"
  say "     --SelectSTIG Ubuntu24 --Output Summary,CKLB,CombinedCSV \\"
  say "     --OutputPath $EVIDENCE 2>&1 | tee $EVIDENCE/scan-$me-\$(date +%Y%m%dT%H%M).log"
  [ -f "$DEST/$(basename "$ANSWERFILE")" ] \
    && say "   ... and add:  --AFPath $DEST" \
    || warn "no Answer File here - from stage-01: sudo ./stig-tools.sh answers $me"
}

# ---------------------------------------------------------------------------------- status
cmd_status() {
  local me; me="$(hostname -s)"
  printf '\n  stig tooling on %s\n\n' "$me"
  if [ -d "$DEST/Evaluate-STIG" ]; then
    ok "Evaluate-STIG: $(find "$DEST/Evaluate-STIG" -type f 2>/dev/null | wc -l) file(s) at $DEST"
  else
    warn "no Evaluate-STIG at $DEST"
  fi
  if [ -x "$DEST/$PWSH_DIR/pwsh" ]; then
    ok "pwsh: $("$DEST/$PWSH_DIR/pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo 'WILL NOT RUN')"
  else
    warn "no pwsh at $DEST/$PWSH_DIR"
  fi
  if [ -f "$DEST/$(basename "$ANSWERFILE")" ]; then
    ok "Answer File: $(stat -c '%A %U:%G' "$DEST/$(basename "$ANSWERFILE")")"
  else
    warn "no Answer File - deviations will re-open as findings on every scan"
  fi
  # /tmp/.dotnet is pwsh's own 0777 leftover and the scanner reports it against V-270750.
  [ -d /tmp/.dotnet ] && warn "/tmp/.dotnet exists - $(stat -c '%A' /tmp/.dotnet). Remove it after scanning: sudo rm -rf /tmp/.dotnet"
  printf '\n  served by the mirror:\n'
  local code
  code=$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' "https://$MIRROR/tools/" 2>/dev/null || echo 000)
  say "   https://$MIRROR/tools/ -> $code"
  echo
}

case "${1:-status}" in
  publish) shift; cmd_publish "$@" ;;
  answers) shift; cmd_answers "$@" ;;
  fetch)   shift; cmd_fetch "$@" ;;
  status)  shift; cmd_status "$@" ;;
  *) printf 'usage: %s {publish|answers <machine>|fetch|status}\n' "$0" >&2; exit 2 ;;
esac
