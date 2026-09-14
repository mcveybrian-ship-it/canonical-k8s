#!/usr/bin/env bash
# =========================================================================================
# stig-tools.sh - put Evaluate-STIG and PowerShell where every in-gap machine can reach them.
#
#     sudo ./stig-tools.sh publish      MACHINE: stage-01. Pushes the tools to the mirror.
#     sudo ./stig-tools.sh answers      MACHINE: stage-01. Pushes the Answer File, ssh only.
#     sudo ./stig-tools.sh fetch        MACHINE: any in-gap machine. Pulls from the mirror.
#     sudo ./stig-tools.sh detect       MACHINE: any in-gap machine. What applies - seconds, no scan.
#     sudo ./stig-tools.sh scan         MACHINE: the machine being assessed. Scan + clean up.
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
# THE KEY BELONGS TO THE OPERATOR, NOT TO ROOT. Under sudo, whether $HOME is still
# /home/encadmin or has become /root depends on `always_set_home` in sudoers - so a default
# of "$HOME/.ssh/build01" works or fails depending on a setting nobody looks at. Resolve
# the INVOKING user's home explicitly instead. `answers` needs no root on this end anyway;
# it scps, and the privileged half runs on the far machine.
_invoker_home="$HOME"
if [ -n "${SUDO_USER:-}" ]; then
  _h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  [ -n "$_h" ] && _invoker_home="$_h"
fi
SSH_KEY="${REPO_PUSH_KEY:-$_invoker_home/.ssh/build01}"

# TWO KINDS OF REMOTE CALL, AND THE DIFFERENCE IS NOT COSMETIC.
#
# After `usg fix` there is no NOPASSWD anywhere, so `ssh host "sudo ..."` gets a password
# prompt with no terminal to type into and hangs or fails. Anything privileged needs -t.
# Anything unprivileged must NOT use -t, or its output is polluted with the DoD banner and
# terminal escapes - which is exactly what makes a captured value unusable later.
# A MACHINE NAME IS NOT AN ADDRESS OUTSIDE THE GAP. `answers svc-obs-01` from stage-01 died
# on "scp: Connection closed" - the real cause was that stage-01 does not resolve enclave
# names at all (the enclave DNS lives on svc-mgmt-01, inside the boundary, and stage-01 is
# outside it by design). The address is already in enclave-addresses.env, so look it up
# rather than making the operator remember which machine is which octet.
#
# Resolution wins if it works - an operator who has a hosts entry or is inside the gap
# should not be overridden by a table.
resolve_target() {
  local name="$1"
  if getent hosts "$name" >/dev/null 2>&1; then printf '%s\n' "$name"; return 0; fi
  case "$name" in *[!0-9.]*) : ;; *) printf '%s\n' "$name"; return 0 ;; esac   # already an IP
  local var; var="$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
  local addr="${!var:-}"
  [ -n "$addr" ] || die "cannot resolve '$name', and enclave-addresses.env has no $var.
       Either add it there, or pass the address directly."
  # TO STDERR, NOT STDOUT. The caller does target="$(resolve_target ...)", so anything this
  # prints on stdout is captured INTO THE ADDRESS. Caught in a dry-run, which is the only
  # reason it is not a "connection to '  using 10.2.20.164' failed" two steps from now.
  printf '  %s\n' "'$name' does not resolve here - using $addr from enclave-addresses.env" >&2
  printf '%s\n' "$addr"
}

