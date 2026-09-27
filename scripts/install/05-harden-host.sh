#!/usr/bin/env bash
# =========================================================================================
# 05-harden-host.sh - drive runbook §6.0 end to end on an enclave machine: a bare-metal host,
# or - since 2026-09-26 (B-06 slice 1, docs/06-guest-vms.md) - a guest VM.
#
#     MACHINE: runs ON the host or guest being hardened. Which one it is comes from the address
#     file, never from an argument; it refuses any machine that is neither.
#
#     sudo ./05-harden-host.sh status     where this machine is in the sequence
#     sudo ./05-harden-host.sh run        do the next steps until it needs you
#     sudo ./05-harden-host.sh resume     GUEST only: hand a halted run back to the unattended unit
#     sudo ./05-harden-host.sh reset      forget the state and start over (does NOT undo)
#
# WHY THIS EXISTS
#
# The final install has to be reproducible inside the air gap with nobody to ask. Driving
# §6.0 by hand takes about forty commands, three reboots and a dozen judgement calls, and it
# was done that way on five machines - which is five chances to do it in a different order.
# host-1 on 2026-09-17 is the run this script encodes.
#
# IT ASKS ONLY FOR SECRETS, AND ONLY WHEN NONE WAS SUPPLIED (2026-09-25, backlog 3.32): the
# GRUB password, the second admin's password and this machine's emergency password. Each is
# taken from a pre-made hash instead when one is in the environment or in the site credentials
# file (/etc/enclave/credentials.env, root 600) - then the whole sequence runs unattended. Everything else is discovered, derived, or read from
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
#   - It DOES patch, at step 3b - after FIPS and BEFORE hardening. That ordering is
#     deliberate: the scan then describes the machine that exists, and a `grub-common`
#     upgrade cannot drop the `--unrestricted` that `grubpw prep` adds later. Every
#     FUTURE patch cycle still needs `grubpw status` and `fixups --verify` afterwards.
#   - It does NOT cover every row of runbook 6.0. Still by hand once `run` completes:
#     14 `stig-tools.sh collect` FROM stage-01, and 15 a test that the machine still does its
#     job. (12f accounts and 16 audit-volume became steps `accounts` and `auditvolume` on
#     2026-09-25 - backlog 3.31 #10.)
#
# STEP NUMBERS. The numbers this script prints (0, 1, 2, 3, 3b ...) are its own. Each step
# function below names the runbook 6.0 row it implements.
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

# ---- B-06 slice 2: on a GUEST, 05 reboots itself and resumes (docs/06-guest-vms.md §8) -----
# A guest has no LUKS prompt, so the one reason a host stops at every reboot does not apply.
# At its first reboot 05 installs RESUME_UNIT, which runs 05 again at each boot until the
# sequence is complete or halted. The unit runs a ROOT-OWNED copy of the repo (BUILD_COPY), never
# ~/canonical-k8s: that is encadmin-writable, and a root unit executing it is the privilege path
# closed in backlog 3.11. D7 (2026-09-26): a failure STOPS - it marks HALTED and disables the unit,
# so nothing retries at every boot; a human reads the console log and re-runs by hand.
RESUME_UNIT=enclave-harden.service
BUILD_COPY="${BUILD_COPY:-/opt/enclave-build}"
HALTED="$STATE_DIR/hardening-halted"
COMPLETE="$STATE_DIR/hardening-complete"
CURRENT_STEP=""
# What an UNATTENDED guest's preflight may flag and still proceed to `usg fix` (step_prechecks).
# In vm-specs.env because the unit runs with no environment; the environment still wins by hand.
GUEST_PRECHECK_EXPECTED="${GUEST_PRECHECK_EXPECTED-$(grep -oE "^GUEST_PRECHECK_EXPECTED='[^']*'" "$ENC/vm-specs.env" 2>/dev/null | cut -d"'" -f2)}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
hdr()  { printf '\n=== %s ===\n' "$*"; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# ---- the guard. Not a hostname list: the address file is the source of truth -------------
# HOST OR GUEST, DERIVED - never typed (backlog B-06, decision D2, 2026-09-26). Which
# address-file key owns an address this machine holds decides it: HOST_* is a bare-metal host,
# SVC_* / PG_* / K8S_CP_* / K8S_WK_* is a guest. Anything else - stage-01, build-01, the K8S API
# VIP, a DHCP range - is refused. Hardening a guest is the same runbook 6.0 as a host: its own Pro
# attach, FIPS kernel and STIG pass (runbook 7.4); the steps differ only where noted by ROLE.
ROLE=""; ME_KEY=""
assert_enclave_host() {
  local af="$ENC/enclave-addresses.env" mine key val
  [ -r "$af" ] || die "cannot read $af"
  mine="$(ip -4 -o addr show scope global 2>/dev/null \
      | awk '{split($4,a,"/"); print a[1]}' | tr '\n' ' ')"
  while IFS='=' read -r key val; do
    val="${val%%#*}"; val="$(printf '%s' "$val" | tr -d "'\" \t")"
    [ -n "$val" ] || continue
    case " $mine " in *" $val "*) ;; *) continue ;; esac
    case "$key" in
      HOST_[0-9]*)                                   ROLE=host ;;
      SVC_*|PG_[0-9]*|K8S_CP_[0-9]*|K8S_WK_[0-9]*)   ROLE=guest ;;
      *) continue ;;
    esac
    ME_KEY="$key"; return 0
  done < <(grep -E '^[A-Z0-9_]+=' "$af")
  die "WRONG MACHINE: $(hostname -s) ($mine)
       05-harden-host.sh runs ON an enclave machine - a host (HOST_*) or a guest (SVC_*, PG_*,
       K8S_CP_*, K8S_WK_*) in $af. None of those addresses is on this machine."
}

