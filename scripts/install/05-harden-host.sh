#!/usr/bin/env bash
# =========================================================================================
# 05-harden-host.sh - drive runbook §6.0 end to end on a bare-metal enclave host.
#
#     MACHINE: runs ON the host being hardened. It refuses to run anywhere else.
#
#     sudo ./05-harden-host.sh status     where this machine is in the sequence
#     sudo ./05-harden-host.sh run        do the next steps until it needs you
#     sudo ./05-harden-host.sh reset      forget the state and start over (does NOT undo)
#
# WHY THIS EXISTS
#
# The final install has to be reproducible inside the air gap with nobody to ask. Driving
# §6.0 by hand takes about forty commands, three reboots and a dozen judgement calls, and it
# was done that way on five machines - which is five chances to do it in a different order.
# host-1 on 2026-09-17 is the run this script encodes.
#
# IT ASKS FOR EXACTLY ONE THING IT CANNOT LOOK UP: the GRUB password, and only because
# `grubpw set` is interactive by design. Everything else is discovered, derived, or read from
# a parameter file. If you find yourself being asked something the machine could have worked
# out, that is a defect in this script.
#
# WHY IT IS RESUMABLE RATHER THAN LINEAR
#
# The sequence contains THREE mandatory reboots - after FIPS, after `usg fix`, and after the
# V1R6 kernel-command-line change - and on this hardware every reboot stops at a console to
# take a LUKS passphrase. No single process survives that. So each completed step is recorded
# and `run` continues from the last one. Re-running is always safe: every step either verifies
# or is idempotent.
#
# WHAT IT WILL NOT DO
#
#   - It will not reboot for you. It stops and tells you, because a reboot here needs a human
#     at a console and pretending otherwise would hang the script forever.
#   - It will not install the Evaluate-STIG Answer File. That is pushed FROM stage-01 and
#     cannot be done from the target; the script tells you when it is needed.
#   - It will not patch. 185 pending upgrades on a freshly hardened host is normal, and a
#     `grub-common` upgrade DROPS `--unrestricted` and turns the next boot into a password
#     prompt. Patch as a deliberate step afterwards, then re-run `grubpw status`.
#
# Runbook §6.0 is the reference. This is the execution.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SELF is <repo>/scripts/install, so the enclave scripts are its SIBLING, not two levels up.
# The first version computed $SELF/.. as the repo root and built scripts/scripts/enclave.
ENC="$(cd "$SELF/../enclave" && pwd)"
REPO="$(cd "$SELF/../.." && pwd)"
STATE_DIR=/var/lib/enclave
STATE="$STATE_DIR/harden.state"
LOG="$STATE_DIR/harden.log"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
hdr()  { printf '\n=== %s ===\n' "$*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# ---- the guard. Not a hostname list: the address file is the source of truth -------------
assert_enclave_host() {
  local af="$ENC/enclave-addresses.env"
  [ -r "$af" ] || die "cannot read $af"
  local HOST_1 HOST_2 HOST_3 HOST_4
  eval "$(awk -F= '/^HOST_[0-9]=/{print $1"="$2}' "$af")"
  local mine; mine="$(ip -4 -o addr show scope global 2>/dev/null \
      | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')"
  local h
  for h in "$HOST_1" "$HOST_2" "$HOST_3" "$HOST_4"; do
    [ -n "${h:-}" ] || continue
    case " $mine " in *" $h "*) return 0 ;; esac
  done
  die "WRONG MACHINE: $(hostname -s) ($mine)
       05-harden-host.sh runs ON a bare-metal enclave host. Expected one of:
         $HOST_1  $HOST_2  $HOST_3  $HOST_4"
}

# ---- state ------------------------------------------------------------------------------
# One step per line. Presence means done. Deliberately a flat file: an operator who has to
# understand why the script thinks step 9 is finished can read it with cat.
done_step()  { grep -qxF "$1" "$STATE" 2>/dev/null; }
mark_step()  { printf '%s\n' "$1" >> "$STATE"; printf '%s  %s\n' "$(date -Is)" "$1" >> "$LOG"; }

