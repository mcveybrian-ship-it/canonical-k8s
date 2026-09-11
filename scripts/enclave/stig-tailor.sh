#!/usr/bin/env bash
# =========================================================================================
# stig-tailor.sh - generate the enclave's STIG tailoring file, with justifications.
#
#     MACHINE: any enclave machine being hardened. Needs `usg` installed and Pro attached.
#
#     sudo ./stig-tailor.sh generate          # the tailoring file
#     sudo ./stig-tailor.sh audit
#     ./stig-tailor.sh show
#     ./stig-tailor.sh fixups                 # what usg fix leaves behind - PLAN ONLY
#     sudo ./stig-tailor.sh fixups --apply    # ... and apply it
#     ./stig-tailor.sh aide status            # what AIDE would hash here - RUN BEFORE usg fix
#     sudo ./stig-tailor.sh aide exclude --apply
#
# TWO JOBS, DELIBERATELY IN ONE PLACE:
#
#   generate/audit - DEVIATIONS. Rules that cannot pass here, answered by tailoring.
#   fixups         - REMEDIATION. Rules that CAN pass but that `usg fix` does not fix.
#
#   They are the same domain - this enclave's STIG posture - and splitting them across two
#   scripts means two places to look and two things to keep in step. `fixups` shows its plan
#   and changes nothing without --apply.
#
# WHY A GENERATOR AND NOT A CHECKED-IN XML:
#
#   `usg generate-tailoring` emits ~1500 lines that are a FUNCTION OF THE INSTALLED
#   BENCHMARK. Checking that in freezes it against one usg version and guarantees it goes
#   stale silently the first time Canonical ships ubuntu2404_STIG_2. What is worth
#   versioning is the DEVIATIONS - what we changed and why - which is what this file holds.
#
#   Regenerating is therefore always safe: the deviations re-apply on top of whatever
#   benchmark is installed today, and a deviation whose rule no longer exists is REPORTED
#   rather than silently dropped.
#
# WHAT A DEVIATION IS:
#
#   Two shapes, and the difference matters to an assessor:
#
#   set-value  - the rule still runs, still has to pass, but is measured against a value
#                appropriate to this system. NOT an exception. Prefer this always.
#   deselect   - the rule is not evaluated. This IS an exception and needs a risk
#                acceptance signed by someone who can sign one.
#
#   Every entry below carries a WHY. The XML gets it as a comment, so the justification
#   travels with the artefact instead of living in a separate spreadsheet nobody opens.
# =========================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
[ -f "$HERE/enclave-addresses.env" ] && . "$HERE/enclave-addresses.env"

PROFILE="${STIG_PROFILE:-stig-v1r1}"
OUT="${STIG_TAILORING:-/etc/usg/enclave-tailoring.xml}"
TIME_MASTER="${TIME_MASTER:-10.2.20.158}"
TIME_MASTER_NAME="${TIME_MASTER_NAME:-host-4}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

tmp=""
trap 'rm -rf "${tmp:-}"' EXIT

# ---------------------------------------------------------------------------- deviations
#
# Fields, tab-separated:  machine | kind | xccdf id (without content_) | value | why
#
# USE `-` FOR AN EMPTY VALUE, NEVER AN EMPTY FIELD. Tab is IFS whitespace, so bash collapses
# consecutive tabs into one delimiter - an empty value column silently shifts `why` into
# `value` and the justification never reaches the XML comment. Found 2026-09-10 when the
# deselect row printed its reasoning as its value.
#
# THE MACHINE COLUMN IS NOT DECORATION. `*` means every machine; a hostname means only that
# one. It was added 2026-09-10 after svc-mgmt-01's post-fix audit produced a deviation that
# must NOT apply anywhere else: sudo_require_authentication fails there because MAAS holds
# per-command NOPASSWD grants, and it PASSES cleanly on svc-harbor-01. A global deviation
# would have silently switched off a control on a machine that satisfies it - which is how a
# tailoring file quietly becomes a blanket exemption.
#
# ACTIVE. These are decided.
#
deviations() {
cat <<'EOF'
*	set-value	value_var_multiple_time_servers	__TIME_MASTER__	__STIG_ID__ / chronyd_specify_remote_server. The DISA profile pins the approved time source to 0.us.pool.ntp.mil, which is unreachable from inside the boundary BY DESIGN - reaching it would be the finding. The enclave's authoritative source is __TIME_MASTER_NAME__ (__TIME_MASTER__), a physical machine serving the enclave subnet only. The rule's INTENT - synchronise only to an organisation-approved source - is met in full; only the list of approved sources differs. This is a retarget, not an exception.
svc-mgmt-01	deselect	rule_sudo_require_authentication	-	__STIG_ID__ / sudo_require_authentication. MAAS ships four sudoers files granting its own service account PER-COMMAND NOPASSWD - start/stop maas-dhcpd, lshw and blockdev for commissioning, reload of maas-agent/http/proxy/syslog, chrony and bind9. The maas user is non-interactive (/usr/sbin/nologin) with no password, so requiring authentication means those commands can never run: no DHCP, no hardware inventory, no PXE - and PXE is how host-1..3 are built. NOTE WHAT IS NOT BEING EXCEPTED: usg fix commented out the BLANKET `encadmin ALL=(ALL) NOPASSWD:ALL` grant and that stays removed - the human administrator authenticates. The residual grants are per-command, not ALL, for an account that cannot log in. This deviation is scoped to svc-mgmt-01 ONLY; the rule passes unmodified on every other machine in the enclave.
EOF
}
#
# NOT YET DECIDED - do not uncomment without an answer. Each needs a decision recorded in
# README section 0 first, because each is a posture choice rather than a technical one:
#
#   check_ufw_active / ufw_rate_limit  - enable ufw with rules for the enclave services, or
#     accept. NOT a paper decision: enabling it on svc-repo-01 with a wrong rule set stops
#     every machine in the enclave installing anything.
#   grub2_uefi_password - a physical-access control on a VM whose console is already reachable
#     only from the hypervisor. Cheap to set. Decide once, apply everywhere.
#   service_sssd_enabled / sssd_enable_user_cert - CAC/PIV authentication. Ties to the
#     YubiKey work. A real control we are deferring, not one that does not apply.
#   encrypt_partitions - COMPENSATING CONTROL, not a deviation: the host-4 NVMe underneath
#     the guest is LUKS. Write it up as such; do not deselect the rule.
#   auditd_offload_logs - no log destination exists inside the boundary yet. Accept with a
#     revisit date, do not deselect permanently.

# ---------------------------------------------------------------------------- generate
cmd_generate() {
  need_root
  command -v usg >/dev/null 2>&1 || die "usg is not installed - 'sudo pro enable usg' first"
  install -d -m 0755 "$(dirname "$OUT")"

  # NOT `local`. The EXIT trap fires after this function has returned, so a local is already
  # out of scope by then and `set -u` aborts the script on the way out - which looks like a
  # failure of whatever ran last rather than of the cleanup.
  tmp="$(mktemp -d)"
  say "generating from profile $PROFILE"
  ( cd "$tmp" && usg generate-tailoring "$PROFILE" base.xml >/dev/null ) \
    || die "usg generate-tailoring failed - is '$PROFILE' the right name? check 'usg list'"

  grep -q '</Profile>' "$tmp/base.xml" || die "generated file has no </Profile> - unexpected format"

  # REPLACE IN PLACE, DO NOT APPEND. usg's generated file ALREADY carries a <set-value> for
  # every value the profile refines - var_multiple_time_servers is pinned to
  # 0.us.pool.ntp.mil, var_network_filtering_service to ufw, and so on. XCCDF 1.2 declares a
  # uniqueness constraint on set-value/@idref, so a second element for the same idref is not
  # "the last one wins" - it makes the whole file INVALID and oscap refuses to run at all.
  #
  # So: rewrite the element that is already there, and only append when there is none.
  local dev="$tmp/dev.tsv" status="$tmp/status.tsv" n=0 missing=0
  : > "$dev"
  local me_gen; me_gen="$(hostname -s)"
  while IFS=$'\t' read -r scope kind id value why; do
    [ -n "${kind:-}" ] || continue
    # Machine scoping: `*` is everywhere, anything else must match this host exactly.
    case "$scope" in
      '*') : ;;
      "$me_gen") : ;;
      *) say "  skipped (scoped to $scope): $id"; continue ;;
    esac
    [ "$value" != "-" ] || value=""     # `-` is the explicit empty-value placeholder
    value="${value//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER_NAME__/$TIME_MASTER_NAME}"

    # A deviation naming a rule or value the benchmark no longer has is a SILENT no-op
    # otherwise - exactly the way a tailoring file rots. Say so loudly and keep going.
    if ! grep -q "content_${id}" "$tmp/base.xml"; then
      warn "NOT IN THIS BENCHMARK: $id - deviation skipped, review it"
      missing=$((missing + 1))
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$kind" "$id" "$value" "$why" >> "$dev"
    n=$((n + 1))
  done < <(deviations)

  awk -v devfile="$dev" -v statusfile="$status" '
    BEGIN {
      while ((getline line < devfile) > 0) {
        split(line, f, "\t")
        id = f[2]
        kind[id] = f[1]; val[id] = f[3]; why[id] = f[4]
        full[id] = "xccdf_org.ssgproject.content_" id
        ids[++k] = id
      }
    }
    # THE STIG ID COMES FROM THE BENCHMARK, NOT FROM US. usg writes a comment carrying the
    # UBTU-24-xxxxx id directly above each element, so the justification can cite the id the
    # installed benchmark actually uses. Typing it by hand is how a document ends up quoting
    # an id that moved - and citing the wrong control to an assessor is worse than citing none.
    function emit(id, sid,   ind, w) {
      ind = "    "
      w = why[id]
      gsub(/__STIG_ID__/, (sid != "" ? sid : "not stated in this benchmark"), w)
      print ind "<!-- DEVIATION: " w " -->"
      if (kind[id] == "set-value")
        print ind "<set-value idref=\"" full[id] "\">" val[id] "</set-value>"
      else
        print ind "<select idref=\"" full[id] "\" selected=\"false\"/>"
    }
    {
      # Remember the most recent UBTU id seen. usg puts it in a comment immediately above the
      # element it belongs to, so when we match an element on the next line this still holds
      # the id for that element. (No apostrophes in here - the awk program is inside single
      # quotes, and one stray quote silently ends it and hands the rest to bash.)
      if (match($0, /UBTU-24-[0-9]+/)) lastid = substr($0, RSTART, RLENGTH)

      for (i = 1; i <= k; i++) {
        id = ids[i]
        if (done[id]) continue
        tag = (kind[id] == "set-value") ? "<set-value idref=\"" : "<select idref=\""
        if (index($0, tag full[id] "\"") > 0) {
          emit(id, lastid); done[id] = 1
          print "replaced\t" id "\t" (lastid == "" ? "-" : lastid) > statusfile
          next
        }
      }
      if ($0 ~ /<\/Profile>/) {
        # Appended elements have no neighbouring comment, so there is no id to cite.
        for (i = 1; i <= k; i++) {
          id = ids[i]
          if (done[id]) continue
          emit(id, ""); done[id] = 1
          print "appended\t" id "\t-" > statusfile
        }
      }
      print
    }
  ' "$tmp/base.xml" > "$tmp/out.xml"

  # Report which shape each deviation took. "replaced" means we overrode a value the profile
  # itself sets - the interesting case, and the one worth reading in a review.
  if [ -s "$status" ]; then
    while IFS=$'\t' read -r how id sid; do say "  $how: $id  [$sid]"; done < "$status"
  fi

  # Prove the result still parses before it replaces anything. A tailoring file that fails
  # to parse makes `usg audit` fall back or fail outright, and the failure arrives at the
  # worst moment - mid-hardening on a machine you have already half-changed.
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$tmp/out.xml" || die "generated tailoring is not well-formed XML"
    ok "XML well-formed"
  else
    warn "xmllint not installed - skipped the well-formedness check (apt install libxml2-utils)"
  fi

  install -m 0644 "$tmp/out.xml" "$OUT"
  ok "wrote $OUT - $n deviation(s) applied"
  [ "$missing" -eq 0 ] || warn "$missing deviation(s) did NOT match this benchmark - see above"
  say ""
  say "audit against it with:  sudo $0 audit"
}

# ---------------------------------------------------------------------------- audit
cmd_audit() {
  need_root
  [ -f "$OUT" ] || die "$OUT does not exist - run '$0 generate' first"
  # PASS THE FILE, NOT A PROFILE. usg rejects both together - "You cannot provide both a
  # tailoring file and a profile!" - because the tailoring file already names the customised
  # profile it defines. Reported here anyway, so the audit output says what it evaluated.
  local cprof; cprof="$(grep -oE 'Profile id="[^"]+_customized"' "$OUT" | head -1 | sed 's/.*id="//; s/"//')"
  [ -n "$cprof" ] || die "cannot find the customised profile id in $OUT"
  say "profile in the tailoring file: $cprof"
  # Print the command. If usg's arguments change on a future release, the failure is then
  # obvious rather than looking like a problem with the tailoring file itself.
  say "running: usg audit --tailoring-file $OUT"
  usg audit --tailoring-file "$OUT"
}

# ---------------------------------------------------------------------------- show
cmd_show() {
  printf '\n  Enclave STIG deviations - profile %s\n\n' "$PROFILE"
  local me_show; me_show="$(hostname -s)"
  while IFS=$'\t' read -r scope kind id value why; do
    [ -n "${kind:-}" ] || continue
    [ "$value" != "-" ] || value=""
    value="${value//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER_NAME__/$TIME_MASTER_NAME}"
    case "$scope" in
      '*')        printf '  %-12s %s\n' "[all]" "$kind" ;;
      "$me_show") printf '  %-12s %s\n' "[THIS BOX]" "$kind" ;;
      *)          printf '  %-12s %s\n' "[$scope]" "$kind" ;;
    esac
    printf '    %s = %s\n    %s\n\n' "$id" "${value:-(deselected)}" "$why"
  done < <(deviations)
}

# ---------------------------------------------------------------------------- fixups
#
# WHAT THIS IS FOR. `usg fix` leaves rules failing that are perfectly fixable - it simply has
# no automated remediation for them. Left alone they become permanent findings that look like
# accepted risk when they are really just unfinished work.
#
# WHY NOT A chmod AT A PROMPT. Two of these have a mechanism that reasserts the value:
#
#   wtmp/btmp/lastlog  - systemd-tmpfiles rewrites the mode from /usr/lib/tmpfiles.d/var.conf
#                        on every boot. A chmod passes the audit you run five minutes later
#                        and is GONE after the next reboot. That is the worst kind of fix:
#                        it produces evidence of compliance and no compliance.
#   apt history.log    - apt creates it 0644 when it does not exist, and the logrotate stanza
#                        carries no `create` line, so the mode comes back on rotation.
#
# So each fix goes in at the layer that owns the value, not on the file.

VARCONF_SRC=/usr/lib/tmpfiles.d/var.conf
VARCONF_DST=/etc/tmpfiles.d/var.conf
APT_LOGROTATE=/etc/logrotate.d/apt
APT_HOOK=/etc/apt/apt.conf.d/99-stig-log-perms
RSYSLOG_LOGROTATE=/etc/logrotate.d/rsyslog
RSYSLOG_STIG=/etc/rsyslog.d/60-stig.conf
DAEMON_LOG=/var/log/daemon.log
LOGMODE="${STIG_LOG_MODE:-0640}"