# ---- state ------------------------------------------------------------------------------
# One step per line. Presence means done. Deliberately a flat file: an operator who has to
# understand why the script thinks step 9 is finished can read it with cat.
done_step()  { grep -qxF "$1" "$STATE" 2>/dev/null; }
mark_step()  { printf '%s\n' "$1" >> "$STATE"; printf '%s  %s\n' "$(date -Is)" "$1" >> "$LOG"; progress "$1" OK; }

# ONE LINE PER STEP ON THE GUEST'S SERIAL CONSOLE, which its host logs to
# <pool>/console/<vm>-console.log - how a run nobody is logged into is watched. Step names and
# results only: that log is 0644 on the host, so nothing from a credential ever goes here.
progress() {
  [ "$ROLE" = guest ] || return 0
  [ -w /dev/ttyS0 ] && printf 'ENCLAVE-HARDEN %s %s %s\n' "$(hostname -s)" "$1" "$2" > /dev/ttyS0 2>/dev/null || true
}

# The unit, and the root-owned copy it runs. Re-copied whenever 05 is started from anywhere
# else (so a fix pushed to ~/canonical-k8s reaches the next unattended boot); left alone while
# the unit itself is running from the copy.
install_resume_unit() {
  # THE GUARD FIRST: the copy is replaced wholesale, so only the two known locations are allowed.
  case "$BUILD_COPY" in /opt/enclave-build|/usr/local/lib/enclave-build) ;;
    *) die "BUILD_COPY='$BUILD_COPY' - refusing: it is replaced wholesale, so it must be /opt/enclave-build or /usr/local/lib/enclave-build" ;; esac
  local src; src="$(cd "$REPO" && pwd -P)"
  if [ "$src" != "$BUILD_COPY" ]; then
    rm -rf "$BUILD_COPY.new"; install -d -m 0755 "$BUILD_COPY.new"
    cp -a "$src/." "$BUILD_COPY.new/"
    chown -R root:root "$BUILD_COPY.new"; chmod -R go-w "$BUILD_COPY.new"
    rm -rf "$BUILD_COPY"; mv "$BUILD_COPY.new" "$BUILD_COPY"
    ok "root-owned copy for the resume unit: $BUILD_COPY ($(cat "$BUILD_COPY/.pushed-from" 2>/dev/null | cut -c1-7 || echo '?'))"
  fi
  resume_unit_text > "/etc/systemd/system/$RESUME_UNIT"
  systemctl daemon-reload
  systemctl enable "$RESUME_UNIT" >/dev/null 2>&1 || die "could not enable $RESUME_UNIT"
  ok "$RESUME_UNIT enabled - it resumes this run at the next boot"
}

# THE UNIT CONTINUES A SUDO RUN, SO IT CARRIES A SUDO RUN'S ENVIRONMENT. Found 2026-09-27: the
# first unattended pass on pg-01 got through every hardening step and died at evalstig on
# `HOME: unbound variable` - systemd gives a root service no HOME, and no SUDO_USER either, which
# is what hands the Evaluate-STIG evidence to the operator so `collect` can pull it unprivileged.
# The operator is whoever handed the run over (`sudo 05 run` or `resume`). The unit sets it, so
# every reboot rewrites the unit with the same value. No operator: root-only evidence, said so.
resume_unit_text() {
  local op=""
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && id "$SUDO_USER" >/dev/null 2>&1; then
    op="Environment=SUDO_USER=$SUDO_USER SUDO_UID=$(id -u "$SUDO_USER") SUDO_GID=$(id -g "$SUDO_USER")"
  else
    warn "no invoking operator (SUDO_USER) - evidence the unit writes will be readable by root only" >&2
  fi
  cat <<UNIT
[Unit]
Description=Enclave hardening - resumes 05-harden-host.sh after its own reboot (B-06 slice 2)
Wants=network-online.target
After=network-online.target
ConditionPathExists=!$COMPLETE
ConditionPathExists=!$HALTED

[Service]
Type=oneshot
ExecStart=$BUILD_COPY/scripts/install/05-harden-host.sh run
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=infinity
Environment=HOME=/root USER=root LOGNAME=root
$op

[Install]
WantedBy=multi-user.target
UNIT
}