# ---- the reboot gate --------------------------------------------------------------------
# Records that a reboot is OWED, so a re-run before it happens says so rather than carrying
# on into steps whose preconditions are not met.
need_reboot() {
  local why="$1"
  hdr "REBOOT REQUIRED"
  say "$why"
  say ""
  say "  This host has no BMC and its LUKS root prompts at a physical console, so the"
  say "  machine will NOT come back on its own - somebody has to be at it with the"
  say "  passphrase. That is why this asks instead of just doing it: an automatic reboot"
  say "  on a machine nobody is standing at is not automation, it is a host sitting at a"
  say "  prompt until someone notices."
  say ""

  # OFFER rather than assume. At the console this is one keystroke; away from it, declining
  # costs nothing and the state file means `run` resumes exactly here afterwards.
  #
  # NOT a default of yes. The whole reason for asking is that the operator's PHYSICAL
  # LOCATION is the thing the machine cannot discover, and a default that guesses wrong
  # leaves the enclave down.
  if [ -t 0 ]; then
    printf '  Are you at the console and ready to type the LUKS passphrase? reboot now? [y/N] '
    local a=""; read -r a || true
    case "$a" in
      y|Y)
        say ""
        ok "rebooting. When it is back:  sudo $0 run"
        say "  (it resumes from this exact point - nothing is repeated)"
        say ""
        sync
        # A short delay so the operator actually sees the two lines above before the
        # connection drops, and so the log write lands.
        ( sleep 3; systemctl reboot ) >/dev/null 2>&1 &
        exit 0 ;;
    esac
  else
    say "  (not a terminal - not offering to reboot)"
  fi

  say ""
  say "  When you are ready:"
  say "    sudo reboot"
  say ""
  say "  Then run this again and it continues from here:"
  say "    sudo $0 run"
  exit 0
}

# =========================================================================================
# the steps
# =========================================================================================

step_preflight() {
  done_step preflight && return 0
  hdr "0. preconditions"

  # sudo works, and the admin has a usable password. usg fix has locked an admin out of sudo
  # before (runbook §6.3a); this is the cheapest possible check that it can be fixed.
  [ -n "${SUDO_USER:-}" ] || warn "no SUDO_USER - running as root directly. Confirm a normal admin can sudo."

  # A SECOND SESSION IS THE ONLY WAY BACK IN if usg fix breaks authentication, and on this
  # hardware there is no console short of driving to it. Count real login sessions.
  local sessions; sessions="$(who 2>/dev/null | wc -l)"
  if [ "$sessions" -lt 2 ]; then
    warn "only $sessions login session(s) open on this machine."
    say  "  OPEN A SECOND SSH SESSION NOW and leave it open until this finishes."
    say  "  usg fix has locked the admin account out of sudo before, and there is no BMC"
    say  "  and no serial console on this hardware - the way back in is a session that is"
    say  "  already authenticated."
    printf '  continue anyway? [y/N] '
    local a=""; read -r a || true
    case "$a" in y|Y) ;; *) die "stopped. Open a second session and re-run." ;; esac
  else
    ok "$sessions login sessions open - there is a way back in"
  fi

  [ -x "$SELF/03-host-services.sh" ]  || die "missing $SELF/03-host-services.sh"
  [ -x "$SELF/04-enclave-services.sh" ] || die "missing $SELF/04-enclave-services.sh"
  [ -x "$ENC/stig-tailor.sh" ]        || die "missing $ENC/stig-tailor.sh"
  ok "scripts present"
  mark_step preflight
}

step_hostprep() {
  done_step hostprep && return 0
  hdr "1. host prep - hosts, trust anchor, apt"

  local pf="$SELF/03-host-services/services-params.env"
  if [ ! -r "$pf" ]; then
    # Nothing in it needs a human any more: the NIC and address discover themselves.
    cp "$pf.example" "$pf"
    ok "created services-params.env from the example (NIC and address self-discover)"
  fi

  "$SELF/03-host-services.sh" hosts
  "$SELF/03-host-services.sh" trustca
  "$SELF/03-host-services.sh" apt
  mark_step hostprep
}