# The three regexes rsyslog_remote_access_monitoring tests for, verbatim from
# ssg-ubuntu2404-oval.xml (obj_remote_method_monitoring_{auth,authpriv,daemon}). They are
# EXISTENCE checks against /etc/rsyslog.conf and /etc/rsyslog.d/*.conf with no state, so the
# destination path is irrelevant - only the selector has to appear.
RE_AUTH='^[^#\n]*auth(,\w+)*\.\*[^\n]*$'
RE_AUTHPRIV='^[^#\n]*authpriv(,\w+)*\.\*[^\n]*$'
RE_DAEMON='^[^#\n]*daemon(,\w+)*\.\*[^\n]*$'

rsyslog_selector_present() {
  grep -qhP "$1" /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null
}

# VALIDATE THROUGH THE ENTRY POINT THAT ACTUALLY RUNS. logrotate.timer runs
# `logrotate /etc/logrotate.conf`, and that file carries a GLOBAL `su root adm` plus
# `include /etc/logrotate.d`. Running `logrotate -d` on a fragment on its own reads neither -
# so /var/log being group-writable by syslog (which is STOCK Ubuntu: rsyslog's postinst runs
# `chgrp syslog /var/log; chmod g+w /var/log`) produces
#
#   error: skipping "/var/log/syslog" because parent directory has insecure permissions
#
# for every file, and the edit gets reverted for a problem that does not exist in production.
#
# WORSE, THE FALSE PASS: the same fragment-only command SUCCEEDS when run unprivileged,
# because the parent-directory security check does not fire the same way for a non-root
# caller. It was tested as a user, passed, and then failed under sudo on the real machine.
# A check whose result depends on the caller being unprivileged is not a check - the same
# lesson as the clean-step guard in build-transfer-bundle.sh.
LOGROTATE_MAIN=/etc/logrotate.conf
LOGROTATE_OUT=""
STIG_BACKUP_DIR="${STIG_BACKUP_DIR:-/var/backups/stig-tailor}"
LAST_BACKUP=""

# NEVER LEAVE A BACKUP INSIDE A conf.d DIRECTORY.
#
# /etc/logrotate.d is read WHOLE - every file in it, whatever the extension. An earlier
# version of this script wrote its backups as /etc/logrotate.d/apt.pre-stig, which logrotate
# then parsed as live configuration:
#
#   error: apt.pre-stig:1 duplicate log entry for /var/log/apt/term.log
#   error: found error in file apt.pre-stig, skipping
#
# Rotation kept working - logrotate skips the file it faulted on - but the configuration was
# permanently dirty and every validation from then on failed. The same is true of
# /etc/cron.d, /etc/sudoers.d and /etc/rsyslog.d: a "harmless" copy left next to the original
# is not inert, it is a second directive.
backup_file() {
  install -d -m 0700 "$STIG_BACKUP_DIR"
  LAST_BACKUP="$STIG_BACKUP_DIR/$(basename "$1").$(date +%Y%m%dT%H%M%S)"
  cp -a "$1" "$LAST_BACKUP"
}

# ONLY MEANINGFUL AS ROOT, IN BOTH DIRECTIONS.
#
#   as root, on a fragment   -> false FAILURE ("insecure permissions" - no global su in scope)
#   as a user, on the whole  -> false FAILURE ("error switching euid ... not permitted")
#   as a user, on a fragment -> false PASS (the parent-directory check does not fire at all)
#
# Only "as root, through /etc/logrotate.conf" reproduces what logrotate.timer actually does.
# Every other combination answers a different question, so this returns 2 - UNKNOWN - rather
# than inventing a verdict it cannot support.
logrotate_config_ok() {
  [ "$(id -u)" -eq 0 ] || { LOGROTATE_OUT="not root"; return 2; }
  local st out rc=0
  st="$(mktemp)"
  out="$(logrotate -d -s "$st" "$LOGROTATE_MAIN" 2>&1)" || rc=$?
  rm -f "$st"
  LOGROTATE_OUT="$out"
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | grep -q 'error:' && return 1
  printf '%s' "$out" | grep -qE 'Handling [0-9]+ logs' || return 1
  return 0
}

# POSTFIX ARRIVES WITH `usg fix` AND LISTENS ON EVERY INTERFACE.
#
# The STIG wants `space_left_action = email`, so usg installs an MTA to deliver it. Nobody
# reviews the MTA. On svc-harbor-01 and again on svc-repo-01 it came up on 0.0.0.0:25 - an
# unreviewed externally bound listener on a machine that has no business receiving mail from
# anywhere, inside an enclave with no mail infrastructure at all.
#
# loopback-only keeps the audit warning working - that mail is local, from root to root - and
# removes the surface. Doing it HERE rather than at a prompt means host-4 gets it too, and a
# rebuilt machine gets it without anyone remembering.
#
# This is NOT a ufw rule. Filtering a listener that should not be listening is the wrong layer:
# ufw would still leave postfix bound to the interface, and the finding "unreviewed listener"
# would still be true.
postfix_external() {
  command -v postconf >/dev/null 2>&1 || return 1
  ss -tulnH 2>/dev/null | awk '{print $5}' \
    | grep -vE '^(127\.|\[::1\])' | grep -v '%lo:' | grep -qE '[:.]25$'
}

fixups_plan() {
  printf '\n  STIG fixups - what `usg fix` does not fix\n'
  local stray_list
  stray_list="$(find /etc/logrotate.d -maxdepth 1 -type f \
                  \( -name '*.pre-stig' -o -name '*.bak' -o -name '*.orig' -o -name '*.dpkg-*' \
                     -o -name '*.ucf-*' -o -name '*~' \) 2>/dev/null)"
  if [ -n "$stray_list" ]; then
    printf '\n  0. STRAY FILES IN /etc/logrotate.d - being parsed as configuration\n'
    printf '%s\n' "$stray_list" | sed 's/^/     /'
    say "   logrotate reads that directory WHOLE, whatever the extension. A backup left there"
    say "   is a second set of directives, not an inert copy."
    say "   fix: move them to $STIG_BACKUP_DIR"
  fi

  printf '\n  1. file_permissions_var_log_stig - wtmp, btmp, lastlog\n'
  say "   owner of the value: systemd-tmpfiles, via $VARCONF_SRC"
  say "   fix: $VARCONF_DST - a FULL COPY with the three modes set to $LOGMODE"
  say "   note: a same-named file in /etc MASKS the whole /usr/lib file, so it must be a copy"
  say "         and not just the three lines - otherwise every other var.conf entry stops"
  say "         being applied. 'fixups --verify' reports drift if the package changes it."
  if [ -f "$VARCONF_DST" ]; then say "   state: $VARCONF_DST EXISTS"; else say "   state: not present"; fi

  printf '\n  2. file_permissions_var_log_stig - apt history.log and term.log\n'
  say "   owner of the value: apt creates them 0644; the logrotate stanza has no 'create'"
  say "   fix: add 'create $LOGMODE root adm' to each stanza in $APT_LOGROTATE, then chmod"
  say "        the existing files once"
  if grep -q '^\s*create ' "$APT_LOGROTATE" 2>/dev/null; then
    say "   state: a 'create' line is already present"
  else
    say "   state: no 'create' line"
  fi

  printf '\n  3. file_groupowner_var_log - /var/log must be group-owned by syslog\n'
  if getent group syslog >/dev/null 2>&1; then
    say "   state: syslog group EXISTS - fix is 'chgrp syslog /var/log'"
  else
    say "   state: NO syslog group. It comes with rsyslog, which is not installed."
    say "   DECISION REQUIRED - this one is not ours to make silently:"
    say "     install rsyslog  - the group is real, the rule passes legitimately, and you get"
    say "                        a syslog path you will need for log offload anyway"
    say "     groupadd syslog  - passes the check with no syslog daemon behind it. Hollow, and"
    say "                        visible to anyone who looks. NOT done by this script."
    say "   pass --with-rsyslog to install it (from the enclave mirror) and set the group."
  fi
  printf '\n  4. rsyslog_remote_access_monitoring - selectors auth.*, authpriv.*, daemon.*\n'
  say "   NOTE: this rule only came into scope BECAUSE rsyslog was installed. It was"
  say "         notapplicable while no syslog daemon existed."
  if rsyslog_selector_present "$RE_AUTH"; then say "   auth.*     present"; else say "   auth.*     MISSING"; fi
  if rsyslog_selector_present "$RE_AUTHPRIV"; then say "   authpriv.* present"; else say "   authpriv.* MISSING"; fi
  if rsyslog_selector_present "$RE_DAEMON"; then say "   daemon.*   present"; else say "   daemon.*   MISSING"; fi
  say "   Ubuntu's 'auth,authpriv.*  /var/log/auth.log' satisfies the first two - the OVAL"
  say "   pattern allows a comma list and any non-# prefix. Usually only daemon.* is missing."
  say "   fix: $RSYSLOG_STIG with 'daemon.*  -$DAEMON_LOG'"
  say "   NOT /var/log/syslog: '*.*' already sends daemon there, so that would write every"
  say "        daemon message TWICE into the same file."
  say "   and: add $DAEMON_LOG to $RSYSLOG_LOGROTATE - Ubuntu's stanza does not list it, so"
  say "        a new log file would otherwise grow forever on a service VM."

  printf '\n  5. postfix bound to all interfaces - installed by `usg fix`, never reviewed\n'
  if ! command -v postconf >/dev/null 2>&1; then
    say "   postfix is not installed here - nothing to do"
  elif postfix_external; then
    say "   state: LISTENING EXTERNALLY on :25 - $(postconf -h inet_interfaces 2>/dev/null)"
    say "   fix: postconf -e 'inet_interfaces = loopback-only' + restart"
    say "        local mail still works, which is all space_left_action = email needs."
    say "   NOT a ufw rule - that would leave it bound and the finding still true."
  else
    say "   state: already loopback-only ($(postconf -h inet_interfaces 2>/dev/null))"
  fi

  printf '\n  nothing above has been changed. re-run with --apply\n\n'
}

cmd_fixups() {
  local apply=0 with_rsyslog=0 verify=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      --with-rsyslog) with_rsyslog=1; shift ;;
      --verify) verify=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  if [ "$verify" -eq 1 ]; then fixups_verify; return; fi
  if [ "$apply" -eq 0 ]; then fixups_plan; return; fi

  need_root
  # THE THREE FIXES ARE INDEPENDENT AND EACH REPORTS FOR ITSELF.
  #
  # An earlier version used `die` on a failure in fix 2, which skipped fix 3 entirely - so a
  # logrotate problem silently prevented the rsyslog install, and the operator was left with a
  # half-applied machine and no statement of which half. A fixup that fails must not take the
  # unrelated ones down with it.
  local failed=0

  # ---- 0. evict anything in /etc/logrotate.d that is not configuration ----------------
  # Runs FIRST, because every later validation reads the whole directory and will fail on a
  # stray file regardless of what we just edited.
  local stray n_stray=0
  while IFS= read -r stray; do
    [ -n "$stray" ] || continue
    install -d -m 0700 "$STIG_BACKUP_DIR"
    mv "$stray" "$STIG_BACKUP_DIR/$(basename "$stray").evicted.$(date +%Y%m%dT%H%M%S)"
    warn "0. moved $stray out of /etc/logrotate.d - it was being PARSED AS CONFIG"
    n_stray=$((n_stray + 1))
  done < <(find /etc/logrotate.d -maxdepth 1 -type f \
             \( -name '*.pre-stig' -o -name '*.bak' -o -name '*.orig' -o -name '*.dpkg-*' \
                -o -name '*.ucf-*' -o -name '*~' \) 2>/dev/null)
  [ "$n_stray" -eq 0 ] || say "   -> $STIG_BACKUP_DIR"

  # ---- 1. tmpfiles: wtmp, btmp, lastlog -------------------------------------------------
  if [ ! -f "$VARCONF_SRC" ]; then
    warn "1. $VARCONF_SRC does not exist - has the layout changed? SKIPPED"
    failed=1
  elif [ -f "$VARCONF_DST" ]; then
    say "1. $VARCONF_DST exists - leaving it alone. Edit it by hand or remove it first."
  else
    install -d -m 0755 /etc/tmpfiles.d
    sed -E 's#^(f /var/log/(wtmp|btmp|lastlog)[[:space:]]+)[0-7]{4}#\1'"$LOGMODE"'#' \
      "$VARCONF_SRC" > "$VARCONF_DST"
    chmod 0644 "$VARCONF_DST"
    # Prove the substitution actually hit all three before trusting it.
    local hits; hits=$(grep -cE "^f /var/log/(wtmp|btmp|lastlog)[[:space:]]+$LOGMODE" "$VARCONF_DST" || true)
    if [ "$hits" -eq 3 ]; then
      ok "1. wrote $VARCONF_DST (full copy, wtmp/btmp/lastlog at $LOGMODE)"
    else
      rm -f "$VARCONF_DST"
      warn "1. expected 3 tightened lines, found $hits - removed the file rather than leaving"
      warn "   a PARTIAL override in place, which would mask the vendor file with the wrong"
      warn "   contents. Inspect $VARCONF_SRC by hand."
      failed=1
    fi
    systemd-tmpfiles --create 2>/dev/null || warn "   systemd-tmpfiles --create reported an issue"
  fi

  # ---- 2. logrotate for apt, then the existing files ------------------------------------
  if grep -q '^[[:space:]]*create ' "$APT_LOGROTATE" 2>/dev/null && [ -f "$APT_HOOK" ]; then
    say "2. $APT_LOGROTATE has a 'create' line and $APT_HOOK exists - nothing to do"
  elif grep -q '^[[:space:]]*create ' "$APT_LOGROTATE" 2>/dev/null; then
    say "2. $APT_LOGROTATE already has a 'create' line - adding the missing apt hook below"
  elif [ -f "$APT_LOGROTATE" ]; then
    backup_file "$APT_LOGROTATE"; local aptbak="$LAST_BACKUP"
    sed -i -E "s/^([[:space:]]*)rotate 12$/\1rotate 12\n\1create $LOGMODE root adm/" "$APT_LOGROTATE"
    # Validated through $LOGROTATE_MAIN - see logrotate_config_ok() for why testing a
    # fragment on its own is the wrong thing to test.
    if ! logrotate_config_ok; then
      cp -a "$aptbak" "$APT_LOGROTATE"
      warn "2. logrotate rejected the edit - REVERTED. Its output:"
      printf '%s\n' "$LOGROTATE_OUT" | sed 's/^/       /'
      failed=1
    else
      ok "2. added 'create $LOGMODE root adm' to $APT_LOGROTATE (backup: $aptbak)"
    fi
  else
    warn "2. $APT_LOGROTATE not present - skipped"
  fi
  # APT RESETS THE MODE ON EVERY RUN. This is the third layer of the same fix and the one
  # that actually holds.
  #
  #   logrotate `create 0640`  - governs files created by ROTATION
  #   a one-time chmod         - governs the file as it is RIGHT NOW
  #   this hook                - governs what apt does NEXT TIME
  #
  # Proof it matters: on svc-harbor-01 the order was `apt install`, then chmod, and
  # file_permissions_var_log_stig PASSED. On svc-mgmt-01 the order was chmod, then
  # `apt install libxml2-utils` two minutes later - and history.log was 0644 again, so the
  # rule FAILED. Same fix, same script, opposite result, purely from sequence. A chmod cannot
  # hold a value that another program sets.
  if [ -d /etc/apt/apt.conf.d ]; then
    cat > "$APT_HOOK" <<EOF