# HOWEVER 05 ENDS. set -e ends a failing step without passing through die(), so the halt hangs
# off EXIT, not off die. rc 0 is a normal stop (a reboot, or the end).
harden_exit() {
  local rc="$1"
  [ "$rc" -ne 0 ] && [ -n "$CURRENT_STEP" ] || return 0
  progress "$CURRENT_STEP" "FAIL rc=$rc"
  if [ "$ROLE" = guest ] && [ ! -t 0 ]; then
    touch "$HALTED"; systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
    progress "$CURRENT_STEP" "HALTED - read this log, fix, then run 05 by hand"
  fi
}

# ---- the reboot gate --------------------------------------------------------------------
# Records that a reboot is OWED, so a re-run before it happens says so rather than carrying
# on into steps whose preconditions are not met.
need_reboot() {
  local why="$1"
  hdr "REBOOT REQUIRED"
  say "$why"
  say ""
  if [ "$ROLE" = guest ]; then
    # B-06 slice 2: no question. A guest has no LUKS prompt - its disk is an image on its host's
    # already-unlocked storage - so it reboots itself and the resume unit carries on at boot.
    say "  A guest reboots ITSELF: no LUKS prompt, and $RESUME_UNIT resumes this run at boot."
    say "  An SSH session to it drops now. Watch from its host, no login needed:"
    say "    sudo tail -f <pool>/console/$(hostname -s)-console.log     (lines start ENCLAVE-HARDEN)"
    install_resume_unit
    progress "${CURRENT_STEP:-reboot}" REBOOT
    sync
    systemctl --no-block reboot
    exit 0
  fi
  say "  On a host the TPM unlocks the disk at boot (clevis, all four hosts since"
  say "  2026-09-22). If it cannot - firmware or boot-chain change - the LUKS passphrase is"
  say "  needed at the console, and the host has no BMC. That is why this asks rather than"
  say "  rebooting a machine nobody may be standing at."
  say ""

  # OFFER rather than assume. At the console this is one keystroke; away from it, declining
  # costs nothing and the state file means `run` resumes exactly here afterwards.
  #
  # NOT a default of yes. The whole reason for asking is that the operator's PHYSICAL
  # LOCATION is the thing the machine cannot discover, and a default that guesses wrong
  # leaves the enclave down.
  if [ -t 0 ]; then
    if [ "$ROLE" = guest ]; then printf '  reboot now? [y/N] '
    else printf '  reboot now? (if the TPM does not unlock it, the LUKS passphrase is needed at the console) [y/N] '; fi
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

# runbook 6.0 steps 1-2: an admin who can sudo, and a second session left open - the only way
# back in if usg fix breaks authentication (6.3a).
step_preflight() {
  done_step preflight && return 0
  hdr "0. preconditions"

  # sudo works, and the admin has a usable password. usg fix has locked an admin out of sudo
  # before (runbook §6.3a); this is the cheapest possible check that it can be fixed.
  [ -n "${SUDO_USER:-}" ] || warn "no SUDO_USER - running as root directly. Confirm a normal admin can sudo."

  # A SECOND SESSION IS THE ONLY WAY BACK IN if usg fix breaks authentication, and on this
  # hardware there is no console short of driving to it. Count real login sessions.
  #
  # NOT ON A GUEST. A guest HAS a console: its serial port is a pty on its host, so
  # `virsh console` from the host plus the break-glass account is the way back in - the path the
  # composer built for exactly this (runbook 6.3j). Asking for a second SSH session there would
  # be a prompt with no purpose, and unattended guest hardening (slices 2-3) cannot answer it.
  local sessions; sessions="$(who 2>/dev/null | wc -l)"
  if [ "$ROLE" = guest ]; then
    local place; place="$(grep -oE "PLACE_${ME_KEY}='[^']*'" "$ENC/vm-specs.env" 2>/dev/null | cut -d"'" -f2)"
    ok "guest ($ME_KEY): the way back in is its serial console - on its host (the map says"
    say "   ${place:-see vm-specs.env PLACE_$ME_KEY}; 'sudo virsh list' there confirms): sudo virsh console $(hostname -s)"
  elif [ "$sessions" -lt 2 ]; then
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

# Not a 6.0 row - the host-prep prerequisites: /etc/hosts, the enclave trust anchors, apt at
# the mirror (03-host-services.sh), plus the tools later steps would otherwise find missing.
step_hostprep() {
  done_step hostprep && return 0
  hdr "1. host prep - hosts, trust anchor, apt"

  if [ "$ROLE" = guest ]; then
    # ON A GUEST, CLOUD-INIT ALREADY DID THIS (03-compose-vm.sh user-data: the /etc/hosts block,
    # ca_certs, the mirror's ubuntu.sources) - and 03-host-services.sh refuses anything but a
    # bare-metal host. Found 2026-09-27, the first 05 run on a guest (pg-01, B-06 slice 1).
    # VERIFY instead of assuming: a guest composed before a change to the composer, or one whose
    # first boot half-failed, must not be hardened on top of a missing piece.
    local gbad=0
    if grep -q '^# BEGIN enclave-addresses' /etc/hosts; then ok "/etc/hosts carries the enclave block (cloud-init)"
    else warn "/etc/hosts has NO enclave block - cloud-init did not write it"; gbad=1; fi
    if grep -qE '^URIs: https://[^ ]*svc-repo-01' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then ok "apt points at the enclave mirror over https (cloud-init)"
    else warn "apt is NOT pointed at the enclave mirror"; gbad=1; fi
    # One real fetch proves both the CA trust and the reachability that everything after this needs.
    local gcode; gcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://svc-repo-01.enclave.internal/ 2>&1 || true)"
    case "$gcode" in 2??|3??) ok "the enclave CA is trusted - https to the mirror verifies (HTTP $gcode)" ;;
      *) warn "https to the mirror FAILED (HTTP ${gcode:-none}) - the enclave CA is not trusted, or the mirror is unreachable"; gbad=1 ;; esac
    [ "$gbad" -eq 0 ] || die "this guest is missing what cloud-init should have given it - fix that (or recompose) before hardening"
  else
    local pf="$SELF/03-host-services/services-params.env"
    if [ ! -r "$pf" ]; then
      # Nothing in it needs a human any more: the NIC and address discover themselves.
      cp "$pf.example" "$pf"
      ok "created services-params.env from the example (NIC and address self-discover)"
    fi

    "$SELF/03-host-services.sh" hosts
    "$SELF/03-host-services.sh" trustca
    "$SELF/03-host-services.sh" apt
  fi

  # THE TOOLS LATER STEPS NEED, INSTALLED WHILE THE MIRROR IS KNOWN GOOD - not discovered
  # missing halfway through hardening.
  #
  # xmllint (libxml2-utils) is the one that mattered: `stig-tailor.sh tailor` validates the
  # generated USG tailoring file with it and SKIPS the check when it is absent. It has been
  # absent on every host ever built - so a generated 1500-line XML that nothing validates has
  # been handed to `usg` five times. Seen again on the host-3 rebuild, 2026-09-21, which is
  # exactly the kind of "nobody noticed for weeks" gap a from-scratch build is supposed to find.
  #
  # lshw, dmidecode and bc were installed at step 13 - too late to help steps 8-12 and no
  # reason to wait. Installing them here makes the hardening steps independent of each other.
  local _need="libxml2-utils lshw dmidecode bc"
  local _miss=""
  for _p in $_need; do dpkg -s "$_p" >/dev/null 2>&1 || _miss="$_miss $_p"; done
  if [ -n "$_miss" ]; then
    say "installing tools later steps need:$_miss"
    # Output captured, and SHOWN on failure - never thrown away (the swallowed-output habit).
    local _out _rc=0
    _out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $_miss 2>&1)" || _rc=$?
    [ "$_rc" -eq 0 ] || { warn "could not install:$_miss (apt exit $_rc):"; printf '%s\n' "$_out" | tail -8 | sed 's/^/       /' >&2; }
  fi
  for _p in $_need; do
    dpkg -s "$_p" >/dev/null 2>&1 && ok "$_p present" || warn "$_p STILL MISSING - checks that need it will be skipped, not failed"
  done
  mark_step hostprep
}