# MULTIPLEX. `ufw limit 22/tcp` REJECTS a source after 6 connections in 30 seconds, and
# `collect` makes several per machine. On svc-repo-01 and svc-obs-01 - the two machines where
# ufw actually enforces - an unmultiplexed run gets refused partway through, and a refusal
# reads like whatever the caller was measuring. One connection per machine, reused.
MUX=(-o ControlMaster=auto -o ControlPath="/tmp/.stig-tools-%r@%h:%p" -o ControlPersist=60)
# REACHABILITY, AND AN HONEST REASON WHEN IT FAILS.
#
# The first version reported every failed probe as "check the key and the address". On
# 2026-09-14 it said that four times in a row when the real cause was HOST KEY VERIFICATION:
# ~/.ssh/known_hosts held each machine's key under its IP and not under its name, and the
# names had only just started resolving. Asserting a cause the code has not established is
# the same defect as a check that reports a pass it did not measure.
#
# So: print ssh's own words. And for the host-key case specifically, do the one safe thing -
# if the address that name resolves to is ALREADY trusted, the key is the same key under a
# different label, so record the alias and say exactly what was recorded. That is not a new
# trust decision. If the address is not trusted either, refuse: that IS a new trust decision
# and it belongs to the operator, not to a script running unattended in an enclave.
preflight_ssh() {
  local target="$1" err
  err="$(ssh -n "${MUX[@]}" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 \
         "$MIRROR_USER@$target" true 2>&1)" && return 0

  if ! printf '%s' "$err" | command grep -qi 'host key verification failed'; then
    warn "ssh to $target failed. ssh said:"
    printf '%s\n' "$err" | sed 's/^/         /'
    return 1
  fi

  local ip; ip="$(getent ahostsv4 "$target" 2>/dev/null | awk 'NR==1 {print $1}')"
  [ -n "$ip" ] || { warn "$target: host key not trusted, and the name resolves to nothing"; return 1; }
  # EVERY KEY, NOT THE FIRST ONE. A host publishes one key per algorithm, and copying only
  # the first line gave host-4 an ed25519 entry - which host-4 does not offer, because it is
  # in FIPS mode and FIPS REMOVES ed25519. ssh then asked for the one algorithm it believed
  # the host used, got a different one, and reported REMOTE HOST IDENTIFICATION HAS CHANGED:
  # the loudest possible message for what was actually an incomplete copy. The stale ed25519
  # lines in known_hosts predate FIPS being enabled; no machine in this enclave offers one.
  local keys; keys="$(ssh-keygen -F "$ip" 2>/dev/null | command grep -v '^#')"
  if [ -z "$keys" ]; then
    warn "$target ($ip): host key is not trusted under EITHER the name or the address."
    warn "  That is a new trust decision. Verify the fingerprint out of band, then:"
    say  "     ssh-keyscan -t rsa,ecdsa $ip >> ~/.ssh/known_hosts   # NOT ed25519 - FIPS has no ed25519"
    return 1
  fi
  local n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Skip one already recorded under this name, so a re-run does not duplicate lines.
    printf '%s %s\n' "$target" "${line#* }" > /tmp/.stig-hk.$$
    if ! command grep -qxFf /tmp/.stig-hk.$$ "$HOME/.ssh/known_hosts" 2>/dev/null; then
      cat /tmp/.stig-hk.$$ >> "$HOME/.ssh/known_hosts"; n=$((n + 1))
    fi
    rm -f /tmp/.stig-hk.$$
  done <<< "$keys"
  ok "$target: recorded $n key(s) already trusted as $ip - same keys, no new trust"

  local err2
  err2="$(ssh -n "${MUX[@]}" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=8 \
          "$MIRROR_USER@$target" true 2>&1)" && return 0
  # PRINT THE RETRY'S REASON. The first version swallowed it with 2>/dev/null, so a failed
  # retry produced "see the reason above" with nothing above it.
  warn "$target still refuses after recording the keys. ssh said:"
  printf '%s\n' "$err2" | sed 's/^/         /'
  return 1
}

rsh()    { ssh "${MUX[@]}" -i "$SSH_KEY" -o ConnectTimeout=10 "$@"; }
rsh_t()  { ssh -t "${MUX[@]}" -i "$SSH_KEY" -o ConnectTimeout=10 "$@"; }
rscp()   { scp -q "${MUX[@]}" -i "$SSH_KEY" -o ConnectTimeout=10 "$@"; }

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
  target="$(resolve_target "$target")"
  # Say which key, and prove the host answers at all, BEFORE blaming authorisation. The
  # first version reported every scp failure as "is the key authorised?" - including the
  # one that was actually a name that did not resolve.
  preflight_ssh "$target" \
    || die "cannot reach $MIRROR_USER@$target - see the reason above"
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