// STIG file_permissions_var_log_stig. Written by stig-tailor.sh.
// apt sets the mode of its own logs when it writes them, so a one-time chmod lasts until the
// next apt run. This re-tightens them immediately after every dpkg invocation.
DPkg::Post-Invoke { "find /var/log/apt -type f -exec chmod $LOGMODE {} + 2>/dev/null || true"; };
EOF
    chmod 0644 "$APT_HOOK"
    if apt-config dump >/dev/null 2>&1; then
      ok "   wrote $APT_HOOK - apt re-tightens its own logs after every run"
    else
      rm -f "$APT_HOOK"
      warn "   apt rejected $APT_HOOK - REMOVED. A bad apt.conf.d file breaks ALL apt use,"
      warn "   which on this enclave means nothing can be installed anywhere."
      failed=1
    fi
  fi
  if find /var/log/apt -type f -exec chmod "$LOGMODE" {} + 2>/dev/null; then
    ok "   existing /var/log/apt files set to $LOGMODE"
  fi

  # ---- 3. /var/log group ownership -------------------------------------------------------
  if getent group syslog >/dev/null 2>&1; then
    # Usually a no-op: rsyslog's postinst already runs `chgrp syslog /var/log; chmod g+w`.
    # Kept because the rule is about the END STATE - a machine can arrive here with the group
    # present and /var/log still owned by root:root.
    chgrp syslog /var/log && ok "3. /var/log group is syslog"
  elif [ "$with_rsyslog" -eq 1 ]; then
    say "3. installing rsyslog from the enclave mirror"
    if ! apt-get install -y rsyslog >/dev/null 2>&1; then
      warn "3. rsyslog install failed - is apt working? file_groupowner_var_log STILL FAILS"
      failed=1
    elif ! getent group syslog >/dev/null 2>&1; then
      warn "3. rsyslog installed but no syslog group appeared - inspect by hand"
      failed=1
    else
      chgrp syslog /var/log && ok "3. rsyslog installed, /var/log group set to syslog"
    fi
  else
    warn "3. no syslog group and --with-rsyslog not given - file_groupowner_var_log STILL FAILS"
    say "   this is the decision in the plan output. Nothing was faked."
    failed=1
  fi

  # ---- 4. rsyslog selectors (only relevant once rsyslog is installed) -------------------
  if ! command -v rsyslogd >/dev/null 2>&1; then
    say "4. rsyslog not installed - rule is notapplicable, nothing to do"
  elif rsyslog_selector_present "$RE_DAEMON"; then
    say "4. a daemon.* selector is already present - not touching rsyslog config"
  else
    # One selector line. Deliberately its own drop-in rather than an edit to the packaged
    # 50-default.conf, so an apt upgrade of rsyslog cannot silently drop it.
    cat > "$RSYSLOG_STIG" <<EOF
# STIG rsyslog_remote_access_monitoring. Written by stig-tailor.sh.
#
# The rule requires the selectors auth.*, authpriv.* and daemon.* to appear somewhere in
# /etc/rsyslog.conf or /etc/rsyslog.d/*.conf. It is an EXISTENCE check with no state, so the
# destination does not matter to the check - only the selector.
#
# Ubuntu's 50-default.conf already carries "auth,authpriv.*  /var/log/auth.log", which
# satisfies the first two: the OVAL pattern allows a comma-separated facility list and any
# prefix that is not a comment. Only daemon.* was missing.
#
# NOT sent to /var/log/syslog: 50-default.conf line "*.*;auth,authpriv.none -/var/log/syslog"
# already delivers daemon messages there, so pointing this at syslog would duplicate every
# daemon line in a single file.
daemon.*                        -$DAEMON_LOG
EOF
    chmod 0644 "$RSYSLOG_STIG"
    if rsyslogd -N1 >/dev/null 2>&1; then
      systemctl restart rsyslog && ok "4. wrote $RSYSLOG_STIG (daemon.* -> $DAEMON_LOG)"
    else
      local rsout; rsout="$(rsyslogd -N1 2>&1)"
      rm -f "$RSYSLOG_STIG"
      warn "4. rsyslog rejected the config - REVERTED. Its output:"
      printf '%s\n' "$rsout" | sed 's/^/       /'
      failed=1
    fi
  fi

  # A NEW LOG FILE THAT NOTHING ROTATES IS A DISK THAT FILLS. Ubuntu's rsyslog stanza names
  # its files explicitly, so daemon.log is not covered until it is added.
  if [ -f "$RSYSLOG_STIG" ] && [ -f "$RSYSLOG_LOGROTATE" ]; then
    if grep -q "^${DAEMON_LOG}\$" "$RSYSLOG_LOGROTATE"; then
      say "   $DAEMON_LOG already in $RSYSLOG_LOGROTATE"
    else
      backup_file "$RSYSLOG_LOGROTATE"; local rsbak="$LAST_BACKUP"
      sed -i "\#^/var/log/syslog\$#a $DAEMON_LOG" "$RSYSLOG_LOGROTATE"
      if ! logrotate_config_ok; then
        cp -a "$rsbak" "$RSYSLOG_LOGROTATE"
        warn "   logrotate rejected the rsyslog edit - REVERTED. Its output:"
        printf '%s\n' "$LOGROTATE_OUT" | sed 's/^/       /'
        failed=1
      else
        ok "   added $DAEMON_LOG to $RSYSLOG_LOGROTATE (backup: $rsbak)"
      fi
    fi
  fi

  # ---- 5. postfix: loopback-only -----------------------------------------------------
  if command -v postconf >/dev/null 2>&1; then
    local cur; cur="$(postconf -h inet_interfaces 2>/dev/null || echo '?')"
    if [ "$cur" = "loopback-only" ]; then
      say "5. postfix already loopback-only"
    else
      postconf -e 'inet_interfaces = loopback-only' \
        && systemctl restart postfix 2>/dev/null
      local new; new="$(postconf -h inet_interfaces 2>/dev/null || echo '?')"
      if [ "$new" = "loopback-only" ] && ! postfix_external; then
        ok "5. postfix inet_interfaces: $cur -> $new, no longer bound externally"
      else
        warn "5. postfix is STILL externally bound (inet_interfaces=$new) - check by hand:"
        warn "   sudo ss -tulnp | grep ':25'"
        failed=1
      fi
    fi
  else
    say "5. postfix not installed - nothing to do"
  fi

  say ""
  [ "$failed" -eq 0 ] || warn "one or more fixups did not complete - see above"
  say ""
  say "verify with:  sudo $0 fixups --verify   then re-audit"
}

fixups_verify() {
  local fail=0
  printf '\n  verifying\n'
  # The modes as they are NOW, and as tmpfiles would reassert them.
  local f
  for f in /var/log/wtmp /var/log/btmp /var/log/lastlog; do
    [ -e "$f" ] || continue
    say "$(stat -c '%A %U:%G %n' "$f")"
    [ "$(stat -c '%a' "$f")" = "${LOGMODE#0}" ] || { warn "$f is not $LOGMODE"; fail=1; }
  done
  # DRIFT CHECK. A same-named file in /etc masks the vendor's entirely, so a package update
  # to var.conf silently stops applying. Report it rather than discovering it in an audit.
  if [ -f "$VARCONF_DST" ]; then
    local d; d=$(diff <(sed -E 's/[[:space:]]+/ /g' "$VARCONF_SRC") \
                      <(sed -E 's/[[:space:]]+/ /g' "$VARCONF_DST") | grep -cE '^[<>]' || true)
    say "var.conf differs from the vendor copy in $d line(s) - expected 6 (3 pairs)"
    [ "$d" -le 6 ] || { warn "MORE drift than the three mode changes - the package may have"
                        warn "changed var.conf. Re-derive $VARCONF_DST from $VARCONF_SRC."; fail=1; }
  fi
  say "$(stat -c '%A %U:%G %n' /var/log)"
  getent group syslog >/dev/null 2>&1 || { warn "no syslog group - file_groupowner_var_log fails"; fail=1; }
  [ "$(stat -c '%G' /var/log)" = "syslog" ] || { warn "/var/log is not group syslog"; fail=1; }
  # SCAN ALL OF /var/log, NOT JUST THE PATHS WE FIXED.
  #
  # This checked /var/log/apt only, so on svc-mgmt-01 it reported clean while
  # file_permissions_var_log_stig was still failing - MAAS writes its own logs and nothing
  # was looking at them. A verify that only re-checks what you already fixed cannot tell you
  # the rule still fails; it can only tell you your fix applied.
  if [ -f "$APT_HOOK" ]; then
    say "apt log-permission hook present ($APT_HOOK)"
  else
    warn "$APT_HOOK MISSING - the next apt run will reset /var/log/apt modes to 0644"
    fail=1
  fi
  local offenders
  offenders="$(find /var/log -type f -perm /0137 -printf '%M %U:%G %p\n' 2>/dev/null | sort -k3)"
  if [ -n "$offenders" ]; then
    warn "files under /var/log more permissive than $LOGMODE - file_permissions_var_log_stig"
    warn "will keep failing until each is dealt with:"
    printf '%s\n' "$offenders" | sed 's/^/       /'
    say  "     Fix at the layer that OWNS each one - the package that creates it, its"
    say  "     logrotate stanza, or a tmpfiles entry. A bare chmod comes back. See 6.3c."
    fail=1
  else
    ok "no file under /var/log is more permissive than $LOGMODE"
  fi
  if command -v rsyslogd >/dev/null 2>&1; then
    for sel in AUTH AUTHPRIV DAEMON; do
      eval "re=\$RE_$sel"
      if rsyslog_selector_present "$re"; then say "rsyslog selector $sel present"
      else warn "rsyslog selector $sel MISSING - rsyslog_remote_access_monitoring fails"; fail=1; fi
    done
    [ ! -e "$DAEMON_LOG" ] || say "$(stat -c '%A %U:%G %n' "$DAEMON_LOG")"
    if [ -f "$RSYSLOG_STIG" ] && ! grep -q "^${DAEMON_LOG}\$" "$RSYSLOG_LOGROTATE" 2>/dev/null; then
      warn "$DAEMON_LOG is NOT in $RSYSLOG_LOGROTATE - it will grow forever"; fail=1
    fi
  fi
  # /var/log is group-writable by syslog on stock Ubuntu, so EVERY rotation depends on the
  # global `su` in logrotate.conf. If anything ever removes it, rotation stops silently for
  # every system log - no error until a disk fills.
  if [ "$(stat -c '%A' /var/log | cut -c6)" = "w" ]; then
    if grep -qE '^[[:space:]]*su ' "$LOGROTATE_MAIN" 2>/dev/null; then
      say "logrotate global su: $(grep -hE '^[[:space:]]*su ' "$LOGROTATE_MAIN" | tr -s ' ')"
    else
      warn "/var/log is group-writable and $LOGROTATE_MAIN has NO 'su' directive -"
      warn "  logrotate will skip EVERY system log. Add 'su root adm'."; fail=1
    fi
  fi
  local sl
  sl="$(find /etc/logrotate.d -maxdepth 1 -type f \
          \( -name '*.pre-stig' -o -name '*.bak' -o -name '*.orig' -o -name '*.dpkg-*' \
             -o -name '*.ucf-*' -o -name '*~' \) 2>/dev/null)"
  if [ -n "$sl" ]; then
    warn "stray files in /etc/logrotate.d being parsed as config:"
    printf '%s\n' "$sl" | sed 's/^/       /'
    fail=1
  fi
  if command -v logrotate >/dev/null 2>&1; then
    local lrrc=0
    logrotate_config_ok || lrrc=$?
    case "$lrrc" in
      0) say "logrotate config parses clean" ;;
      2) say "logrotate config check SKIPPED - needs root. Re-run with sudo to include it." ;;
      *) warn "logrotate config has errors:"
         printf '%s\n' "$LOGROTATE_OUT" | grep 'error:' | sed 's/^/       /'
         fail=1 ;;
    esac
  fi
  if command -v postconf >/dev/null 2>&1; then
    if postfix_external; then
      warn "postfix is EXTERNALLY BOUND on :25 (inet_interfaces=$(postconf -h inet_interfaces 2>/dev/null))"
      fail=1
    else
      say "postfix inet_interfaces: $(postconf -h inet_interfaces 2>/dev/null) - not externally bound"
    fi
  fi
  say ""
  [ "$fail" -eq 0 ] && ok "all checks passed" || warn "some checks failed - see above"
  return 0
}

# ---------------------------------------------------------------------------- usb
#
# USB STORAGE, ON THE ONE MACHINE THAT NEEDS IT.
#
# `kernel_module_usb` wants USB storage unavailable. On the seven VMs that is free - they have
# no USB and never will. On **host-4 it is not free**: host-4 is where the 318 GB transfer SSD
# plugs in, inside the gap, and there is no other route for media (docs/airgap-media.md 6.1a).
# Hardening it without a way back would mean a machine that cannot accept a transfer.
#
# A PERMANENT EXCEPTION IS THE WRONG ANSWER. A TOGGLE IS BETTER, because the deviation
# becomes a WINDOW with a start, an end, and a log - which is a far better thing to hand an
# assessor than "USB storage is enabled on the hypervisor".
#
#   disable  - the compliant state. This is where host-4 lives.
#   enable   - opens the window for a transfer. Logged, and it tells you to close it.
#   status   - which state, and how long it has been open.
#
# BOTH MODULES MATTER. A modern USB SSD enclosure usually binds `uas` (USB Attached SCSI),
# NOT `usb_storage`. Blocking only usb_storage would leave a UAS enclosure working - the
# control would look applied and not be - and enabling only usb_storage would leave the SSD
# undetected while apparently permitted. Handle both, always.
# Module names for load/unload (modprobe accepts either spelling; these are the canonical
# in-kernel names as they appear in lsmod).
USB_MODULES="usb_storage uas"
USB_BLOCK=/etc/modprobe.d/99-stig-usb-storage.conf
USB_LOG=/var/log/stig-usb-window.log

# EVERY FILE THAT BLOCKS, NOT JUST OURS.
#
# `usg fix` writes /etc/modprobe.d/usb-storage.conf itself, with the same hyphen spellings.
# An earlier version of `enable` moved only OUR file aside, so usg's file kept the block, the
# modules did not load, and the script printed "USB STORAGE IS NOW ENABLED" while it was not.
# A false success on a hypervisor you are standing in front of with a disk in your hand.
#
# So: discover the blocking files, stash ALL of them, and verify with lsmod rather than
# trusting modprobe's exit status.
USB_PATHS="/etc/modprobe.d /run/modprobe.d /usr/lib/modprobe.d"
USB_STASH="$STIG_BACKUP_DIR/usb-window"

usb_block_files() {
  grep -rlE '^[[:space:]]*(install|blacklist)[[:space:]]+(usb.?storage|uas)' $USB_PATHS 2>/dev/null | sort -u
}
usb_blocked() { [ -n "$(usb_block_files)" ]; }
usb_loaded()  { lsmod 2>/dev/null | awk '{print $1}' | grep -qxE "$(echo $USB_MODULES | tr ' ' '|')"; }

usb_log() {
  # The window IS the evidence. Append-only, and never silently fail to record.
  printf '%s  %-8s by=%s modules="%s"  %s\n' \
    "$(date -Is)" "$1" "${SUDO_USER:-$(id -un)}" "$USB_MODULES" "${2:-}" >> "$USB_LOG" 2>/dev/null \
    || warn "could not write $USB_LOG - the window is UNRECORDED, fix that before relying on this"
  chmod 0640 "$USB_LOG" 2>/dev/null || true
}