# runbook 6.0 step 4 (6.1): attach to the enclave contracts server, nothing enabled.
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
  [ -s "$tok" ] || tok="${HOME:-/root}/.pro-contract-token"
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

# runbook 6.0 step 5 (6.2): fips-updates, then a reboot onto the FIPS kernel. The SSP wording
# for what this delivers is ssp-inputs.md 1.1-1.2 (suggested control SC-13).
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

# Not a 6.0 row (this script's step 3b): patch to the mirror's level after FIPS and before
# hardening. Why, at length, inside.
step_patch() {
  done_step patch && return 0
  hdr "3b. PATCH - before hardening, deliberately"

  # WHY HERE AND NOT AT THE END. Brian asked the right question on 2026-09-17: patch first so
  # the scan describes the machine that exists.
  #
  #   1. EVIDENCE. Scanning an unpatched host and then patching means the CKLs document a
  #      state that is already gone. An assessor is shown a machine nobody has.
  #   2. IT DEFUSES grub-common. /etc/grub.d/10_linux is a PACKAGE file: upgrading it DROPS
  #      the --unrestricted that `grubpw prep` adds, which turns the next boot into a GRUB
  #      password prompt on a box with no console. Patch BEFORE prep and the upgrade cannot
  #      take it away afterwards.
  #   3. ONE FEWER REBOOT. The patch reboot folds into the sequence instead of being a fourth
  #      trip to the rack.
  #
  # AND WHY AFTER FIPS, NOT BEFORE: `pro enable fips-updates` moves this host onto the FIPS
  # kernel line. Patching the generic kernel first is work thrown away.
  #
  # THIS DOES NOT REMOVE THE DAY-2 OBLIGATION. Every future patch cycle still has to be
  # followed by `grubpw status` and `fixups --verify`, because the same package can drop the
  # same setting again. Doing it here only means the BUILD ends in a consistent state.

  apt-get update >/dev/null 2>&1 || warn "apt-get update reported a problem"

  # MEASURE IT FIRST. The count and download size are the only real data anyone has for Q6 -
  # the offline patch-bundle size and cadence question open since August - and they are free
  # to capture here. A simulated run changes nothing.
  local sim n bytes
  sim="$(apt-get -s full-upgrade 2>/dev/null)"
  n="$(printf '%s\n' "$sim" | awk '/^[0-9]+ upgraded/{print $1; exit}')"
  bytes="$(printf '%s\n' "$sim" | awk -F'[ /]' '/Need to get/{print $4, $5; exit}')"
  n="${n:-0}"
  if [ "$n" -eq 0 ]; then
    ok "nothing to upgrade - already at the mirror's level"
    mark_step patch; return 0
  fi
  say "$n package(s) to upgrade${bytes:+, $bytes to download}"
  printf 'patch %s packages %s\n' "$n" "${bytes:-?}" >> "$LOG"
  say ""
  say "  NOTE FOR THE SSP: this brings the host to THE MIRROR'S level, not to upstream"
  say "  current. The mirror has a sync date, and AptMetadataStale exists to say when it is"
  say "  drifting. \"Fully patched\" here means \"matches the mirror\"."
  say ""

  DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    full-upgrade || die "full-upgrade failed - resolve it before hardening a half-patched host"

  apt-get -y autoremove >/dev/null 2>&1 || true
  ok "upgraded $n package(s)"
  mark_step patch

  if [ -f /var/run/reboot-required ]; then
    need_reboot "The upgrade installed something that needs a reboot$(
      [ -r /var/run/reboot-required.pkgs ] && printf ' (%s)' "$(tr '\n' ' ' < /var/run/reboot-required.pkgs)")."
  fi
  ok "no reboot required by the upgrade"
}

