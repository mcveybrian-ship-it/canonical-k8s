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

  ssh "$MIRROR_USER@$MIRROR" "sudo install -d -m 0755 '$REPO_ROOT/tools'" \
    || die "cannot create $REPO_ROOT/tools on $MIRROR"

  # --rsync-path so the remote side runs as root without needing this whole script there.
  rsync -a --delete --info=progress2 --rsync-path="sudo rsync" \
    "$STAGING/Evaluate-STIG" "$MIRROR_USER@$MIRROR:$REPO_ROOT/tools/" \
    || die "Evaluate-STIG transfer failed"
  rsync -a --info=progress2 --rsync-path="sudo rsync" \
    "$STAGING/$PWSH_TARBALL" "$MIRROR_USER@$MIRROR:$REPO_ROOT/tools/" \
    || die "$PWSH_TARBALL transfer failed"

  # A CHECKSUM FILE GENERATED ON THE SOURCE, so `fetch` verifies against what was published
  # rather than against whatever arrived.
  ( cd "$STAGING" && sha256sum "$PWSH_TARBALL" ) \
    | ssh "$MIRROR_USER@$MIRROR" "sudo tee '$REPO_ROOT/tools/SHA256SUMS' >/dev/null" \
    || die "could not write SHA256SUMS"
  ssh "$MIRROR_USER@$MIRROR" "sudo chmod -R a+rX '$REPO_ROOT/tools'"

  # PROVE IT SERVES, rather than trusting that the files landed. A file on disk that nginx
  # does not have a location for is a file nobody can fetch, and that failure is silent until
  # the next machine tries.
  say ""
  local code
  code=$(curl_v -sI -o /dev/null -w '%{http_code}' "https://$MIRROR/tools/$PWSH_TARBALL" || echo 000)
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
  ssh "$MIRROR_USER@$target" "sudo install -d -m 0755 '$DEST'" || die "cannot create $DEST on $target"
  # The file itself stays root-readable only. It is not secret from the operator, but it has
  # no business being world-readable on a multi-user machine either.
  scp -q "$ANSWERFILE" "$MIRROR_USER@$target:/tmp/$(basename "$ANSWERFILE")" || die "scp failed"
  ssh "$MIRROR_USER@$target" \
    "sudo install -o root -g root -m 0640 '/tmp/$(basename "$ANSWERFILE")' '$DEST/$(basename "$ANSWERFILE")' \
     && rm -f '/tmp/$(basename "$ANSWERFILE")'" || die "install on $target failed"
  ok "$DEST/$(basename "$ANSWERFILE") on $target, 0640 root:root"
  say "   use it with:  --AFPath $DEST"
}

# ----------------------------------------------------------------------------------- fetch
cmd_fetch() {
  need_root
  local me; me="$(hostname -s)"
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