cmd_usb() {
  local action="${1:-status}" mins=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --minutes) mins="${2:?--minutes needs a number}"; shift 2 ;;
      --minutes=*) mins="${1#--minutes=}"; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  case "$action" in
    status)
      printf '\n  USB storage on %s\n\n' "$(hostname -s)"
      if usb_blocked; then
        ok "  BLOCKED by:"
        usb_block_files | sed 's/^/       /'
      else
        warn "  NOT BLOCKED - no file in $USB_PATHS blocks usb-storage or uas"
        say  "     kernel_module_usb-storage_disabled will FAIL"
      fi
      if [ -d "$USB_STASH" ] && [ -n "$(ls -A "$USB_STASH" 2>/dev/null)" ]; then
        warn "  A WINDOW IS OPEN - files stashed in $USB_STASH:"
        ls -1 "$USB_STASH" | sed 's/^/       /'
        say  "     close it with:  sudo $0 usb disable"
      fi
      if usb_loaded; then warn "  module LOADED: $(lsmod | awk '{print $1}' | grep -xE "$(echo $USB_MODULES | tr ' ' '|')" | tr '\n' ' ')"
      else ok "  no USB storage module loaded"; fi
      if [ -r "$USB_LOG" ]; then
        say ""
        say "  last 5 window events:"
        tail -5 "$USB_LOG" | sed 's/^/    /'
      else
        say "  no window log yet ($USB_LOG)"
      fi
      say ""
      ;;

    disable)
      need_root
      # Put back anything a previous `enable` stashed, so the compliant state is restored
      # exactly rather than approximated.
      if [ -d "$USB_STASH" ] && [ -n "$(ls -A "$USB_STASH" 2>/dev/null)" ]; then
        local st
        for st in "$USB_STASH"/*; do
          [ -f "$st" ] || continue
          # Stashed as <dir-with-slashes-as-%>%<name> so the original path is recoverable.
          local orig; orig="$(basename "$st" | tr '%' '/')"
          mv "$st" "$orig" && ok "restored $orig"
        done
      fi
      cat > "$USB_BLOCK" <<EOF
# STIG kernel_module_usb-storage_disabled. Managed by stig-tailor.sh - do not hand-edit.
#
# SPELLING IS LOAD-BEARING. The OVAL patterns are literal text matches:
#     ^\s*install\s+usb-storage\s+(/bin/false|/bin/true)\$
#     ^blacklist\s+usb-storage\$
# HYPHEN, not underscore. modprobe treats usb-storage and usb_storage as the same module, so
# the underscore form BLOCKS correctly and still FAILS THE CHECK. Both spellings are written:
# the hyphen form is what the benchmark reads, the underscore form is belt-and-braces.
#
# uas is here for a different reason - it is functional, not compliance. A USB SSD enclosure
# usually binds uas (USB Attached SCSI), so blocking only usb-storage leaves it working.
install usb-storage /bin/false
install usb_storage /bin/false
install uas /bin/false
blacklist usb-storage
blacklist usb_storage
blacklist uas
EOF
      chmod 0644 "$USB_BLOCK"
      local m
      for m in $USB_MODULES; do modprobe -r "$m" 2>/dev/null || true; done
      if usb_loaded; then
        warn "a module is still loaded - something is USING it. Unmount the media first:"
        say  "    lsblk -o NAME,LABEL,MOUNTPOINT | grep -i usb   # then umount, then retry"
        usb_log DISABLE "INCOMPLETE - module still loaded"
        return 1
      fi
      ok "USB storage blocked and unloaded"
      usb_log DISABLE "window closed"
      ;;

    enable)
      need_root
      # Stash EVERY blocking file, not just ours - see the note above usb_block_files().
      # Stashed outside modprobe.d, because a leftover .conf there is still live config
      # (the same lesson as /etc/logrotate.d in 6.3c).
      install -d -m 0700 "$USB_STASH"
      local bf n_stashed=0
      while IFS= read -r bf; do
        [ -n "$bf" ] || continue
        mv "$bf" "$USB_STASH/$(printf '%s' "$bf" | tr '/' '%')" && n_stashed=$((n_stashed + 1))
        say "stashed $bf"
      done < <(usb_block_files)
      [ "$n_stashed" -gt 0 ] || say "nothing was blocking - modules may already be loadable"

      local m
      for m in $USB_MODULES; do modprobe "$m" 2>/dev/null || true; done
      # VERIFY WITH lsmod, not with modprobe's exit status. `install <mod> /bin/false` makes
      # modprobe succeed while loading nothing.
      if ! usb_loaded; then
        warn "NO USB STORAGE MODULE LOADED - the window did NOT open."
        say  "   check:  dmesg | tail -20   and   modprobe -v usb_storage"
        usb_log ENABLE "FAILED - no module loaded after stashing $n_stashed file(s)"
        return 1
      fi
      ok "loaded: $(lsmod | awk '{print $1}' | grep -xE "$(echo $USB_MODULES | tr ' ' '|')" | tr '\n' ' ')"
      # WAIT FOR udev BEFORE LOOKING. The device node appears almost immediately, but LABEL
      # and FSTYPE are filled in by blkid via udev a moment later. Checking too early shows a
      # partition with no label and reads exactly like "the disk did not come back".
      udevadm settle --timeout=15 2>/dev/null || warn "udevadm settle timed out - labels may lag"
      # AND EXPECT A DIFFERENT DEVICE NAME. On host-4 the transfer SSD came back as sda after
      # having been sdb - unloading and reloading the modules re-enumerates. Anything that
      # touches this disk must use LABEL=enclave-xfer, never /dev/sdX.
      local xfer; xfer="$(lsblk -o NAME,SIZE,LABEL,FSTYPE 2>/dev/null | grep -i 'enclave-xfer' || true)"
      if [ -n "$xfer" ]; then
        ok "transfer media present: $xfer"
      else
        say "no volume labelled enclave-xfer yet - if the disk is attached, give udev a moment"
        say "   and re-check with:  lsblk -o NAME,SIZE,LABEL,FSTYPE"
      fi
      warn "USB STORAGE IS NOW ENABLED on $(hostname -s) - this is an OPEN DEVIATION WINDOW"
      say  "   close it as soon as the transfer is done:  sudo $0 usb disable"
      if [ -n "$mins" ]; then
        # Auto-close. An open window nobody remembers is how a temporary exception becomes
        # permanent - so offer to close it without depending on anyone remembering.
        if systemd-run --on-active="${mins}m" --unit="stig-usb-autoclose" \
             --description="auto-close the STIG USB window" \
             "$(readlink -f "$0")" usb disable >/dev/null 2>&1; then
          ok "auto-close scheduled in ${mins} minutes (unit: stig-usb-autoclose)"
          usb_log ENABLE "window opened, auto-close in ${mins}m"
        else
          warn "could not schedule auto-close - you MUST close it by hand"
          usb_log ENABLE "window opened, auto-close FAILED to schedule"
        fi
      else
        usb_log ENABLE "window opened, NO auto-close - manual close required"
      fi
      say ""
      lsblk -o NAME,SIZE,LABEL,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
      ;;

    *) die "usage: $0 usb {status|enable [--minutes N]|disable}" ;;
  esac
}

# ------------------------------------------------------------------------------- grubpw
#
# V-270675 / UBTU-24-102000 (HIGH) and USG's grub2_uefi_password - the GRUB password.
#
# TWO STEPS, AND THE ORDER IS THE WHOLE POINT.
#
#   prep - put `--unrestricted` in /etc/grub.d/10_linux
#   set  - set superusers and the password hash
#
# `set superusers="root"` makes GRUB require authentication to **BOOT EVERY ENTRY**, not just
# to edit one. `--unrestricted` on the menu entry class is what restores unattended boot while
# keeping the editor locked - and **DISA's FixText does not mention it at all.** Follow DISA
# verbatim on a headless machine and it does not come back from a reboot; on svc-repo-01 that
# is the box every other machine installs from, and nothing in the enclave could install the
# fix because svc-repo-01 IS the source of the fix.
#
# So `set` REFUSES until `prep` has run. That is a guard, not a note.
#
# THE PASSWORD IS NOT THIS SCRIPT'S BUSINESS.
#
#   It is one password for the whole enclave, held in the customer's controlled document, and
#   deliberately nowhere in this repository - not host-params.env, not a parameter, not a
#   comment. This script reads it from the terminal with `read -rsp`, pipes it straight into
#   grub-mkpasswd-pbkdf2, and never echoes it or the hash.
#
#   Generate the hash HERE rather than copying one from another machine: pbkdf2 salts randomly,
#   so both verify the same password, but a pasted hash travels through shell history and a
#   clipboard and a generated one does not.
#
# WHY grub-mkpasswd-pbkdf2 IS PIPED AND NOT PROMPTED:
#
#   Its prompts go to STDOUT. `grub-mkpasswd-pbkdf2 > file` therefore captures the prompt and
#   leaves the operator at a blind cursor that also swallows Ctrl-C. That happened on
#   2026-09-10. Feed it on stdin instead and the prompt never matters.

GRUB_10_LINUX=/etc/grub.d/10_linux
GRUB_CUSTOM=/etc/grub.d/40_custom

# ANCHORED TO THE CLASS LINE, not just "the word appears somewhere". 10_linux is 18 KB of
# shell; a comment mentioning --unrestricted would otherwise read as "already configured",
# and `set` would then happily lock the bootloader on a headless machine. The CLASS variable
# is what every generated menu entry's --class list comes from, so that line is the one that
# decides whether the machine boots unattended.
grubpw_unrestricted_ok() { grep -qE '^CLASS=.*--unrestricted' "$GRUB_10_LINUX" 2>/dev/null; }
# `grep -c` PRINTS 0 AND EXITS 1 WHEN NOTHING MATCHES. So `grep -c ... || echo 0` emits TWO
# lines - "0" from grep and "0" from the fallback - and the caller's `[ "$n" -gt 0 ]` then dies
# with "integer expression expected". It printed `0\n0` in grubpw status and would have
# aborted `grubpw set` on its first real use. Take grep's own count and only default when the
# capture is genuinely empty (no such file).
_count_lines() {
  local n; n="$(grep -c "$1" "$2" 2>/dev/null)" || true
  printf '%s\n' "${n:-0}"
}
grubpw_pw_count()        { _count_lines '^password_pbkdf2' "$GRUB_CUSTOM"; }
grubpw_su_count()        { _count_lines '^set superusers' "$GRUB_CUSTOM"; }

cmd_grubpw() {
  local action="${1:-status}"
  local me; me="$(hostname -s)"

  case "$action" in
    status)
      printf '\n  GRUB password on %s\n\n' "$me"
      if grubpw_unrestricted_ok; then
        ok "--unrestricted present in $GRUB_10_LINUX"
        grep -nE '^CLASS=' "$GRUB_10_LINUX" | sed 's/^/       /'
      else
        warn "--unrestricted ABSENT from $GRUB_10_LINUX"
        say  "   setting a password now would make GRUB demand it to BOOT."
        say  "   run:  sudo $0 grubpw prep"
      fi
      if [ "$(id -u)" -eq 0 ]; then
        say "superusers lines:      $(grubpw_su_count)"
        say "password_pbkdf2 lines: $(grubpw_pw_count)   (want exactly 1)"
        if [ -f /boot/grub/grub.cfg ]; then
          say "in the generated config: superusers=$(_count_lines 'superusers' /boot/grub/grub.cfg) unrestricted=$(_count_lines 'unrestricted' /boot/grub/grub.cfg)"
        fi
      else
        warn "run as root to read $GRUB_CUSTOM and grub.cfg - both are root-only, and an"
        warn "  unprivileged read returns EMPTY, which looks exactly like 'not configured'"
      fi
      echo
      ;;

    prep)
      need_root
      if grubpw_unrestricted_ok; then
        ok "--unrestricted already in $GRUB_10_LINUX - nothing to do"
        return 0
      fi
      # The CLASS variable is what every menu entry's --class list comes from. Appending
      # --unrestricted there covers every generated entry rather than one of them.
      grep -n '^CLASS=' "$GRUB_10_LINUX" | sed 's/^/       before: /'
      backup_file "$GRUB_10_LINUX"
      sed -i -E 's|^(CLASS=".*)(")$|\1 --unrestricted\2|' "$GRUB_10_LINUX"
      grep -n '^CLASS=' "$GRUB_10_LINUX" | sed 's/^/       after:  /'
      if ! grubpw_unrestricted_ok; then
        warn "the edit did not take. Restoring and stopping."
        [ -n "${LAST_BACKUP:-}" ] && cp -a "$LAST_BACKUP" "$GRUB_10_LINUX"
        die "could not add --unrestricted to $GRUB_10_LINUX - do it by hand, runbook 6.3i"
      fi
      # 10_linux is a SHELL SCRIPT that grub-mkconfig executes. Syntax-check it, the same way
      # /etc/default/grub gets sh -n - a boot generator that cannot parse is a machine whose
      # grub.cfg can never be regenerated.
      if ! sh -n "$GRUB_10_LINUX" 2>/dev/null; then
        sh -n "$GRUB_10_LINUX" 2>&1 | sed 's/^/       /'
        [ -n "${LAST_BACKUP:-}" ] && cp -a "$LAST_BACKUP" "$GRUB_10_LINUX"
        die "$GRUB_10_LINUX failed sh -n - RESTORED from backup"
      fi
      ok "$GRUB_10_LINUX passes sh -n"
      ok "prep done. Now: sudo $0 grubpw set"
      say "   NOTE: 10_linux is a PACKAGE file. A grub-common upgrade replaces it and drops"
      say "   --unrestricted, which turns the next reboot into a password prompt on a headless"
      say "   box. Re-check with \`grubpw status\` after any grub-common upgrade."
      ;;

    set)
      need_root
      grubpw_unrestricted_ok || die "REFUSING - --unrestricted is not in $GRUB_10_LINUX.
       Setting superusers now makes GRUB demand the password to BOOT, not just to edit an
       entry, and this machine is headless. Run: sudo $0 grubpw prep"

      local n_pw; n_pw="$(grubpw_pw_count)"
      if [ "$n_pw" -gt 0 ]; then
        warn "$GRUB_CUSTOM already has $n_pw password_pbkdf2 line(s)."
        say  "   Re-running would add a second. Remove the existing block first, or leave it."
        return 1
      fi

      # READ IT TWICE, SILENTLY, AND NEVER ECHO IT.
      local P P2
      read -rsp '  GRUB password (enclave-wide, from the controlled document): ' P; echo
      read -rsp '  again: ' P2; echo
      [ -n "$P" ] || die "empty password - refusing"
      [ "$P" = "$P2" ] || die "the two entries do not match - nothing was changed"

      # PIPED, NOT PROMPTED - its prompts go to stdout and would be captured.
      local H
      H="$(printf '%s\n%s\n' "$P" "$P" | grub-mkpasswd-pbkdf2 2>/dev/null \
            | awk '/PBKDF2 hash/{print $NF}')"
      P=""; P2=""
      case "$H" in
        grub.pbkdf2.sha512.*) ok "hash generated (${#H} chars, not shown)" ;;
        *) die "grub-mkpasswd-pbkdf2 produced nothing usable - nothing was changed" ;;
      esac

      backup_file "$GRUB_CUSTOM"
      # APPEND EXACTLY ONCE AND COUNT. An earlier hand-run of this appended twice and the
      # second block carried an EMPTY hash, because $H had already been unset - a machine that
      # would have accepted no password at all. Counting is what caught it.
      printf 'set superusers="root"\npassword_pbkdf2 root %s\n' "$H" >> "$GRUB_CUSTOM"
      H=""
      local su pw; su="$(grubpw_su_count)"; pw="$(grubpw_pw_count)"
      say "   $GRUB_CUSTOM now: $su superusers line(s), $pw password line(s)"
      if [ "$su" -ne 1 ] || [ "$pw" -ne 1 ]; then
        warn "expected exactly one of each - RESTORING"
        [ -n "${LAST_BACKUP:-}" ] && cp -a "$LAST_BACKUP" "$GRUB_CUSTOM"
        die "$GRUB_CUSTOM had the wrong line count - restored, nothing applied"
      fi
      # An empty hash is the specific failure worth naming.
      if grep -qE '^password_pbkdf2 root[[:space:]]*$' "$GRUB_CUSTOM"; then
        [ -n "${LAST_BACKUP:-}" ] && cp -a "$LAST_BACKUP" "$GRUB_CUSTOM"
        die "the password line has NO HASH - restored. This would accept any password."
      fi

      local ug_out ug_rc=0
      ug_out="$(update-grub 2>&1)" || ug_rc=$?
      printf '%s\n' "$ug_out" | sed 's/^/       /'
      [ "$ug_rc" -eq 0 ] || die "update-grub failed (exit $ug_rc) - output above"

      # PROVE BOTH HALVES REACHED THE GENERATED CONFIG. superusers without unrestricted is a
      # machine that will not boot unattended, and that is discovered at the rack.
      local g_su g_un
      g_su="$(_count_lines 'superusers' /boot/grub/grub.cfg)"
      g_un="$(_count_lines 'unrestricted' /boot/grub/grub.cfg)"
      say "   /boot/grub/grub.cfg: superusers=$g_su  unrestricted=$g_un"
      if [ "$g_su" -lt 1 ]; then
        die "superusers did NOT reach grub.cfg - do not reboot, investigate 40_custom"
      fi
      if [ "$g_un" -lt 1 ]; then
        warn "unrestricted did NOT reach grub.cfg. DO NOT REBOOT - this machine would stop"
        warn "at a password prompt. Revert 40_custom from $LAST_BACKUP and re-run update-grub."
        return 1
      fi
      ok "both present - unattended boot preserved, editor locked"
      echo
      warn "REBOOT IS THE TEST, and it is the only test. Confirm the machine comes back with"
      warn "  no keyboard, then confirm 'e' at the menu asks for a password."
      warn "  Have the console route open first:  vm-rescue.sh console $me   (from host-4)"
      ;;

    *) die "usage: $0 grubpw {status|prep|set}" ;;
  esac
}

# --------------------------------------------------------------------------------- v1r6
#
# THE DISA V1R6 RESIDUAL THAT `usg fix` DOES NOT TOUCH.
#
# `usg fix` remediates against Canonical's V1R1. Evaluate-STIG assesses against DISA V1R6,
# and the gap is real: on a machine USG has finished with, V1R6 still reports ~14-20 Open.
# Most are ordinary defects with mechanical fixes - they were hand-triaged on svc-mgmt-01
# (20 Open -> 8) and were about to be hand-triaged again on svc-repo-01, and again on host-4.
#
# THREE TIMES BY HAND IS A PROCEDURE NOBODY CAN REPEAT. So the mechanical ones live here,
# with the same plan / --apply / --verify shape as `fixups`.
#
# WHAT IS DELIBERATELY *NOT* HERE:
#
#   V-270675  GRUB password  - interactive by nature, and the hash must never be echoed. 6.3i
#   V-270663/735/736/722     - the smart-card family. One missing subsystem, an AO decision
#   V-270817/658             - audit offload. Blocked on svc-log-01 and three AO answers, 6.3d
#   V-270751                 - chrony: unpassable in an air gap by design. Answer File, 10.1d
#   V-270681, V-270699(dbus) - scanner false positives. Answer File, with the verbatim output
#
#   A fix that requires somebody to DECIDE does not belong in a script that applies fixes.
#
# EVERY CHECK BELOW IS DISA'S OWN CHECKTEXT, RUN VERBATIM - not a paraphrase of it. That is
# what caught V-270681 and half of V-270699 as false positives: the scanner said Open, and
# DISA's own command said otherwise.

V1R6_GRUB_DROPIN=/etc/default/grub.d/99-zz-enclave-stig.cfg
V1R6_AUDIT_RULES=/etc/audit/rules.d/99-enclave-stig.rules
V1R6_JOURNAL_TMPFILES=/etc/tmpfiles.d/zzz-systemd-stig.conf
V1R6_REBOOT_NEEDED=0

# ---- the checks, each one DISA's command ------------------------------------------------
v1r6_timesyncd_installed() {
  # DISA'S CHECK IS `dpkg -l | grep systemd-timesyncd`, AND THAT IS WHAT THIS RUNS.
  #
  # The first version asked dpkg-query for `ok installed`, which is FALSE for the
  # `deinstall ok config-files` state - the state `apt-get remove` leaves behind. That state
  # prints as `rc` in `dpkg -l`, so DISA still calls it a finding, and my check reported
  # svc-repo-01 clean while the scanner reported it Open.
  #
  # The comment on the fix already said `deinstall ok config-files` still counts. The check
  # did not implement the comment. Run DISA's command, not a smarter one.
  dpkg -l 2>/dev/null | grep -q 'systemd-timesyncd'
}
v1r6_nullok_files() {
  grep -l 'nullok' /etc/pam.d/common-auth /usr/share/pam-configs/unix 2>/dev/null || true
}
v1r6_bad_libs() {
  find /lib /lib64 /usr/lib /usr/lib64 -type f -name '*.so*' ! -group root \
       -exec stat -c "%n %G" {} + 2>/dev/null || true
}
# EVERY ONE OF THESE READERS ENDS IN `|| true`, AND THAT IS LOAD-BEARING.
#
# `find` exits 1 after any permission-denied even when its output is complete; `grep -l`
# exits 1 when nothing matches. Under `set -euo pipefail`, `local x; x="$(reader)"` with a
# non-zero reader KILLS THE FUNCTION MID-REPORT - the caller sees a partial plan that looks
# like a clean bill of health. That is precisely how `preflight` failed on 2026-09-10, it is
# documented in 6.3f, and the first version of this function did it again.
v1r6_sticky_missing() {
  # DISA: world-writable directories must have the sticky bit. -xdev keeps it off the 321 GB
  # mirror and host-4's 1.9 TB image store if they are separate filesystems.
  find / -xdev \( -path /proc -o -path /sys -o -path /run \) -prune -o \
       -type d -perm -0002 ! -perm -1000 -print 2>/dev/null || true
}
v1r6_cron_audit_ok() {
  auditctl -l 2>/dev/null | grep -qw -- '-w /etc/cron.d' && \
  auditctl -l 2>/dev/null | grep -qw -- '-w /var/spool/cron'
}
# V-270676 NEEDS audit=1 IN TWO PLACES, FOR TWO DIFFERENT REASONS.
#
# DISA's CheckText reads `/etc/default/grub` for GRUB_CMDLINE_LINUX and
# GRUB_CMDLINE_LINUX_DEFAULT, then the generated grub.cfg. It does NOT read /proc/cmdline.
# The first version of this check read /proc/cmdline only, found audit=1 there, and reported
# PASS on a machine the scanner had marked Open - because /etc/default/grub said
# "quiet splash".
#
# And on a cloud image /etc/default/grub is not sufficient on its own: 50-cloudimg-settings.cfg
# HARD-ASSIGNS GRUB_CMDLINE_LINUX_DEFAULT and silently discards what came before, so a value
# set only there never reaches the kernel (the grub trap in 6.3). So:
#
#   /etc/default/grub      - satisfies the CHECK
#   /etc/default/grub.d/99 - makes the value TRUE at runtime
#
# Both, or the machine is compliant-on-paper or compliant-in-fact but never both.
v1r6_audit_default_grub() { grep -hE '^GRUB_CMDLINE_LINUX(_DEFAULT)?=' /etc/default/grub 2>/dev/null || true; }
v1r6_audit_at_boot() {
  grep -qw 'audit=1' /proc/cmdline \
    && v1r6_audit_default_grub | grep -q 'audit=1' \
    && ! v1r6_audit_default_grub | grep -v 'audit=1' | grep -q 'GRUB_CMDLINE'
}
v1r6_journal_dirs()  { stat -c '%a %n' /var/log/journal /run/log/journal 2>/dev/null || true; }

cmd_v1r6() {
  local apply=0 verify=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply)  apply=1; shift ;;
      --verify) verify=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  local me; me="$(hostname -s)"
  [ "$apply" -eq 1 ] && need_root

  printf '\n  DISA V1R6 residual on %s%s\n\n' "$me" \
    "$([ "$apply" -eq 1 ] && echo ' - APPLYING' || echo ' - PLAN ONLY')"

  local n_todo=0 failed=0

  # ---- V-270645  systemd-timesyncd ------------------------------------------------------
  printf '  V-270645  UBTU-24-100010  systemd-timesyncd must not be installed\n'
  if v1r6_timesyncd_installed; then
    n_todo=$((n_todo+1))
    if [ "$apply" -eq 1 ]; then
      # PURGE, not remove. `remove` leaves config-files state, which DISA still reads as
      # installed - that is the whole trap in this control.
      DEBIAN_FRONTEND=noninteractive apt-get purge -y systemd-timesyncd >/dev/null 2>&1 \
        && ok "   purged" || { warn "   purge FAILED"; failed=1; }
      systemctl is-active chrony >/dev/null 2>&1 \
        && ok "   chrony still active - time keeps working" \
        || { warn "   CHRONY IS NOT ACTIVE - this machine has no time source"; failed=1; }
    else
      say "   state: INSTALLED -> apt-get purge -y systemd-timesyncd"
      say "          (purge, not remove: 'deinstall ok config-files' still reads as installed)"
    fi
  else
    ok "   not installed"
  fi

  # ---- V-270750  the scanner's own 0777 directory, and sticky bits ----------------------
  printf '\n  V-270750  UBTU-24-600150  sticky bit on public directories\n'
  if [ -d /tmp/.dotnet ]; then
    n_todo=$((n_todo+1))
    if [ "$apply" -eq 1 ]; then
      rm -rf /tmp/.dotnet && ok "   removed /tmp/.dotnet - PowerShell's own 0777 litter"
    else
      say "   /tmp/.dotnet  $(stat -c '%a' /tmp/.dotnet)  <- THE SCANNER CREATED THIS FINDING"
      say "          pwsh writes it 0777 on every run. Remove it after scanning, not before."
    fi
  fi
  local sticky; sticky="$(v1r6_sticky_missing)"
  if [ -n "$sticky" ]; then
    n_todo=$((n_todo+1))
    printf '%s\n' "$sticky" | sed 's/^/       /'
    if [ "$apply" -eq 1 ]; then
      printf '%s\n' "$sticky" | while IFS= read -r d; do chmod a+t "$d" 2>/dev/null; done
      [ -z "$(v1r6_sticky_missing)" ] && ok "   sticky bit set" \
        || { warn "   some directories still lack it"; failed=1; }
    else
      say "   -> chmod a+t on each"
    fi
  else
    ok "   every world-writable directory has the sticky bit"
  fi

  # ---- V-270699  library group ownership ------------------------------------------------
  printf '\n  V-270699  UBTU-24-300009  shared libraries group-owned by root\n'
  local badlibs; badlibs="$(v1r6_bad_libs)"
  if [ -n "$badlibs" ]; then
    n_todo=$((n_todo+1))
    printf '%s\n' "$badlibs" | sed 's/^/       /'
    say "   NOTE: the scanner also reports /usr/lib/dbus-1.0/dbus-daemon-launch-helper."
    say "         That is NOT a *.so file, so DISA's own find does not return it, and it is"
    say "         setgid messagebus - chowning it BREAKS D-Bus. Answer-File it, do not fix it."
    if [ "$apply" -eq 1 ]; then
      find /lib /lib64 /usr/lib /usr/lib64 -type f -name '*.so*' ! -group root \
           -exec chown :root {} + 2>/dev/null
      [ -z "$(v1r6_bad_libs)" ] && ok "   group set to root" \
        || { warn "   some files still not group root"; failed=1; }
    else
      say "   -> find ... ! -group root -exec chown :root {} +   (DISA's FixText verbatim)"
    fi
  else
    ok "   DISA's find returns nothing"
  fi

  # ---- V-270714  nullok -----------------------------------------------------------------
  printf '\n  V-270714  UBTU-24-300028  PAM must not permit empty passwords (HIGH)\n'
  local nullok; nullok="$(v1r6_nullok_files)"
  if [ -n "$nullok" ]; then
    n_todo=$((n_todo+1))
    printf '%s\n' "$nullok" | sed 's/^/       carries nullok: /'
    # THE GATE, BEFORE TOUCHING A PAM AUTH STACK ON A HEADLESS MACHINE.
    local np; np="$(awk -F: '{print $1}' /etc/passwd | while read -r u; do
        [ "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" = "NP" ] && echo "$u"
      done || true)"
    if [ -n "$np" ]; then
      warn "   ACCOUNTS WITH NO PASSWORD - removing nullok LOCKS THESE OUT:"
      printf '%s\n' "$np" | sed 's/^/         /'
      warn "   REFUSING. Give them a password or lock them deliberately first."
      failed=1
    else
      ok "   no NP accounts - removing nullok cannot lock anyone out"
      if [ "$apply" -eq 1 ]; then
        # BOTH FILES OR NEITHER. common-auth alone is undone by the next pam-auth-update;
        # the pam-configs source alone does nothing until common-auth is regenerated.
        local f
        for f in /etc/pam.d/common-auth /usr/share/pam-configs/unix; do
          [ -f "$f" ] || continue
          backup_file "$f"
          sed -i 's/[[:space:]]\{1,\}nullok//g' "$f"
        done
        # DEBIAN_FRONTEND=noninteractive, AND DO NOT SWALLOW THE OUTPUT.
        #
        # `pam-auth-update --force` goes through debconf, and debconf draws a whiptail
        # dialog. With `>/dev/null 2>&1` that dialog is INVISIBLE and the script simply
        # stops - on svc-repo-01 it sat with no output at all while a menu waited for a
        # keypress nobody could see. Identical to piping grub-mkpasswd-pbkdf2 into a file
        # and then wondering why the prompt never appeared. Second time in one night.
        #
        # noninteractive makes debconf answer itself; the timeout means a frontend that
        # ignores that fails loudly instead of hanging; and the output is PRINTED.
        local pau_out pau_rc=0
        pau_out="$(DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
                   timeout 60 pam-auth-update --force 2>&1)" || pau_rc=$?
        [ -n "$pau_out" ] && printf '%s\n' "$pau_out" | sed 's/^/       /'
        if [ "$pau_rc" -eq 124 ]; then
          warn "   pam-auth-update TIMED OUT after 60s - it was waiting for input."
          warn "   nullok is already out of both files, so the machine is correct; the"
          warn "   regeneration is what is unproven. Run it by hand to see the dialog."
          failed=1
        elif [ "$pau_rc" -ne 0 ]; then
          warn "   pam-auth-update exited $pau_rc"
        fi
        if [ -z "$(v1r6_nullok_files)" ]; then
          ok "   nullok removed from both files, pam-auth-update re-run"
          warn "   VERIFY NOW, in this session:  sudo -k; sudo -v"
          warn "   /usr/share/pam-configs/unix is a PACKAGE file, not a conffile - a"
          warn "   libpam-runtime upgrade reinstates nullok. Re-run --verify after upgrades."
        else
          warn "   nullok STILL PRESENT after the edit"; failed=1
        fi
      else
        say "   -> strip nullok from BOTH files, then pam-auth-update --force"
        say "      neither edit works alone - see runbook 10.1d"
      fi
    fi
  else
    ok "   no nullok in common-auth or pam-configs/unix"
  fi

  # ---- V-270676  audit=1 at boot --------------------------------------------------------
  printf '\n  V-270676  UBTU-24-102010  session audits must start at boot\n'
  say "   /proc/cmdline:      $(grep -o 'audit=[0-9]*' /proc/cmdline | sort -u | tr '\n' ' ' || echo 'audit= ABSENT')"
  v1r6_audit_default_grub | sed 's|^|       /etc/default/grub:  |'
  [ -f "$V1R6_GRUB_DROPIN" ] && grep -h 'audit=1' "$V1R6_GRUB_DROPIN" 2>/dev/null \
    | sed "s|^|       $(basename "$V1R6_GRUB_DROPIN"):  |"
  if v1r6_audit_at_boot; then
    ok "   audit=1 live AND in every GRUB_CMDLINE line DISA reads"
  else
    n_todo=$((n_todo+1))
    if [ "$apply" -eq 1 ]; then
      # 1. THE FILE DISA READS.
      backup_file /etc/default/grub
      local gl
      for gl in GRUB_CMDLINE_LINUX_DEFAULT GRUB_CMDLINE_LINUX; do
        if grep -qE "^$gl=" /etc/default/grub; then
          grep -qE "^$gl=.*audit=1" /etc/default/grub \
            || sed -i -E "s|^($gl=\")(.*)(\")|\\1\\2 audit=1\\3|" /etc/default/grub
        else
          printf '%s="audit=1"\n' "$gl" >> /etc/default/grub
        fi
      done
      # Collapse the leading space a previously-empty value leaves behind.
      #
      # \1 IS A BACKREFERENCE ONLY IF sed ACTUALLY RECEIVES ONE BACKSLASH. The first version
      # wrote '\\1' inside SINGLE quotes, so bash passed \\1 through verbatim, sed read it as
      # an escaped backslash followed by a 1, and the replacement was the LITERAL TEXT \1.
      # /etc/default/grub line 11 became:
      #
      #     \1audit=1"
      #
      # An unmatched quote in a file that grub-mkconfig SOURCES, which is why update-grub
      # exited 2 with "EOF in backquote substitution" - and why GRUB_CMDLINE_LINUX looked
      # deleted when it had only been mangled. The identical expression one line above works
      # because it is double-quoted, where bash turns \\1 into \1 before sed sees it.
      sed -i -E 's|^(GRUB_CMDLINE_LINUX(_DEFAULT)?=")[[:space:]]+|\1|' /etc/default/grub

      # AND NOW VALIDATE, BECAUSE THIS FILE IS SOURCED BY THE BOOTLOADER GENERATOR.
      #
      # grub-mkconfig runs `. /etc/default/grub` with sh, so `sh -n` is exactly the right
      # check - it catches an unbalanced quote or backtick before update-grub does. Any sed
      # against a boot-critical file gets this treatment: edit, syntax-check, revert on
      # failure. A broken /etc/default/grub is not dangerous on its own (the existing
      # grub.cfg keeps booting), but it silently blocks every later grub change.
      if ! sh -n /etc/default/grub 2>/dev/null; then
        warn "   /etc/default/grub FAILED sh -n after the edit - REVERTING"
        sh -n /etc/default/grub 2>&1 | sed 's/^/       /'
        if [ -n "${LAST_BACKUP:-}" ] && [ -f "$LAST_BACKUP" ]; then
          cp -a "$LAST_BACKUP" /etc/default/grub
          ok "   restored from $LAST_BACKUP"
        else
          warn "   NO BACKUP TO RESTORE FROM - fix by hand before any update-grub"
        fi
        failed=1
      else
        ok "   /etc/default/grub passes sh -n"
        ok "   now: $(v1r6_audit_default_grub | tr '\n' ' ')"
      fi
      # 2. THE FILE THAT MAKES IT TRUE. On a cloud image 50-cloudimg-settings.cfg
      # hard-assigns GRUB_CMDLINE_LINUX_DEFAULT, so the value above never reaches the
      # kernel on its own. The drop-in sorts after it and appends.
      install -d -m 0755 /etc/default/grub.d
      if ! grep -q 'audit=1' "$V1R6_GRUB_DROPIN" 2>/dev/null; then
        printf '# audit=1 for UBTU-24-102010. Written by stig-tailor.sh %s\n' "$(date -Is)" \
          >> "$V1R6_GRUB_DROPIN"
        # IDEMPOTENT APPEND. A bare `="$X audit=1"` adds it again every time the value
        # already carries it - which it does now that /etc/default/grub sets it too, so
        # svc-repo-01 booted with audit=1 twice on its command line. Harmless (the kernel
        # takes the last one) but untidy in a file an assessor reads.
        cat >> "$V1R6_GRUB_DROPIN" <<'DROPIN'
case " $GRUB_CMDLINE_LINUX_DEFAULT " in
  *" audit=1 "*) ;;
  *) GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT audit=1" ;;
esac
DROPIN
        ok "   $V1R6_GRUB_DROPIN written"
      else
        ok "   $V1R6_GRUB_DROPIN already carries it"
      fi
      # THE DROP-IN MUST BE 0644. root's umask is 077 after `usg fix`, so a bare `printf >>`
      # creates it 0600 - readable by grub-mkconfig (which is root) but inconsistent with
      # every other file in grub.d and invisible to any later non-root inspection.
      chmod 0644 "$V1R6_GRUB_DROPIN"
      # AND DO NOT SWALLOW update-grub. Third time in one night that hiding a command's
      # output turned a legible error into "FAILED" with no reason attached.
      local ug_out ug_rc=0
      ug_out="$(update-grub 2>&1)" || ug_rc=$?
      printf '%s\n' "$ug_out" | sed 's/^/       /'
      if [ "$ug_rc" -eq 0 ]; then
        # PROVE IT REACHED THE GENERATED CONFIG - DISA checks that too, and this is the step
        # where a discarded /etc/default/grub edit shows up.
        if grep -q 'audit=1' /boot/grub/grub.cfg 2>/dev/null; then
          ok "   audit=1 present in the generated /boot/grub/grub.cfg"
        else
          warn "   update-grub ran but /boot/grub/grub.cfg has NO audit=1 - something is"
          warn "   overriding it. Check /etc/default/grub.d/ ordering before rebooting."
          failed=1
        fi
      else
        warn "   update-grub FAILED (exit $ug_rc) - output above. NOT rebooting on this."
        failed=1
      fi
      V1R6_REBOOT_NEEDED=1
    else
      say "   -> add audit=1 to BOTH GRUB_CMDLINE lines in /etc/default/grub (what DISA reads)"
      say "      AND $V1R6_GRUB_DROPIN (what makes it true - cloudimg hard-assigns the"
      say "      default, so the /etc/default/grub value alone never reaches the kernel)"
      say "      then update-grub and REBOOT"
    fi
  fi

  # ---- V-274870  cron audit rules -------------------------------------------------------
  printf '\n  V-274870  UBTU-24-200270  audit anything cron runs as root\n'
  if v1r6_cron_audit_ok; then
    ok "   both watches loaded"
  else
    n_todo=$((n_todo+1))
    if [ "$apply" -eq 1 ]; then
      if ! grep -q 'cronjobs' "$V1R6_AUDIT_RULES" 2>/dev/null; then
        cat >> "$V1R6_AUDIT_RULES" <<'RULES'
# UBTU-24-200270 / V-274870 - audit anything cron runs as root. DISA FixText verbatim.
-w /etc/cron.d/ -p wa -k cronjobs
-w /var/spool/cron/ -p wa -k cronjobs
RULES
        # 0600, NOT 0640. USG's file_permissions_etc_audit_rulesd says, verbatim:
        #   "$ sudo chmod 0600 /etc/audit/rules.d/*.rules"
        # The file arrives 0600 anyway from root's umask 077, and an explicit chmod 0640 here
        # BROKE a rule that had been passing - a V1R6 fix that opened a V1R1 finding. Adding a
        # file to a directory the STIG measures means matching that directory's required mode,
        # not a mode that looks reasonable.
        chmod 0600 "$V1R6_AUDIT_RULES"
        ok "   rules written to $V1R6_AUDIT_RULES ($(stat -c '%a' "$V1R6_AUDIT_RULES"))"
        # Prove it matches its neighbours rather than assuming chmod was enough.
        local odd
        odd="$(find /etc/audit/rules.d -maxdepth 1 -type f -name '*.rules' ! -perm 0600 \
                 -exec stat -c '%a %n' {} + 2>/dev/null || true)"
        if [ -n "$odd" ]; then
          warn "   these are not 0600 and WILL fail file_permissions_etc_audit_rulesd:"
          printf '%s\n' "$odd" | sed 's/^/         /'
          failed=1
        fi
      fi
      augenrules --load >/dev/null 2>&1 || true
      if v1r6_cron_audit_ok; then
        ok "   loaded live"
      else
        # auditd IN IMMUTABLE MODE (-e 2) REFUSES RULE CHANGES UNTIL REBOOT. That is not a
        # failure - it is the control working. Say which it is rather than reporting an error.
        if auditctl -s 2>/dev/null | grep -q 'enabled 2'; then
          warn "   auditd is IMMUTABLE (-e 2) - rules are on disk and load at REBOOT"
          V1R6_REBOOT_NEEDED=1
        else
          warn "   rules did not load and auditd is not immutable - investigate"; failed=1
        fi
      fi
    else
      say "   state: MISSING -> two -w watches in $V1R6_AUDIT_RULES"
      say "          auditd is immutable, so this needs a REBOOT, not a reload"
    fi
  fi

  # ---- V-270757  journal directory permissions ------------------------------------------
  printf '\n  V-270757  UBTU-24-700020  journal must not reveal information\n'
  v1r6_journal_dirs | sed 's/^/       /'
  if v1r6_journal_dirs | awk '{print $1}' | grep -qv '^640$'; then
    n_todo=$((n_todo+1))
    if [ "$apply" -eq 1 ]; then
      # DISA names this exact filename. MEASURED on svc-mgmt-01: it wins over
      # /usr/lib/tmpfiles.d/systemd.conf's `Z ... ~2750` despite sorting later. Reasoning
      # about tmpfiles precedence got this wrong; measuring got it right.
      cat > "$V1R6_JOURNAL_TMPFILES" <<'TMPF'
# UBTU-24-700020 / V-270757. DISA's FixText names this filename; it overrides
# /usr/lib/tmpfiles.d/systemd.conf's `Z /var/log/journal ~2750`, measured 2026-09-11.
z /var/log/journal 0640 root systemd-journal - -
z /run/log/journal 0640 root systemd-journal - -
TMPF
      chmod 0644 "$V1R6_JOURNAL_TMPFILES"
      systemd-tmpfiles --create >/dev/null 2>&1 || true
      v1r6_journal_dirs | sed 's/^/       now: /'
      systemctl is-active systemd-journald >/dev/null 2>&1 \
        && ok "   journald still active" \
        || { warn "   JOURNALD IS NOT ACTIVE"; failed=1; }
      warn "   reboot verification owed - DISA says restart for these to take effect"
      V1R6_REBOOT_NEEDED=1
    else
      say "   -> $V1R6_JOURNAL_TMPFILES + systemd-tmpfiles --create"
      say "      0640 on a directory drops the x bit. It costs nothing here: usg fix already"
      say "      made journalctl non-executable by non-root, so non-root reading was already"
      say "      impossible. Confirm that on THIS machine before believing it."
    fi
  else
    ok "   both directories are 0640"
  fi

  # ---- what is left, and who has to decide it -------------------------------------------
  printf '\n  NOT HANDLED HERE - each needs a decision, not a command:\n'
  say "   V-270675           GRUB password - interactive. runbook 6.3i"
  say "   V-270663/735/736   smart card / CAC family - one missing subsystem, AO question"
  say "   V-270722/745       DoD PKI + smart-card login - same family"
  say "   V-270817 / 658     audit offload - svc-log-01, blocked on three AO answers (6.3d)"
  say "   V-270751           chrony - unpassable in an air gap by design. Answer File (10.1d)"
  say "   V-270681           rsyslog selectors - SCANNER FALSE POSITIVE. DISA's own grep"
  say "                      returns both required lines. Answer File with that output."
  say "   V-270754           ufw rate-limit - the 443 decision (6.3e)"

  printf '\n'
  ok "v1r6 report COMPLETE - if you did not see this line it exited early and the report"
  ok "  above is PARTIAL. A partial report reads exactly like a clean one."
  if [ "$verify" -eq 1 ]; then
    # --verify IS the plan, scored. Same checks, but it exits non-zero when anything is
    # outstanding so it can gate a re-scan or run from another script.
    printf '\n'
    if [ "$n_todo" -eq 0 ]; then ok "VERIFY PASSED - nothing mechanical left on $me"; return 0
    else warn "VERIFY FAILED - $n_todo item(s) outstanding"; return 1; fi
  fi
  if [ "$apply" -eq 0 ]; then
    say "$n_todo item(s) to fix. Nothing changed. Re-run with --apply"
  else
    [ "$failed" -eq 0 ] || warn "one or more fixes did not complete - see above"
    [ "$V1R6_REBOOT_NEEDED" -eq 0 ] \
      || warn "REBOOT REQUIRED - grub and/or audit rules. Then: sudo $0 v1r6 --verify"
    say "then re-scan: runbook 10.1 step 13d"
  fi
  printf '\n'
}

# -------------------------------------------------------------------------------- aide
#
# KEEP AIDE OFF THE BULK DATA - AND DECIDE IT BEFORE `usg fix`, NOT AFTER.
#
# `usg fix` installs AIDE and BUILDS THE DATABASE as part of remediation. Whatever is in
# scope at that moment gets hashed. On svc-repo-01 that meant walking a 321 GB apt mirror at
# ~26 MB/s - roughly three and a half hours, inside a fix run, with no progress output.
#
# I CONCLUDED THE OPPOSITE FIRST, AND THE WAY I GOT IT WRONG IS THE POINT.
#
#   Runbook 6.3h said "/srv is not an AIDE root, nothing to do." That was measured on
#   svc-mgmt-01 - a machine WHOSE /srv IS EMPTY. The evidence (0 entries under /srv) was
#   real and meant nothing: an empty directory produces zero entries whether it is in scope
#   or not. A control verified on a machine that cannot exercise it is not verified.
#
#   So this does not reason about aide.conf precedence at all. It MEASURES: it walks what is
#   actually on the disk, reports anything large that AIDE would reach, and makes you look at
#   the number before you harden.
#
# WHY A FRAGMENT NUMBERED 90:
#
#   /etc/aide/aide.conf.d/99_aide_root holds the catch-all `/ 0 Full`. Fragments are included
#   in filename order, so an exclusion has to sort BEFORE it. 90 leaves room either side.
#   The filename carries no dot - aide.conf's @@x_include filter rejects names that do.
#
# WHY IT CAN RUN BEFORE AIDE IS INSTALLED:
#
#   That is the whole point. The directory is created here if the package has not arrived
#   yet; dpkg will not remove a file it does not own. Seed the exclusion, THEN harden, and
#   the database is built right the first time instead of being rebuilt for three hours.

AIDE_CONF_D="${AIDE_CONF_D:-/etc/aide/aide.conf.d}"
AIDE_FRAGMENT="$AIDE_CONF_D/90_aide_enclave_exclude"
AIDE_DB=/var/lib/aide/aide.db
# Anything bigger than this inside AIDE's reach gets reported by `aide status`. Not a rule -
# a prompt to look. Override with AIDE_BIG_GB=n.
AIDE_BIG_GB="${AIDE_BIG_GB:-5}"

# machine <TAB> path <TAB> why
#
# `*` means every machine. A path that does not exist on this machine is SKIPPED and said so -
# excluding a path that is not there is noise in the artefact an assessor reads.
#
# EVERY ENTRY IS A COVERAGE REDUCTION AND NEEDS A REASON THAT SURVIVES BEING ASKED ABOUT.
# The reason is always the same shape: this content has its own integrity mechanism that is
# stronger than AIDE's, and it changes as part of normal operation.
aide_excludes() {
cat <<'EOF'
svc-repo-01	/srv/repo	THE MIRROR - 321 GB, 91,073 files. Every file is covered by apt's own Release/Packages signature chain, which AIDE cannot improve on. Re-syncing the mirror is normal operation and would flag thousands of changes every run
host-4	/var/lib/libvirt/images	VM DISK IMAGES - ~1.9 TB of qcow2 that change on every guest write. Hashing them is meaningless: a running VM guarantees the hash is stale before aide finishes. Guest integrity is the guest's own AIDE, which is what 6.0 installs on each one
svc-harbor-01	/var/lib/docker	CONTAINER LAYER STORE - content-addressed by digest, which IS an integrity mechanism, and rewritten by every image push. Harbor's own content trust covers what matters here
svc-mgmt-01	/var/lib/maas/boot-resources	MAAS BOOT IMAGES - re-downloaded and rotated by MAAS on its own schedule; each is checksummed by MAAS against its own index
EOF
}

aide_fragment_body() {
  local me="$1" mach path why n=0
  printf '# Written by stig-tailor.sh on %s - do not edit by hand, edit the table in the script.\n' "$(date -Is)"
  printf '# Numbered 90 so it is included BEFORE 99_aide_root, whose `/ 0 Full` is the catch-all.\n#\n'
  while IFS=$'\t' read -r mach path why; do
    [ -n "${mach:-}" ] || continue
    [ "$mach" = '*' ] || [ "$mach" = "$me" ] || continue
    [ -e "$path" ] || continue
    printf '# %s\n!%s\n' "$why" "$path"
    n=$((n + 1))
  done < <(aide_excludes)
  [ "$n" -gt 0 ] || printf '# no exclusions apply to %s\n' "$me"
}

# du that cannot wander off the machine. -x stays on one filesystem; the pseudo-filesystems
# are named anyway because a bind mount of /proc inside a container root is not hypothetical.
aide_du_bytes() {
  du -sxb --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run "$1" 2>/dev/null \
    | awk '{print $1}'
}

aide_human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

cmd_aide() {
  local action="${1:-status}" apply=0
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  local me; me="$(hostname -s)"

  case "$action" in
    status)
      printf '\n  AIDE scope on %s\n\n' "$me"

      if [ -f "$AIDE_FRAGMENT" ]; then
        ok "exclusion fragment present: $AIDE_FRAGMENT"
        grep -c '^!' "$AIDE_FRAGMENT" 2>/dev/null | sed 's/^/       excluding /;s/$/ path(s)/'
        grep '^!' "$AIDE_FRAGMENT" 2>/dev/null | sed 's/^/         /'
      else
        warn "NO exclusion fragment - $AIDE_FRAGMENT does not exist"
        say  "   if usg fix runs now, AIDE hashes whatever is below."
      fi

      printf '\n  what the table wants excluded here:\n'
      local mach path why any=0
      while IFS=$'\t' read -r mach path why; do
        [ -n "${mach:-}" ] || continue
        [ "$mach" = '*' ] || [ "$mach" = "$me" ] || continue
        any=1
        if [ -e "$path" ]; then
          printf '     %-32s %10s   %s\n' "$path" "$(aide_human "$(aide_du_bytes "$path")")" "present"
        else
          printf '     %-32s %10s   %s\n' "$path" "-" "not on this machine - skipped"
        fi
      done < <(aide_excludes)
      [ "$any" -eq 1 ] || say "     (none - this machine has no entry in the table)"

      # THE PART THAT WOULD HAVE CAUGHT 6.3h.
      #
      # Do not ask the config what is in scope. Ask the disk what is big, then say whether it
      # is covered. A directory that shows up here and is NOT covered is the next three-hour
      # aideinit, wherever it lives and whatever the config seems to say.
      printf '\n  anything over %s GB STILL IN SCOPE, after exclusions:\n' "$AIDE_BIG_GB"
      # SIZE IS NOT SCOPE, AND ON THE FIRST REAL RUN THAT DIFFERENCE CRIED WOLF.
      #
      # svc-repo-01, 2026-09-11: with !/srv/repo applied, this printed
      #     /srv/repo   321GB  excluded
      # [!] /srv        321GB  IN SCOPE - aideinit hashes all of it
      # Both lines are the same 321 GB. /srv is big only BECAUSE of the child that is already
      # excluded, and what AIDE actually hashes under /srv is a few hundred bytes.
      #
      # A check that reports a problem it has itself already solved is a check the operator
      # learns to skim. So: subtract every excluded subtree from its parents and threshold on
      # what is LEFT.
      local thresh=$((AIDE_BIG_GB * 1024 * 1024 * 1024)) sz d covered found=0
      local -a EXC_P=() EXC_S=()
      if [ -f "$AIDE_FRAGMENT" ]; then
        local e
        while IFS= read -r e; do
          [ -n "$e" ] || continue
          EXC_P+=("$e"); EXC_S+=("$(aide_du_bytes "$e")")
        done < <(grep '^!' "$AIDE_FRAGMENT" | sed 's/^!//')
      fi
      while read -r sz d; do
        [ -n "${d:-}" ] || continue
        [ "$d" = / ] && continue
        covered=no
        local deduct=0 k ex
        for k in "${!EXC_P[@]}"; do
          ex="${EXC_P[$k]}"
          case "$d" in "$ex"|"$ex"/*) covered=yes; break ;; esac
          # an excluded path strictly BELOW d does not count against d's in-scope size
          case "$ex" in "$d"/*) deduct=$(( deduct + ${EXC_S[$k]:-0} )) ;; esac
        done
        if [ "$covered" = yes ]; then continue; fi
        local inscope=$(( sz - deduct ))
        [ "$inscope" -ge "$thresh" ] || continue
        found=1
        if [ "$deduct" -gt 0 ]; then
          printf '  [!] %-40s %10s   IN SCOPE (of %s; the rest is excluded)\n' \
                 "$d" "$(aide_human "$inscope")" "$(aide_human "$sz")"
        else
          printf '  [!] %-40s %10s   IN SCOPE - aideinit hashes all of it\n' \
                 "$d" "$(aide_human "$inscope")"
        fi
      done < <(du -xb --max-depth=3 --threshold="$thresh" \
                  --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
                  --exclude=/var/lib/aide / 2>/dev/null | sort -rn)
      if [ "$found" -eq 1 ]; then
        say "  nothing else over ${AIDE_BIG_GB} GB is in scope"
      else
        ok "nothing over ${AIDE_BIG_GB} GB is in scope"
      fi
      # What IS excluded, said once, plainly - the line above no longer repeats it per parent.
      local k
      for k in "${!EXC_P[@]}"; do
        printf '     %-40s %10s   excluded\n' "${EXC_P[$k]}" "$(aide_human "${EXC_S[$k]}")"
      done

      printf '\n  database:\n'
      if [ -f "$AIDE_DB" ]; then
        say "     $AIDE_DB  $(ls -lh "$AIDE_DB" 2>/dev/null | awk '{print $5}')  built $(date -r "$AIDE_DB" -Is 2>/dev/null)"
        if [ "$(id -u)" -eq 0 ]; then
          say "     entries: $(zgrep -c . "$AIDE_DB" 2>/dev/null || grep -c . "$AIDE_DB" 2>/dev/null || echo '?')"
        else
          warn "   run as root to count entries - /var/lib/aide is 0600 and an unprivileged"
          warn "   read returns EMPTY, which looks exactly like 'no entries'. That mistake is"
          warn "   how 6.3h got written wrong the first time."
        fi
      else
        say "     none yet - $AIDE_DB does not exist"
      fi
      echo
      ;;

    exclude)
      if [ "$apply" -eq 0 ]; then
        printf '\n  PLAN ONLY - would write %s\n\n' "$AIDE_FRAGMENT"
        aide_fragment_body "$me" | sed 's/^/     /'
        printf '\n  apply with:  sudo %s aide exclude --apply\n\n' "$0"
        return 0
      fi
      need_root
      # Created even if aide is not installed yet - seeding BEFORE `usg fix` is the whole
      # reason this exists. dpkg will not remove a file the package does not own.
      install -d -m 0755 "$AIDE_CONF_D"
      if [ -f "$AIDE_FRAGMENT" ]; then
        install -d -m 0700 "$STIG_BACKUP_DIR"
        cp -a "$AIDE_FRAGMENT" "$STIG_BACKUP_DIR/$(basename "$AIDE_FRAGMENT").$(date +%Y%m%dT%H%M%S)"
      fi
      aide_fragment_body "$me" > "$AIDE_FRAGMENT"
      chmod 0644 "$AIDE_FRAGMENT"
      ok "wrote $AIDE_FRAGMENT"
      grep '^!' "$AIDE_FRAGMENT" | sed 's/^/       /'
      # A TABLE ENTRY THAT SILENTLY DID NOT APPLY IS THE FAILURE MODE HERE. If /srv/repo is
      # an unmounted mountpoint at the moment this runs, the exclusion is quietly absent and
      # you find out three hours into aideinit. Say it out loud.
      local mach path why
      while IFS=$'\t' read -r mach path why; do
        [ -n "${mach:-}" ] || continue
        [ "$mach" = '*' ] || [ "$mach" = "$me" ] || continue
        [ -e "$path" ] && continue
        warn "SKIPPED $path - the table has it for $me but it is not on the disk right now."
        warn "  if that is a mountpoint, mount it and re-run before hardening."
      done < <(aide_excludes)
      if command -v aide >/dev/null 2>&1 && [ -f "$AIDE_DB" ]; then
        warn "a database already exists and was built WITHOUT this exclusion."
        warn "  it is stale until rebuilt:  sudo $0 aide init"
      fi
      ;;

    init)
      need_root
      command -v aideinit >/dev/null 2>&1 \
        || die "aideinit not present - aide-common arrives with \`usg fix\`. Seed the exclusion first, then harden."
      [ -f "$AIDE_FRAGMENT" ] \
        || die "no $AIDE_FRAGMENT - run \`sudo $0 aide exclude --apply\` FIRST. Initialising
       without it is what took three and a half hours on svc-repo-01."
      # An interrupted init leaves aide.db.new behind and aideinit then refuses or resumes
      # from it. Clear it so the timing below means what it says.
      rm -f /var/lib/aide/aide.db.new
      say "initialising - this prints nothing until it finishes. Timing is reported."
      say "excluded: $(grep -c '^!' "$AIDE_FRAGMENT") path(s)"
      local t0 t1
      t0=$(date +%s)
      aideinit -y -f
      t1=$(date +%s)
      ok "aideinit finished in $(( (t1 - t0) / 60 ))m $(( (t1 - t0) % 60 ))s"
      [ -f "$AIDE_DB" ] && ok "$AIDE_DB  $(ls -lh "$AIDE_DB" | awk '{print $5}')"
      ;;

    *) die "usage: $0 aide {status|exclude [--apply]|init}" ;;
  esac
}

# ---------------------------------------------------------------------------- preflight
#
# WHAT WILL `usg fix` TAKE AWAY FROM THIS MACHINE.
#
# The STIG profile does not only tighten settings - it REMOVES packages and DISABLES services.
# On svc-harbor-01 that was harmless: nothing in the profile targeted anything Harbor needed,
# and we got away with reading the failing list and hoping.
#
# svc-mgmt-01 is different. It runs isc-dhcp-server (MAAS DHCP), python3-txtftp (PXE TFTP),
# squid (maas-proxy) and nginx. A single package_*_removed rule that matches one of those
# takes out commissioning - and commissioning is how host-1..3 get built. Finding that out
# from a broken PXE boot next week is not the same as finding it out now.
#
# So: cross-reference the SELECTED rules against what is actually installed and running, and
# print the collisions BEFORE anything is remediated. Rule ids carry the target in the middle:
# package_<name>_removed, service_<name>_disabled, service_<name>_masked.
#
# This does not decide anything. It tells you what to decide.

cmd_preflight() {
  local me; me="$(hostname -s)"
  command -v usg >/dev/null 2>&1 \
    || die "usg is not installed on $me - runbook 6.0 step 6 first (pro enable usg)"

  # Prefer the tailoring file if one exists: it is the authoritative selected set for THIS
  # enclave, deviations included. Fall back to the benchmark's own stig profile block.
  local src block
  if [ -f "$OUT" ]; then
    src="$OUT"
    block="$(grep -oE 'idref="xccdf_org.ssgproject.content_rule_[a-z0-9_.-]+"[^>]*selected="true"' "$src" \
             | sed 's/.*content_rule_//; s/".*//')"
  else
    # PICK THE BENCHMARK CHANNEL THAT MATCHES THE PROFILE. `ls */ssg-*.xml | head -1` took
    # ubuntu2404_CIS_1 because CIS sorts before STIG - and BOTH channel files happen to
    # contain a content_profile_stig, so the output looked entirely plausible while coming
    # from the wrong vintage. Never let a glob choose which compliance benchmark you audit
    # against.
    local fam=STIG
    case "$PROFILE" in
      *cis*|*CIS*) fam=CIS ;;
      *stig*|*STIG*) fam=STIG ;;
      *) die "cannot tell which benchmark family '$PROFILE' belongs to - pass STIG_PROFILE" ;;
    esac
    local cand
    cand="$(ls -d /usr/share/usg-benchmarks/*"$fam"* 2>/dev/null)"
    [ -n "$cand" ] || die "no usg-benchmarks directory matching '$fam' - is usg-benchmarks installed?
      found: $(ls -1 /usr/share/usg-benchmarks/ 2>/dev/null | tr '\n' ' ')"
    [ "$(printf '%s\n' "$cand" | wc -l)" -eq 1 ] \
      || die "more than one '$fam' benchmark directory - be explicit rather than guessing:
$(printf '%s\n' "$cand" | sed 's/^/        /')"
    src="$cand/ssg-ubuntu2404-xccdf.xml"
    [ -f "$src" ] || die "expected $src and it is not there"
    block="$(awk '/Profile id="xccdf_org.ssgproject.content_profile_stig"/,/<\/xccdf-1.2:Profile>/' "$src" \
             | grep -oE 'content_rule_[a-z0-9_.-]+' | sed 's/content_rule_//' | sort -u)"
  fi
  [ -n "$block" ] || die "found no selected rules in $src - inspect it by hand"

  printf '\n  preflight for %s\n  source: %s\n  selected rules: %s\n\n' \
    "$me" "$src" "$(printf '%s\n' "$block" | wc -l)"

  local hits=0 fuzzy=0 name rule

  printf '  PACKAGES the profile wants REMOVED that are INSTALLED here\n'
  while read -r rule; do
    case "$rule" in
      package_*_removed) name="${rule#package_}"; name="${name%_removed}" ;;
      *) continue ;;
    esac
    if dpkg -s "$name" 2>/dev/null | grep -q '^Status: install ok installed'; then
      warn "  $name   (rule: $rule)"
      hits=$((hits + 1))
    else
      # THE RULE ID IS NOT ALWAYS THE PACKAGE NAME. package_timesyncd_removed refers to
      # `systemd-timesyncd`, so an exact dpkg lookup finds nothing and reports "none" - a
      # false all-clear on the check that decides whether a service survives. So when the
      # exact name misses, look for installed packages CONTAINING the token and flag them
      # for a human. An unresolved name is reported, never silently dropped.
      # `|| true` IS LOAD-BEARING. dpkg-query exits 1 when the glob matches nothing, and under
      # `set -euo pipefail` a failing command substitution in an assignment aborts the whole
      # function SILENTLY - preflight printed its "PACKAGES" header and then simply stopped,
      # with no error and no exit code visible to the operator. Found on svc-repo-01
      # 2026-09-11, on the first run after this fuzzy fallback was added.
      local matches
      matches="$(dpkg-query -W -f='${Package} ${Status}\n' "*${name}*" 2>/dev/null \
                 | awk '$NF=="installed" {print $1}' | tr '\n' ' ' || true)"
      if [ -n "${matches// /}" ]; then
        warn "  $rule -> no package literally named '$name', but INSTALLED and similar:$matches"
        say  "     VERIFY BY HAND which one the rule means before running fix"
        fuzzy=$((fuzzy + 1))
      fi
    fi
  done < <(printf '%s\n' "$block")
  [ $((hits + fuzzy)) -gt 0 ] || ok "  none"

  local shits=0
  printf '\n  SERVICES the profile wants DISABLED or MASKED that are ACTIVE here\n'
  while read -r rule; do
    case "$rule" in
      service_*_disabled) name="${rule#service_}"; name="${name%_disabled}" ;;
      service_*_masked)   name="${rule#service_}"; name="${name%_masked}" ;;
      *) continue ;;
    esac
    if systemctl is-active "$name" >/dev/null 2>&1; then
      warn "  $name is ACTIVE   (rule: $rule)"
      shits=$((shits + 1))
    fi
  done < <(printf '%s\n' "$block")
  [ "$shits" -gt 0 ] || ok "  none"

  say ""
  if [ $((hits + shits + fuzzy)) -eq 0 ]; then
    ok "nothing the profile removes or disables is present on this machine"
  else
    [ "$fuzzy" -eq 0 ] || warn "$fuzzy rule(s) name a package that does not exist under that"
    [ "$fuzzy" -eq 0 ] || say  "   exact name - resolve those by hand; they are NOT clear."
    warn "$((hits + shits + fuzzy)) collision(s). For EACH one, decide before running fix:"
    say "   - is it actually needed here?  (MAAS needs DHCP, TFTP and its proxy)"
    say "   - if yes, it is a TAILORING DEVIATION with a justification, not a surprise"
    say "   - if no, let fix remove it and the machine is smaller"
    say "   Add deviations to the table in this script, then re-run generate."
  fi
  # --- NOPASSWD grants to SERVICE accounts ------------------------------------------------
  #
  # `usg fix` strips NOPASSWD from sudoers - correctly, STIG requires sudo to authenticate.
  # On svc-harbor-01 that locked out the only human admin (6.3a). On svc-mgmt-01 it does
  # something quieter and worse: MAAS ships FOUR sudoers files granting its own service
  # account per-command NOPASSWD for starting maas-dhcpd, running lshw and blockdev during
  # commissioning, and reloading maas-agent/http/proxy/syslog, chrony and bind9.
  #
  # The `maas` user is non-interactive with no password. Take NOPASSWD away and sudo prompts
  # into the void: no DHCP, no hardware inventory, no PXE. THIS IS NOT A PACKAGE OR SERVICE
  # RULE, so the two checks above cannot see it.
  local np_files nf=0
  printf '\n  NOPASSWD grants that `usg fix` will strip\n'
  np_files="$(grep -rlE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null || true)"
  if [ -z "$np_files" ] && [ "$(id -u)" -ne 0 ]; then
    # NEVER report "none" from a check that could not read its inputs. /etc/sudoers.d is
    # root-only, so unprivileged this finds nothing whether or not anything is there - and a
    # false "none" here is what lets someone run fix and break MAAS.
    warn "  INCOMPLETE - /etc/sudoers.d is not readable as $(id -un)."
    say  "     This check found nothing because it could not look, NOT because there is"
    say  "     nothing. Re-run:  sudo $0 preflight"
    nf=1
  elif [ -z "$np_files" ]; then
    ok "  none found (checked as root, so this is a real answer)"
  else
    local f who shell
    for f in $np_files; do
      while read -r who; do
        [ -n "$who" ] || continue
        shell="$(getent passwd "$who" 2>/dev/null | cut -d: -f7)"
        case "$shell" in
          ""|*/nologin|*/false)
            warn "  $who in $(basename "$f") - SERVICE ACCOUNT (shell: ${shell:-none})"
            say  "     stripping this breaks whatever it automates, silently"
            nf=$((nf + 1)) ;;
          *)
            say  "  $who in $(basename "$f") - interactive account (shell: $shell)"
            say  "     MUST have a working password before fix runs, or it is locked out (6.3a)"
            nf=$((nf + 1)) ;;
        esac
      done < <(grep -hE '^[^#]*NOPASSWD' "$f" 2>/dev/null | awk '{print $1}' | grep -v '^%' | sort -u)
    done
    say ""
    say "   Back these up OUTSIDE /etc/sudoers.d before fix - $STIG_BACKUP_DIR - then restore"
    say "   only the SERVICE-ACCOUNT grants afterwards, as a documented deviation. Restoring"
    say "   per-command NOPASSWD for a service account is a far better story than a blanket"
    say "   deviation on the rule, and the human admin stays authenticated as STIG wants."
  fi

  say ""
  say "NOTE: the package and service checks only catch rules whose id names the target. A rule"
  say "that breaks something as a side effect of a SETTING - like the NOPASSWD strip above -"
  say "will not appear in them. The baseline audit and the failing list still matter."
  say ""
  ok "preflight complete - if you did not see this line, it exited early and the report is"
  ok "  INCOMPLETE. Do not run \`usg fix\` on a partial preflight."
}