# runbook 6.0 step 6: enable usg and pin the versioned STIG profile it offers.
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

# runbook 6.0 step 7: the unhardened audit - the BEFORE number of the evidence pair.
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

# runbook 6.0 steps 8b + 8c: what usg fix would remove here (6.3f), and AIDE kept off the
# bulk data BEFORE fix builds its database (6.3h). Stops for a human decision.
step_prechecks() {
  done_step prechecks && return 0
  hdr "6. what 'usg fix' will remove, and keeping AIDE off the bulk data"
  local rep="$STATE_DIR/preflight-report"
  PREFLIGHT_REPORT="$rep" "$ENC/stig-tailor.sh" preflight \
    || die "preflight failed or was incomplete - do NOT run usg fix"
  "$ENC/stig-tailor.sh" aide exclude --apply || warn "aide exclude reported a problem"
  say ""
  if [ "$ROLE" = guest ] && [ ! -t 0 ]; then
    # NOBODY IS HERE TO ANSWER, SO DECIDE - NARROWLY (B-06 slice 2, 2026-09-27: the [y/N] below
    # read nothing and halted the first unattended run on pg-01, correctly). The gate exists so a
    # person reads what `usg fix` will remove. Proceed ONLY if nothing was flagged beyond the
    # already-decided set (a decided item already ABSENT is fine) and no account loses NOPASSWD
    # into a lock-out (6.3a). Anything else halts for a person, who then runs 05 by hand and gets
    # the question. Reads preflight's REPORT, not its prose.
    local flagged extra u bad=0
    grep -qx 'complete preflight' "$rep" 2>/dev/null \
      || die "preflight left no complete report at $rep - do NOT run usg fix"
    flagged="$(awk '$1=="package"||$1=="service"{print $2}' "$rep" | sort -u)"
    extra="$(comm -23 <(printf '%s\n' "$flagged" | awk 'NF') \
      <(printf '%s\n' "$GUEST_PRECHECK_EXPECTED" | tr -s ' \t' '\n\n' | awk 'NF' | sort -u) | paste -sd' ' -)"
    if [ -z "$extra" ]; then ok "preflight flagged only decided items: [$(printf '%s' "$flagged" | paste -sd' ' -)]"
    else warn "preflight flagged [$extra] - NOT in GUEST_PRECHECK_EXPECTED (vm-specs.env)"; bad=1; fi
    for u in $(awk '$1=="nopasswd-service"||$1=="incomplete"{print $1":"$2}' "$rep"); do
      warn "preflight: ${u} - a person must decide this one"; bad=1
    done
    for u in $(awk '$1=="nopasswd-user"{print $2}' "$rep" | sort -u); do
      if [ "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" = P ]; then
        ok "$u loses NOPASSWD and has a password - not locked out"
      else warn "$u loses NOPASSWD and has NO usable password - the 6.3a lock-out"; bad=1; fi
    done
    [ "$bad" -eq 0 ] || die "stopped before usg fix - this preflight needs a person. Nothing has been changed by it."
  else
    say "  Read the preflight output above. Anything it flagged as a COLLISION is a decision:"
    say "  either the thing is needed here and becomes a tailoring deviation with a written"
    say "  justification, or it is not and 'fix' may remove it."
    printf '  preflight understood, proceed to usg fix? [y/N] '
    local a=""; read -r a || true
    case "$a" in y|Y) ;; *) die "stopped before usg fix. Nothing has been changed by it." ;; esac
  fi
  mark_step prechecks
}