# --------------------------------------------------------------------------------- collect
# STEP 14. Evidence you cannot collect is evidence you do not have - and on 2026-09-14 every
# one of the five machines held its own checklist while stage-01 held none. Four of them are
# VMs that can be rebuilt, which is exactly the case this step exists for.
#
# TWO SOURCES, TWO PROBLEMS:
#   /srv/stig-evidence  Evaluate-STIG output. Already readable - `scan` fixes ownership.
#   /var/lib/usg        USG's XML and HTML. 0600 root:root, on purpose. Needs one privileged
#                       call per machine, so the operator types one password per machine and
#                       the rest is unattended.
cmd_collect() {
  local here; here="$(hostname -s)"
  [ "$here" = stage-01 ] || warn "collecting onto $here, not stage-01 - is that what you meant?"
  local into="${STIG_COLLECT_DIR:-$EVIDENCE}"
  install -d -m 0755 "$into" 2>/dev/null || die "cannot create $into - run with sudo, or set STIG_COLLECT_DIR"
  [ -w "$into" ] || die "$into is not writable by $(id -un)"

  # Default to every machine in the address table that answers. Named machines override.
  local list=("$@")
  if [ "${#list[@]}" -eq 0 ]; then
    local v
    for v in HOST_1 HOST_2 HOST_3 HOST_4 SVC_MGMT_01 SVC_REPO_01 SVC_HARBOR_01 SVC_OBS_01; do
      [ -n "${!v:-}" ] && list+=("${!v}")
    done
  fi

  local addr host rc=0 got=0
  for addr in "${list[@]}"; do
    addr="$(resolve_target "$addr")"
    preflight_ssh "$addr" || { say "-- $addr unreachable - skipped"; continue; }
    host="$(rsh -n -o BatchMode=yes "$MIRROR_USER@$addr" 'hostname -s' 2>/dev/null | tr -d '\r')"
    [ -n "$host" ] || { warn "$addr answered but would not say its name - skipped"; rc=1; continue; }
    printf '\n  == %s (%s) ==\n' "$host" "$addr"

    # 1. USG results. Privileged, so one -t call that stages them beside the scanner output
    #    and hands them to the operator's account. `|| true` on the copy: a machine that has
    #    never run usg has nothing to stage and that is not an error.
    # COMPUTE THE DIRECTORY NAME HERE, NOT ON THE FAR SIDE. A nested $(hostname) inside a
    # quoted sudo sh -c inside an ssh argument is three levels of escaping for a value this
    # side already knows. Levels of escaping are where these scripts break.
    local up; up="$(printf '%s' "$host" | tr 'a-z' 'A-Z')"
    say "  staging USG results (asks for the sudo password on $host):"
    rsh_t "$MIRROR_USER@$addr" \
      "sudo install -d -m 0755 -o $MIRROR_USER $EVIDENCE/$up/USG && \
       sudo cp -p /var/lib/usg/usg-results-*.xml /var/lib/usg/usg-report-*.html $EVIDENCE/$up/USG/ ; \
       sudo chown -R $MIRROR_USER $EVIDENCE/$up/USG" \
      || { warn "$host: could not stage USG results"; rc=1; }

    # 2. One recursive pull for everything. Unprivileged by now, by construction.
    if rscp -r "$MIRROR_USER@$addr:$EVIDENCE/$up" "$into/" 2>/dev/null; then
      local n; n="$(find "$into/$up" -type f 2>/dev/null | wc -l)"
      ok "$host: $n file(s) -> $into/$up"
      got=$((got + 1))
    else
      warn "$host: nothing at $EVIDENCE/$up - has it been scanned?"
      rc=1
    fi
  done

  printf '\n'
  # SAY THE COUNT. "collected" alone reads the same whether it pulled five machines or none.
  ok "collected from $got machine(s) into $into"
  find "$into" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | while read -r d; do
    say "   $(basename "$d"): $(find "$d" -type f | wc -l) file(s), $(du -sh "$d" 2>/dev/null | cut -f1)"
  done
  return $rc
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

  # THE EVIDENCE DIRECTORY BELONGS TO THE OPERATOR, NOT TO root.
  #
  # The scan runs under sudo and writes every checklist as root with umask 077, so the CKLB
  # and CSV land 0600 root:root. The operator then cannot copy them off the machine at all.
  # This is the same friction as /var/lib/usg being root-only (runbook 6.0 step 14); no
  # reason to reproduce it in a directory we create ourselves.
  install -d -m 0755 "$DEST"
  install -d -m 0755 -o "${SUDO_USER:-root}" -g "${SUDO_USER:-root}" "$EVIDENCE" 2>/dev/null \
    || install -d -m 0755 "$EVIDENCE"
  [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$EVIDENCE" 2>/dev/null || true
  say "fetching from https://$MIRROR/tools/ onto $me"

  # 1. Evaluate-STIG. A directory tree over HTTP means walking the autoindex, so mirror it
  # with wget's recursive mode.
  #
  # STAGE INTO A TEMP DIR, THEN MOVE. The first version wrote straight into $DEST with
  # --cut-dirs=2, which strips BOTH `tools` and `Evaluate-STIG` from the served path - so 390
  # files landed flat in /srv/stig-tools/ and the scanner was "installed" in a layout nothing
  # could use. Counting path components in a flag is exactly the kind of arithmetic that is
  # wrong once and then wrong everywhere; staging and checking the result is not.
  command -v wget >/dev/null 2>&1 || die "wget is not installed - apt-get install -y wget"
  local TMPD; TMPD="$(mktemp -d "$DEST/.fetch.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$TMPD'" RETURN
  ( cd "$TMPD" && wget -q --show-progress --no-verbose \
      --ca-certificate="$CA" \
      -r -np -nH --cut-dirs=1 -R 'index.html*' \
      "https://$MIRROR/tools/Evaluate-STIG/" ) \
    || die "Evaluate-STIG fetch failed - nothing was written to $DEST"
  [ -f "$TMPD/Evaluate-STIG/Evaluate-STIG_Bash.sh" ] \
    || die "fetched, but Evaluate-STIG_Bash.sh is not where it should be. Got:
$(find "$TMPD" -maxdepth 2 | head -12 | sed 's/^/       /')
       Nothing was written to $DEST."

  # A PREVIOUS BAD LAYOUT HAS TO GO, or the flat copy sits alongside the good one and the next
  # operator cannot tell which is live.
  if [ -f "$DEST/Evaluate-STIG_Bash.sh" ] && [ ! -d "$DEST/Evaluate-STIG" ]; then
    warn "removing an earlier flat extraction in $DEST"
    ( cd "$DEST" && rm -rf AnswerFiles Doc Modules Prerequisites StigContent \
        Evaluate-STIG.ps1 Evaluate-STIG_Bash.sh Evaluate-STIG_GUI.ps1 LICENSE Preferences.xml )
  fi
  rm -rf "$DEST/Evaluate-STIG"
  mv "$TMPD/Evaluate-STIG" "$DEST/Evaluate-STIG"
  # SET THE MODE, DO NOT INHERIT IT. The tree came out of a 0700 mktemp staging directory and
  # arrived drwx------, so `cd /srv/stig-tools/Evaluate-STIG` failed for the operator on a
  # fetch that had just reported success. Anything this script installs for someone else to
  # run must be readable and traversable by them, stated rather than assumed.
  chmod -R a+rX "$DEST/Evaluate-STIG"
  ok "Evaluate-STIG: $(find "$DEST/Evaluate-STIG" -type f | wc -l) file(s) at $DEST/Evaluate-STIG"
  if [ -n "${SUDO_USER:-}" ]; then
    runuser -u "$SUDO_USER" -- test -r "$DEST/Evaluate-STIG/Evaluate-STIG_Bash.sh" \
      && ok "readable by $SUDO_USER" \
      || warn "NOT readable by $SUDO_USER - the scan command below will fail for them"
    runuser -u "$SUDO_USER" -- test -w "$EVIDENCE" \
      && ok "$EVIDENCE writable by $SUDO_USER (the \`| tee\` needs this)" \
      || warn "$EVIDENCE NOT writable by $SUDO_USER - the scan log will not be captured"
  fi

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
  say "   sudo $0 scan"
  say ""
  say "   Use that rather than calling Evaluate-STIG_Bash.sh by hand. It auto-detects every"
  say "   applicable STIG (a bare --SelectSTIG Ubuntu24 assesses the OS and NOTHING else),"
  say "   does not pipe the output - a pipe hides Write-Progress and the scan looks hung -"
  say "   cleans up /tmp/.dotnet, and leaves the evidence readable so step 14 can collect it."
  [ -f "$DEST/$(basename "$ANSWERFILE")" ] \
    && say "   ... and add:  --AFPath $DEST" \
    || warn "no Answer File here - from stage-01, WITHOUT sudo: ./stig-tools.sh answers $me"
}

# ------------------------------------------------------------------------------------ scan
#
# RUN THE SCAN, AND LEAVE THE EVIDENCE IN A STATE SOMEONE CAN ACTUALLY COLLECT.
#
# The bare invocation is six flags long, and two things must happen afterwards or the run is
# worth less than it looks:
#
#   1. `/tmp/.dotnet` must go. PowerShell creates it 0777 at startup; leaving a world-writable
#      directory on a hardened machine is a real defect even though the control that reports
#      it is answered (the scanner made the condition - see runbook 10.1).
#
#   2. THE OUTPUT MUST BE READABLE BY THE OPERATOR. The scan runs as root with umask 077, so
#      every CKLB and CSV lands 0600 root:root. On svc-mgmt-01 that meant the checklist could
#      not be copied off the machine at all - and §6.0 step 14 is "copy the reports off".
#      **Evidence you cannot collect is evidence you do not have.**
#
#      A default ACL would fix it at creation, but `setfacl` is absent on three of the four
#      machines and adding the `acl` package to hardened hosts to solve this is the wrong
#      trade. So ownership is corrected here, and then VERIFIED as the operator.
#
# It also prints the tally, so nobody has to paste a python heredoc at a prompt to find out
# what the scan said.

# AUTO-DETECT BY DEFAULT. `--SelectSTIG Ubuntu24` ASSESSES THE OS AND NOTHING ELSE.
#
# Every scan up to 2026-09-13 passed `--SelectSTIG Ubuntu24`, so four machines were measured
# against the operating system STIG only. svc-mgmt-01 runs PostgreSQL 16 as MAAS's database and
# it was never assessed - the bundle ships U_PGS_SQL_9-x_STIG_V2R5 and a real
# Scan-PostgreSQL9-x_Checks module, so it was assessable the whole time and simply never
# selected.
#
# Evaluate-STIG detects what applies. Test-IsPostgresInstalled requires BOTH a running
# postgres/postmaster process AND a matching apt package; Test-IsRKE2Installed will matter once
# the cluster exists. Omitting --SelectSTIG lets it decide, which is the behaviour an assessor
# expects: "what is on this machine", not "what did you choose to look at".
#
# --stig <shortname> narrows it deliberately when you want a fast re-check of one product.
cmd_scan() {
  local me stig="" deprecated=0 failed_scan=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --stig) stig="${2:?--stig needs a shortname, e.g. Ubuntu24}"; shift 2 ;;
      --stig=*) stig="${1#--stig=}"; shift ;;
      --allow-deprecated) deprecated=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  me="$(hostname -s)"
  case "$me" in
    stage-01|build-01)
      die "scan does not run on $me - it is outside the ATO boundary. Run it ON the machine
       being assessed." ;;
  esac
  need_root
  local owner="${SUDO_USER:-root}"

  # PREREQUISITES, NAMED INDIVIDUALLY. "something is missing" costs a round trip.
  local missing=0
  [ -x "$DEST/$PWSH_DIR/pwsh" ] || { warn "no pwsh at $DEST/$PWSH_DIR"; missing=1; }
  [ -f "$DEST/Evaluate-STIG/Evaluate-STIG_Bash.sh" ] || { warn "no scanner at $DEST/Evaluate-STIG"; missing=1; }
  local af_arg=()
  if [ -f "$DEST/$(basename "$ANSWERFILE")" ]; then
    af_arg=(--AFPath "$DEST")
  else
    warn "NO ANSWER FILE at $DEST - every documented deviation will re-open as a finding."
    warn "  From stage-01:  ./scripts/enclave/stig-tools.sh answers $me"
  fi
  for p in lshw dmidecode bc; do
    command -v "$p" >/dev/null 2>&1 || { warn "$p missing - the scan dies seconds in"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "prerequisites missing - see above. sudo $0 fetch"

  install -d -m 0755 -o "$owner" "$EVIDENCE" 2>/dev/null || install -d -m 0755 "$EVIDENCE"

  # SAY WHAT WILL BE ASSESSED, BEFORE SPENDING 15 MINUTES ON IT.
  #
  # --ListApplicableProducts runs the same detection the scan uses and prints the result
  # without scanning. It is how you find out a machine has a second product on it -
  # svc-mgmt-01's PostgreSQL went unassessed for days because nobody asked this question.
  say "detecting what applies to $me ..."
  ( cd "$DEST/Evaluate-STIG" && bash Evaluate-STIG_Bash.sh --NoUpstream \
      --PSPath "$DEST/$PWSH_DIR" --ListApplicableProducts 2>&1 ) | sed 's/^/       /'
  say ""

  local dep_arg=()
  if [ "$deprecated" -eq 1 ]; then
    dep_arg=(--AllowDeprecated)
    warn "--AllowDeprecated: SUNSET benchmarks will be assessed."
    warn "  A sunset STIG is one DISA has RETIRED. Results are evidence of nothing on their"
    warn "  own - say in the artefact why you ran it and against what."
  fi
  local sel_arg=()
  if [ -n "$stig" ]; then
    sel_arg=(--SelectSTIG "$stig")
    warn "NARROWED to --SelectSTIG $stig - this assesses that product ONLY."
    warn "  Anything else installed here is not looked at. Drop --stig for the full picture."
  else
    say "auto-detecting applicable STIGs - everything listed above will be assessed"
  fi
  say "this takes 7-15 minutes, longer with more than one STIG"
  say ""

  # DO NOT PIPE THIS. Evaluate-STIG reports progress with Write-Progress, which writes to
  # PowerShell's PROGRESS STREAM, not stdout. Put a pipe in the way - `| tee`, `| tail`,
  # anything - and the progress display vanishes: earlier runs printed "STIGs to process - 1"
  # and then nothing for eleven minutes, which reads as hung.
  #
  # tee was never needed. The tool writes its own detailed log to
  # <OutputPath>/<HOSTNAME>/Evaluate-STIG.log - 150 KB of it - so the record already exists
  # and is better than a console capture. Let the progress render on the terminal.
  ( cd "$DEST/Evaluate-STIG" && bash Evaluate-STIG_Bash.sh --NoUpstream \
      --PSPath "$DEST/$PWSH_DIR" \
      "${sel_arg[@]}" \
      "${dep_arg[@]}" \
      "${af_arg[@]}" \
      --Output Summary,CKLB,CombinedCSV \
      --OutputPath "$EVIDENCE" )

  say ""
  # ---- clean up after the tool ----------------------------------------------------------
  if [ -d /tmp/.dotnet ]; then
    rm -rf /tmp/.dotnet && ok "removed /tmp/.dotnet (PowerShell's 0777 leftover)"
  fi
  # `_Partial_{HOSTNAME^^}` is a bash uppercase expansion leaking as a literal from the
  # vendor wrapper. Cosmetic, root-owned, and it has no business in an evidence tree.
  local stray
  stray="$(find "$EVIDENCE" -maxdepth 1 -name '_Partial_*' 2>/dev/null || true)"
  if [ -n "$stray" ]; then
    printf '%s\n' "$stray" | while IFS= read -r d; do rm -rf "$d"; done
    ok "removed the wrapper's _Partial_* directory"
  fi

  # ---- make the evidence collectable, then PROVE it -------------------------------------
  chown -R "$owner" "$EVIDENCE" 2>/dev/null || true
  find "$EVIDENCE" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  find "$EVIDENCE" -type f -exec chmod u+rw {} + 2>/dev/null || true
  # A MULTI-STIG SCAN PRODUCES A CHECKLIST PER PRODUCT. Say how many, and name them - the
  # whole point of auto-detect is finding products you did not think to look for.
  # ONLY Checklist/, NEVER the whole tree. Evaluate-STIG rotates the previous run into
  # Previous/<timestamp>/, so a recursive find counts a stale checklist from an earlier scan
  # and reports 2 when the current run produced 1. It did exactly that on svc-mgmt-01.
  local ckldir n_ckl
  ckldir="$(find "$EVIDENCE" -maxdepth 2 -type d -name Checklist 2>/dev/null | head -1)"
  n_ckl="$(find "$ckldir" -maxdepth 1 -name '*.cklb' 2>/dev/null | wc -l)"
  say "checklists produced: $n_ckl"
  find "$ckldir" -maxdepth 1 -name '*.cklb' 2>/dev/null | sed 's|.*/||; s/^/       /' | sort

  # A STIG THAT WAS DETECTED AND THEN SKIPPED IS THE FINDING, NOT A FOOTNOTE.
  #
  # svc-mgmt-01 detected PostgreSQL, printed "STIGs to process - 2", produced ONE checklist,
  # and this wrapper reported success. The tool had logged
  #     Utilizing Preference: AllowDeprecated false
  #     Unable to process PgSQL9x - skipping
  # because DISA has SUNSET the PostgreSQL 9.x STIG. A product that is installed, detected,
  # and not assessed is precisely the gap --SelectSTIG was hiding - so say it loudly.
  local tl skipped
  tl="$(find "$EVIDENCE" -maxdepth 2 -name 'Evaluate-STIG.log' 2>/dev/null | head -1)"
  if [ -n "$tl" ]; then
    skipped="$(grep -oE 'Unable to process [A-Za-z0-9_.-]+ - skipping' "$tl" 2>/dev/null \
                | sed 's/Unable to process //; s/ - skipping//' | sort -u || true)"
    if [ -n "$skipped" ]; then
      warn "DETECTED BUT NOT ASSESSED: $(printf '%s' "$skipped" | tr '\n' ' ')"
      warn "  The tool found the product and refused the benchmark - almost always because"
      warn "  DISA has SUNSET that STIG. Check the detection list above for DISAStatus."
      warn "  This is a COVERAGE GAP, not a pass. Options: obtain the current STIG and put"
      warn "  its xccdf in $DEST/Evaluate-STIG/StigContent/Manual/, or re-run with"
      warn "  --allow-deprecated and state in the artefact that the benchmark is retired."
      failed_scan=1
    fi
  fi
  local csv
  csv="$(find "$EVIDENCE" -name '*COMBINED*.csv' -newermt '-30 minutes' 2>/dev/null | sort | tail -1)"
  if [ -z "$csv" ]; then
    warn "no COMBINED csv newer than 30 minutes - did the scan actually finish?"
    return 1
  fi
  if [ "$owner" != root ]; then
    runuser -u "$owner" -- test -r "$csv" \
      && ok "$owner can read the checklist - it can be copied off this machine" \
      || { warn "$owner still CANNOT read $csv - step 14 will fail"; return 1; }
  fi

  # ---- the tally, so nobody types a heredoc at a prompt ---------------------------------
  say ""
  python3 - "$csv" <<'PY'
import csv, collections, os, sys, time
f = sys.argv[1]
rows = list(csv.DictReader(open(f, encoding='utf-8-sig')))
c = collections.Counter(r['Status'] for r in rows)
print("  file : %s" % f)
print("  mtime: %s" % time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(os.path.getmtime(f))))
print("  %d controls   NF=%d  Open=%d  NotReviewed=%d  NA=%d"
      % (len(rows), c.get('NF', 0), c.get('O', 0), c.get('NR', 0), c.get('NA', 0)))