step_pro() {
  done_step pro && return 0
  hdr "2. Ubuntu Pro attach"

  if pro status --format json 2>/dev/null | grep -q '"attached": *true'; then
    ok "already attached"
    mark_step pro; return 0
  fi

  # The token is a FILE, mode 0600, pushed from stage-01 with `scp -3` so it never lands on
  # an intermediate disk. It is the one thing this script cannot discover.
  local tok="${SUDO_USER:+/home/$SUDO_USER}/.pro-contract-token"
  [ -s "$tok" ] || tok="$HOME/.pro-contract-token"
  if [ ! -s "$tok" ]; then
    die "no Pro contract token found.
       From stage-01, and it never touches an intermediate disk:
         scp -3 -p -i ~/.ssh/build01 \\
           encadmin@\$SVC_MGMT_01:~/.pro-contract-token encadmin@$(hostname -s):~/.pro-contract-token
       Then re-run:  sudo $0 run"
  fi
  "$SELF/04-enclave-services.sh" pro
  mark_step pro
}

step_fips() {
  done_step fips && return 0
  hdr "3. FIPS"

  if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 0)" = 1 ]; then
    ok "fips_enabled=1, kernel $(uname -r)"
    # Prove the PROVIDER is active, not just the kernel flag. Those are different postures
    # and an assessor knows the difference - runbook §2.3 / HANDOFF §3.
    if openssl list -providers 2>/dev/null | grep -qi 'fips'; then
      ok "OpenSSL FIPS provider is active"
    else
      warn "fips_enabled=1 but the OpenSSL FIPS provider is NOT listed - check before claiming FIPS"
    fi
    mark_step fips; return 0
  fi

  pro enable fips-updates --assume-yes
  need_reboot "FIPS is enabled but the FIPS kernel is not running yet."
}

step_usg() {
  done_step usg && return 0
  hdr "4. USG"
  pro enable usg --assume-yes 2>/dev/null || true
  command -v usg >/dev/null 2>&1 || die "usg not installed after 'pro enable usg'"
  # Take the profile from the tool, never from a document. DISA content moves.
  local prof
  prof="$(usg list 2>/dev/null | awk '/stig/{print $1; exit}')"
  [ -n "$prof" ] || die "could not read a stig profile from 'usg list' - run it by hand and look"
  printf '%s\n' "$prof" > "$STATE_DIR/usg-profile"
  ok "profile: $prof (recorded, so every later step uses the same one)"
  mark_step usg
}

usg_profile() { cat "$STATE_DIR/usg-profile" 2>/dev/null || echo stig-v1r1; }

usg_tally() {  # prints "pass=N fail=N" from the newest report
  local r; r="$(ls -t /var/lib/usg/usg-results-*.xml 2>/dev/null | head -1)"
  [ -n "$r" ] || { echo "pass=? fail=?"; return; }
  printf 'pass=%s fail=%s  (%s)\n' \
    "$(grep -c '<result>pass</result>' "$r")" \
    "$(grep -c '<result>fail</result>' "$r")" "$(basename "$r")"
}

step_baseline() {
  done_step baseline && return 0
  hdr "5. baseline audit - the BEFORE half of the evidence pair"
  say "this takes a few minutes"
  usg audit "$(usg_profile)" >/dev/null 2>&1 || warn "usg audit returned non-zero - the report may still be usable"
  local t; t="$(usg_tally)"
  ok "baseline: $t"
  printf 'baseline %s\n' "$t" >> "$LOG"
  mark_step baseline
}

step_prechecks() {
  done_step prechecks && return 0
  hdr "6. what 'usg fix' will remove, and keeping AIDE off the bulk data"
  "$ENC/stig-tailor.sh" preflight || die "preflight failed or was incomplete - do NOT run usg fix"
  "$ENC/stig-tailor.sh" aide exclude --apply || warn "aide exclude reported a problem"
  say ""
  say "  Read the preflight output above. Anything it flagged as a COLLISION is a decision:"
  say "  either the thing is needed here and becomes a tailoring deviation with a written"
  say "  justification, or it is not and 'fix' may remove it."
  printf '  preflight understood, proceed to usg fix? [y/N] '
  local a=""; read -r a || true
  case "$a" in y|Y) ;; *) die "stopped before usg fix. Nothing has been changed by it." ;; esac
  mark_step prechecks
}