# ---------------------------------------------------------------------------- ufw
#
# WHAT THE RULES ACTUALLY REQUIRE, read from the benchmark on 2026-09-10:
#
#   check_ufw_active      - `ufw status` must not report "inactive". That is all.
#   set_ufw_default_rule  - default DENY on incoming.
#   ufw_rate_limit        - "If any port with a state of LISTEN is not marked with the LIMIT
#                            action, this is a finding." EVERY listening port, not just ssh.
#
# AND THAT LAST ONE CONFLICTS WITH WHAT THIS ENCLAVE IS FOR.
#
#   `ufw limit` denies a source IP after 6 connections in 30 seconds. On ssh that is exactly
#   right. On 443 of svc-repo-01 it rate-limits APT, and on 443 of svc-harbor-01 it
#   rate-limits CONTAINER PULLS - containerd opens parallel connections per layer and apt
#   pipelines. A rule set that satisfies the benchmark and breaks the package mirror has made
#   the enclave worse, not safer.
#
#   So the action is a PER-PORT decision recorded in the table below, `limit` where it is
#   safe and `allow` where limiting would break the service.
#
#   WHETHER 443 ACTUALLY BREAKS UNDER LIMIT IS TESTABLE, not a matter of opinion. The test
#   is in runbook 6.3e: set `limit 443/tcp` on svc-harbor-01 (disposable), pull a
#   multi-layer image from host-4, and watch for connection resets. If pulls survive, change
#   this table to `limit` and the finding closes honestly. Until someone runs that test the
#   service ports stay `allow` - a documented finding beats a throttled mirror.
#
# MACHINES DELIBERATELY ABSENT FROM THIS TABLE:
#
#   svc-mgmt-01 - MAAS opens ~30 ports (5239-5284, 3128, 8000, 53, 67/udp, 69/udp, 5353) and
#                 getting it wrong breaks PXE and deploy, which is how host-1..3 get built.
#   host-4      - it BRIDGES guest traffic over br0, and ufw's default FORWARD policy is DROP.
#                 Enabling ufw on the hypervisor can cut off every VM depending on
#                 br_netfilter. Same class of risk as MAAS, and it takes the whole enclave
#                 with it rather than one machine.
#
#   The script REFUSES on a machine it has no table for. That is the guard, not a comment.