# runbook 6.0 step 9: usg fix, then the mandatory reboot. Never re-run fix; audit instead.
step_usgfix() {
  done_step usgfix && return 0
  hdr "7. usg fix - THIS CHANGES THE MACHINE"
  usg fix "$(usg_profile)" || warn "usg fix returned non-zero - continuing, the audit is the judge"
  mark_step usgfix
  need_reboot "usg fix has been applied and needs a reboot before anything is re-checked."
}

# runbook 6.0 steps 10, 11 and 12b: tailoring (6.3b), fixups (6.3c), ufw (6.3e), and chrony
# pointed at the time master. The post-reboot proof of the fixups is in step_verify.
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
  if [ "$ROLE" = guest ]; then
    # No question on a guest (B-06): an unattended run has nobody to answer it, and a machine
    # cannot test its own firewall from outside. Its host does that after the run (slice 4);
    # until then, check it by hand: ssh to it from another machine.
    warn "ufw is live - check SSH to $(hostname -s) FROM ANOTHER MACHINE (slice 4 will do this from the host)"
  else
    warn "VERIFY SSH FROM ANOTHER MACHINE NOW, before continuing."
    say  "  ufw is live. A firewall you have not tested from off-box is a firewall you are guessing."
    printf '  confirmed reachable from off-box? [y/N] '
    local a=""; read -r a || true
    case "$a" in y|Y) ;; *) die "stopped. Fix reachability, then re-run." ;; esac
  fi
  mark_step tailor
}

# runbook 6.0 step 12b2 (6.3g.1).
step_radio() {
  done_step radio && return 0
  hdr "8a. radios - WiFi and Bluetooth"
  # V-270755 / UBTU-24-600230. THIS IS NOT A PAPERWORK CONTROL IN AN AIR GAP: a radio is the
  # one component that can cross the boundary without anybody moving a cable. Measured
  # 2026-09-17, every host in this lab shipped with one - Realtek RTL8821CE on host-1/2/3,
  # MediaTek MT7922 on host-4, and a USB Bluetooth radio on all four.
  #
  # The checklist does not reliably catch it. Where no driver is bound there is no interface,
  # DISA's check finds nothing, and the rule scores NOT APPLICABLE on a machine with a radio
  # physically in it. So this runs unconditionally rather than on the scan result.
  #
  # It is safe to run on a machine with no radio - it discovers nothing and does nothing - and
  # it REFUSES rather than guessing if discovery ever lands on a module carrying the network.
  "$ENC/stig-tailor.sh" radio status
  "$ENC/stig-tailor.sh" radio disable || warn "radio disable reported a problem - see above"
  "$ENC/stig-tailor.sh" radio status
  mark_step radio
}

# runbook 6.0 step 12c (6.3i): GRUB password, V-270675. prep FIRST, or GRUB demands the
# password to boot (ssp-inputs.md 4.4).
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