step_usgfix() {
  done_step usgfix && return 0
  hdr "7. usg fix - THIS CHANGES THE MACHINE"
  usg fix "$(usg_profile)" || warn "usg fix returned non-zero - continuing, the audit is the judge"
  mark_step usgfix
  need_reboot "usg fix has been applied and needs a reboot before anything is re-checked."
}

step_tailor() {
  done_step tailor && return 0
  hdr "8. tailoring, fixups, ufw, time"
  "$ENC/stig-tailor.sh" generate
  "$ENC/stig-tailor.sh" fixups --apply
  "$ENC/stig-tailor.sh" fixups --verify || warn "fixups --verify reported drift"

  # ufw LAST of this group and verified off-box afterwards: it is the only step here that can
  # make the machine unreachable, and on this hardware unreachable means a drive to the rack.
  "$ENC/stig-tailor.sh" ufw --apply || warn "ufw apply reported a problem"

  # Time: host-4 is the master and has no upstream, so ITS chrony rules are a deviation. A
  # client host has an upstream and the rules are PASSABLE - configure, do not deviate.
  local master master_name
  eval "$(awk -F= '/^TIME_MASTER(_NAME)?=/{print $1"="$2}' "$ENC/enclave-addresses.env")"
  master="${TIME_MASTER:-}"; master_name="${TIME_MASTER_NAME:-}"
  local mine; mine="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')"
  case " $mine " in
    *" $master "*) ok "this machine IS the time master - chrony rules stay a deviation" ;;
    *) "$ENC/time-sync.sh" client && ok "chrony pointed at $master_name ($master)" ;;
  esac

  say ""
  warn "VERIFY SSH FROM ANOTHER MACHINE NOW, before continuing."
  say  "  ufw is live. A firewall you have not tested from off-box is a firewall you are guessing."
  printf '  confirmed reachable from off-box? [y/N] '
  local a=""; read -r a || true
  case "$a" in y|Y) ;; *) die "stopped. Fix reachability, then re-run." ;; esac
  mark_step tailor
}

step_grub() {
  done_step grub && return 0
  hdr "9. GRUB password"
  "$ENC/stig-tailor.sh" grubpw prep
  say ""
  say "  'prep' put --unrestricted on the boot classes FIRST. That ordering is not optional:"
  say "  a password without it makes GRUB demand one to BOOT, not just to edit, and this"
  say "  machine has no console you can reach."
  say ""
  say "  THE ONE THING THIS SCRIPT CANNOT LOOK UP is next. Record the password wherever the"
  say "  LUKS passphrase is recorded - it is the second thing that can stop this host booting."
  say ""
  "$ENC/stig-tailor.sh" grubpw set
  mark_step grub
}

step_v1r6() {
  done_step v1r6 && return 0
  hdr "10. DISA V1R6 mechanical fixes"
  "$ENC/stig-tailor.sh" v1r6 --apply
  mark_step v1r6
  need_reboot "V1R6 changed the kernel command line (audit=1) and auditd is immutable.
       Both need a boot - a reload will not do it."
}

step_verify() {
  done_step verify && return 0
  hdr "11. verify everything, after the last reboot"
  local bad=0
  grep -qw 'audit=1' /proc/cmdline && ok "audit=1 is LIVE on the kernel command line" \
    || { warn "audit=1 is NOT on /proc/cmdline - the reboot did not deliver it"; bad=1; }
  "$ENC/stig-tailor.sh" grubpw status
  "$ENC/stig-tailor.sh" v1r6 --verify   || { warn "v1r6 --verify failed"; bad=1; }
  "$ENC/stig-tailor.sh" fixups --verify || { warn "fixups --verify failed"; bad=1; }
  local f; f="$(systemctl --failed --no-legend --plain | wc -l)"
  [ "$f" -eq 0 ] && ok "no failed units" || { warn "$f failed unit(s):"; systemctl --failed --no-legend --plain; bad=1; }
  [ "$bad" -eq 0 ] || warn "items above need attention before this machine is called done"
  mark_step verify
}