op = sorted([r for r in rows if r['Status'] == 'O'], key=lambda r: (r['Severity'], r['GroupID']))
if op:
    print("\n  OPEN:")
    for r in op:
        print("    %-6s %-10s %-16s %s" % (r['Severity'], r['GroupID'], r['STIGID'], r['RuleTitle'][:50]))
else:
    print("\n  nothing Open.")
PY
  local toollog
  toollog="$(find "$EVIDENCE" -name 'Evaluate-STIG.log' -newermt '-90 minutes' 2>/dev/null | head -1)"
  [ -n "$toollog" ] && say "the tool's own log: $toollog ($(du -h "$toollog" | cut -f1))"
  say ""
  if [ "$failed_scan" -ne 0 ]; then
    warn "scan finished with a COVERAGE GAP - see DETECTED BUT NOT ASSESSED above."
    say ""
    say "   Collect the evidence FROM stage-01 with:"
    say "     ./scripts/enclave/stig-tools.sh collect $me"
    return 1
  fi
  # POINT AT THE COMMAND, NOT AT A RECIPE. The hand-written scp this used to print also
  # skipped the root-only USG results, which is half the evidence - and step 14 went
  # unperformed on all five machines for a week while this line looked like instructions.
  ok "scan complete. Collect the evidence FROM stage-01 with:"
  say "   ./scripts/enclave/stig-tools.sh collect $me"
  say "   (no argument collects every machine; it takes the root-only USG results too,"
  say "    which the hand-written scp did not)"
}