ufw_rules() {
cat <<'EOF'
svc-repo-01	22/tcp	limit	ssh - safe to rate-limit, and what the rule is really aimed at
svc-repo-01	80/tcp	allow	nginx 301 redirect only; kept so a plaintext client gets a redirect rather than a timeout
svc-repo-01	443/tcp	allow	THE MIRROR - 318 GB of apt over TLS, plus /keys /debs /snaps /maas-images. LIMIT here throttles apt for every machine in the enclave
svc-harbor-01	22/tcp	limit	ssh
svc-harbor-01	80/tcp	allow	NO-OP under Docker - docker-proxy DNATs this, so ufw INPUT never sees it. Kept for the day Harbor runs host-network. runbook 6.3e
svc-harbor-01	443/tcp	allow	NO-OP under Docker - same reason. ufw on this host protects ssh and postfix, NOT the registry ports. Say so in the findings register
EOF
}

cmd_ufw() {
  local apply=0 me; me="$(hostname -s)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  # ufw ARRIVES WITH `usg fix` - it is not installed on a machine that has not been hardened
  # yet. Without this check, --apply swallows a "command not found" on the reset and then dies
  # on the first real rule, which reads like a script bug rather than "harden this box first".
  if ! command -v ufw >/dev/null 2>&1; then
    die "ufw is not installed on $me.
      It is installed by \`usg fix\` (the STIG profile selects package_ufw_installed and
      deliberately does NOT enable the service). So this machine has not been through the
      hardening sequence yet - do runbook 6.0 steps 4-11 first, then come back to ufw.
      Installing ufw by hand here would work, and would also mean firewalling a machine whose
      baseline audit has never been taken."
  fi

  local mine; mine="$(ufw_rules | awk -F'\t' -v m="$me" '$1==m')"
  if [ -z "$mine" ]; then
    die "no ufw rule table for '$me'.
      This machine is deliberately not covered - see the comment above ufw_rules().
      svc-mgmt-01: MAAS port list unconfirmed; breaking it breaks PXE and deploy.
      host-4:      bridges guest traffic; ufw FORWARD policy can cut off every VM.
      Add a table entry only after the port list is confirmed AND tested."
  fi

  printf '\n  ufw plan for %s\n\n' "$me"
  printf '  %-10s %-7s %s\n' PORT ACTION WHY
  printf '%s\n' "$mine" | awk -F'\t' '{printf "  %-10s %-7s %s\n", $2, $3, $4}'

  # Anything EXTERNALLY BOUND that the table does not mention is either surface to remove or
  # a rule we forgot. Say which - do not silently firewall a service into the dark.
  #
  # ONLY EXTERNALLY BOUND. The first version of this check stripped the address and kept the
  # port, so it reported 25, 53, 323, 1514 and 40249 as "will be BLOCKED" when every one of
  # them was bound to loopback - which ufw does not filter. Five false alarms in the first
  # run it ever made. A check that cries wolf is a check that gets ignored, and then the one
  # real warning goes past unread.
  local unlisted
  unlisted="$(ss -tulnH 2>/dev/null | awk '{print $5}' \
    | grep -vE '^(127\.|\[::1\])' | grep -v '%lo:' \
    | sed 's/.*:\([0-9]*\)$/\1/' | grep -E '^[0-9]+$' | sort -un \
    | while read -r pt; do
        printf '%s\n' "$mine" | awk -F'\t' '{print $2}' | cut -d/ -f1 | grep -qx "$pt" || echo "$pt"
      done | tr '\n' ' ')"
  if [ -n "${unlisted// /}" ]; then
    say ""
    warn "EXTERNALLY BOUND but NOT in the table: $unlisted"
    say "   these WILL be blocked once ufw is active. Each is either surface to remove or a"
    say "   rule that was forgotten. Identify them before applying:"
    say "     sudo ss -tulnp | grep -E \":($(echo $unlisted | tr ' ' '|'))\\b\""
  else
    say ""
    ok "every externally bound listener is covered by the table"
    say "   (loopback-only listeners are not listed - ufw does not filter lo)"
  fi

  # DOCKER BYPASSES ufw's INPUT CHAIN. If a port in the table is published by docker-proxy,
  # the ufw rule for it does nothing at all - neither allow, deny, nor limit. Saying so here
  # is the difference between "ufw is active on the registry" (true, and misleading) and a
  # statement an assessor can rely on.
  local dockered=""
  if command -v docker >/dev/null 2>&1 && pgrep -x docker-proxy >/dev/null 2>&1; then
    local tp
    for tp in $(printf '%s\n' "$mine" | awk -F'\t' '{print $2}' | cut -d/ -f1); do
      ss -tulnH 2>/dev/null | grep -qE "[:.]${tp} .*docker-proxy" && dockered="$dockered $tp"
    done
    if [ -n "${dockered// /}" ]; then
      say ""
      warn "PUBLISHED BY DOCKER, so the ufw rule is a NO-OP:$dockered"
      say "   docker-proxy DNATs these in nat/PREROUTING; the traffic traverses FORWARD via"
      say "   DOCKER-USER and never reaches ufw's INPUT chain. ufw on this host protects the"
      say "   HOST listeners (ssh, postfix) and NOT those ports."
      say "   Record that limitation in the findings register - 'ufw active' on a container"
      say "   host overstates the control without it. Filtering container ports means rules"
      say "   in the DOCKER-USER chain, which is separate work and is not ufw. runbook 6.3e"
    fi
  fi

  if [ "$apply" -eq 0 ]; then
    say ""
    say "nothing changed. re-run with --apply"
    return 0
  fi

  need_root
  # THE SSH RULE GOES IN BEFORE ENABLE, ALWAYS. Enabling a default-deny firewall over ssh
  # without an ssh rule locks you out of a headless machine - and on svc-repo-01 nothing in
  # the enclave could install the fix, because svc-repo-01 IS the source of the fix.
  printf '%s\n' "$mine" | awk -F'\t' '$2 ~ /^22\// {found=1} END {exit !found}' \
    || die "the table for $me has no rule for 22 - refusing to enable ufw"

  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null   # set_ufw_default_rule
  ufw default allow outgoing >/dev/null
  local port action why
  while IFS=$'\t' read -r _ port action why; do
    [ -n "${port:-}" ] || continue
    ufw "$action" "$port" >/dev/null || die "ufw $action $port failed"
    ok "ufw $action $port   ($why)"
  done < <(printf '%s\n' "$mine")

  ufw --force enable >/dev/null && ok "ufw enabled"
  say ""
  ufw status verbose | sed 's/^/  /'
  say ""
  warn "NOW VERIFY FROM ANOTHER MACHINE before you close this session:"
  say "   ssh from host-4, and fetch something over 443. A firewall you have not tested"
  say "   from off-box is a firewall you are guessing about."
}

case "${1:-}" in
  generate) shift; cmd_generate "$@" ;;
  fixups)   shift; cmd_fixups "$@" ;;
  preflight) shift; cmd_preflight "$@" ;;
  usb)      shift; cmd_usb "$@" ;;
  ufw)      shift; cmd_ufw "$@" ;;
  aide)     shift; cmd_aide "$@" ;;
  v1r6)     shift; cmd_v1r6 "$@" ;;
  grubpw)   shift; cmd_grubpw "$@" ;;
  audit)    shift; cmd_audit "$@" ;;
  show)     shift; cmd_show "$@" ;;
  *) printf 'usage: %s {generate|audit|show|preflight|aide {status|exclude [--apply]|init}|v1r6 [--apply|--verify]|grubpw {status|prep|set}|fixups [...]|ufw [--apply]|usb {status|enable|disable}}\n' "$0" >&2; exit 2 ;;
esac