step_final_audit() {
  done_step final_audit && return 0
  hdr "12. final USG audit, against the tailoring file"
  "$ENC/stig-tailor.sh" audit >/dev/null 2>&1 || warn "tailored audit returned non-zero"
  local t; t="$(usg_tally)"
  ok "FINAL: $t"
  printf 'final %s\n' "$t" >> "$LOG"
  say ""
  say "  Both numbers are in $LOG. Record them in airgapped-setup-machine/README.md §0 -"
  say "  the pair is the evidence, not the final number alone."
  say ""
  say "  Anything still failing should be a POLICY DECISION, not a defect. On host-1 the"
  say "  residual was: auditd_offload_logs (AO), sssd x2 (the CAC family, and one of them"
  say "  because we deliberately disabled a service that cannot start), and nothing else."
  mark_step final_audit
}

step_evalstig() {
  done_step evalstig && return 0
  hdr "13. Evaluate-STIG - the second scanner, DISA V1R6 content"
  apt-get install -y lshw dmidecode bc >/dev/null 2>&1 || warn "could not install lshw/dmidecode/bc"
  "$ENC/stig-tools.sh" fetch || die "stig-tools fetch failed"

  # The Answer File is pushed FROM stage-01 and cannot be fetched from here. Without it the
  # scan reports every documented deviation as Open/NR and the whole thing has to be re-run.
  if ! ls /srv/stig-tools/Evaluate-STIG/AnswerFiles/*.xml >/dev/null 2>&1; then
    hdr "ANSWER FILE NEEDED - from stage-01, WITHOUT sudo"
    say "  cd ~/canonical-k8s && ./scripts/enclave/stig-tools.sh answers $(hostname -s)"
    say ""
    say "  Without it the scan marks every documented deviation Open or Not Reviewed and you"
    say "  will triage 17 entries by hand and then scan again. Do it first."
    say ""
    say "  Then:  sudo $0 run"
    exit 0
  fi
  ok "Answer File present"
  say "scanning - 7 to 15 minutes, and it prints progress"
  "$ENC/stig-tools.sh" scan || warn "scan returned non-zero - read the output"
  mark_step evalstig
}

step_done() {
  hdr "sequence complete on $(hostname -s)"
  say "$(cat "$LOG" 2>/dev/null | tail -20)"
  say ""
  say "  STILL OWED, and neither is part of §6.0:"
  say "    - stig-tools.sh collect      (step 14 - gather evidence to the repo)"
  say "    - PATCH. This host has pending upgrades and they were deliberately NOT applied."
  say "      A grub-common upgrade DROPS --unrestricted and turns the next boot into a"
  say "      password prompt on a machine with no console. After patching, re-run:"
  say "        sudo $ENC/stig-tailor.sh grubpw status"
  say "        sudo $ENC/stig-tailor.sh fixups --verify"
  say ""
  say "  AND CONFIRM THIS MACHINE STILL DOES ITS JOB. §6.0 step 15. On a hypervisor that"
  say "  means starting and stopping a guest - not reading unit states. FIPS silently broke"
  say "  MAAS for seven days while systemctl said everything was active."
}

# =========================================================================================
cmd_status() {
  assert_enclave_host
  printf '\n  hardening state on %s\n\n' "$(hostname -s)"
  local s
  for s in preflight hostprep pro fips usg baseline prechecks usgfix tailor grub v1r6 verify final_audit evalstig; do
    printf '  %s %s\n' "$(done_step "$s" && echo '[x]' || echo '[ ]')" "$s"
  done
  printf '\n  state file: %s\n' "$STATE"
  [ -r "$LOG" ] && { printf '  log:\n'; sed 's/^/    /' "$LOG"; }
  printf '\n'
}

cmd_run() {
  need_root; assert_enclave_host
  install -d -m 0755 "$STATE_DIR"; touch "$STATE" "$LOG"
  step_preflight; step_hostprep; step_pro; step_fips; step_usg; step_baseline
  step_prechecks; step_usgfix; step_tailor; step_grub; step_v1r6
  step_verify; step_final_audit; step_evalstig; step_done
}

case "${1:-status}" in
  status) cmd_status ;;
  run)    cmd_run ;;
  reset)  need_root; assert_enclave_host
          rm -f "$STATE"; ok "state cleared - this does NOT undo anything already applied" ;;
  *) printf 'usage: %s {status|run|reset}\n' "$(basename "$0")" >&2; exit 2 ;;
esac