# ---------------------------------------------------------------------------------- detect
#
# WHAT WOULD BE ASSESSED HERE - in seconds, without scanning.
#
# `scan` runs this first anyway, but a 15-minute scan is the wrong way to ask "what is on this
# machine". Run `detect` across the enclave to find products nobody thought to look for, then
# decide where to spend the scan time.
#
# READ THE DISAStatus COLUMN. A product listed as `Sunset` is one DISA has RETIRED: the tool
# will detect it, refuse to score it, and produce no checklist for it. That is a coverage gap,
# and it is invisible unless you look here - svc-mgmt-01's PostgreSQL 9.x was exactly that.
cmd_detect() {
  local me; me="$(hostname -s)"
  case "$me" in
    stage-01|build-01)
      die "detect does not run on $me - it is outside the ATO boundary." ;;
  esac
  need_root
  [ -x "$DEST/$PWSH_DIR/pwsh" ] || die "no pwsh at $DEST/$PWSH_DIR - sudo $0 fetch"
  printf '\n  applicable STIGs on %s\n' "$me"
  ( cd "$DEST/Evaluate-STIG" && bash Evaluate-STIG_Bash.sh --NoUpstream \
      --PSPath "$DEST/$PWSH_DIR" --ListApplicableProducts 2>&1 ) | sed 's/^/     /'
  printf '\n  Active  = will be assessed by `sudo %s scan`\n' "$0"
  printf '  Sunset  = DISA RETIRED it. Detected, NOT assessed, no checklist. A coverage gap:\n'
  printf '            get the current STIG and put its xccdf in\n'
  printf '            %s/Evaluate-STIG/StigContent/Manual/, or force it with\n' "$DEST"
  printf '            --allow-deprecated and say so in the artefact.\n\n'
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
  collect) shift; cmd_collect "$@" ;;
  fetch)   shift; cmd_fetch "$@" ;;
  scan)    shift; cmd_scan "$@" ;;
  detect)  shift; cmd_detect "$@" ;;
  status)  shift; cmd_status "$@" ;;
  *) printf 'usage: %s {publish|answers <machine>|collect [machine...]|fetch|detect|scan|status}\n' "$0" >&2; exit 2 ;;
esac