# runbook 6.0 step 12f (backlog 3.15 / 3.32): the second named admin and the console-only
# emergency account. Placed BEFORE v1r6 on purpose: v1r6 ends in a reboot, and that reboot is
# what loads the emergency account's audit rule - auditd is immutable after usg fix.
# Unattended when hashes are supplied (environment, or /etc/enclave/credentials.env - the
# emergency one PER MACHINE); otherwise two custodians type it here and seal it.
step_accounts() {
  done_step accounts && return 0
  hdr "9b. second named admin and console-only emergency account"
  "$ENC/stig-tailor.sh" accounts create
  mark_step accounts
}

# runbook 6.0 step 16: the hourly audit-volume sample that sizes this machine's audit
# allocation (V-270816). No prompts, safe to repeat; installs a root-owned runtime copy.
step_auditvolume() {
  done_step auditvolume && return 0
  hdr "11b. audit-volume sampling timer"
  "$ENC/audit-volume.sh" install
  mark_step auditvolume
}

# runbook 6.0 step 12d (10.1): the DISA V1R6 fixes usg fix does not make, then a reboot.
step_v1r6() {
  done_step v1r6 && return 0
  hdr "10. DISA V1R6 mechanical fixes"
  "$ENC/stig-tailor.sh" v1r6 --apply
  mark_step v1r6
  need_reboot "V1R6 changed the kernel command line (audit=1) and auditd is immutable.
       Both need a boot - a reload will not do it."
}

# After the last reboot: the --verify halves of steps 12 and 12d, the GRUB state, and no
# failed units.
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

# runbook 6.0 step 13: the AFTER number, audited against the tailoring file.
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

# runbook 6.0 steps 13a-13b (10.1): Evaluate-STIG, the second scanner, against DISA V1R6.
step_evalstig() {
  done_step evalstig && return 0
  hdr "13. Evaluate-STIG - the second scanner, DISA V1R6 content"
  # Installed at step 1 now; kept here as a belt-and-braces for a machine hardened before
  # that change, and it is a no-op when they are present.
  apt-get install -y lshw dmidecode bc >/dev/null 2>&1 || warn "could not install lshw/dmidecode/bc"
  "$ENC/stig-tools.sh" fetch || die "stig-tools fetch failed"

  # The Answer File is pushed FROM stage-01 and cannot be fetched from here. Without it the
  # scan reports every documented deviation as Open/NR and the whole thing has to be re-run.
  # CHECK THE EXACT FILE, NOT A GLOB IN A DIRECTORY WE DO NOT OWN.
  #
  # The first version globbed /srv/stig-tools/Evaluate-STIG/AnswerFiles/*.xml and reported
  # "Answer File present" on host-2 while stig-tools.sh said "NO ANSWER FILE" on the very
  # next line - because the Evaluate-STIG tarball SHIPS ITS OWN AnswerFiles/ directory full
  # of vendor samples. The glob matched those. A 15-minute scan then ran without our answers,
  # which re-opens every documented deviation as a finding, and had to be killed and redone.
  #
  # Ours is one named file, put there by `stig-tools.sh answers <host>`, and that script is
  # the authority on the path - so derive it the same way rather than writing it twice.
  ANSWERS="/srv/stig-tools/Ubuntu24_AnswerFile.xml"
  if [ ! -f "$ANSWERS" ]; then
    hdr "ANSWER FILE NEEDED - from stage-01, WITHOUT sudo"
    say "  cd ~/canonical-k8s && ./scripts/enclave/stig-tools.sh answers $(hostname -s)"
    say ""
    say "  Without it the scan marks every documented deviation Open or Not Reviewed and you"
    say "  will triage 17 entries by hand and then scan again. Do it first."
    say ""
    say "  Then:  sudo $0 run"
    if [ "$ROLE" = guest ] && [ ! -t 0 ]; then
      touch "$HALTED"; systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
      progress evalstig "WAITING - push the answer file, then run 05 by hand"
    fi
    exit 0
  fi
  ok "Answer File present: $ANSWERS ($(grep -c '<Vuln ' "$ANSWERS" 2>/dev/null || echo '?') entries)"
  say "scanning - 7 to 15 minutes, and it prints progress"
  "$ENC/stig-tools.sh" scan || warn "scan returned non-zero - read the output"
  mark_step evalstig
}

step_done() {
  hdr "sequence complete on $(hostname -s)"
  if [ "$ROLE" = guest ]; then
    touch "$COMPLETE"; systemctl disable "$RESUME_UNIT" >/dev/null 2>&1 || true
    progress DONE "$(grep -o 'final pass=[0-9]* fail=[0-9]*' "$LOG" 2>/dev/null | tail -1 | sed 's/final //')"
  fi
  say "$(cat "$LOG" 2>/dev/null | tail -20)"
  say ""
  say "  STILL OWED, and neither is part of §6.0:"
  say "    - stig-tools.sh collect      (step 14 - gather evidence to the repo)"
  say "    - EVERY FUTURE PATCH CYCLE re-applies three things. Patching happened at step 3b,"
  say "      BEFORE hardening, so this build is consistent - but a patch from now on reverts"
  say "      hardened controls and three packages are known to do it (runbook 10d):"
  say "        grub-common     drops --unrestricted   -> grubpw prep"
  say "        libpam-modules  restores nullok (HIGH) -> v1r6 --apply"
  say "        systemd         journalctl + journal %m dir -> fixups --apply"
  say "      So the day-2 sequence is: patch, grubpw status BEFORE the reboot, fixups --apply,"
  say "      v1r6 --apply, reboot, then verify. Not patch-and-verify - verify only tells you"
  say "      it already broke."
  say ""
  say "  AND CONFIRM THIS MACHINE STILL DOES ITS JOB. §6.0 step 15. On a hypervisor that"
  say "  means starting and stopping a guest - not reading unit states. FIPS silently broke"
  say "  MAAS for seven days while systemctl said everything was active."
}

# =========================================================================================
# THE STEP LIST, ONCE. `status` and `run` each carried their own copy until 2026-09-25, and the
# copies drifted: step_radio sat on the status board as "[ ] radio" and was never dispatched
# (host-3 rebuild, 2026-09-21). One list means a step is either shown AND run, or neither.
# Order matters: accounts before v1r6 (its reboot loads the emergency audit rule).
STEPS=(preflight hostprep pro fips patch usg baseline prechecks usgfix tailor radio grub
       accounts v1r6 verify auditvolume final_audit evalstig)

cmd_status() {
  assert_enclave_host
  printf '\n  hardening state on %s (%s, %s)\n\n' "$(hostname -s)" "$ROLE" "$ME_KEY"
  local s
  for s in "${STEPS[@]}"; do
    printf '  %s %s\n' "$(done_step "$s" && echo '[x]' || echo '[ ]')" "$s"
  done
  printf '\n  state file: %s\n' "$STATE"
  [ -r "$LOG" ] && { printf '  log:\n'; sed 's/^/    /' "$LOG"; }
  printf '\n'
}

cmd_run() {
  need_root; assert_enclave_host
  install -d -m 0755 "$STATE_DIR"; touch "$STATE" "$LOG"
  # A HUMAN starting it (a terminal) is the retry D7 asks for: clear the halt and go on.
  if [ -t 0 ]; then rm -f "$HALTED"; elif [ -e "$HALTED" ]; then exit 0; fi
  trap 'harden_exit $?' EXIT
  local s
  # step_radio WAS MISSING FROM THIS LIST while appearing in `status` as a step - so it read
  # "[ ] radio" forever and never ran. Found 2026-09-21 on the host-3 rebuild: the machine came
  # up with its RTL8821CE driver loaded, bluetooth loaded, wlp2s0 present and no blacklist, and
  # V-270755 landed Not Reviewed with "a wireless interface is configured". host-1/2/4 have no
  # radio only because someone disabled theirs BY HAND on 2026-09-17. A step that is displayed
  # but never dispatched is worse than a missing step: the status board says it is accounted for.
  for s in "${STEPS[@]}"; do
    CURRENT_STEP="$s"
    done_step "$s" || progress "$s" START
    "step_$s"
  done
  CURRENT_STEP=""
  step_done
}

case "${1:-status}" in
  status) cmd_status ;;
  run)    cmd_run ;;
  resume) # A HALTED GUEST HANDED BACK TO THE UNATTENDED RUN (B-06 slice 2). Clears the halt,
          # refreshes the root-owned copy from THIS repo - so a pushed fix reaches the unit - and
          # starts the unit without waiting. Progress is on the host's console log, not here.
          need_root; assert_enclave_host
          [ "$ROLE" = guest ] || die "resume is for guests - a host is always run by hand: $0 run"
          [ ! -e "$COMPLETE" ] || die "$COMPLETE exists - this guest already finished"
          rm -f "$HALTED"; install_resume_unit
          systemctl start --no-block "$RESUME_UNIT"
          ok "handed to $RESUME_UNIT - watch the host's console log, lines start ENCLAVE-HARDEN" ;;
  reset)  need_root; assert_enclave_host
          rm -f "$STATE"; ok "state cleared - this does NOT undo anything already applied" ;;
  *) printf 'usage: %s {status|run|resume|reset}\n' "$(basename "$0")" >&2; exit 2 ;;
esac
