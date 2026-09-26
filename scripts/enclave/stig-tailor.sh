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
#     sudo ./stig-tailor.sh luksenroll        # TPM unlock via clevis (proven; runbook 6.3i.1)
#     sudo ./stig-tailor.sh radio status      # what radios this machine has
#     sudo ./stig-tailor.sh radio disable     # ... and block them
#
# EVERY SUBCOMMAND, IN THE ORDER A REBUILD RUNS THEM. The numbers are runbook section 6.0's
# hardening table. scripts/install/05-harden-host.sh runs 8b-12d in this same order under its
# own step names (step_prechecks, step_tailor, step_radio, step_grub, step_v1r6, step_verify,
# step_final_audit), except that it runs the tailored `audit` once, at the end. 12f is run
# by hand because it prompts for passwords.
#
#   8b   preflight                   READ-ONLY. What `usg fix` will remove, disable or strip
#                                    (packages, services, NOPASSWD grants) - decide each
#                                    collision BEFORE fix. runbook 6.3f
#   8c   aide status                 READ-ONLY. What AIDE would hash here, measured on disk.
#        aide exclude --apply        Seed the exclusion BEFORE `usg fix` builds the database,
#                                    or it hashes the bulk data inside the fix run. 6.3h
#   10   generate, then audit        Build the tailoring file from the INSTALLED benchmark plus
#                                    the deviations() table, and audit against it. 6.3b
#   11   fixups | --apply | --verify What `usg fix` leaves failing but could have fixed, each
#                                    fixed at the layer that owns the value. 6.3c
#   12   fixups --verify             Again after a reboot: the tmpfiles fix must survive one.
#   12b  ufw | --apply               Per-machine firewall table; REFUSES where there is
#                                    none. 6.3e
#   12b2 radio status | disable      V-270755 / UBTU-24-600230, plus Bluetooth. 6.3g.1
#   12c  grubpw prep, then set       V-270675 / UBTU-24-102000. `set` refuses until
#                                    `prep` has run. 6.3i
#   12d  v1r6 | --apply | --verify   DISA V1R6 residual `usg fix` does not touch. 10.1d
#   12f  accounts create             Second named admin + console-only emergency account.
#                                    backlog 3.15. `accounts status` proves it after the reboot
#   12e  one reboot for 12-12f, then grubpw status, v1r6 --verify, fixups --verify, audit
#
#   NOT IN THE 6.0 TABLE - run when the situation calls for it:
#   luksenroll [--method=clevis|systemd] [--force]
#                                    TPM unlock of the LUKS root, physical hosts only, after
#                                    first boot. runbook 6.3i.1, backlog 2.4
#   usb status | enable [--minutes N] | disable
#                                    host-4's logged, time-boxed USB storage window. 6.3g
#   aide init                        Rebuild the AIDE database after an exclusion change.
#                                    Hours on a large filesystem.
#   show                             Print the deviation table and its justifications.
#   accounts rotate [user]           New password; for the emergency account, after EVERY use.
#
#   AFTER EVERY PATCH CYCLE (05-harden-host.sh step_done): grubpw status before the reboot,
#   fixups --apply, v1r6 --apply, reboot, then the --verify pair. Packages revert controls.
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
# (That deviation was REMOVED 2026-09-19, backlog 3.13: MAAS was purged 2026-09-18, and a root
# check found no NOPASSWD grant anywhere and no maas account. A deviation whose cause is gone
# is a control switched off for nothing. The machine column's reason still stands.)
#
# ACTIVE. These are decided.
#
deviations() {
cat <<'EOF'
*	set-value	value_var_multiple_time_servers	__TIME_MASTER__	__STIG_ID__ / chronyd_specify_remote_server. The DISA profile pins the approved time source to 0.us.pool.ntp.mil, which is unreachable from inside the boundary BY DESIGN - reaching it would be the finding. The enclave's authoritative source is __TIME_MASTER_NAME__ (__TIME_MASTER__), a physical machine serving the enclave subnet only. The rule's INTENT - synchronise only to an organisation-approved source - is met in full; only the list of approved sources differs. This is a retarget, not an exception.
host-4	deselect	rule_chronyd_server_directive	-	__STIG_ID__ / chronyd_server_directive. THIS MACHINE IS THE ENCLAVE'S TIME MASTER, AND A MASTER IN AN AIR GAP HAS NO UPSTREAM TO POINT AT. The rule requires a `server` directive naming an authorised time source. host-4 has none by design: `time-sync.sh master` gives it `local stratum 5` and `allow 10.2.20.0/24`, so it serves the enclave subnet from its own hardware clock. Every OTHER machine carries `server 10.2.20.158 iburst maxpoll 16` and passes this rule unmodified - the hierarchy is real and measured: `chronyc sources` on svc-repo-01 shows `^* host-4` with reach 377. THE ALTERNATIVE WOULD BE WORSE. Pointing the master at a public pool it cannot reach produces a machine that never synchronises while appearing configured, which is the failure mode this rule exists to prevent. AND THE CHECK IS NOT ABANDONED: `time-sync.sh status` verifies the master is serving and that every client is actually locked to it, which is a stronger test than the presence of a directive. Scoped to host-4 only; if the time master moves, this deviation moves with it.
host-4	deselect	rule_chronyd_specify_remote_server	-	__STIG_ID__ / chronyd_specify_remote_server. Same cause as chronyd_server_directive above, and the same scope. The `*` set-value deviation in this table already retargets value_var_multiple_time_servers to __TIME_MASTER__ so that every CLIENT passes by naming the enclave's authoritative source instead of DISA's 0.us.pool.ntp.mil. That retarget cannot help the master itself, which would have to name itself as its own remote server. The intent - synchronise only to an organisation-approved source - is met in full across the enclave; the master is the source.
*	deselect	rule_file_groupowner_system_journal	-	__STIG_ID__ / file_groupowner_system_journal. THIS RULE CONFLICTS WITH UBTU-24-700020, WHICH IS ALSO IN THIS PROFILE. 700020 requires the journal DIRECTORIES at 640 or less permissive, and the scanner implements that as `find -perm /7137` - which includes the SETGID bit (verified: 0640 passes, 2640 fails, systemd's own 2750 fails). Setgid on the directory is exactly what made journald create new files owned by group systemd-journal. Removing it, as 700020 requires, makes journald write new files with the creating process's group, which is root. The two controls cannot both be continuously satisfied. MEASURED: DISA's complete FixText (the four-line /etc/tmpfiles.d/zzz-systemd-stig.conf) corrects existing files at every boot and every systemd-tmpfiles run, and a journal rotation immediately produces new root-group files again. THE RESULT IS THEREFORE NON-DETERMINISTIC - it passes or fails depending on how long since the last tmpfiles run, which is why it failed on svc-obs-01 at 02:34 and passed on svc-repo-01 the same day. WHAT WE ACTUALLY HAVE IS STRICTER THAN THE RULE ASKS: root:root 0640 is readable by root alone; root:systemd-journal 0640 is readable by every member of that group. AND THE CHECK IS NOT ABANDONED - `stig-tailor.sh v1r6` verifies this on every run and FAILS on any journal file that is neither systemd-journal nor root at 0640-or-tighter, which is a stronger check than the rule performs. Full write-up and the measurements: runbook 10.1.
*	deselect	rule_display_login_attempts	-	__STIG_ID__ / display_login_attempts. THE MODULE IT REQUIRES DOES NOT EXIST ON UBUNTU 24.04, AND THE LINE IT WRITES BREAKS EVERY CONSOLE LOGIN. The fix adds `session required pam_lastlog.so showfailed` to /etc/pam.d/login. libpam-modules 1.5.3-5ubuntu5.7 ships no pam_lastlog.so and no package in the noble archive provides one (checked on all eight machines and against the enclave mirror, 2026-09-23), so a REQUIRED session module that cannot load fails the session AFTER the password is accepted - "Module is unknown" and straight back to login:, for every account including the break-glass account. SSH is unaffected because its PAM stack does not include that line, which is why this went unseen from the first `usg fix` until the break-glass console test on svc-obs-01. DISA has already dropped the requirement: UBTU-24-300024 has no row in the V1R6 checklist; the usg stig-v1r1 profile predates that. Deselecting stops `usg fix` re-adding the line; `fixups` item 8 removes the one already written. Backlog 3.28.
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
# RUNBOOK 6.0 STEP 10 (05-harden-host.sh step_tailor). Writes $OUT (/etc/usg/enclave-
# tailoring.xml by default): usg's own generated tailoring for $PROFILE with each deviation
# from deviations() applied in place and its WHY carried as an XML comment. Root, because it
# writes under /etc/usg. Safe to re-run - it regenerates from whatever benchmark is installed.
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
      # A DOUBLE HYPHEN CANNOT APPEAR INSIDE AN XML COMMENT. Any justification that cites a
      # long option - `journalctl --rotate`, `find --version` - makes the whole tailoring file
      # unparseable, and the failure surfaces as a parser error 300 lines into a temp file
      # rather than as "your text is wrong". Space them here so the justification can be
      # written in plain English. Caught 2026-09-14 by the xmllint gate below, which is the
      # only reason this did not ship a broken profile.
      while (index(w, "--") > 0) gsub(/--/, "- -", w)
      # A comment also cannot END with a hyphen - "- ->" closes it one character early.
      sub(/-+$/, "", w)
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
# RUNBOOK 6.0 STEP 10, and the FINAL audit after the last reboot (05-harden-host.sh
# step_final_audit). `usg audit` against the tailoring file, so deviations are scored as
# tailored rather than as failures. That result is the AFTER half of the evidence pair; the
# BEFORE half is the untailored baseline audit taken at step 7.
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
# READ-ONLY, no root. Prints deviations() with its machine scope, value and justification -
# the answer to an assessor's "what did you tailor, where, and why" without opening the XML.
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
#
# WHERE IT RUNS: runbook 6.0 step 11 (plan, --apply, --verify) and step 12 (--verify again
# after a reboot); 05-harden-host.sh step_tailor runs --apply then --verify. Every item is
# idempotent, which is what makes it the post-patch re-assert as well as a build step.
#
# THE ITEMS, IN THE ORDER --apply RUNS THEM (the plan prints 0-8 first, then 0b-0d):
#   0c  /usr/bin/journalctl to 740 - UBTU-24-700030; a systemd upgrade restores 755
#   0d  journal machine-id directories back to 0640 - UBTU-24-700020
#   0b  disable sssd / openipmi / fwupd-refresh where each provably has nothing to serve
#   0a  /etc/ssh/ssh_config.d/*.conf back to 0644 - usg leaves them 0600 and ssh-out breaks
#   0   evict backups and stray files from /etc/logrotate.d, which parses them as config
#   1   wtmp/btmp/lastlog modes via a tmpfiles override - file_permissions_var_log_stig
#   2   apt logs: logrotate `create` line + a dpkg Post-Invoke hook - same rule
#   2b  sysstat UMASK, then DISA's find/chmod over /var/log - V-270756 / UBTU-24-700010
#   2c  `create 0640 root adm` for the root-written logrotate stanzas - V-270756
#   3   /var/log group syslog - file_groupowner_var_log (needs rsyslog: --with-rsyslog)
#   4   rsyslog daemon.* selector, plus rotation for every rsyslog destination -
#       rsyslog_remote_access_monitoring; `su` and `maxsize` so rotation actually runs
#   5   postfix inet_interfaces = loopback-only (usg installs it listening on 0.0.0.0:25)
#   6   sudo passwd_tries=1 - one faillock strike per sudo invocation, not three (6.3m)
#   7   audit allocation sized from THIS machine's measured rate - V-270816
#   8   comment out the pam_lastlog line that breaks every console login - backlog 3.28

VARCONF_SRC=/usr/lib/tmpfiles.d/var.conf
VARCONF_DST=/etc/tmpfiles.d/var.conf
APT_LOGROTATE=/etc/logrotate.d/apt
# sysstat writes a NEW accounting file every day and a summary every night, and it takes the
# mode from its own UMASK setting - not from logrotate, and not from anything usg touches.
SYSSTAT_CONF=/etc/sysstat/sysstat
SYSSTAT_UMASK="${STIG_SYSSTAT_UMASK:-0027}"
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

# Is a PAM module actually installed? PAM searches the multiarch directory; check the usual
# places rather than one path, so a merged-/usr or non-x86 layout does not read as "missing".
pam_module_present() {
  local d
  for d in /lib/x86_64-linux-gnu/security /usr/lib/x86_64-linux-gnu/security /lib/security /usr/lib/security; do
    [ -e "$d/$1" ] && return 0
  done
  return 1
}
PAM_LOGIN=/etc/pam.d/login
pam_lastlog_line() { grep -nE '^[[:space:]]*session[[:space:]].*pam_lastlog\.so' "$PAM_LOGIN" 2>/dev/null || true; }

# `fixups` with no flag. PLAN ONLY: measures each item's state on THIS machine and prints the
# fix it would make. Changes nothing and needs no root, though root-only files (auditd.conf)
# then read as unreadable rather than as a state.
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

  printf '\n  2b. file_permissions_var_log_stig - sysstat writes a new 0644 file every day\n'
  say "   THE ENCLAVE'S ANSWER TO THIS RULE IS TO PURGE sysstat, decided 2026-09-16:"
  say "     node-exporter already publishes CPU, disk, memory and load, so the package earns"
  say "     nothing and its files re-open this control every single day. host-4 was purged"
  say "     then; host-1/2/3 followed on 2026-09-18 once node-exporter reached them."
  say "   This fixup is the FALLBACK for a machine where sysstat must stay:"
  say "   owner of the value: UMASK in $SYSSTAT_CONF, which ships as 0022"
  say "   fix: UMASK=$SYSSTAT_UMASK there, then DISA's own find/chmod once over /var/log"
  say "   why it matters: this control PASSED on host-1/2/3 on 2026-09-17 and re-opened by"
  say "        itself overnight - sa<DD> is written every 10 minutes and sar<DD> at 23:53."
  say "        A chmod cannot hold a value another program sets on a schedule."
  if [ -f "$SYSSTAT_CONF" ]; then
    say "   state: UMASK=$(awk -F= '/^[[:space:]]*UMASK=/{print $2; exit}' "$SYSSTAT_CONF" 2>/dev/null || echo '<unset>')"
  else
    say "   state: sysstat not installed here"
  fi

  printf '\n  2c. file_permissions_var_log_stig - logrotate recreates files world-readable\n'
  say "   THIS, not sysstat, is what keeps re-opening V-270756. Purging sysstat on host-1/2/3"
  say "   removed two offenders and FOUR more appeared, two created by libvirt an hour earlier."
  local _lr_bad="" _lr_none="" _lr_f
  for _lr_f in /etc/logrotate.d/*; do
    [ -f "$_lr_f" ] || continue
    grep -q "/var/log" "$_lr_f" 2>/dev/null || continue
    if grep -qE "^[[:space:]]*create[[:space:]]+0?64[4-7]" "$_lr_f" 2>/dev/null; then
      _lr_bad="$_lr_bad $(basename "$_lr_f")"
    elif ! grep -qE "^[[:space:]]*create[[:space:]]" "$_lr_f" 2>/dev/null; then
      _lr_none="$_lr_none $(basename "$_lr_f")"
    fi
  done
  say "   recreate world-readable ON PURPOSE:${_lr_bad:- none}"
  say "   no 'create' line, so the daemon's umask decides:${_lr_none:- none}"
  say "   fix: 'create $LOGMODE root adm' on the four whose writer is ROOT -"
  say "        alternatives, dpkg, ubuntu-pro-client, unattended-upgrades"
  say "   NOT touched: rsyslog (writes as syslog), chrony (_chrony), sssd. Without a create"
  say "        line the DAEMON makes the file on reopen, so forcing root:adm onto a non-root"
  say "        writer breaks its logging outright. Adding a package to that list is a"
  say "        decision about its writer, not a mechanical edit."
  say "   also: /var/log/libvirt/{qemu,lxc}/.placeholder arrive 0644 and no package owns them"

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

  printf '\n  6. sudo passwd_tries - one faillock strike per invocation, not three\n'
  if [ -f /etc/sudoers.d/99-stig-passwd-tries ]; then
    say "   state: already set ($(grep -h passwd_tries /etc/sudoers.d/99-stig-passwd-tries 2>/dev/null))"
  else
    say "   state: NOT set - sudo allows 3 attempts per invocation and faillock is deny=3,"
    say "          so ONE fumbled password locks the only admin account, permanently"
    say "          (unlock_time=0). faillock is 'silent', so it looks like a typo."
    say "   fix: /etc/sudoers.d/99-stig-passwd-tries with 'Defaults passwd_tries=1'"
    say "        deny=3 is unchanged - the STIG control is untouched. Validated with visudo"
    say "        on a temp file BEFORE install, and the whole set re-checked after."
  fi

  printf '\n  7. V-270816 - the audit allocation must hold a WEEK at THIS machine rate\n'
  say "     auditd ships max_log_file=8 x num_logs=5 = 40MB. That is a fixed number on a"
  say "     machine whose audit rate is not fixed - measured 2026-09-22, host-1 wrote"
  say "     39.3MB in 37.6h (~25MB/day), so 40MB held 1.6 DAYS against a 7-day control,"
  say "     with 19GB free on the volume. svc-mgmt-01 once ran 176x svc-harbor-01's rate."
  if [ -r /etc/audit/auditd.conf ]; then
    local pm pn ph ps
    pm="$(awk -F= '/^max_log_file[[:space:]]*=/{gsub(/ /,"",$2); print $2}' /etc/audit/auditd.conf | head -1)"
    pn="$(awk -F= '/^num_logs[[:space:]]*=/{gsub(/ /,"",$2); print $2}' /etc/audit/auditd.conf | head -1)"
    ph="$(stat -c %s /var/log/audit/audit.log* 2>/dev/null | awk '{t+=$1} END{print t+0}')"
    ps="$(stat -c %Y /var/log/audit/audit.log* 2>/dev/null | sort -n | awk 'NR==1{f=$1} {l=$1} END{print (l-f)+0}')"
    if [ "${ps:-0}" -ge 3600 ] && [ "${ph:-0}" -gt 0 ]; then
      say "   state: allocation $(( ${pm:-0} * ${pn:-0} ))MB, measured $(( ph * 86400 / ps / 1048576 ))MB/day over $(( ps / 3600 ))h"
    else
      say "   state: allocation $(( ${pm:-0} * ${pn:-0} ))MB, not enough history to measure a rate yet"
    fi
  else
    say "   state: /etc/audit/auditd.conf not readable as this user"
  fi
  say "   fix: size max_log_file x num_logs from the MEASURED rate (a week, doubled), only"
  say "        when the volume has room for twice that, then SIGHUP auditd. It refuses a"
  say "        manual restart, and killing it would drop records."
  say "   NOT this: audit OFFLOAD (V-270817) still needs the collector and three AO answers."

  printf '\n  8. pam_lastlog - a REQUIRED module that does not exist breaks every console login\n'
  local pll; pll="$(pam_lastlog_line)"
  if [ -z "$pll" ]; then
    say "   state: no pam_lastlog line in $PAM_LOGIN - nothing to do"
  elif pam_module_present pam_lastlog.so; then
    say "   state: line present AND pam_lastlog.so installed - left alone"
  else
    say "   state: $PAM_LOGIN line $pll"
    say "          pam_lastlog.so is NOT installed. The session fails after the password is"
    say "          accepted: 'Module is unknown', back to login:. SSH is unaffected; the"
    say "          CONSOLE - the break-glass and at-the-rack path - is dead for every account."
    say "   fix: comment the line out (backup kept). usg wrote it; the tailoring now deselects"
    say "        display_login_attempts so the next usg fix does not put it back."
  fi

  # ITEMS 0b-0d RUN ON --apply AND WERE NEVER LISTED HERE. Found 2026-09-20 reading this plan
  # on svc-mgmt-01: the numbered list above starts at 1, `fixups_plan` returns before the 0*
  # items, and the operator therefore approved a change set that was not the change set. The
  # state is measured here rather than described, so the line is true on the machine reading it.
  printf '\n  ALSO ON --apply, and not numbered above:\n'
  local f0b="" svc
  for svc in sssd openipmi fwupd-refresh; do
    case "$(systemctl is-enabled "$svc" 2>/dev/null)" in
      # `|| true` IS LOAD-BEARING: is-active EXITS 3 for an inactive unit, and under set -e that
      # ended the whole plan here, silently, before 0b-0d and the "nothing changed" line printed
      # (found 2026-09-25 on stage-01; a fresh build, where these units are not yet disabled,
      # would hit it at runbook 6.0 step 11).
      enabled|enabled-runtime|static) f0b="$f0b $svc($(systemctl is-active "$svc" 2>/dev/null || true))" ;;
    esac
  done
  printf '     0b. disable units with nothing to serve, PROVEN case by case - no domain for sssd,\n'
  printf '         no /dev/ipmi* for openipmi, no route for fwupd-refresh. Packages stay installed.\n'
  printf '         state: enabled here:%s\n' "${f0b:- none}"
  printf '     0c. re-set the controls a package upgrade reverts and only `usg fix` ever set\n'
  printf '     0d. /var/log/journal/<machine-id> to 0640, and %s so a REBOOT keeps it there\n' "$JOURNAL_MID_TMPFILES"
  printf '\n  nothing above has been changed. re-run with --apply\n\n'
}

# `fixups --apply` (root) makes the changes, item by item, each reporting for itself;
# `fixups --verify` hands off to fixups_verify(); no flag prints the plan.
# --with-rsyslog allows item 3 to install rsyslog from the enclave mirror.
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

  # ---- 0c. CONTROLS A PACKAGE UPGRADE REVERTS, THAT ONLY `usg fix` EVER SET -------------
  #
  # MEASURED ON host-1, 2026-09-17: a 185-package upgrade took a fully hardened machine from
  # 213 pass / 3 fail back to 211/5. `/usr/bin/journalctl` was 755 with the PACKAGE's July
  # mtime - dpkg had replaced it and restored the archive's file, discarding the mode that
  # `usg fix` set during hardening.
  #
  # THE REAL PROBLEM IS NOT THE MODE, IT IS THAT NOTHING COULD PUT IT BACK. `usg fix` is the
  # only thing that ever set it, and runbook §6.0 step 9 says explicitly do NOT re-run `fix`.
  # So a routine patch cycle silently un-hardened the machine and the only documented remedy
  # was one the procedure forbids. A control that can only be applied once is not a control,
  # it is a coincidence that held for a while.
  #
  # So `fixups` owns it now: idempotent, re-assertable after every patch, and part of the
  # post-patch sequence rather than a one-time act during the build.
  local jc=/usr/bin/journalctl
  if [ -x "$jc" ]; then
    local jcmode; jcmode="$(stat -c %a "$jc" 2>/dev/null)"
    case "$jcmode" in
      *[0-7][0-7])
        # Non-root must not be able to run it. 0750 keeps root and the owning group.
        case "$jcmode" in
          740) ok "journalctl is 740 - UBTU-24-700030 satisfied" ;;
          *)
            # DISA'S OWN REMEDIATION, VERBATIM, NOT A NUMBER SOMEBODY DERIVED.
            #
            # UBTU-24-700030's CheckText is explicit: "Verify that the journalctl command has
            # a permission set of 740 ... If journalctl is not set to 740, this is a finding."
            # Its fix is `chmod u-s,g-xws,o-xwrt`, which takes 755 to exactly 740.
            #
            # The first version of this used 0750 because it looked reasonable. It is wrong by
            # one bit - group execute - and the rule kept failing on two machines while the
            # output claimed success. Reading the rule took one command; guessing at it took
            # three rounds. Use the vendor's expression so the intent survives even if the
            # numeric target ever changes.
            if chmod u-s,g-xws,o-xwrt "$jc"; then
              ok "journalctl was $jcmode, now $(stat -c %a "$jc") - UBTU-24-700030 (DISA's own chmod)"
              say "     a systemd upgrade restores this to 755 EVERY TIME. This runs after every patch."
            else
              warn "could not chmod $jc"; failed=$((failed+1))
            fi ;;
        esac ;;
    esac
  fi

  # ---- 0d. THE JOURNAL'S PER-MACHINE-ID DIRECTORY, which journald resets ---------------
  #
  # MEASURED 2026-09-17. `dir_permissions_system_journal` (UBTU-24-700020) failed on host-1
  # and host-2 and PASSED on host-3, with identical file permissions on all three. The
  # difference was one directory nobody was looking at:
  #
  #   host-1  /var/log/journal/<machine-id>  2755   <- journald's default, setgid back
  #   host-3  /var/log/journal/<machine-id>  640
  #
  # journald recreates that subdirectory with its own default after a systemd upgrade and
  # restart. The declared fix already exists - `Z /var/log/journal/%m ~0640` in the tmpfiles
  # config v1r6 writes - so the remedy is to RE-APPLY THE DECLARATION rather than chmod by
  # hand. systemd-tmpfiles is idempotent and is the mechanism that owns this path.
  #
  # AND NOTE WHY IT WENT UNNOTICED: `v1r6 --verify` checks /var/log/journal and
  # /run/log/journal and reported 0640 on both - correctly - while never looking at the %m
  # subdirectory that the rule evaluates. A verify that misses the object under test reads
  # exactly like a pass.
  # FIRST, THE DECLARATION THAT HOLDS ACROSS A REBOOT - see JOURNAL_MID_TMPFILES. Without it
  # this item repaired the directory until the next boot put it back (host-1/2, 2026-09-24).
  if ! grep -qxF "$JOURNAL_MID_LINE" "$JOURNAL_MID_TMPFILES" 2>/dev/null; then
    printf '%s\n' \
      "# UBTU-24-700020 - the machine-id journal directory. Written by stig-tailor.sh fixups 0d." \
      "# A same-type 'z' line, so it overrides /usr/lib/tmpfiles.d/systemd.conf's" \
      "# 'z /var/log/journal/%m 2755' at boot. DISA's 'Z ... ~0640' alone loses (measured 2026-09-25)." \
      "$JOURNAL_MID_LINE" > "$JOURNAL_MID_TMPFILES"
    chmod 0644 "$JOURNAL_MID_TMPFILES"
    ok "0d. wrote $JOURNAL_MID_TMPFILES - the machine-id journal dir now stays 0640 across reboots"
  fi
  local jdir bad_jdir=0
  for jdir in /var/log/journal/* /run/log/journal/*; do
    [ -d "$jdir" ] || continue
    case "$(stat -c %a "$jdir" 2>/dev/null)" in
      640|600|0640|0600) : ;;
      *) bad_jdir=1 ;;
    esac
  done
  if [ "$bad_jdir" -eq 1 ]; then
    # TARGET OUR OWN FILE, NOT A GLOBAL --create. MEASURED on host-1 2026-09-17:
    #
    #   systemd-tmpfiles --create                          -> directory stays 2755
    #   systemd-tmpfiles --create <our stig conf>          -> directory becomes 640
    #
    # The vendor config is the reason: /usr/lib/tmpfiles.d/systemd.conf carries
    # `z /var/log/journal/%m 2755 root systemd-journal`, which directly contradicts our
    # `Z /var/log/journal/%m ~0640`. Basename ordering says ours should run last and win
    # (systemd.conf < zzz-...), and on a global run it does not. I am not going to assert a
    # mechanism I have not proven - the targeted call demonstrably works and the global one
    # demonstrably does not, and that is enough to make the fix correct.
    # `|| true` IS LOAD-BEARING. Without it this line ENDS THE SCRIPT on a machine that has no
    # stig tmpfiles config yet: the glob matches nothing, `ls` exits 2, `pipefail` propagates it
    # past `head`, and `set -e` kills the run - with NO MESSAGE, immediately after the journalctl
    # line above. Measured on the freshly rebuilt host-3, 2026-09-21: hardening stopped dead at
    # step 8 and `tailor` was never marked done. Every host built before that survived only
    # because it already had the file from an earlier hand-run, so a clean build had never once
    # exercised this path. Same shape as the `df` crash in 03-compose-vm.sh the day before.
    local jtf; jtf="$(find /etc/tmpfiles.d -maxdepth 1 -name '*stig*.conf' 2>/dev/null | sort | head -1 || true)"
    if [ -z "$jtf" ]; then
      # NOT counted as a failure during a first build: `v1r6 --apply` writes this file at
      # hardening step 12 and re-applies it, which is four steps after this one runs. Saying
      # "run v1r6 first" and failing would stop a sequence that is already going to fix it.
      # The gap is not hidden either way - `fixups --verify` re-checks the directories.
      say "no stig tmpfiles config in /etc/tmpfiles.d yet - the journal machine-id directories"
      say "     stay at journald's default until 'v1r6 --apply' writes it (hardening step 12)."
    elif systemd-tmpfiles --create "$jtf" "$JOURNAL_MID_TMPFILES" >/dev/null 2>&1; then
      local still=0
      for jdir in /var/log/journal/* /run/log/journal/*; do
        [ -d "$jdir" ] || continue
        case "$(stat -c %a "$jdir" 2>/dev/null)" in 640|600|0640|0600) : ;; *) still=1 ;; esac
      done
      if [ "$still" -eq 0 ]; then
        ok "journal machine-id directories re-tightened to 0640 via $jtf"
        say "     journald and the systemd package both reset these to 2755. UBTU-24-700020."
        say "     A GLOBAL 'systemd-tmpfiles --create' does NOT fix it - the vendor config"
        say "     contradicts ours. The file has to be named explicitly."
      else
        warn "systemd-tmpfiles ran but a journal directory is still more permissive than 0640:"
        for jdir in /var/log/journal/* /run/log/journal/*; do
          [ -d "$jdir" ] && printf '       %s %s\n' "$jdir" "$(stat -c %a "$jdir")" >&2
        done
        warn "  is the 'Z /var/log/journal/%m ~0640' line present in /etc/tmpfiles.d? v1r6 --apply writes it"
        failed=$((failed+1))
      fi
    else
      warn "systemd-tmpfiles --create failed"; failed=$((failed+1))
    fi
  else
    ok "journal machine-id directories are 0640 or stricter"
  fi

  # ---- 0b. SERVICES usg fix LEAVES PERMANENTLY FAILED ---------------------------------
  #
  # FOUND 2026-09-17 on host-1, then measured on ALL FIVE existing machines: every hardened
  # machine in this enclave has been carrying TWO permanently failed units since the day it
  # was hardened, and nothing reported it.
  #
  #   sssd.service          "SSSD couldn't load the configuration database: No domain is enabled"
  #   openipmi.service      no IPMI device to talk to
  #   fwupd-refresh.service firmware metadata from the internet, with no default route
  #
  # Neither is a defect in the machine - they are services with nothing to serve. `usg fix`
  # installs and enables them because the STIG wants the PACKAGES present (pam_sss, nss_sss),
  # and a package being present is not the same as a daemon having a job. An air-gapped
  # enclave has no directory service, and none of this hardware has a BMC.
  #
  # A permanently failed unit is not cosmetic. It trains the operator to ignore
  # `systemctl --failed`, which is the one place a REAL failure would show up - and it is the
  # exact reason MAAS sat broken for seven days while `is-active` said healthy.
  #
  # DISABLE ONLY WHERE THERE IS GENUINELY NOTHING TO SERVE, and prove it each time rather
  # than assuming: sssd only when no domain is configured, openipmi only when no ipmi device
  # exists. A site WITH a directory or a BMC must keep them, so this can never be a blanket
  # disable. Packages stay installed, so the STIG rules that want them still pass.
  local svc cond
  for svc in sssd openipmi fwupd-refresh; do
    case "$(systemctl is-enabled "$svc" 2>/dev/null)" in
      enabled|enabled-runtime|static) : ;;
      *) continue ;;
    esac
    cond=""
    case "$svc" in
      sssd)
        # TEST WHAT SSSD ITSELF TESTS. The first version of this checked for a
        # [domain/<name>] SECTION and therefore reported "has something to serve" on host-1
        # while sssd was still failing with "No domain is enabled" - because `usg fix` writes
        # the section and never lists it. A section that is not named in `domains=` is inert,
        # which is exactly what sssd's own error message says.
        #
        # So the condition is a NON-EMPTY `domains=` under [sssd]. That is the thing that
        # enables a domain, and matching sssd's own wording is why this is now correct.
        if ! grep -rqsE '^[[:space:]]*domains[[:space:]]*=[[:space:]]*[^[:space:]]' \
               /etc/sssd/sssd.conf /etc/sssd/conf.d/ 2>/dev/null; then
          cond="no non-empty 'domains=' in /etc/sssd - a [domain/...] section alone is inert, which is what sssd means by 'No domain is enabled'"
        fi ;;
      openipmi)
        if [ ! -e /dev/ipmi0 ] && [ ! -e /dev/ipmi/0 ] && [ ! -e /dev/ipmidev/0 ]; then
          cond="no IPMI device present - this hardware has no BMC"
        fi ;;
      fwupd-refresh)
        # It downloads firmware metadata from the internet. THE ENCLAVE HAS NO DEFAULT ROUTE,
        # by design (enclave-addresses.env: MAAS hands out no `option routers`), so this is
        # not a service that is failing - it is a service that cannot possibly succeed.
        #
        # Found on host-1 and host-2 2026-09-17. host-3 showed zero failed units only because
        # its timer had not fired yet; it would have joined them. That is the shape of every
        # one of these: a unit that fails on a schedule looks fine until the schedule comes
        # round, and by then nobody is watching that machine any more.
        if [ -z "$(ip route show default 2>/dev/null)" ]; then
          cond="no default route - firmware metadata cannot be fetched from an air gap"
        fi ;;
    esac
    if [ -z "$cond" ]; then
      ok "$svc has something to serve - leaving it enabled"
      continue
    fi
    if systemctl disable --now "$svc" >/dev/null 2>&1; then
      # RESET THE RECORDED FAILURE TOO. `disable --now` stops the unit and prevents it
      # starting again, but the LAST FAILURE stays recorded - so `systemctl --failed` keeps
      # listing it until someone reboots. Measured on host-1 2026-09-17: sssd reported
      # "disabled" and still appeared in --failed on the very next line.
      #
      # That matters more than it looks. The whole reason for disabling these is that a
      # permanently listed failure trains the operator to ignore `systemctl --failed`, which
      # is the one place a real failure shows up. Leaving the stale entry defeats the fix.
      systemctl reset-failed "$svc" >/dev/null 2>&1 || true
      ok "$svc disabled and its failed state cleared - $cond"
      say "     the package stays installed, so the STIG rule that wants it still passes"
    else
      warn "could not disable $svc - it will keep appearing in systemctl --failed"
      failed=$((failed+1))
    fi
  done

  # ---- 0a. REPAIR THE SSH CLIENT that `usg fix` breaks ---------------------------------
  #
  # FOUND 2026-09-17 ON host-4, latent since its hardening on 09-11. `ssh` as any non-root
  # user died before connecting:
  #
  #   Can't open user config file /etc/ssh/ssh_config.d/00-cipher-list.conf: Permission denied
  #   /etc/ssh/ssh_config: terminating, 1 bad configuration options
  #
  # TWO STIG CONTROLS COLLIDING, and neither is wrong alone. The SSG remediation for the ssh
  # client cipher and MAC lists creates drop-ins in /etc/ssh/ssh_config.d/ and never chmods
  # them - so under the `umask 077` the STIG itself mandates, they land 0600 root:root. The
  # tell is that /etc/ssh/ssh_config beside them is 0644, shipped that way by openssh-client.
  #
  # sshd is unaffected: it runs as root and reads sshd_config, which SHOULD be 0600. Only the
  # CLIENT breaks, and only for unprivileged users - so nothing fails on the way in and the
  # machine looks fine. It stays broken until somebody tries to ssh OUT as themselves.
  #
  # No SSG rule wants these restricted. 0644 is correct: the content is a public algorithm
  # list and every user who runs ssh must read it.
  local sshcfg n_sshfix=0
  for sshcfg in /etc/ssh/ssh_config.d/*.conf; do
    [ -e "$sshcfg" ] || continue
    local mode; mode="$(stat -c %a "$sshcfg" 2>/dev/null || echo '')"
    case "$mode" in
      *4|*5|*6|*7) : ;;                      # already world-readable
      '') : ;;
      *) if chmod 0644 "$sshcfg"; then
           ok "ssh client config readable again: $sshcfg was $mode, now 0644"
           n_sshfix=$((n_sshfix+1))
         else
           warn "could not chmod $sshcfg"; failed=$((failed+1))
         fi ;;
    esac
  done
  if [ "$n_sshfix" -gt 0 ]; then
    # PROVE IT. A chmod that reports success and leaves the client broken is the case this
    # exists to catch - and `ssh -G` parses the whole config without connecting anywhere.
    if su -s /bin/sh -c 'ssh -G localhost >/dev/null 2>&1' "${SUDO_USER:-nobody}" 2>/dev/null; then
      ok "verified: the ssh client parses its configuration as ${SUDO_USER:-an unprivileged user}"
    else
      warn "chmod applied but the ssh client still will not parse. Run as a normal user:"
      warn "  ssh -G localhost"
    fi
  else
    ok "ssh client configs already readable - nothing to repair"
  fi

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
  # file_permissions_var_log_stig. An existing /etc copy is left alone, never overwritten;
  # `fixups --verify` reports how far it has drifted from the vendor file instead.
  if [ ! -f "$VARCONF_SRC" ]; then
    warn "1. $VARCONF_SRC does not exist - has the layout changed? SKIPPED"
    failed=1
  elif [ -f "$VARCONF_DST" ]; then
    say "1. $VARCONF_DST exists - leaving it alone. Edit it by hand or remove it first."
  else
    install -d -m 0755 /etc/tmpfiles.d
    # The WHOLE vendor file, with only the mode column of the three `f` lines rewritten.
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
    # Apply the new modes now instead of waiting for the next boot to do it.
    systemd-tmpfiles --create 2>/dev/null || warn "   systemd-tmpfiles --create reported an issue"
  fi

  # ---- 2. logrotate for apt, then the existing files ------------------------------------
  if grep -q '^[[:space:]]*create ' "$APT_LOGROTATE" 2>/dev/null && [ -f "$APT_HOOK" ]; then
    say "2. $APT_LOGROTATE has a 'create' line and $APT_HOOK exists - nothing to do"
  elif grep -q '^[[:space:]]*create ' "$APT_LOGROTATE" 2>/dev/null; then
    say "2. $APT_LOGROTATE already has a 'create' line - adding the missing apt hook below"
  elif [ -f "$APT_LOGROTATE" ]; then
    backup_file "$APT_LOGROTATE"; local aptbak="$LAST_BACKUP"
    # Add `create $LOGMODE root adm` after each stanza's `rotate 12` - the anchor is Ubuntu's
    # stock apt stanza, which has one per log (history.log, term.log).
    sed -i -E "s/^([[:space:]]*)rotate 12$/\1rotate 12\n\1create $LOGMODE root adm/" "$APT_LOGROTATE"
    # COUNT WHAT THE EDIT DID, do not assume it (backlog 3.31 #4). The anchor is the exact
    # line `rotate 12`; a stanza with any other rotate count matches nothing, sed exits 0, and
    # this used to report "added" regardless. Every stanza (one `rotate` line each) must now
    # carry a `create` line - item 2c counts the same way.
    local n_rot n_cre
    n_rot="$(grep -cE '^[[:space:]]*rotate[[:space:]]' "$APT_LOGROTATE" || true)"
    n_cre="$(grep -cE '^[[:space:]]*create[[:space:]]' "$APT_LOGROTATE" || true)"
    if [ "${n_cre:-0}" -lt "${n_rot:-0}" ] || [ "${n_cre:-0}" -eq 0 ]; then
      cp -a "$aptbak" "$APT_LOGROTATE"
      warn "2. only ${n_cre:-0} of ${n_rot:-0} stanza(s) got a 'create' line - the 'rotate 12' anchor"
      warn "   did not match them all. REVERTED. Add 'create $LOGMODE root adm' to each stanza by hand."
      failed=1
    # Validated through $LOGROTATE_MAIN - see logrotate_config_ok() for why testing a
    # fragment on its own is the wrong thing to test.
    elif ! logrotate_config_ok; then
      cp -a "$aptbak" "$APT_LOGROTATE"
      warn "2. logrotate rejected the edit - REVERTED. Its output:"
      printf '%s\n' "$LOGROTATE_OUT" | sed 's/^/       /'
      failed=1
    else
      ok "2. added 'create $LOGMODE root adm' to all $n_cre stanza(s) of $APT_LOGROTATE (backup: $aptbak)"
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

  # ---- 2b. sysstat RE-CREATES A 0644 FILE EVERY DAY -------------------------------------
  #
  # V-270756 / UBTU-24-700010 fails on any file under /var/log matching `find -perm /137`.
  # sysstat's collector writes /var/log/sysstat/sa<DD> every ten minutes and sa2 writes
  # sar<DD> at 23:53, both with the mode implied by UMASK in its own config, which ships as
  # 0022 - so 0644.
  #
  # THE PREFERRED ANSWER IS TO PURGE THE PACKAGE, not to run this fixup. Decided 2026-09-16
  # for host-4 and applied to host-1/2/3 on 2026-09-18: node-exporter already publishes what
  # sysstat collects, so the package earns nothing and its files re-open the control daily.
  # This code stays because it is the right fix for any machine that genuinely needs sysstat,
  # and because a machine can arrive with it installed. Where the package is absent it says so
  # and does nothing.
  #
  # MEASURED ON host-1 2026-09-18, and it is the clearest possible demonstration of why a
  # chmod is not a fix:
  #
  #     -rw-r-----  sa17     <- chmod'd to 0640 at 23:50 on the 17th
  #     -rw-r--r--  sar17    <- written 00:07 on the 18th, back to 0644
  #     -rw-r--r--  sa18     <- written 00:20 on the 18th, back to 0644
  #
  # The control had PASSED on all three hosts the day before and re-opened overnight with no
  # change to the machine. It will re-open every single day until the value is fixed where
  # the file is created. That is this file, and it is one line.
  if [ -f "$SYSSTAT_CONF" ]; then
    local cur_um; cur_um="$(awk -F= '/^[[:space:]]*UMASK=/{print $2; exit}' "$SYSSTAT_CONF" 2>/dev/null)"
    if [ "$cur_um" = "$SYSSTAT_UMASK" ]; then
      say "2b. $SYSSTAT_CONF already has UMASK=$SYSSTAT_UMASK"
    else
      backup_file "$SYSSTAT_CONF"
      if grep -qE '^[[:space:]]*UMASK=' "$SYSSTAT_CONF"; then
        sed -i -E "s/^[[:space:]]*UMASK=.*/UMASK=$SYSSTAT_UMASK/" "$SYSSTAT_CONF"
      else
        printf 'UMASK=%s\n' "$SYSSTAT_UMASK" >> "$SYSSTAT_CONF"
      fi
      if [ "$(awk -F= '/^[[:space:]]*UMASK=/{print $2; exit}' "$SYSSTAT_CONF")" = "$SYSSTAT_UMASK" ]; then
        ok "2b. $SYSSTAT_CONF UMASK $cur_um -> $SYSSTAT_UMASK (new files will be $LOGMODE)"
      else
        warn "2b. could not set UMASK in $SYSSTAT_CONF - V-270756 will re-open tomorrow"
        failed=1
      fi
    fi
  else
    say "2b. no $SYSSTAT_CONF - sysstat is not installed here, nothing to do"
  fi

  # NOW CORRECT WHAT ALREADY EXISTS, with DISA's own FixText command - but SAY WHAT IT
  # TOUCHED first. A silent recursive chmod across /var/log is exactly the kind of thing
  # that should never happen without the operator seeing the list.
  local offenders
  offenders="$(find /var/log -perm /137 ! -name '*[bw]tmp' ! -name '*lastlog' -type f \
                 -exec stat -c '%n %a' {} \; 2>/dev/null || true)"
  if [ -n "$offenders" ]; then
    say "2b. files under /var/log more permissive than $LOGMODE - correcting:"
    printf '%s\n' "$offenders" | sed 's/^/       /'
    find /var/log -perm /137 ! -name '*[bw]tmp' ! -name '*lastlog' -type f \
      -exec chmod "$LOGMODE" {} + 2>/dev/null || true
    local still
    still="$(find /var/log -perm /137 ! -name '*[bw]tmp' ! -name '*lastlog' -type f 2>/dev/null || true)"
    if [ -z "$still" ]; then
      ok "   V-270756 clean - no file under /var/log matches DISA's find"
    else
      warn "   still more permissive than $LOGMODE:"
      printf '%s\n' "$still" | sed 's/^/       /'
      failed=1
    fi
  else
    ok "2b. no file under /var/log is more permissive than $LOGMODE"
  fi

  # ---- 2c. LOGROTATE IS WHAT KEEPS RE-OPENING V-270756 -----------------------------------
  #
  # Purging sysstat on host-1/2/3 removed two offenders and FOUR MORE APPEARED, two of them
  # created by libvirt which had been installed an hour earlier. The pattern is not sysstat;
  # sysstat was one instance of it.
  #
  # Surveyed on host-1 2026-09-18 - of the logrotate stanzas covering /var/log:
  #
  #   THREE recreate world-readable ON PURPOSE:  alternatives, dpkg, ubuntu-pro-client
  #                                              (`create 0644 root root` / `create 644`)
  #   TWELVE have no `create` line at all, so the mode comes from the writing daemon's umask,
  #        which for a root daemon is 022 -> 0644. That is exactly how
  #        /var/log/unattended-upgrades/*.log arrived at 644.
  #
  # WHY NOT FIX ALL FIFTEEN. Without `create`, logrotate does not make the new file - the
  # DAEMON does, on reopen. Forcing `create 0640 root adm` onto a stanza whose writer is not
  # root breaks that daemon's logging entirely. rsyslog writes as syslog, chrony as _chrony,
  # sssd has its own handling - those are deliberately untouched, and their files are correct
  # today because the /var/log work in item 1 set them.
  #
  # So this table is the ones whose writer IS root, where root:adm 0640 is safe. Adding a
  # package here is a decision about that package's writer, not a mechanical edit.
  local lr_file lr_mode
  for lr_file in alternatives dpkg ubuntu-pro-client unattended-upgrades; do
    local lrp="/etc/logrotate.d/$lr_file"
    [ -f "$lrp" ] || { say "2c. no $lrp - skipped"; continue; }
    if grep -qE "^[[:space:]]*create[[:space:]]+0?640[[:space:]]" "$lrp"; then
      say "2c. $lr_file already creates at $LOGMODE"
      continue
    fi
    backup_file "$lrp"; local lrbak="$LAST_BACKUP"
    if grep -qE "^[[:space:]]*create[[:space:]]" "$lrp"; then
      # Has a create line with the wrong mode - rewrite the mode, keep the stanza shape.
      sed -i -E "s|^([[:space:]]*)create[[:space:]]+[0-7]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+|\1create $LOGMODE root adm|" "$lrp"
    else
      # No create line - add one after every opening brace in the file.
      sed -i -E "s|^([[:space:]]*)\{[[:space:]]*$|\1{\n\1  create $LOGMODE root adm|" "$lrp"
    fi
    # DID THE EDIT ACTUALLY LAND? Both sed forms can match nothing - the add-a-create branch
    # anchors on a brace alone on its line, and a stanza written as `/path/to.log {` has no
    # such line. Without this check the config would still be VALID, logrotate would still
    # accept it, and this would report success having changed nothing at all.
    if ! grep -qE "^[[:space:]]*create[[:space:]]+${LOGMODE}[[:space:]]+root[[:space:]]+adm" "$lrp"; then
      cp -a "$lrbak" "$lrp"
      warn "2c. could not place a create line in $lr_file - REVERTED, nothing changed."
      warn "   its stanza is shaped in a way this edit does not handle. Fix it by hand:"
      warn "     add   create $LOGMODE root adm   inside the stanza in $lrp"
      failed=1
      continue
    fi
    if logrotate_config_ok; then
      ok "2c. $lr_file now creates at $LOGMODE root adm (backup: $lrbak)"
    else
      cp -a "$lrbak" "$lrp"
      warn "2c. logrotate rejected the edit to $lr_file - REVERTED. Its output:"
      printf '%s\n' "$LOGROTATE_OUT" | sed 's/^/       /'
      failed=1
    fi
  done

  # THE libvirt PLACEHOLDERS. /var/log/libvirt/{qemu,lxc}/.placeholder arrive at 0644 and are
  # owned by NO package - `dpkg -S` finds nothing, they are made at runtime when libvirt
  # creates its log directories. Nothing rewrites them, so a chmod holds; they are listed
  # explicitly rather than swept up so that a future one is noticed rather than silently
  # absorbed.
  local ph
  for ph in /var/log/libvirt/qemu/.placeholder /var/log/libvirt/lxc/.placeholder; do
    [ -f "$ph" ] || continue
    if [ "$(stat -c %a "$ph")" = "${LOGMODE#0}" ]; then
      say "2c. $ph already $LOGMODE"
    else
      chmod "$LOGMODE" "$ph" && ok "2c. $ph -> $LOGMODE"
    fi
  done

  # ---- 3. /var/log group ownership -------------------------------------------------------
  # file_groupowner_var_log. The group only exists with rsyslog, so the choice is install it
  # (--with-rsyslog) or leave the rule failing - never `groupadd syslog` (see the plan).
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
  # rsyslog_remote_access_monitoring - the three selector regexes are RE_AUTH/RE_AUTHPRIV/
  # RE_DAEMON above, copied from the benchmark's OVAL.
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
    # `rsyslogd -N1` checks the whole configuration without starting a daemon; the restart
    # that loads the drop-in only happens once it passes.
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

  # A NEW LOG FILE THAT NOTHING ROTATES IS A DISK THAT FILLS.
  #
  # THIS USED TO ONLY COVER OUR OWN DROP-IN, AND THAT WAS THE BUG. The check was gated on
  # [ -f "$RSYSLOG_STIG" ], so on a machine where a daemon.* selector ALREADY existed we
  # skipped writing the selector - correctly - and skipped adding rotation with it.
  #
  # MEASURED ON svc-mgmt-01, 2026-09-14: `usg fix` writes RED HAT style selectors into the
  # packaged /etc/rsyslog.d/50-default.conf -
  #     auth.*,authpriv.*   /var/log/secure
  #     daemon.*            /var/log/messages
  # - and adds NO logrotate entry for either. Ubuntu's rsyslog stanza names its files
  # explicitly (syslog, mail.log, kern.log, auth.log, user.log, cron.log), so neither is
  # covered. /var/log/messages had reached 7.9 GB and had never rotated once. On a machine
  # with a 96 GB root that is a disk-full outage with a date on it.
  #
  # So: do not ask "did we write a selector". Ask WHAT DOES RSYSLOG WRITE, and is each of
  # those files rotated by something. That is the question that stays true when the vendor
  # changes what it remediates.
  if [ -f "$RSYSLOG_LOGROTATE" ] && command -v rsyslogd >/dev/null 2>&1; then
    local dests missing=0 d
    # Destinations from every active rsyslog config line. The leading '-' means async write
    # and is not part of the path.
    dests="$(grep -rhE '^[[:space:]]*[^#[:space:]].*[[:space:]]-?/var/log/[^[:space:]]+' \
               /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null \
             | grep -oE '[-]?/var/log/[^[:space:]]+' | sed 's/^-//' | sort -u)"
    for d in $dests; do
      # Covered if ANY logrotate stanza names it - the vendor's, ours, or a package's.
      if grep -rqF "$d" /etc/logrotate.conf /etc/logrotate.d/ 2>/dev/null; then continue; fi
      missing=$((missing + 1))
      backup_file "$RSYSLOG_LOGROTATE"; local rsbak="$LAST_BACKUP"
      # Append the path on the line after /var/log/syslog - i.e. into the file list of
      # Ubuntu's rsyslog stanza, so it inherits that stanza's rotation settings.
      sed -i "\#^/var/log/syslog\$#a $d" "$RSYSLOG_LOGROTATE"
      if ! logrotate_config_ok; then
        cp -a "$rsbak" "$RSYSLOG_LOGROTATE"
        # A DUPLICATE IS NOT A FAILURE, IT IS AN ANSWER. Another stanza already covers this
        # file through a GLOB - /etc/logrotate.d/cloud-init carries /var/log/cloud-init*.log
        # - which a literal grep for the exact path cannot see. logrotate can, and says so.
        # Treating that as a failure made an already-correct machine report a problem.
        if printf '%s' "$LOGROTATE_OUT" | command grep -qi "duplicate log entry for $d"; then
          say "   $d is already covered by a GLOB in another stanza - left alone"
          missing=$((missing - 1))
        else
          warn "   logrotate rejected adding $d - REVERTED. Its output:"
          printf '%s\n' "$LOGROTATE_OUT" | sed 's/^/       /'
          failed=1
        fi
      else
        ok "   NOT ROTATED BY ANYTHING - added $d to $RSYSLOG_LOGROTATE (backup: $rsbak)"
        # Say how big it already is. A number here is the difference between "tidy-up" and
        # "this machine was going to fill up".
        [ -f "$d" ] && say "       current size: $(du -h "$d" 2>/dev/null | cut -f1)"
      fi
    done
    if [ "$missing" -eq 0 ]; then
      say "   every rsyslog destination is already rotated by something ($(printf '%s' "$dests" | wc -w) checked)"
    fi

    # THE HARDENING ITSELF STOPS LOGROTATE, AND IT FAILS SILENTLY.
    #
    # Fixup 3 sets /var/log to group `syslog` to satisfy the STIG. logrotate then REFUSES
    # every file in that directory - "skipping ... because parent directory has insecure
    # permissions (It's world writable or writable by group which is not root). Set the su
    # directive" - unless the stanza says which user and group to operate as.
    #
    # MEASURED 2026-09-14: all five hardened machines had /var/log group syslog and NO `su`
    # in the rsyslog stanza, so NOTHING in it had been rotating - syslog, auth.log, kern.log
    # and the rest, not just the files added above. /var/log/messages had reached 7.9 GB.
    # The packaged stanzas that DO work (cloud-init, postgresql-common, ubuntu-pro-client)
    # all ship `su root root`; only rsyslog's does not.
    #
    # This is the worst shape a defect can take: hardening a control silently disables an
    # unrelated subsystem, and the only symptom is a number going up.
    local vlgroup; vlgroup="$(stat -c %G /var/log 2>/dev/null || echo root)"
    if [ "$vlgroup" != root ] && ! grep -qE '^[[:space:]]*su[[:space:]]' "$RSYSLOG_LOGROTATE"; then
      backup_file "$RSYSLOG_LOGROTATE"; local sbak="$LAST_BACKUP"
      # Insert `su root <group>` above the FIRST `rotate` line only (0,/re/ is GNU sed's
      # first-match range), i.e. inside the stanza's braces.
      sed -i "0,/^[[:space:]]*rotate[[:space:]]/s//\tsu root $vlgroup\n&/" "$RSYSLOG_LOGROTATE"
      if ! logrotate_config_ok; then
        cp -a "$sbak" "$RSYSLOG_LOGROTATE"
        warn "   logrotate rejected 'su root $vlgroup' - REVERTED. Its output:"
        printf '%s\n' "$LOGROTATE_OUT" | sed 's/^/       /'
        failed=1
      else
        ok "   added 'su root $vlgroup' to $RSYSLOG_LOGROTATE"
        say "       /var/log is group '$vlgroup', and WITHOUT this logrotate silently skips"
        say "       every file in the stanza. Nothing was rotating before this line existed."
      fi
    fi

    # ROTATING WEEKLY IS NOT A BOUND. Ubuntu's stanza is `weekly` + `rotate 4`, so a file is
    # allowed to grow for seven days before anything happens to it. svc-mgmt-01 produces
    # ~5 GB/day of syslog, which that policy permits to reach ~140 GB on a 96 GB disk. The
    # files being listed is necessary and not sufficient.
    #
    # `maxsize` rotates on EITHER the time interval or the size, whichever comes first, so
    # quiet machines keep weekly rotation and noisy ones stop before the disk does.
    if ! grep -qE '^[[:space:]]*maxsize' "$RSYSLOG_LOGROTATE"; then
      backup_file "$RSYSLOG_LOGROTATE"; local mbak="$LAST_BACKUP"
      # Same first-match insertion as the `su` line above.
      sed -i '0,/^[[:space:]]*rotate[[:space:]]/s//\tmaxsize 100M\n&/' "$RSYSLOG_LOGROTATE"
      if ! logrotate_config_ok; then
        cp -a "$mbak" "$RSYSLOG_LOGROTATE"
        warn "   logrotate rejected maxsize - REVERTED. Its output:"
        printf '%s\n' "$LOGROTATE_OUT" | sed 's/^/       /'
        failed=1
      else
        ok "   added 'maxsize 100M' to $RSYSLOG_LOGROTATE - weekly alone is not a bound"
      fi
    else
      say "   $RSYSLOG_LOGROTATE already carries a maxsize"
    fi
  fi

  # ---- 5. postfix: loopback-only -----------------------------------------------------
  if command -v postconf >/dev/null 2>&1; then
    local cur; cur="$(postconf -h inet_interfaces 2>/dev/null || echo '?')"
    if [ "$cur" = "loopback-only" ]; then
      say "5. postfix already loopback-only"
    else
      # `postconf -e` edits main.cf in place; inet_interfaces only changes on a RESTART - a
      # reload does not re-bind listeners. Then re-measured with ss, not trusted.
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

  # ---- 6. sudo passwd_tries: one strike per invocation, not three -----------------------
  #
  # `usg fix` sets pam_faillock deny=3 unlock_time=0 - three failures and the account is
  # locked UNTIL AN ADMINISTRATOR RELEASES IT. sudo's own prompt allows three attempts per
  # invocation, so ONE fumbled password exhausts the entire budget and locks the only account
  # that can administer the machine. faillock.conf also sets `silent`, so the lock then
  # presents as "Sorry, try again" - indistinguishable from a typo, which invites more
  # attempts that cannot succeed because preauth is already refusing.
  #
  # That happened on svc-mgmt-01 on 2026-09-11. Recovery was a reboot - the tally lives in
  # /run/faillock, which is tmpfs - but on host-4 that means a physical trip and the LUKS
  # passphrase, on the machine that runs every VM.
  #
  # passwd_tries=1 costs one strike per invocation instead of three. deny=3 is unchanged, so
  # the STIG control is untouched; the operator simply gets three separate attempts with a
  # visible failure between each rather than losing everything in one prompt.
  local TRIES_FILE=/etc/sudoers.d/99-stig-passwd-tries
  if [ -f "$TRIES_FILE" ] && grep -q 'passwd_tries' "$TRIES_FILE"; then
    say "6. sudo passwd_tries already set ($(grep -h passwd_tries "$TRIES_FILE"))"
  else
    # A SYNTAX ERROR IN sudoers BREAKS sudo ENTIRELY, and on these machines sudo is the only
    # route to privilege. Write to a temp file, have visudo check THAT, and only install a
    # file that has already been validated. Never edit a live sudoers file in place.
    local tf; tf="$(mktemp)"
    cat > "$tf" <<'SUDOERS'
# One password attempt per sudo invocation.
#
# pam_faillock is deny=3 unlock_time=0: three failures lock the account until an
# administrator releases it. sudo's default of three attempts per invocation means a single
# fumbled password locks the only administrative account on the machine, and faillock's
# `silent` makes that look like a typo rather than a lock.
#
# This does not weaken the STIG control - deny=3 still applies. It spends the budget one
# strike at a time. Written by stig-tailor.sh fixups.
Defaults passwd_tries=1
SUDOERS
    chmod 0440 "$tf"
    if visudo -c -q -f "$tf" 2>/dev/null; then
      install -o root -g root -m 0440 "$tf" "$TRIES_FILE"
      # And check the WHOLE sudoers set still parses with the new file in place - a fragment
      # can be valid alone and conflict once included.
      if visudo -c -q 2>/dev/null; then
        ok "6. wrote $TRIES_FILE (passwd_tries=1) - full sudoers set still parses"
        warn "   VERIFY NOW, in this session:  sudo -k; sudo -v"
      else
        rm -f "$TRIES_FILE"
        warn "6. the full sudoers set FAILED to parse with that file - REMOVED it"
        visudo -c 2>&1 | sed 's/^/       /'
        failed=1
      fi
    else
      warn "6. the generated sudoers fragment did not pass visudo - NOT installed"
      visudo -c -f "$tf" 2>&1 | sed 's/^/       /'
      failed=1
    fi
    rm -f "$tf"
  fi

  # ---- 7. V-270816 - the audit allocation must hold a WEEK at THIS machine's rate --------
  #
  # MEASURED 2026-09-22, and it is a real finding rather than a scanner quirk. auditd ships
  # `max_log_file 8` x `num_logs 5` = 40 MB. On host-1 the audit trail grew 39.3 MB in 37.6
  # hours - about 25 MB/day - so 40 MB holds **1.6 days** against a control that requires
  # seven. The volume has 19 GB free. The allocation is not sized to the machine.
  #
  # SIZE IT FROM MEASUREMENT, NEVER A CONSTANT. The rate is not a property of the enclave:
  # svc-mgmt-01 once ran 430 MB/day against svc-harbor-01's 2.44 MB/day, 176x apart, because
  # MAAS invoked sudo about 1.7 times a second and auditd recorded every one. A number
  # measured on one machine and pasted onto another is how a control passes on paper.
  #
  # This does NOT solve audit offload (V-270817) - that needs the collector and three AO
  # answers. It makes the local buffer honest in the meantime.
  local ACONF=/etc/audit/auditd.conf
  if [ ! -r "$ACONF" ]; then
    warn "7. cannot read $ACONF - skipping the audit allocation check"
  else
    local cur_max cur_num alloc_mb held span rate_day need_mb free_mb
    cur_max="$(awk -F= '/^max_log_file[[:space:]]*=/{gsub(/ /,"",$2); print $2}' "$ACONF" | head -1)"
    cur_num="$(awk -F= '/^num_logs[[:space:]]*=/{gsub(/ /,"",$2); print $2}' "$ACONF" | head -1)"
    alloc_mb=$(( ${cur_max:-0} * ${cur_num:-0} ))
    # Rate from the files themselves: total bytes over the span between oldest and newest.
    held="$(stat -c %s /var/log/audit/audit.log* 2>/dev/null | awk '{t+=$1} END{print t+0}')"
    span="$(stat -c %Y /var/log/audit/audit.log* 2>/dev/null | sort -n | awk 'NR==1{f=$1} {l=$1} END{print (l-f)+0}')"
    if [ "${span:-0}" -lt 3600 ] || [ "${held:-0}" -le 0 ]; then
      say "7. audit allocation is ${alloc_mb}MB; too little history to measure a rate yet"
      say "     (need at least an hour spanning two files - re-run later)"
    else
      rate_day=$(( held * 86400 / span ))
      need_mb=$(( rate_day * 7 * 2 / 1048576 ))   # one week, doubled for burst headroom
      [ "$need_mb" -lt 64 ] && need_mb=64
      free_mb="$(df -PBM /var/log/audit 2>/dev/null | awk 'NR==2{gsub(/M/,"",$4); print $4+0}')"
      say "7. audit: $((rate_day/1048576))MB/day measured over $((span/3600))h; allocation ${alloc_mb}MB holds $(( alloc_mb * 1048576 / (rate_day>0?rate_day:1) )) day(s)"
      if [ "$alloc_mb" -ge "$need_mb" ]; then
        ok "7. allocation already covers a week with headroom (${alloc_mb}MB >= ${need_mb}MB)"
      elif [ "${free_mb:-0}" -lt $(( need_mb * 2 )) ]; then
        warn "7. needs ${need_mb}MB but only ${free_mb}MB free on /var/log/audit - NOT changing it"
        warn "   grow the volume first; silently filling the audit partition is worse than the finding"
        failed=1
      elif [ "$apply" -eq 0 ]; then
        say "     fix: max_log_file=$(( need_mb / 8 )) num_logs=8  (=${need_mb}MB), then reload auditd"
      else
        local new_max=$(( need_mb / 8 ))
        [ "$new_max" -lt 8 ] && new_max=8
        cp -a "$ACONF" "/var/backups/auditd.conf.$(date +%Y%m%dT%H%M%S)"
        # num_logs is pinned at 8 and max_log_file (MB per file) carries the size, so the
        # allocation is max_log_file x 8. Only existing lines are rewritten - none are added.
        sed -i -e "s/^max_log_file[[:space:]]*=.*/max_log_file = ${new_max}/" \
               -e "s/^num_logs[[:space:]]*=.*/num_logs = 8/" "$ACONF"
        # auditd re-reads its configuration on SIGHUP. `systemctl restart auditd` is REFUSED
        # on Ubuntu (RefuseManualStop), and killing it would drop records.
        if systemctl kill -s HUP auditd 2>/dev/null; then
          ok "7. audit allocation now $(( new_max * 8 ))MB (max_log_file=${new_max}, num_logs=8) - auditd reloaded"
          say "     that is $(( new_max * 8 * 1048576 / (rate_day>0?rate_day:1) )) days at the measured rate"
        else
          warn "7. config written but auditd did not accept SIGHUP - check: systemctl status auditd"
          failed=1
        fi
      fi
    fi
  fi

  # ---- 8. pam_lastlog: a REQUIRED module that does not exist on 24.04 -------------------
  #
  # FOUND 2026-09-23 testing the break-glass account at svc-obs-01's serial console: the
  # password was accepted, the MOTD printed, then "Module is unknown" and back to login:.
  # usg's display_login_attempts wrote `session required pam_lastlog.so showfailed` into
  # /etc/pam.d/login; 24.04's libpam-modules does not ship that module and nothing in the
  # archive provides it. `required` + unloadable = every console session fails, every
  # account, all eight machines. SSH never noticed - its stack does not include the line.
  #
  # Only act when the module is genuinely absent: if a future libpam ships it again, the
  # line is correct and stays.
  local pll8; pll8="$(pam_lastlog_line)"
  if [ -z "$pll8" ]; then
    say "8. no pam_lastlog line in $PAM_LOGIN"
  elif pam_module_present pam_lastlog.so; then
    say "8. pam_lastlog.so is installed here - line left alone"
  else
    backup_file "$PAM_LOGIN"
    sed -i -E 's|^([[:space:]]*session[[:space:]].*pam_lastlog\.so.*)$|# removed by stig-tailor.sh fixups 8 (backlog 3.28): pam_lastlog.so does not exist on 24.04\n# \1|' "$PAM_LOGIN"
    # PROVE IT: the live line is gone AND the rest of the stack is intact. A bad sed on a PAM
    # file is a machine nobody can log in to by ANY route that uses it.
    if [ -n "$(pam_lastlog_line)" ]; then
      [ -n "${LAST_BACKUP:-}" ] && cp -a "$LAST_BACKUP" "$PAM_LOGIN"
      warn "8. the pam_lastlog line is still live after the edit - RESTORED $PAM_LOGIN"
      failed=1
    elif ! grep -q '^@include common-auth' "$PAM_LOGIN" || ! grep -q '^@include common-session' "$PAM_LOGIN"; then
      [ -n "${LAST_BACKUP:-}" ] && cp -a "$LAST_BACKUP" "$PAM_LOGIN"
      warn "8. $PAM_LOGIN lost its common-auth/common-session includes - RESTORED"
      failed=1
    else
      ok "8. pam_lastlog line commented out in $PAM_LOGIN (backup: ${LAST_BACKUP:-none})"
      warn "   VERIFY AT A CONSOLE: log in. SSH cannot prove this - it never used the line."
    fi
  fi

  say ""
  [ "$failed" -eq 0 ] || warn "one or more fixups did not complete - see above"
  say ""
  say "verify with:  sudo $0 fixups --verify   then re-audit"
}

# `fixups --verify` - runbook 6.0 steps 11 and 12, and 05-harden-host.sh step_verify.
# READ-ONLY re-check of END STATE, not of what the last --apply did: modes, groups, hooks,
# selectors, logrotate, sudo, console PAM, postfix. Run it with sudo - the logrotate check
# is skipped unprivileged. It prints its verdict and RETURNS 0 EITHER WAY.
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
  # sysstat's UMASK is the one that re-opens V-270756 on a timer rather than on an event, so
  # verify the SETTING and not only today's files - the files will look right for hours after
  # a chmod and be wrong again by morning.
  if [ -f "$SYSSTAT_CONF" ]; then
    local vum; vum="$(awk -F= '/^[[:space:]]*UMASK=/{print $2; exit}' "$SYSSTAT_CONF" 2>/dev/null)"
    if [ "$vum" = "$SYSSTAT_UMASK" ]; then
      say "sysstat UMASK=$vum - new accounting files will be $LOGMODE"
    else
      warn "sysstat UMASK=${vum:-<unset>}, expected $SYSSTAT_UMASK - V-270756 WILL re-open"
      warn "  the next time sa1 or sa2 runs, whatever today's file modes look like"
      fail=1
    fi
  fi
  local offenders
  # `|| true`: find exits non-zero after ANY permission-denied even when its output is complete,
  # and with pipefail that status reaches the assignment and set -e ends the run. Same class of
  # bug as the tmpfiles glob above.
  offenders="$(find /var/log -type f -perm /0137 -printf '%M %U:%G %p\n' 2>/dev/null | sort -k3 || true)"
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
  if [ -f /etc/sudoers.d/99-stig-passwd-tries ]; then
    say "sudo passwd_tries: $(grep -h passwd_tries /etc/sudoers.d/99-stig-passwd-tries)"
  else
    warn "sudo passwd_tries NOT set - one fumbled password locks this account permanently"
    fail=1
  fi
  # THE MACHINE-ID JOURNAL DIRECTORY - what dir_permissions_system_journal evaluates, and what
  # this verify never looked at until 2026-09-25 (so host-1/2 read clean here and failed usg).
  if [ "$(id -u)" -eq 0 ]; then
    local jd jbad=""
    for jd in /var/log/journal/*/ /run/log/journal/*/; do
      [ -d "$jd" ] || continue
      case "$(stat -c %a "$jd")" in 640|600) : ;; *) jbad="$jbad $jd($(stat -c %a "$jd"))" ;; esac
    done
    if [ -n "$jbad" ]; then warn "journal machine-id dir(s) not 0640:$jbad (fixups 0d)"; fail=1
    else say "journal machine-id directories: 0640"; fi
  fi
  grep -qxF "$JOURNAL_MID_LINE" "$JOURNAL_MID_TMPFILES" 2>/dev/null \
    || { warn "$JOURNAL_MID_TMPFILES missing - the journal dir reverts to 2755 at the next reboot (fixups 0d)"; fail=1; }
  if [ -n "$(pam_lastlog_line)" ] && ! pam_module_present pam_lastlog.so; then
    warn "$PAM_LOGIN requires pam_lastlog.so, which is NOT installed - console login is BROKEN (fixups 8)"
    fail=1
  else
    say "console PAM: no required module missing from $PAM_LOGIN (pam_lastlog)"
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
  # THE EXIT CODE MUST CARRY THE RESULT (backlog 3.31 #3). This returned 0 unconditionally, so
  # `fixups --verify || ...` in 05-harden-host.sh could never fire - a check that cannot fail.
  #   0 = every check passed, run as root      1 = at least one check failed
  #   2 = nothing failed, but NOT run as root  - several checks could not read their files, so
  #       "passed" would be a false pass (the 2026-09-24 hidden-Permission-denied lesson).
  [ "$fail" -eq 0 ] || return 1
  if [ "$(id -u)" -ne 0 ]; then
    warn "NOT ROOT - some checks could not read what they check; this is not evidence. Use sudo."
    return 2
  fi
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
#
# WHERE IT RUNS: not a runbook 6.0 step - `usg fix` already blocks USB storage everywhere.
# This is the operating procedure for host-4's transfer and backup windows (runbook 6.3g;
# vm-backup.sh points at it). Rule: kernel_module_usb-storage_disabled. ssp-inputs 4.1.
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
      # SHOW EVERY REMOVABLE DISK, NOT ONLY THE ONE WE EXPECTED. This used to report solely
      # on a volume labelled enclave-xfer - the transfer SSD - so opening the window for any
      # other disk (a backup drive, for instance) printed "no volume labelled enclave-xfer",
      # which reads exactly like the window failed to open. Say what actually appeared.
      # FILTER ON TRANSPORT, NOT ON THE "REMOVABLE" FLAG. The first version selected RM=1,
      # and USB HARD DRIVES REPORT RM=0 - only card readers and optical drives set it. So on
      # 2026-09-14 it printed "no removable disk is visible yet" with a 1 TB SSD and a 5 TB
      # WD easystore both attached and both visible in dmesg. The kernel had done everything
      # right; the filter asked the wrong question.
      local usbdisks rem=""
      usbdisks="$(lsblk -S -n -o NAME,TRAN 2>/dev/null | awk '$2=="usb" {print "/dev/"$1}')"
      if [ -n "$usbdisks" ]; then
        # shellcheck disable=SC2086
        rem="$(lsblk -o NAME,SIZE,LABEL,FSTYPE,MOUNTPOINT $usbdisks 2>/dev/null)"
      fi
      if [ -n "$rem" ]; then
        ok "USB disk(s) now visible:"
        printf '%s\n' "$rem" | sed 's/^/       /'
        say ""
        say "       ADDRESS THESE BY ID, NEVER BY /dev/sdX - reloading the modules"
        say "       re-enumerates and the letters move:"
        ls -l /dev/disk/by-id/ 2>/dev/null | awk '/usb-|wwn-/ && !/-part/ {print "         "$9}' | head -6
      else
        warn "no USB disk is visible yet."
        say  "   The modules loaded, so the window IS open - the disk is what is missing."
        say  "   Give udev a moment, then:  lsblk -o NAME,SIZE,LABEL,FSTYPE,MOUNTPOINT"
        say  "   and check the cable and the enclosure's own power switch."
      fi
      local xfer; xfer="$(lsblk -o NAME,SIZE,LABEL,FSTYPE 2>/dev/null | grep -i 'enclave-xfer' || true)"
      [ -n "$xfer" ] && ok "transfer media present: $xfer"
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

# ------------------------------------------------------------------------------- radio
#
# V-270755 / UBTU-24-600230 - "must disable all wireless network adapters", AND the Bluetooth
# radio that the benchmark never mentions at all.
#
# THESE MACHINES HAVE RADIOS. Measured 2026-09-17, all four:
#     host-1/2/3   Realtek RTL8821CE 802.11ac  -> live interface wlp2s0, module rtw88_8821ce
#     host-4       MediaTek MT7922 802.11ax    -> no interface, the driver simply never loaded
#     all four     a USB Bluetooth radio, btusb resident
#
# In an air-gapped enclave a radio is not a compliance line item, it is the one piece of
# hardware that can cross the gap without anybody unplugging anything.
#
# WHY THE CHECKLIST DOES NOT CATCH IT EVERYWHERE. DISA's CheckText is:
#
#     ls -L -d /sys/class/net/*/wireless
#
# MEASURED 2026-09-17, and it behaves differently on the two kinds of machine here:
#
#   host-1/2/3  the glob DOES match wlp2s0 - rtw88 still creates the legacy WEXT directory -
#               so the rule is correctly raised, and lands on NOT REVIEWED because DISA's
#               check ends in a human judgement: "if a wireless interface is configured and
#               has not been documented and approved by the ISSO, this is a finding."
#
#   host-4      the glob matches NOTHING. The mt76 driver never loaded, so there is no
#               interface to find. The scanner then applies the CheckText's opening note -
#               "not applicable for systems that do not have physical wireless network
#               radios" - and scores it NOT APPLICABLE. host-4 has an MT7922 in it. The NA
#               is FALSE, and re-running the checklist will never say so, because an
#               unbound radio is invisible to a check that looks at interfaces.
#
# So this command tests the HARDWARE - PCI class 0x0280 - which is what that N/A note
# actually turns on, as well as the interface. `phy80211` is used for the live-interface
# test rather than the WEXT directory because it is what modern cfg80211 drivers are
# guaranteed to expose; DISA's glob is printed beside it so the difference between the two
# is visible rather than argued about.
#
# WHY THE FIXTEXT'S OWN INSTRUCTION DOES NOT WORK HERE. DISA says to find the module with:
#
#     basename $(readlink -f /sys/class/net/<if>/device/driver)
#
# On host-1 that returns `rtw_8821ce` - the PCI DRIVER name. The MODULE is `rtw88_8821ce`.
# `install rtw_8821ce /bin/true` blocks nothing, because no module is called that, and the
# card keeps working while the file looks like a remediation. Read `device/driver/module`
# instead, which is a symlink to the real module, and the two names stop disagreeing.
#
# THE SAFETY PROPERTY THAT MATTERS MORE THAN THE CONTROL: these are budget test machines with
# NO BMC (operator, 2026-09-16). Blacklisting the wrong module means a host that comes up with
# no network and no remote console - a drive to the rack. So every module backing an interface
# that holds an address or feeds a bridge is PROTECTED, and if discovery ever lands on one of
# those, this refuses and changes nothing rather than guessing.
# ONE IMPLEMENTATION OF "REBUILD THE INITRAMFS, AND PROVE IT".
#
# `update-initramfs -u` targets the NEWEST initramfs by version sort. On these FIPS hosts that
# is the **-generic** kernel they do not boot, so it rebuilds the wrong one, reports success,
# and leaves the running kernel's initrd untouched. Measured TWICE:
#
#   2026-09-16  cmd_luksenroll, host-4 - "initramfs rebuilt" while initrd.img-6.8.0-138-fips
#               was still hours old. Fixed there by naming the kernel.
#   2026-09-17  `radio disable`, ALL FOUR hosts - 99-stig-radio.conf landed in
#               initrd.img-6.8.0-138-generic (mtime 23:21:55) while the running -fips initrd
#               stayed at 22:00:16. The same bug, rewritten from scratch in new code because
#               the lesson lived in one function instead of one helper.
#
# `-k all` rather than just the running kernel: a module blacklist has to hold whichever
# kernel the machine comes up on, and the generic fallback is in the GRUB menu.
#
# Returns non-zero on any of: the command failed, the RUNNING kernel's initrd did not change,
# or the file we care about is not inside it. An mtime bump says a rebuild happened - not that
# it included what we needed.
# Is a path already inside the RUNNING kernel's initramfs? Returns 2 when it CANNOT TELL,
# so "could not verify" never reads as "verified".
# MEASURED 2026-09-21 on host-3, and it corrects two earlier conclusions.
#
# The image DOES carry both /etc/modprobe.d/99-stig-radio.conf and
# /usr/lib/modprobe.d/99-stig-radio.conf - verified by hand with `lsinitramfs | grep -c
# stig-radio` = 2 - while this function had just reported the file absent and `radio disable`
# warned that "the rebuild did not pick it up". So:
#
#   - the file was never missing. /etc/modprobe.d IS packed, contrary to what the kmod hook
#     alone suggests, and the warning on all four hosts on 2026-09-17 was a FALSE ALARM.
#   - the failure is in the CHECK: listing a 77 MB multi-segment zstd initrd straight after
#     update-initramfs returns can come back short, and `2>/dev/null` hid whatever it said.
#
# So: sync first, retry, accept EITHER path, and on failure SHOW the error instead of hiding
# it. A check that reports a false negative on a correct machine is worse than no check - it
# was ignored for four days because it always said the same thing.
initramfs_has() {
  local want="$1" initrd="/boot/initrd.img-$(uname -r)" out rc i
  [ -r "$initrd" ] || return 2
  command -v lsinitramfs >/dev/null 2>&1 || return 2
  for i in 1 2 3; do
    sync
    out="$(lsinitramfs "$initrd" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q -e "$want" -e "etc/modprobe.d/$(basename "$want")"; then
      return 0
    fi
    [ "$i" -lt 3 ] && sleep 2
  done
  # Only reached when it is genuinely not there, or lsinitramfs failed - say which.
  if [ "${rc:-1}" -ne 0 ]; then
    warn "lsinitramfs could not read $initrd: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  fi
  return 1
}

# rebuild_initramfs [path-inside-initrd] - this function's header is the "ONE IMPLEMENTATION
# OF REBUILD THE INITRAMFS, AND PROVE IT" block above initramfs_has(); the two headers sit
# together there. Used by `radio` and `luksenroll` (clevis).
rebuild_initramfs() {
  local want="${1:-}"                       # path INSIDE the initramfs, no leading slash
  local kver; kver="$(uname -r)"
  local initrd="/boot/initrd.img-$kver"
  local before; before="$(stat -c %Y "$initrd" 2>/dev/null || echo 0)"
  local iout; iout="$(mktemp)"
  if ! update-initramfs -u -k all >"$iout" 2>&1; then
    warn "update-initramfs FAILED - output follows:"
    sed 's/^/       /' "$iout" >&2
    rm -f "$iout"
    warn "DO NOT REBOOT THIS MACHINE until it succeeds. This root is LUKS-encrypted and"
    warn "  these machines have no BMC - a broken initramfs stops at a passphrase prompt"
    warn "  on a console nobody can reach."
    return 1
  fi
  grep -iE 'warning|error' "$iout" | sed 's/^/       /' || true
  rm -f "$iout"
  local after; after="$(stat -c %Y "$initrd" 2>/dev/null || echo 0)"
  if [ "$after" -le "$before" ]; then
    warn "update-initramfs reported success but $initrd DID NOT CHANGE."
    warn "  the RUNNING kernel's initramfs does not carry this change. Check:"
    warn "    sudo update-initramfs -u -k $kver"
    return 1
  fi
  ok "initramfs rebuilt for every installed kernel (running: $kver)"
  if [ -n "$want" ] && command -v lsinitramfs >/dev/null 2>&1; then
    # USE THE RETRYING HELPER, not a bare lsinitramfs|grep. This function had its own inline
    # copy that ran the instant update-initramfs returned, which is the race that made the
    # radio check cry wolf on four hosts since 09-17 - and then did it AGAIN on 2026-09-21
    # for clevis, reporting "NOT inside" when the image demonstrably held 11 clevis files.
    # Fixing the helper and leaving a second copy here fixed nothing: the same bug, twice,
    # in one file.
    if initramfs_has "$want"; then
      ok "verified: $want is inside $initrd"
    else
      warn "$want is NOT inside $initrd - the rebuild did not pick it up"
      return 1
    fi
  fi
  return 0
}

RADIO_BLOCK=/etc/modprobe.d/99-stig-radio.conf
# THE INITRAMFS COPY, AND WHY IT IS A SECOND FILE RATHER THAN THE SAME ONE.
#
# initramfs-tools packs ONLY /usr/lib/modprobe.d/* into the image - read it in
# /usr/share/initramfs-tools/hooks/kmod, which copies that directory and nothing else. It
# NEVER copies /etc/modprobe.d. So the old check ("is /etc/modprobe.d/99-stig-radio.conf inside
# the initrd?") could not pass no matter how many times update-initramfs ran, and it warned
# after every single `radio disable` - including the one on host-3 on 2026-09-21, which
# rebuilt the initramfs and then reported its own work as failed. A check that cannot succeed
# teaches the operator to ignore warnings, which is worse than not checking.
#
# /etc keeps the authoritative copy: it is where an admin looks, where DISA's CheckText points,
# and it wins at runtime. /usr/lib carries an identical copy purely so the block is present
# before the real root is mounted.
RADIO_BLOCK_INITRD=/usr/lib/modprobe.d/99-stig-radio.conf
RADIO_LOG=/var/log/stig-radio.log
# Bluetooth has no STIG rule to name its modules, so the family is a parameter. btusb is the
# transport, bluetooth is the core, the bt*{rtl,intel,bcm,mtk} pieces are vendor firmware
# loaders that btusb pulls in.
RADIO_BT_MODULES="${RADIO_BT_MODULES:-btusb btrtl btintel btbcm btmtk bluetooth}"
# Anything the operator wants blocked that discovery cannot see. Empty by design.
RADIO_EXTRA_MODULES="${RADIO_EXTRA_MODULES:-}"

# The whole 802.11 / Bluetooth module family, for UNLOADING only - never for blacklisting.
# Spells the bt* members out rather than using ^bt, which would also match btrfs, and cannot
# match r8169, the ethernet driver every one of these hosts depends on.
RADIO_FAMILY_RE='^(rtw[0-9]*_|rtw[0-9]+|mt7[0-9]|mt76|iwlwifi|iwl[dm]vm|ath[0-9]+k?|brcmfmac|bt(usb|rtl|intel|bcm|mtk)|bluetooth|mac80211|cfg80211|libarc4)'
radio_family_resident() { lsmod 2>/dev/null | cut -d' ' -f1 | grep -E "$RADIO_FAMILY_RE" || true; }

# Modules backing a network interface that is actually carrying traffic: anything with a
# global address, plus bridge slaves (host-4's enp42s0 has no address of its own - br0 holds
# it - and blacklisting it would take every VM off the network with it).
radio_protected_modules() {
  local i m
  { ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}'
    ip -o -6 addr show scope global 2>/dev/null | awk '{print $2}'
    ip -o link show type bridge_slave 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1
  } | sort -u | while read -r i; do
    [ -n "$i" ] || continue
    m="$(basename "$(readlink -f "/sys/class/net/$i/device/driver/module" 2>/dev/null)" 2>/dev/null)"
    case "$m" in ''|.|/) continue ;; esac
    printf '%s\n' "$m"
  done | sort -u
}

# Live 802.11 interfaces, by the marker modern drivers actually create.
radio_wifi_ifaces() {
  local d
  for d in /sys/class/net/*/phy80211; do
    [ -e "$d" ] || continue
    basename "$(dirname "$d")"
  done
}

radio_wifi_modules() {
  local i m c dev
  # (a) from live interfaces - device/driver/module, NOT device/driver (see the header).
  for i in $(radio_wifi_ifaces); do
    m="$(basename "$(readlink -f "/sys/class/net/$i/device/driver/module" 2>/dev/null)" 2>/dev/null)"
    case "$m" in ''|.|/) continue ;; esac
    printf '%s\n' "$m"
  done
  # (b) from the hardware, whether or not a driver ever bound to it. PCI class 0x0280 is
  #     "Network controller / other", which is what every 802.11 card reports; ethernet is
  #     0x0200 and is deliberately not matched. modprobe -R resolves the modalias to the
  #     module name without loading anything, so this sees host-4's MT7922 too.
  for c in /sys/bus/pci/devices/*/class; do
    case "$(cat "$c" 2>/dev/null)" in
      0x0280*) dev="$(dirname "$c")"
               [ -r "$dev/modalias" ] && modprobe -R "$(cat "$dev/modalias")" 2>/dev/null ;;
    esac
  done
  printf '%s\n' $RADIO_EXTRA_MODULES
}

# Is there a Bluetooth radio in this machine at all? USB class e0 is "wireless controller";
# PCI 0x0d11 is the bus-attached equivalent.
radio_bt_present() {
  local f c
  for f in /sys/bus/usb/devices/*/bDeviceClass; do
    [ "$(cat "$f" 2>/dev/null)" = "e0" ] && return 0
  done
  for c in /sys/bus/pci/devices/*/class; do
    case "$(cat "$c" 2>/dev/null)" in 0x0d11*) return 0 ;; esac
  done
  lsmod 2>/dev/null | awk '{print $1}' | grep -qx btusb && return 0
  return 1
}

radio_target_modules() {
  # `radio_bt_present && printf ...` as the last command of this group made the WHOLE
  # pipeline exit 1 on a machine with no Bluetooth (pipefail), and `mods="$(...)"` under
  # set -e then killed the caller - so `radio status` printed nothing and exited 1 on every
  # machine with no radio. That is all seven VMs, and step_radio in 05-harden-host.sh runs
  # `radio status` first, so it would have aborted the hardening run. `if` leaves no
  # non-zero status behind; the explicit return says the emptiness is an answer, not a fault.
  { radio_wifi_modules
    if radio_bt_present; then printf '%s\n' $RADIO_BT_MODULES; fi
  } | sed '/^$/d' | sort -u
  return 0
}

radio_loaded() { lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

# Every file that blocks, not just ours - the lesson `usb` already learned the hard way.
radio_block_files() {
  local mods; mods="$(radio_target_modules | tr '\n' '|' | sed 's/|$//')"
  [ -n "$mods" ] || return 0
  grep -rlE "^[[:space:]]*(install|blacklist)[[:space:]]+($mods)([[:space:]]|\$)" \
    /etc/modprobe.d /run/modprobe.d /usr/lib/modprobe.d 2>/dev/null | sort -u
}

# Append-only evidence of every block and unblock, like usb_log: when, what, and who (sudo).
radio_log() {
  printf '%s  %-8s by=%s  %s\n' "$(date -Is)" "$1" "${SUDO_USER:-$(id -un)}" "${2:-}" \
    >> "$RADIO_LOG" 2>/dev/null \
    || warn "could not write $RADIO_LOG - this change is UNRECORDED"
  chmod 0640 "$RADIO_LOG" 2>/dev/null || true
}

# RUNBOOK 6.0 STEP 12b2 (05-harden-host.sh step_radio runs status, disable, status).
#   status   read-only: hardware, DISA's check beside the phy80211 check, block, initramfs
#   disable  root: write the block to /etc AND /usr/lib/modprobe.d, rebuild the initramfs,
#            unload the module chain. Nothing to do on a machine with no radio (every VM)
#   enable   root: removes the /etc block file and logs V-270755 as open. It does NOT remove
#            the /usr/lib/modprobe.d copy; its closing "other files may still block" line
#            lists what is still blocking
# The answer-file entry for V-270755 (answerfile.sh) re-checks this block at every scan.
# ssp-inputs 4.1a.
cmd_radio() {
  local action="${1:-status}"
  local mods prot clash m i disa left

  mods="$(radio_target_modules)"
  prot="$(radio_protected_modules)"

  case "$action" in
    status)
      printf '\n  Radios on %s\n\n' "$(hostname -s)"
      say "  hardware:"
      lspci 2>/dev/null | grep -iE 'network controller|wireless' | sed 's/^/       PCI  /' || true
      lsusb 2>/dev/null | grep -iE 'bluetooth|wireless' | sed 's/^/       USB  /' || true
      [ -z "$(lspci 2>/dev/null | grep -iE 'network controller|wireless')" ] \
        && [ -z "$(lsusb 2>/dev/null | grep -iE 'bluetooth|wireless')" ] \
        && ok "  no wireless or Bluetooth hardware found - this control is genuinely N/A here"
      say ""
      # Show BOTH checks side by side. The gap between them is the whole point.
      # `ls` exits 2 when nothing matches, pipefail carries that out of the pipeline, and the
      # assignment then kills the whole command under set -e. Measured on stage-01
      # 2026-09-17: `radio status` printed two lines and exited 2 on every machine WITHOUT a
      # radio - the machines where the answer is "nothing to do". Emptiness is an answer here.
      disa="$(ls -L -d /sys/class/net/*/wireless 2>/dev/null | xargs -r -n1 dirname | xargs -r -n1 basename | tr '\n' ' ' || true)"
      say "  DISA CheckText (ls /sys/class/net/*/wireless) : ${disa:-<nothing - WEXT is obsolete>}"
      say "  live 802.11 interfaces (phy80211)             : $(radio_wifi_ifaces | tr '\n' ' ')"
      if [ -n "$(radio_wifi_ifaces || true)" ] && [ -z "$disa" ]; then
        warn "  the checklist check finds NOTHING while a live 802.11 interface exists"
      fi
      for i in $(radio_wifi_ifaces); do
        say "       $i  state=$(cat "/sys/class/net/$i/operstate" 2>/dev/null)  addr=$(ip -br -4 a show "$i" 2>/dev/null | awk '{$1=$2="";print}')"
      done
      say ""
      # $mods is newline-separated (sort -u); print it on one line or the table is unreadable.
      say "  modules to block : $(printf '%s' "${mods:-<none>}" | tr '\n' ' ')"
      say "  protected (carrying this machine's network, never blocked): ${prot:-<none>}"
      say ""
      # NOTHING TO BLOCK IS NOT A FINDING. On a machine with no radio - all seven VMs - the
      # blocked/initramfs questions have no subject, and warning about them there trains the
      # reader to ignore the warning on the machines where it means something.
      if [ -z "$mods" ]; then
        ok "  nothing to block on this machine"
        say ""
        return 0
      fi
      local blockers; blockers="$(radio_block_files || true)"
      if [ -n "$blockers" ]; then
        ok "  BLOCKED by:"
        printf '%s\n' "$blockers" | sed 's/^/       /'
      else
        warn "  NOT BLOCKED - nothing in modprobe.d blocks these modules"
      fi

      # SAY WHAT THE BOOT PATH CARRIES, not only what /etc says. A correct file in /etc with a
      # running initramfs that does not contain it is exactly the state all four hosts were
      # left in on 2026-09-17, and nothing in this output would have shown it.
      # `|| src=$?` and not a bare call: initramfs_has returns 2 when it cannot tell, and a
      # bare non-zero command is fatal under set -e before `case` ever runs.
      local src=0; initramfs_has "${RADIO_BLOCK_INITRD#/}" || src=$?
      case "$src" in
        0) ok "  and it is inside the RUNNING kernel's initramfs ($(uname -r))" ;;
        2) say "  (cannot read /boot/initrd.img-$(uname -r) to check - run this as root)" ;;
        *) warn "  it is NOT in the running kernel's initramfs ($(uname -r))"
           say  "     fix: sudo $0 radio disable   (rebuilds for every installed kernel)" ;;
      esac
      left=""
      for m in $mods; do
        if radio_loaded "$m"; then left="$left $m"; fi
      done
      if [ -n "$left" ]; then
        warn "  still LOADED:$left"
        say  "     fix: sudo $0 radio disable"
      else
        ok "  no blocked radio module is loaded"
      fi
      # REPORT THE LIBRARY CHAIN TOO. `left` only covers the modules we blacklist - the
      # driver. Saying "no radio module loaded" while rtw88_core, mac80211 and cfg80211 are
      # resident is the kind of half-true green result this project keeps getting burned by.
      local residue; residue="$(radio_family_resident | tr '\n' ' ' || true)"
      if [ -n "$residue" ]; then
        say "  library modules still resident: $residue"
        say "     harmless with no device bound and the driver blocked; cleared by a reboot,"
        say "     or by re-running: sudo $0 radio disable"
      fi
      if [ -r "$RADIO_LOG" ]; then
        say ""; say "  last 5 events:"
        tail -5 "$RADIO_LOG" | sed 's/^/    /'
      fi
      say ""
      ;;

    disable)
      need_root
      [ -n "$mods" ] || { ok "no radio hardware on $(hostname -s) - nothing to do"; return 0; }

      # REFUSE ON AMBIGUITY. If discovery has landed on a module that is carrying the
      # network, something is wrong with the assumption, not with the machine - and the
      # cost of being wrong here is a host with no network and no BMC.
      clash=""
      for m in $mods; do
        case " $prot " in *" $m "*) clash="$clash $m" ;; esac
      done
      [ -n "$clash" ] && die "REFUSING:$clash back(s) a live network interface on $(hostname -s).
       Blocking it would take this host off the network, and these machines have no BMC.
       Check 'ip -br a' and '$0 radio status', then set RADIO_EXTRA_MODULES deliberately."

      say "  modules: $mods"
      for i in $(radio_wifi_ifaces); do
        say "  bringing $i down"
        ip link set "$i" down 2>/dev/null || warn "  could not down $i"
      done

      local tmp; tmp="$(mktemp)"
      { printf '# Written by stig-tailor.sh radio disable on %s\n' "$(date -Is)"
        printf '# V-270755 / UBTU-24-600230, plus the Bluetooth radio the benchmark omits.\n'
        printf '# DISA FixText form is "install <module> /bin/true"; blacklist is added so an\n'
        printf '# explicit modprobe by name is refused too, not only autoload.\n'
        for m in $mods; do printf 'install %s /bin/true\nblacklist %s\n' "$m" "$m"; done
      } > "$tmp"
      # BOTH copies are written from $tmp, so it is removed ONCE, after both - the first
      # version of this deleted it in each branch above and the initramfs copy then failed
      # with "install: cannot stat /tmp/tmp.XXXX" while still reporting the /etc write as ok.
      if [ -f "$RADIO_BLOCK" ] && cmp -s "$tmp" "$RADIO_BLOCK"; then
        ok "$RADIO_BLOCK already correct"
      else
        [ -f "$RADIO_BLOCK" ] && backup_file "$RADIO_BLOCK"
        install -m 0644 -o root -g root "$tmp" "$RADIO_BLOCK"
        ok "wrote $RADIO_BLOCK"
      fi
      # The initramfs copy, kept byte-identical to the one in /etc.
      install -d -m 0755 "$(dirname "$RADIO_BLOCK_INITRD")"
      if [ -f "$RADIO_BLOCK_INITRD" ] && cmp -s "$tmp" "$RADIO_BLOCK_INITRD"; then
        ok "$RADIO_BLOCK_INITRD already correct (initramfs copy)"
      else
        install -m 0644 -o root -g root "$tmp" "$RADIO_BLOCK_INITRD"
        ok "wrote $RADIO_BLOCK_INITRD - the only modprobe.d path initramfs-tools packs"
      fi
      rm -f "$tmp"

      # THE INITRAMFS CHECK IS DRIVEN BY STATE, NOT BY WHETHER THE FILE CHANGED.
      #
      # The blacklist has to reach the initramfs as well as /etc, or a module packed into the
      # initramfs loads before /etc is even mounted and the file is decoration. And every host
      # here is LUKS-encrypted with no BMC, so rebuild_initramfs prints what update-initramfs
      # said and refuses to call a rebuild successful unless the RUNNING kernel's initrd moved.
      #
      # An earlier version rebuilt only when it had just written the file, which left this
      # command unable to repair itself. On 2026-09-17 all four hosts ended with a correct
      # /etc/modprobe.d/99-stig-radio.conf and a running initramfs that did not contain it,
      # because the rebuild had gone to the -generic kernel. Re-running took the "already
      # correct" branch and skipped the rebuild, so a second run CONFIRMED the bug instead of
      # fixing it. A remediation that cannot repair a half-applied state is not a remediation.
      local irc=0; initramfs_has "${RADIO_BLOCK_INITRD#/}" || irc=$?
      case "$irc" in
        0) ok "block is already inside the running kernel's initramfs" ;;
        2) warn "cannot read the running kernel's initramfs to check - rebuilding anyway"
           rebuild_initramfs "${RADIO_BLOCK_INITRD#/}" \
             || warn "the block is live in /etc but NOT verified in the running initramfs" ;;
        *) say "  the running kernel's initramfs does not carry the block - rebuilding"
           rebuild_initramfs "${RADIO_BLOCK_INITRD#/}" \
             || warn "the block is live in /etc but NOT in the running kernel's initramfs" ;;
      esac

      # UNLOAD THE WHOLE CHAIN, NOT JUST THE TOP MODULE.
      #
      # Discovery names the DRIVER - rtw88_8821ce, mt7921e. The library modules underneath it
      # are not in $mods, so nothing removed them. Measured 2026-09-17: after `disable` the
      # device was unbound and wlp2s0 gone, but rtw88_core, mac80211 and cfg80211 stayed
      # resident on host-1/2/3 and six modules on host-4. Harmless with no device bound and
      # the driver blacklisted, but "wireless modules still loaded" in a checklist is an
      # argument nobody needs to have.
      #
      # Remove by REFCOUNT, not in a fixed order: the vendor bt* helpers hold references
      # until btusb goes and mac80211/cfg80211 only release once the driver is out. Take
      # anything in the family whose refcnt is 0, repeat until a pass removes nothing, and
      # never touch a PROTECTED module whatever the regex says.
      local pass removed m2
      for pass in 1 2 3 4 5; do
        removed=0
        for m2 in $(radio_family_resident); do
          case " $prot " in *" $m2 "*) continue ;; esac
          [ "$(cat "/sys/module/$m2/refcnt" 2>/dev/null || echo 1)" = 0 ] || continue
          if modprobe -r "$m2" 2>/dev/null; then removed=1; fi
        done
        [ "$removed" -eq 1 ] || break
      done
      left=""
      for m in $mods; do
        if radio_loaded "$m"; then left="$left $m"; fi
      done
      if [ -n "$left" ]; then
        warn "still loaded after unload:$left - they will not load on next boot, but say so"
        warn "  in the evidence rather than claiming the radio is off right now"
        radio_log DISABLE "blocked: $mods; still resident:$left"
      else
        ok "all radio modules unloaded"
        radio_log DISABLE "blocked and unloaded: $mods"
      fi
      say ""
      say "  verify with:  sudo $0 radio status"
      say ""
      ;;

    enable)
      need_root
      [ -f "$RADIO_BLOCK" ] || { warn "no $RADIO_BLOCK - nothing of ours to remove"; return 0; }
      backup_file "$RADIO_BLOCK"
      rm -f "$RADIO_BLOCK"
      rebuild_initramfs || warn "initramfs not rebuilt - the block may still be in it"
      radio_log ENABLE "removed $RADIO_BLOCK - V-270755 is now OPEN on this machine"
      warn "radio block REMOVED. V-270755 is a finding until 'radio disable' is run again."
      say "  other files may still block: $(radio_block_files | tr '\n' ' ')"
      say ""
      ;;

    *) die "usage: $0 radio {status|disable|enable}" ;;
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
# THE PASSWORD IS NOT THIS SCRIPT'S BUSINESS. (Since 2026-09-25 a pre-made pbkdf2 HASH may come
# from GRUB_PASSWORD_HASH or the site credentials file - see cred_get. The password never does.)
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

# RUNBOOK 6.0 STEP 12c (05-harden-host.sh step_grub: prep, then set). Needs a reboot, batched
# at 12e. `status` is read-only and belongs in every post-patch check too, because a
# grub-common upgrade replaces 10_linux and drops --unrestricted (ssp-inputs 4.4).
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
      # Insert " --unrestricted" just before the closing quote of the CLASS="..." line.
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

      # A PRE-MADE HASH FIRST (2026-09-25) - environment, then the site credentials file - so an
      # unattended rebuild never stops here. Made OFFLINE with grub-mkpasswd-pbkdf2 by the
      # custodians; the password itself is never stored anywhere.
      local H src=""
      H="${GRUB_PASSWORD_HASH:-}"; [ -n "$H" ] && src="GRUB_PASSWORD_HASH (environment)"
      if [ -z "$H" ]; then cred_require_safe; H="$(cred_get GRUB_PASSWORD_HASH)"; [ -n "$H" ] && src="$ENCLAVE_CREDENTIALS"; fi
      if [ -n "$H" ]; then
        # CHECK THE SHAPE: a truncated or mis-pasted hash would lock the editor with a password
        # nobody knows - or, worse, one that matches nothing and is never noticed.
        [[ "$H" =~ ^grub\.pbkdf2\.sha512\.[0-9]+\.[0-9A-F]+\.[0-9A-F]+$ ]] \
          || die "the GRUB hash from $src is not a grub.pbkdf2.sha512 hash - nothing was changed"
        ok "using the GRUB password hash from $src - no prompt (${#H} chars, not shown)"
      else
      # READ IT TWICE, SILENTLY, AND NEVER ECHO IT.
      local P P2
      read -rsp '  GRUB password (enclave-wide, from the controlled document): ' P; echo
      read -rsp '  again: ' P2; echo
      [ -n "$P" ] || die "empty password - refusing"
      [ "$P" = "$P2" ] || die "the two entries do not match - nothing was changed"

      # PIPED, NOT PROMPTED - its prompts go to stdout and would be captured.
      H="$(printf '%s\n%s\n' "$P" "$P" | grub-mkpasswd-pbkdf2 2>/dev/null \
            | awk '/PBKDF2 hash/{print $NF}')"
      P=""; P2=""
      case "$H" in
        grub.pbkdf2.sha512.*) ok "hash generated (${#H} chars, not shown)" ;;
        *) die "grub-mkpasswd-pbkdf2 produced nothing usable - nothing was changed" ;;
      esac
      fi

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

      # update-grub regenerates /boot/grub/grub.cfg from /etc/grub.d - the file GRUB reads.
      # Nothing edited above has any effect at boot until this succeeds.
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
      # NAME THE RECOVERY ROUTE THAT EXISTS ON THIS MACHINE. The first version told host-4 to
      # run `vm-rescue.sh console host-4` from host-4 - advice that is nonsense on the
      # hypervisor, printed at the exact moment someone is deciding whether it is safe to
      # reboot. A recovery instruction that is wrong is worse than none.
      if [ "$(systemd-detect-virt 2>/dev/null || echo none)" = none ]; then
        warn "  BARE METAL - there is no vm-rescue console here. Your routes are:"
        if grep -q 'console=ttyS' /proc/cmdline 2>/dev/null; then
          warn "    - the SERIAL console ($(grep -o 'console=ttyS[^ ]*' /proc/cmdline | head -1)),"
          warn "      IF something is actually attached to that port. Verify that, do not assume it."
        fi
        if [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ]; then
          warn "    - BMC serial-over-LAN (/dev/ipmi present)"
        else
          warn "    - NO BMC on this machine (no /dev/ipmi*), so otherwise: physical access."
        fi
        warn "    Do not reboot without one of those available."
      else
        warn "  Have the console route open first, FROM THE HYPERVISOR:"
        warn "    ./scripts/enclave/vm-rescue.sh console $me"
      fi
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
#   V-270817/658             - audit offload. A collector VM EXISTS now (svc-obs-01); what is
#                              still missing is the three AO answers, not the machine. 6.3d
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
# THE LINE THAT MAKES IT SURVIVE A REBOOT (2026-09-25, measured on host-1). At boot the vendor
# `z /var/log/journal/%m 2755` beat DISA's `Z /var/log/journal/%m ~0640`: where both rules for a
# path are the SAME type (`z` vs `z`, the top-level dir) ours wins; where the types DIFFER
# (`z` vs `Z`) the vendor's does. So the machine-id dir gets its own same-type `z` line, in a file
# of its own so DISA's four-line FixText stays exactly four lines.
JOURNAL_MID_TMPFILES=/etc/tmpfiles.d/zzzz-enclave-journal.conf
JOURNAL_MID_LINE='z /var/log/journal/%m 0640 root systemd-journal - -'
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
# THE MACHINE-ID SUBDIRECTORIES, WHICH v1r6_journal_dirs DOES NOT SEE.
#
# Measured on host-4 2026-09-18: /var/log/journal and /run/log/journal were both 0640 and the
# subdirectory /var/log/journal/<machine-id> was 2750. The apply was gated on the PARENTS
# only, so it was skipped - and the file it would have written is precisely what fixes the
# subdirectory. The result was an advice loop: v1r6 --apply said "fix: run fixups --apply",
# fixups --apply said "v1r6 --apply writes it", and neither wrote anything.
#
# A trigger that cannot see the broken object will never fire on it.
v1r6_journal_subbad() {
  local sub
  for sub in /var/log/journal/*/ /run/log/journal/*/; do
    [ -d "$sub" ] || continue
    case "$(stat -c %a "$sub" 2>/dev/null)" in
      640|600|0640|0600) : ;;
      *) printf '%s(%s) ' "$sub" "$(stat -c %a "$sub" 2>/dev/null)" ;;
    esac
  done
}
# CHECKING THE DIRECTORIES WAS NOT ENOUGH. V-270757 is about directory modes and V-270762 is
# about FILE group ownership, and the fix for the first broke the second. Report both.
v1r6_journal_badfiles() {
  find /run/log/journal /var/log/journal -type f ! -group systemd-journal 2>/dev/null || true
}
# ACCEPTED vs ACTUALLY WRONG - and the difference is documented, so the check must know it.
#
# V-270757 forbids setgid on the journal directories (the scanner's `-perm /7137` catches it),
# and setgid is what made journald set the group. So files created between tmpfiles runs land
# root:root 0640. That is STRICTER than the systemd-journal group this control asks for, it is
# answered in the answer file on exactly that basis, and runbook 10.1 carries the measurement.
#
# So `root` at 0640-or-tighter is the accepted state. Anything else - a different group, or
# group-write, or any world bit - is a real finding and must fail.
v1r6_journal_reallywrong() {
  find /run/log/journal /var/log/journal -type f ! -group systemd-journal \
       \( ! -group root -o -perm /0027 \) 2>/dev/null || true
}

# RUNBOOK 6.0 STEP 12d (05-harden-host.sh step_v1r6 runs --apply, step_verify runs --verify).
# Runs BEFORE the first Evaluate-STIG scan so the scan measures the residual, not these.
#   (none)    plan: DISA's check for each control, and the fix it would make
#   --apply   root: make the fixes; audit=1 and new audit rules need a REBOOT (batched at 12e)
#   --verify  the plan, scored: returns 1 while anything is outstanding, so it can gate
# Controls handled: V-270645, V-270750, V-270699, V-270714, V-270676, V-274870, V-270757 /
# V-270762. Re-run --apply after every patch cycle (05-harden-host.sh step_done): a PAM
# package upgrade reinstates nullok.
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
          # Delete every " nullok" token (with its leading whitespace), leaving the rest of
          # each pam_unix line exactly as it was.
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
        # Append audit=1 inside the closing quote of the line if it lacks it; add the whole
        # line if the variable is not set at all.
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
      # augenrules merges /etc/audit/rules.d/*.rules into audit.rules and loads the result.
      # Its exit status is ignored on purpose: the live `auditctl -l` check below is the test.
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
  local jbad jreal; jbad="$(v1r6_journal_badfiles)"; jreal="$(v1r6_journal_reallywrong)"
  if [ -n "$jbad" ]; then
    say "   $(printf '%s\n' "$jbad" | grep -c .) journal FILE(s) not group systemd-journal - V-270762."
    if [ -n "$jreal" ]; then
      say "   AND $(printf '%s\n' "$jreal" | grep -c .) of them are looser than root/0640 - a real finding."
    else
      say "   All are root:root 0640, which is STRICTER than the control asks. Accepted and"
      say "   answered - V-270757 forbids the setgid bit journald needed. runbook 10.1."
    fi
  fi
  # THE DECLARATION IS PART OF THE CONDITION, NOT JUST THE SYMPTOM. Found 2026-09-21 on
  # svc-mgmt-01: its directories were already 0640, so this whole block was skipped and the
  # machine kept the STALE TWO-LINE file from 2026-09-11 - the version that manufactured
  # V-270762. It measured compliant with nothing declaring it: journald resets those modes on
  # restart and the four-line file is what puts them back. A control whose value is correct by
  # accident re-opens the first time something touches it, and the scan in between reads clean.
  local jtf_stale=0
  if [ ! -f "$V1R6_JOURNAL_TMPFILES" ] \
     || [ "$(grep -c '^[zZ] ' "$V1R6_JOURNAL_TMPFILES" 2>/dev/null || echo 0)" -ne 4 ]; then
    jtf_stale=1
    say "   $V1R6_JOURNAL_TMPFILES is missing or not DISA's four-line FixText - it will be rewritten"
  fi
  if v1r6_journal_dirs | awk '{print $1}' | grep -qv '^640$' || [ -n "$jreal" ] \
     || [ "$jtf_stale" -eq 1 ] || [ -n "$(v1r6_journal_subbad)" ]; then
    n_todo=$((n_todo+1))
    if [ "$apply" -eq 1 ]; then
      # DISA names this exact filename. MEASURED on svc-mgmt-01: it wins over
      # /usr/lib/tmpfiles.d/systemd.conf's `Z ... ~2750` despite sorting later. Reasoning
      # about tmpfiles precedence got this wrong; measuring got it right.
      # DISA'S FIXTEXT IS FOUR LINES. THE FIRST VERSION WROTE TWO, AND THAT MANUFACTURED A
      # SECOND FINDING.
      #
      # `z <dir> 0640` sets the DIRECTORY and nothing else. Setting a journal directory to
      # 0640 strips the setgid bit that /usr/lib/tmpfiles.d/systemd.conf's `~2750` carried -
      # and setgid is what made journald's NEW files inherit group systemd-journal. Without
      # it they land with the creating process's group, which is root, and that is
      # UBTU-24-700070 / V-270762 ("files used by the system journal must be group-owned by
      # systemd-journal").
      #
      # Measured on svc-mgmt-01 2026-09-11: every journal file written AFTER the two-line
      # version was applied had group root; every file before it had systemd-journal. All
      # four machines were left in that state.
      #
      # The `Z ... %m` lines are RECURSIVE and set group ownership, which is what keeps the
      # files right. They are in DISA's FixText for BOTH controls. Apply it whole, not the
      # half that happens to satisfy the control you were looking at.
      cat > "$V1R6_JOURNAL_TMPFILES" <<'TMPF'
# UBTU-24-700020 / V-270757 AND UBTU-24-700070 / V-270762 - DISA's FixText for both,
# complete. This filename is the one DISA names; it overrides
# /usr/lib/tmpfiles.d/systemd.conf's `Z /var/log/journal ~2750` (measured 2026-09-11).
#
# The `z` lines set the top-level directories. The `Z ... %m` lines are RECURSIVE and set
# group ownership on the journal FILES - without them, 0640 on the directory strips setgid
# and journald starts writing files owned by group root.
z /run/log/journal 0640 root systemd-journal - -
Z /run/log/journal/%m ~0640 root systemd-journal - -
z /var/log/journal 0640 root systemd-journal - -
Z /var/log/journal/%m ~0640 root systemd-journal - -
TMPF
      chmod 0644 "$V1R6_JOURNAL_TMPFILES"
      # Apply it now. The global form is used here; `fixups` item 0d names the file instead,
      # because on host-1 the global form left the machine-id directory at 2755.
      systemd-tmpfiles --create >/dev/null 2>&1 || true
      v1r6_journal_dirs | sed 's/^/       now: /'
      local badf really; badf="$(v1r6_journal_badfiles)"; really="$(v1r6_journal_reallywrong)"
      if [ -n "$really" ]; then
        warn "   journal file(s) neither systemd-journal NOR root/0640 - a REAL V-270762:"
        printf '%s\n' "$really" | head -5 | sed 's/^/         /'
        failed=1
      elif [ -n "$badf" ]; then
        ok "   $(printf '%s\n' "$badf" | grep -c .) journal file(s) are root:root 0640 - ACCEPTED"
        say "     V-270757 forbids setgid on the directory, which is what made journald set"
        say "     the group. root at 0640 is STRICTER than systemd-journal at 0640. Answered"
        say "     in the answer file on that basis - runbook 10.1."
      else
        ok "   all journal files are group systemd-journal (V-270762)"
      fi
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
    # WIDENED 2026-09-17. This used to stop here and say "both directories are 0640", which
    # was TRUE and still missed the finding: UBTU-24-700020 also evaluates the PER-MACHINE-ID
    # subdirectory, /var/log/journal/<machine-id>, and journald resets that to 2755 after a
    # systemd upgrade. host-1 and host-2 failed the rule while this check reported a pass;
    # host-3 passed. Identical file permissions on all three - the only difference was the
    # one directory nothing looked at.
    #
    # A verify that does not inspect the object the rule inspects reads exactly like a pass.
    local sub subbad=""
    for sub in /var/log/journal/*/ /run/log/journal/*/; do
      [ -d "$sub" ] || continue
      case "$(stat -c %a "$sub" 2>/dev/null)" in
        640|600|0640|0600) : ;;
        *) subbad="$subbad $sub($(stat -c %a "$sub"))" ;;
      esac
    done
    if [ -n "$subbad" ]; then
      warn "   parent directories are 0640 but a MACHINE-ID SUBDIRECTORY is not:$subbad"
      say  "      journald resets these after a systemd upgrade. UBTU-24-700020 checks them."
      say  "      fix: sudo $0 v1r6 --apply   (writes DISA's four-line tmpfiles rule, which"
      say  "           is what corrects the subdirectory - fixups only re-runs systemd-tmpfiles"
      say  "           against whatever rule is already there)"
      failed=1
    else
      ok "   both directories AND every machine-id subdirectory are 0640"
    fi
  fi

  # ---- what is left, and who has to decide it -------------------------------------------
  printf '\n  NOT HANDLED HERE - each needs a decision, not a command:\n'
  say "   V-270675           GRUB password - interactive. runbook 6.3i"
  say "   V-270663/735/736   smart card / CAC family - one missing subsystem, AO question"
  say "   V-270722/745       DoD PKI + smart-card login - same family"
  say "   V-270817 / 658     audit offload - svc-obs-01 can host the collector; the blocker"
  say "                      is now the three AO answers alone, not the missing VM (6.3d)"
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
*	/var/lib/libvirt/images	VM DISK IMAGES. **Wildcard, not per-host, as of 2026-09-17** - the fragment builder skips any path that does not exist, so this is self-limiting: a machine with no libvirt pool gets nothing, and a fourth or fifth hypervisor at another site is covered without editing this table. Added when host-1..3 were built and `aide status` reported "no entry in the table" while their pools were still EMPTY - which is a trap, not a clean result, because `usg fix` builds the AIDE database at that moment and the 100 GB qcow2 files arrive afterwards. Excluding an empty path now costs nothing; excluding it later means rebuilding the database. VM DISK IMAGES on a dedicated LUKS volume. qcow2 files change on every guest write, so a running VM guarantees the hash is stale before aide finishes - the check cannot pass and its failure carries no information. Guest integrity is each guest's own AIDE, which runbook 6.0 installs on every one of them
host-4	/mnt/vmbackup	THE VM BACKUP VOLUME - 399 GB of qcow2 backup sets on removable, LUKS-encrypted media. Four separate reasons, any one of which is sufficient. (1) SIZE: hashing it blew Evaluate-STIG's 15-minute per-check timeout on 2026-09-16, which is why V-270650 came back Not Reviewed on host-4 and Not a Finding everywhere else. (2) IT IS SUPPOSED TO CHANGE: a new backup set lands every night at 02:00, so AIDE would report thousands of new files every single morning - noise that teaches people to ignore the one alert that matters. (3) IT IS ALREADY INTEGRITY-PROTECTED, and better: every set carries a MANIFEST.sha256 written after the copy completes, and `vm-backup.sh verify` checks both the manifest and the qcow2 structure with qemu-img. That is a stronger statement about a backup than a whole-tree hash. (4) IT IS NOT ALWAYS THERE: usb-storage is STIG-blocked, so the volume is detached after every reboot and reattached deliberately. AIDE would see the entire tree vanish and reappear, which is indistinguishable from the thing it exists to detect. Tracks BACKUP_DEST in vm-specs.env - if that moves, this moves.
*	/var/lib/libvirt/images-data	THE SECOND VM DISK POOL - VM_POOL_DATA in vm-specs.env, deliberately on a different physical device from VM_POOL so a database guest's data and WAL do not share a spindle with the host OS and the cluster's etcd. Same reasoning as the pool above: qcow2 files change on every guest write, so a running VM guarantees the hash is stale before aide finishes, and the check cannot pass. On host-1..3 this is the 500 GB encrypted half of the 1 TB M.2 that carries the PostgreSQL guest's data disk. Wildcard and self-limiting - skipped where the path does not exist.
svc-harbor-01	/var/lib/docker	CONTAINER LAYER STORE - content-addressed by digest, which IS an integrity mechanism, and rewritten by every image push. Harbor's own content trust covers what matters here
svc-obs-01	/var/lib/prometheus/metrics2	THE METRICS DATABASE - a time-series store rewritten continuously as samples arrive and compacted on its own schedule. A hash is stale before aide finishes computing it, so the check cannot pass and its failure carries no information. Retention is capped at 100GB, so this is also the only path here that can grow large
svc-obs-01	/var/lib/grafana	GRAFANA'S SQLITE DATABASE - dashboards, users and sessions, written on every login and every dashboard edit. Same reasoning: it changes as part of normal operation. The CONFIGURATION that matters for integrity is /etc/grafana, which is NOT excluded and stays in scope
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
    # RECORD THE MEASURED SIZE, NOT THE ESTIMATE IN THE TABLE. The table said "~1.9 TB of
    # qcow2" for host-4 because that is the VOLUME; 362 GB was actually present. An assessor
    # reads this fragment, and a number that overstates by 5x undermines the justification it
    # is supporting. The table now carries the reasoning; the fragment carries the fact.
    printf '# %s\n# measured %s at %s\n!%s\n' \
      "$why" "$(aide_human "$(aide_du_bytes "$path")")" "$(date -Is)" "$path"
    n=$((n + 1))
  done < <(aide_excludes)
  [ "$n" -gt 0 ] || printf '# no exclusions apply to %s\n' "$me"
}

# EVERY LOCAL FILESYSTEM, NOT JUST THE ROOT ONE.
#
# `du -x` stops at a mount point. On host-4 the 362 GB image store is its own filesystem at
# /var/lib/libvirt/images, so a `du -x /` scan reported "nothing over 5 GB is in scope" on the
# one machine where the check mattered most - while 362 GB sat unexcluded and AIDE, which
# walks paths and does not care about mount boundaries, would have hashed all of it.
#
# So: enumerate the LOCAL filesystems and scan each. Network and pseudo filesystems are
# excluded by type rather than by path, because a check that depends on remembering every
# mount point is a check that misses the next one.
aide_local_mounts() {
  findmnt -rn -o TARGET,FSTYPE 2>/dev/null | awk '
    $2 ~ /^(proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|securityfs|pstore|efivarfs|bpf|tracefs|debugfs|mqueue|hugetlbfs|configfs|fusectl|ramfs|autofs|binfmt_misc|squashfs|nsfs|rpc_pipefs)$/ { next }
    $2 ~ /^(nfs|nfs4|cifs|smb3|fuse\.sshfs|ceph|glusterfs)$/ { next }
    { print $1 }' | sort -u || true
}

# du that cannot wander off the machine. -x stays on one filesystem; the pseudo-filesystems
# are named anyway because a bind mount of /proc inside a container root is not hypothetical.
aide_du_bytes() {
  du -sxb --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run "$1" 2>/dev/null \
    | awk '{print $1}'
}

aide_human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}"; }

# RUNBOOK 6.0 STEP 8c (05-harden-host.sh step_prechecks runs `aide exclude --apply`).
#   status             read-only: the fragment, the table, and anything >AIDE_BIG_GB in scope
#   exclude            plan: print the fragment it would write
#   exclude --apply    root: write $AIDE_FRAGMENT, then say whether the database is now stale
#   init               root: rebuild the database with aideinit - hours; refuses without the
#                      fragment
# Why it matters beyond the fix-run time: V-270650 (UBTU-24-100110) runs a full aide --check,
# and on host-4 hashing /mnt/vmbackup blew the scanner's 15-minute per-rule timeout.
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
      done < <(aide_local_mounts | while IFS= read -r mp; do
                 [ -d "$mp" ] || continue
                 du -xb --max-depth=3 --threshold="$thresh" \
                    --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
                    --exclude=/var/lib/aide "$mp" 2>/dev/null || true
               done | sort -rn -k1,1 -u)
      # THE SUMMARY MUST NOT CONTRADICT THE TABLE ABOVE IT. host-4 printed
      #   /var/lib/libvirt/images  362GB  present
      #   [ok] nothing over 5 GB is in scope
      # in the same report. If a path the table wants excluded is on the disk and no fragment
      # covers it, that is the answer, whatever the size scan found.
      local uncovered=0 mach path why
      while IFS=$'\t' read -r mach path why; do
        [ -n "${mach:-}" ] || continue
        [ "$mach" = '*' ] || [ "$mach" = "$me" ] || continue
        [ -e "$path" ] || continue
        grep -q "^!${path}$" "$AIDE_FRAGMENT" 2>/dev/null || uncovered=$((uncovered + 1))
      done < <(aide_excludes)
      if [ "$uncovered" -gt 0 ]; then
        warn "$uncovered path(s) the table wants excluded are present and NOT covered by"
        warn "  $AIDE_FRAGMENT - run: sudo $0 aide exclude --apply"
      elif [ "$found" -eq 1 ]; then
        say "  nothing else over ${AIDE_BIG_GB} GB is in scope"
      else
        ok "nothing over ${AIDE_BIG_GB} GB is in scope"
      fi
      say "  scanned filesystems: $(aide_local_mounts | tr '\n' ' ')"
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
      # ASK THE DATABASE, DO NOT ASSUME. This used to warn "stale until rebuilt" whenever a
      # database existed at all - true when an exclusion is added for a path the database
      # already covers, and false when the path did not exist when the database was built.
      # On host-4, 2026-09-16, it sent the operator at a multi-hour aideinit that would have
      # achieved nothing: /mnt/vmbackup was created three days AFTER that database, so the
      # exclusion brought the CHECK into line with the database rather than out of it.
      #
      # A rebuild is hours on this machine. A warning that cannot tell the difference between
      # "you must" and "you need not" is the same failure as an alert that always fires.
      if command -v aide >/dev/null 2>&1 && [ -f "$AIDE_DB" ]; then
        local stale=0 n
        while IFS=$'\t' read -r mach path why; do
          [ -n "${mach:-}" ] || continue
          [ "$mach" = '*' ] || [ "$mach" = "$me" ] || continue
          # The database may be plain or gzipped depending on the aide build; try both and
          # never let a no-match exit status end the script.
          n="$(zgrep -c "^${path}/" "$AIDE_DB" 2>/dev/null || true)"
          [ -n "$n" ] || n="$(grep -c "^${path}/" "$AIDE_DB" 2>/dev/null || true)"
          case "$n" in ''|*[!0-9]*) n=0 ;; esac
          if [ "$n" -gt 0 ]; then
            stale=1
            warn "  $path: $n entry(ies) ALREADY IN the database"
          fi
        done < <(aide_excludes)
        if [ "$stale" -eq 1 ]; then
          warn "the database covers a path this exclusion now removes - it is stale."
          warn "  rebuild it:  sudo $0 aide init      (hours on a large filesystem)"
        else
          ok "database holds nothing under the excluded path(s) - NO REBUILD NEEDED"
          say "     $AIDE_DB, built $(date -r "$AIDE_DB" -Is 2>/dev/null)"
        fi
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
      # Debian's wrapper around `aide --init`. -y overwrites aide.db.new and -f replaces an
      # existing $AIDE_DB, both without asking (aide-common's own usage text).
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
# svc-mgmt-01 WAS different (MAAS removed 2026-09-18 - kept here because it is why this
# preflight exists): it ran isc-dhcp-server (MAAS DHCP), python3-txtftp (PXE TFTP),
# squid (maas-proxy) and nginx. A single package_*_removed rule that matches one of those
# takes out commissioning - and commissioning is how host-1..3 get built. Finding that out
# from a broken PXE boot next week is not the same as finding it out now.
#
# So: cross-reference the SELECTED rules against what is actually installed and running, and
# print the collisions BEFORE anything is remediated. Rule ids carry the target in the middle:
# package_<name>_removed, service_<name>_disabled, service_<name>_masked.
#
# This does not decide anything. It tells you what to decide.

# RUNBOOK 6.0 STEP 8b (05-harden-host.sh step_prechecks: a failure here stops the build
# before `usg fix`, and the operator must confirm the collisions were read). READ-ONLY. Run
# it with sudo: unprivileged, the NOPASSWD check cannot read /etc/sudoers.d and says so.
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
#   svc-mgmt-01 - WAS absent: MAAS opened ~30 ports and getting them wrong broke PXE. MAAS was
#                 removed 2026-09-18, and its table below was written 2026-09-19 from the
#                 MEASURED listeners (ppsm.py, backlog 6a.22), not from a port list in a doc.
#   host-4      - it BRIDGES guest traffic over br0, and ufw's default FORWARD policy is DROP.
#                 Enabling ufw on the hypervisor can cut off every VM depending on
#                 br_netfilter. Same class of risk as MAAS, and it takes the whole enclave
#                 with it rather than one machine.
#
#   The script REFUSES on a machine it has no table for. That is the guard, not a comment.

ufw_rules() {
cat <<'EOF'
svc-repo-01	22/tcp	limit	any	ssh - safe to rate-limit, and what the rule is really aimed at
svc-repo-01	80/tcp	allow	any	nginx 301 redirect only; kept so a plaintext client gets a redirect rather than a timeout
svc-repo-01	443/tcp	allow	any	THE MIRROR - 318 GB of apt over TLS, plus /keys /debs /snaps /maas-images. LIMIT here throttles apt for every machine in the enclave
svc-repo-01	9100/tcp	allow	__SVC_OBS_01__	node-exporter. SOURCE-RESTRICTED to the collector - metrics name every mount, interface, process count and kernel version on the box, and there is no reason for anything but svc-obs-01 to read them
svc-harbor-01	22/tcp	limit	any	ssh
svc-harbor-01	80/tcp	allow	any	NO-OP under Docker - docker-proxy DNATs this, so ufw INPUT never sees it. Kept for the day Harbor runs host-network. runbook 6.3e
svc-harbor-01	443/tcp	allow	any	NO-OP under Docker - same reason. ufw on this host protects ssh and postfix, NOT the registry ports. Say so in the findings register
svc-harbor-01	9100/tcp	allow	__SVC_OBS_01__	node-exporter, source-restricted to the collector - same reasoning as svc-repo-01
svc-obs-01	22/tcp	limit	any	ssh
svc-obs-01	443/tcp	allow	__ENCLAVE_CIDR__	GRAFANA over TLS, via nginx with an enclave certificate. Restricted to the enclave subnet, not the world: the dashboards expose the shape of every host in the boundary. Grafana itself binds 127.0.0.1:3000 and is NOT reachable - the admin password and every session cookie would otherwise cross the enclave in clear
svc-obs-01	80/tcp	allow	__ENCLAVE_CIDR__	301 to https only, so a plaintext client gets a redirect rather than a timeout. Same arrangement as svc-repo-01
svc-obs-01	9100/tcp	allow	__SVC_OBS_01__	its own node-exporter, scraped by the Prometheus on this same box. Kept explicit so the rule set reads the same on every machine
host-4	9100/tcp	limit	__SVC_OBS_01__	node-exporter. NOTE: host-4 has no rule table in practice - see the comment above ufw_rules() - so this row exists for the day it does, and documents the intent meanwhile. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
host-4	9177/tcp	limit	__SVC_OBS_01__	prometheus-libvirt-exporter. Per-guest CPU, disk and network for EVERY VM in the enclave - the single most revealing port in the boundary. Source-restricted, always. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
host-1	22/tcp	limit	any	ssh - the ONLY management path into this machine. No BMC, no serial console, and the LUKS root prompts at a physical console, so losing ssh means a drive to the rack. `limit` not `deny`: rate-limiting is what the STIG rule is aimed at
host-1	9100/tcp	limit	__SVC_OBS_01__	node-exporter, source-restricted to the collector. Listening since 2026-09-18, when monitoring was extended to host-1/2/3. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
host-1	9177/tcp	limit	__SVC_OBS_01__	prometheus-libvirt-exporter. Added 2026-09-18 when host-1 became a virtualisation host - per-guest CPU, disk and network for every VM it runs. Source-restricted to the collector, always: this is the most revealing port on the machine. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
host-2	22/tcp	limit	any	ssh - same reasoning as host-1
host-2	9100/tcp	limit	__SVC_OBS_01__	node-exporter, source-restricted to the collector. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
host-2	9177/tcp	limit	__SVC_OBS_01__	prometheus-libvirt-exporter. Added 2026-09-18 when host-2 became a virtualisation host - per-guest CPU, disk and network for every VM it runs. Source-restricted to the collector, always: this is the most revealing port on the machine. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
host-3	22/tcp	limit	any	ssh - same reasoning as host-1
host-3	9100/tcp	limit	__SVC_OBS_01__	node-exporter, source-restricted to the collector. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
host-3	9177/tcp	limit	__SVC_OBS_01__	prometheus-libvirt-exporter. Added 2026-09-18 when host-3 became a virtualisation host - per-guest CPU, disk and network for every VM it runs. Source-restricted to the collector, always: this is the most revealing port on the machine. LIMIT not allow (2026-09-19): the only permitted source scrapes every 15 s, ~2 connections per 30 s, well under ufw's 6-per-30 s threshold - and ufw_rate_limit fails on ANY listening port left at allow
svc-mgmt-01	22/tcp	limit	any	ssh - administrative access; limit is safe here, as everywhere
svc-mgmt-01	53/tcp	allow	__ENCLAVE_CIDR__	BIND - authoritative for enclave.internal and its reverse zone, recursion off. TCP for large answers and zone checks. allow not limit: every machine resolves through this box, and a rate limit on DNS fails resolution enclave-wide
svc-mgmt-01	53/udp	allow	__ENCLAVE_CIDR__	BIND over UDP - the normal query path. Enclave subnet only; recursion is off, so it answers nothing outside enclave.internal anyway
svc-mgmt-01	123/udp	allow	__ENCLAVE_CIDR__	chrony serving time on to the enclave - it syncs from host-4 (the reference) and serves the subnet
svc-mgmt-01	80/tcp	allow	__ENCLAVE_CIDR__	nginx 301 to https only, so a plaintext client gets a redirect rather than a timeout
svc-mgmt-01	443/tcp	allow	__ENCLAVE_CIDR__	nginx TLS in front of the Ubuntu Pro contracts server on 127.0.0.1:8484 - every machine's `pro` client talks to it. 8484 itself is NOT in this table: it is loopback-only by systemd IPAddressDeny, proven by the 2026-09-19 scan (filtered)
svc-mgmt-01	9100/tcp	limit	__SVC_OBS_01__	node-exporter, source-restricted to the collector; limit for the same reason as host-1/2/3
EOF
}

# RUNBOOK 6.0 STEP 12b (05-harden-host.sh step_tailor runs it LAST, then stops for an off-box
# reachability check). usg rules check_ufw_active, set_ufw_default_rule, ufw_rate_limit;
# the DISA side is V-270754. No flag = plan (read-only); --apply = root, rebuilds the whole
# rule set from ufw_rules() and enables ufw. Refuses on a machine with no table.
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

  # __SVC_OBS_01__ resolves from enclave-addresses.env, the single source of truth for who is
  # at which address. Hardcoding the collector's IP in this table would put the same address in
  # a second place and guarantee they drift.
  local obs="${SVC_OBS_01:-}"
  # The enclave CIDR is derived from the addresses file rather than written down again - the
  # third octet is the one thing that changed when the lab moved behind its own router (3.1),
  # and a hardcoded 10.2.20.0/24 here would be the copy that got missed.
  local cidr="${ENCLAVE_CIDR:-${SVC_OBS_01%.*}.0/24}"
  local mine; mine="$(ufw_rules \
      | sed -e "s|__SVC_OBS_01__|${obs}|g" -e "s|__ENCLAVE_CIDR__|${cidr}|g" \
      | awk -F'\t' -v m="$me" '$1==m')"

  # NO TABLE AT ALL IS CHECKED FIRST, and the order is load-bearing. `printf '%s\n' ""`
  # emits ONE EMPTY LINE, so awk sees a record whose $4 is empty and the source check below
  # fires - reporting "SVC_OBS_01 is probably unset" on a machine where it is set perfectly
  # well. Measured on host-1 2026-09-17: it sent the operator to inspect the address file
  # while the real answer was that host-1 simply had no rows yet. A diagnostic that names the
  # wrong cause is worse than no diagnostic.
  if [ -z "$mine" ]; then
    die "no ufw rule table for '$me'.
       Every bare-metal host and service VM needs its own rows in ufw_rules() - there is no
       default, deliberately, because a firewall built from a guess is worse than none.
       A new hypervisor needs at least: 22/tcp limit, and 9100/tcp restricted to the
       collector once monitoring reaches it."
  fi

  # A SOURCE-RESTRICTED RULE WITH NO SOURCE IS A RULE OPEN TO EVERYTHING. If the address is
  # unset the substitution leaves an empty field, `ufw allow from  to any port 9100` becomes
  # `ufw allow 9100`, and a port meant for one host is open to the enclave. Refuse instead.
  if printf '%s\n' "$mine" | awk -F'\t' '$4=="" {found=1} END {exit !found}'; then
    die "a rule for $me has an EMPTY source field - SVC_OBS_01 is probably unset in
       enclave-addresses.env. Refusing: an empty source silently becomes 'from anywhere'."
  fi
  if [ -z "$mine" ]; then
    die "no ufw rule table for '$me'.
      This machine is deliberately not covered - see the comment above ufw_rules().
      host-4:      bridges guest traffic; ufw FORWARD policy can cut off every VM.
      Add a table entry only after the port list is confirmed AND tested."
  fi

  printf '\n  ufw plan for %s\n\n' "$me"
  printf '  %-10s %-7s %-14s %s\n' PORT ACTION FROM WHY
  printf '%s\n' "$mine" | awk -F'\t' '{printf "  %-10s %-7s %-14s %s\n", $2, $3, $4, $5}'

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

  # Start from an EMPTY rule set, so what is live afterwards is exactly the table - no rule
  # left over from a hand edit. --force skips ufw's interactive confirmation.
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null   # set_ufw_default_rule
  # Outbound stays open: the table, and the ufw rules above, govern INBOUND listeners only.
  ufw default allow outgoing >/dev/null
  local port action src why
  while IFS=$'\t' read -r _ port action src why; do
    [ -n "${port:-}" ] || continue
    if [ "$src" = any ]; then
      ufw "$action" "$port" >/dev/null || die "ufw $action $port failed"
      ok "ufw $action $port   ($why)"
    else
      # `from <ip> to any port <n>` - ufw's own syntax. The port number must be bare here,
      # so strip the /tcp and pass the protocol separately.
      local pnum proto
      pnum="${port%%/*}"; proto="${port#*/}"
      ufw "$action" from "$src" to any port "$pnum" proto "$proto" >/dev/null \
        || die "ufw $action from $src to any port $pnum proto $proto failed"
      ok "ufw $action $port from $src   ($why)"
    fi
  done < <(printf '%s\n' "$mine")

  # --force skips the "may disrupt existing ssh connections" prompt - safe only because the
  # 22/tcp rule was proven present above. check_ufw_active.
  ufw --force enable >/dev/null && ok "ufw enabled"
  say ""
  ufw status verbose | sed 's/^/  /'
  say ""
  warn "NOW VERIFY FROM ANOTHER MACHINE before you close this session:"
  say "   ssh from host-4, and fetch something over 443. A firewall you have not tested"
  say "   from off-box is a firewall you are guessing about."
}

# ------------------------------------------------------------------------- luksenroll
# ENROL THE TPM SO THE HOST UNLOCKS WITHOUT A HUMAN - keeping the passphrase as a fallback.
#
# Why this is a separate step and not part of the install: sealing binds the key to the boot
# chain's PCR measurements, and curtin runs in the INSTALLER's boot state. Sealing there would
# bind to a measurement the installed system never reproduces, and the host would never unlock.
# The installer records the CHOICE in /etc/enclave-build-info; this acts on it after first boot.
#
# WHAT THIS IS NOT: it is not a compliance change. Verified 2026-09-16 against the full DISA
# V1R6 checklist - zero of 194 controls mention TPM, and V-270747 checks only that every
# persistent partition has a crypttab entry, not how the key is supplied. The volume stays
# LUKS and every encryption control evaluates identically. This is a RISK decision (Q20):
# passphrase is two factors, disk AND a human; TPM is one, disk AND this motherboard. It
# defeats a stolen drive and does not defeat a stolen chassis.
#
# PCR 7 ONLY, and that is the load-bearing choice. PCR 11 covers the kernel and initrd and
# would be stronger, but it CHANGES ON EVERY KERNEL UPDATE - and this enclave takes FIPS
# kernel updates. Sealing to 11 turns "always needs a human" into "needs a human
# unpredictably, after a patch, at 02:00", which is worse than what it replaced.
# luks_os_device - echo "<name> <device>" for the volume that PROMPTS at the console.
# Shared by both enrolment methods. The OS volume is the crypttab entry whose key field is
# `none`; the data volume already has a keyfile and never asks anybody anything.
luks_os_device() {
  local cname cuuid _rest keyfield dev=""
  while read -r cname cuuid _rest; do
    case "$cname" in ''|\#*) continue ;; esac
    case "$cuuid" in UUID=*) : ;; *) continue ;; esac
    keyfield="$(awk -v n="$cname" '$1==n{print $3}' /etc/crypttab)"
    if [ "$keyfield" = none ]; then dev="/dev/disk/by-uuid/${cuuid#UUID=}"; printf '%s %s' "$cname" "$dev"; return 0; fi
  done < /etc/crypttab
  return 1
}

# ------------------------------------------------------------------- luksenroll, clevis
# THE METHOD THAT ACTUALLY WORKS ON THIS STACK - measured on host-3, 2026-09-21.
#
# `systemd-cryptenroll` is blocked twice over here and the sibling path below records why:
# libtss2-rc0 is not in the mirror (systemd DLOPENS the TPM2 stack, so one absent library
# reports as an absent feature), and this initrd is cryptsetup-initramfs, which has no TPM2
# token support at all - which is why host-4's `tpm2-device=auto` only ever produced
# "ignoring unknown option" on every rebuild.
#
# clevis stores its own LUKS2 token and ships an initramfs hook that unlocks before the
# passphrase prompt is answered. All four packages are in the mirror and tpm2-tools is the
# FIPS build. PCR 7 only, for the same reason as the systemd path: PCR 11 changes on every
# kernel update, which converts "always needs a human" into "needs a human unpredictably at
# 02:00 after a patch".
cmd_luksenroll_clevis() {
  local force="$1"
  local cname dev
  read -r cname dev <<<"$(luks_os_device || true)"
  [ -n "${dev:-}" ] || die "no crypttab entry with key 'none' - nothing here prompts for a
       passphrase, so there is nothing to enrol. Check /etc/crypttab."
  [ -b "$dev" ] || die "$dev is not a block device"
  ok "OS volume: $cname -> $(readlink -f "$dev")"

  # THE PASSPHRASE FALLBACK MUST EXIST BEFORE ANYTHING IS ADDED. Worst case then is "it
  # prompts like it does today", never "bricked".
  local slots; slots="$(cryptsetup luksDump "$dev" 2>/dev/null | grep -cE '^[[:space:]]+[0-9]+: luks2' || true)"
  [ "${slots:-0}" -ge 1 ] || die "cannot see a usable key slot on $dev - refusing to touch it"
  ok "$slots existing key slot(s) - the passphrase fallback survives this"

  local need="clevis clevis-luks clevis-tpm2 clevis-initramfs tpm2-tools" miss="" p
  for p in $need; do dpkg -s "$p" >/dev/null 2>&1 || miss="$miss $p"; done
  if [ -n "$miss" ]; then
    say "installing:$miss"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $miss >/dev/null 2>&1 \
      || die "could not install:$miss - is the mirror reachable?"
  fi
  for p in $need; do dpkg -s "$p" >/dev/null 2>&1 || die "$p still missing - nothing changed"; done
  ok "clevis and tpm2-tools present"

  # DOES THE TPM ANSWER, UNDER FIPS? Asked before anything is written, because a TPM that
  # cannot read a PCR cannot release a key either, and the answer is the whole feasibility
  # question for this platform.
  local pcr; pcr="$(tpm2_pcrread sha256:7 2>&1 || true)"
  case "$pcr" in
    *0x*) ok "TPM answers under FIPS: PCR 7 = $(printf '%s' "$pcr" | grep -oE '0x[0-9A-F]+' | head -1 | cut -c1-18)..." ;;
    *) warn "tpm2_pcrread failed - the TPM cannot be used for this:"
       printf '%s\n' "$pcr" | head -3 | sed 's/^/       /' >&2
       die "nothing has been changed" ;;
  esac

  if clevis luks list -d "$dev" 2>/dev/null | grep -q tpm2; then
    ok "already bound: $(clevis luks list -d "$dev" 2>/dev/null | head -1)"
  else
    [ "$force" -eq 1 ] || say ""
    say "binding to PCR 7 - you will be asked for the EXISTING LUKS passphrase once, so a new"
    say "   slot can be added. Keyslot 0 and that passphrase are NOT touched."
    clevis luks bind -d "$dev" tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}' \
      || die "bind failed - nothing changed, the passphrase still works"
    ok "bound: $(clevis luks list -d "$dev" 2>/dev/null | head -1)"
  fi

  # CLEVIS DOES NOT USE crypttab OPTIONS, AND A STALE tpm2-device= IS WORSE THAN NOTHING:
  # cryptsetup-initramfs prints "ignoring unknown option 'tpm2-device'" on every rebuild and
  # the line reads as if TPM unlock were configured. host-4 has carried exactly that since
  # 2026-09-16. Remove it where it appears, and back the file up first - it is the boot path.
  if grep -q 'tpm2-device=' /etc/crypttab; then
    cp -a /etc/crypttab "/var/backups/crypttab.$(date +%Y%m%dT%H%M%S)"
    # Three forms, so the option comes out cleanly wherever it sits in the comma list.
    sed -i -e 's/,tpm2-device=auto//g' -e 's/tpm2-device=auto,//g' -e 's/[[:space:]]tpm2-device=auto$//' /etc/crypttab
    ok "removed the inert tpm2-device= option from /etc/crypttab (clevis does not use it)"
  fi

  # The hook has to be IN the running kernel's initrd, and `update-initramfs -u` without -k
  # targets the newest by version sort - where `generic` sorts after `fips`. That cost a day
  # on host-4; rebuild_initramfs names the kernel and proves the file moved.
  rebuild_initramfs clevis \
    || warn "the binding exists but the running initrd may not carry clevis - it will fall
       back to the passphrase, which is safe. Re-run before relying on unattended boot."
  say ""
  ok "enrolled. THE TEST IS A REBOOT: the console shows the passphrase prompt briefly and then"
  say "   continues without input. If it waits, type the passphrase - nothing is lost."
  say "   Undo with:  clevis luks unbind -d $dev -s <slot> && update-initramfs -u -k all"
  say ""
  warn "SCOPE: Secure Boot is off on this hardware, so PCR 7 does not bind the boot chain."
  say  "   This defeats a stolen DISK, not a stolen CHASSIS, and it does nothing for a FAILED"
  say  "   boot - seeing that still needs a BMC (backlog 1.1, 2.8)."
}

# NOT A RUNBOOK 6.0 STEP: runbook 6.3i.1, physical hosts only, once after first boot, for a
# host built with LUKS_UNLOCK=tpm2. Proven on all four hosts with the clevis default
# (backlog 2.4). Everything below the `case` is the --method=systemd path, kept for a stack
# whose initramfs carries systemd-cryptsetup. NOTE: only that path reads the build's choice
# from /etc/enclave-build-info (its step 2); the clevis default does not consult it.
# ssp-inputs 2.1 states the trade: defeats a stolen disk, not a stolen chassis.
cmd_luksenroll() {
  need_root
  local force=0 dev slot_count method=clevis
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      # DEFAULT IS clevis BECAUSE IT IS THE ONE THAT WORKS HERE - proven on host-3
      # 2026-09-21. --method=systemd keeps the original path for a stack where
      # systemd-cryptsetup is in the initrd and libtss2-rc0 is available.
      --method=*) method="${1#--method=}"; shift ;;
      --method) method="${2:?--method needs clevis or systemd}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  case "$method" in
    clevis)  cmd_luksenroll_clevis "$force"; return $? ;;
    systemd) say "method=systemd - the original path. See runbook 6.3i.1 for why clevis is the default." ;;
    *) die "--method must be clevis or systemd, got '$method'" ;;
  esac

  # ---- 1. a TPM has to exist, and be the right version --------------------------------
  [ -c /dev/tpmrm0 ] || die "no /dev/tpmrm0 - this machine has no usable TPM.
       Guests do not have one; this runs on physical hosts only."
  local tv; tv="$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo '?')"
  [ "$tv" = 2 ] || die "TPM reports version '$tv' - systemd-cryptenroll needs TPM 2.0."
  command -v systemd-cryptenroll >/dev/null 2>&1 || die "systemd-cryptenroll not present"

  # ---- 1b. systemd DLOPENS the TPM2 stack, so a missing library is not a missing feature
  #
  # On host-4, 2026-09-16, `systemd-cryptenroll --tpm2-device=list` said "TPM2 support is not
  # installed" while `systemd-analyze --version` reported `+TPM2` and the TPM was present and
  # working. Both were true: systemd was built with support, and it loads libtss2 at RUNTIME.
  # Six of the seven tss2 libraries were installed; **libtss2-rc.so.0 was not**, because
  # nothing hard-depends on it - systemd only dlopens it. One absent library reports as an
  # absent feature.
  #
  # Check the sonames directly. The error message systemd gives sends you looking at the TPM,
  # the firmware and the kernel, none of which are the problem.
  local so missing=""
  for so in libtss2-esys.so.0 libtss2-mu.so.0 libtss2-rc.so.0 libtss2-tcti-device.so.0; do
    ldconfig -p 2>/dev/null | awk -v s="$so" '$1==s {found=1} END {exit !found}' \
      || missing="$missing $so"
  done
  if [ -n "$missing" ]; then
    warn "systemd cannot load the TPM2 stack - these shared libraries are missing:"
    for so in $missing; do say "     $so"; done
    say  "  systemd dlopens them, so nothing depends on them and apt never pulled them in."
    say  ""
    # INSTALL IT RATHER THAN PRINT INSTRUCTIONS. The operator invoked this subcommand
    # deliberately; handing them an apt line to retype is a step that can be mistyped at a
    # rack. Candidate names differ across releases - 24.04 carries the t64 suffix from the
    # time_t transition - so resolve the name against what this machine can actually see.
    local want cand pol pkgs=""
    for want in $missing; do
      case "$want" in
        libtss2-rc.so.0)           cand="libtss2-rc0t64 libtss2-rc0" ;;
        libtss2-esys.so.0)         cand="libtss2-esys-3.0.2-0t64 libtss2-esys-3.0.2-0" ;;
        libtss2-mu.so.0)           cand="libtss2-mu-4.0.1-0t64 libtss2-mu0" ;;
        libtss2-tcti-device.so.0)  cand="libtss2-tcti-device0t64 libtss2-tcti-device0" ;;
        *) cand="" ;;
      esac
      local pick=""
      for c in $cand; do
        pol="$(apt-cache policy "$c" 2>/dev/null || true)"
        case "$pol" in *"Candidate: "[0-9]*) pick="$c"; break ;; esac
      done
      [ -n "$pick" ] && pkgs="$pkgs $pick" \
        || warn "  no package on this mirror provides $want - carry one in"
    done
    [ -n "$pkgs" ] || die "cannot resolve a package for the missing library - nothing changed"
    say "installing:$pkgs"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgs 2>&1 | tail -3
    # RE-CHECK. An install that reports success and still leaves the soname absent is the
    # case this whole block exists to catch.
    missing=""
    for so in libtss2-esys.so.0 libtss2-mu.so.0 libtss2-rc.so.0 libtss2-tcti-device.so.0; do
      ldconfig -p 2>/dev/null | awk -v t="$so" '$1==t {f=1} END {exit !f}' || missing="$missing $so"
    done
    [ -z "$missing" ] || die "still missing:$missing - nothing has been changed"
    ok "TPM2 libraries installed"
  fi

  # Ask systemd, not just the linker. This is the test that actually gates enrolment.
  local tpmlist
  tpmlist="$(systemd-cryptenroll --tpm2-device=list 2>&1 || true)"
  case "$tpmlist" in
    *"not installed"*|*"No TPM2 devices"*)
      warn "systemd-cryptenroll still will not use the TPM. It said:"
      printf '%s\n' "$tpmlist" | sed 's/^/       /'
      die "resolve that before enrolling - nothing has been changed" ;;
  esac
  ok "TPM 2.0 present at /dev/tpmrm0 and systemd can use it"
  printf '%s\n' "$tpmlist" | sed 's/^/     /'

  # ---- 2. was this asked for at build time? -------------------------------------------
  # The installer wrote the operator's choice. Honour it rather than guessing, and refuse
  # to silently change the security posture of a host built to be unlocked by a human.
  local want; want="$(awk -F= '/^luks_unlock=/{print $2}' /etc/enclave-build-info 2>/dev/null)"
  case "${want:-}" in
    tpm2) ok "the build recorded luks_unlock=tpm2" ;;
    passphrase)
      if [ "$force" -eq 0 ]; then
        die "this host was built with luks_unlock=passphrase.
       Enrolling the TPM changes its security posture from two factors to one - see Q20.
       If that is a deliberate decision, re-run with --force and record it."
      fi
      warn "build recorded 'passphrase'; proceeding because --force was given" ;;
    "") warn "/etc/enclave-build-info has no luks_unlock line - built before the parameter existed" ;;
    *)  warn "unrecognised luks_unlock='$want' - treating as unset" ;;
  esac

  # ---- 3. which device holds the OS volume --------------------------------------------
  # From crypttab, not from a guess. The name is whatever the installer chose.
  local cname cuuid
  while read -r cname cuuid _rest; do
    case "$cname" in ''|\#*) continue ;; esac
    case "$cuuid" in
      UUID=*) : ;;
      *) continue ;;
    esac
    # The OS volume is the one WITHOUT a keyfile - the data volume already has one.
    local keyfield; keyfield="$(awk -v n="$cname" '$1==n{print $3}' /etc/crypttab)"
    if [ "$keyfield" = none ]; then dev="/dev/disk/by-uuid/${cuuid#UUID=}"; break; fi
  done < /etc/crypttab
  [ -n "${dev:-}" ] || die "no crypttab entry with key 'none' - nothing here prompts for a
       passphrase, so there is nothing to enrol. Check /etc/crypttab."
  [ -b "$dev" ] || die "$dev is not a block device"
  ok "OS volume: $cname -> $(readlink -f "$dev")"

  # ---- 4. REFUSE TO LEAVE NO WAY IN ---------------------------------------------------
  # This is the guard that makes the whole thing safe to try. cryptenroll adds a slot; the
  # passphrase slot stays unless someone explicitly wipes it. Confirm a passphrase slot
  # exists FIRST, so the worst case is "it prompts like it does today" and never "bricked".
  slot_count="$(cryptsetup luksDump "$dev" 2>/dev/null | grep -cE '^[[:space:]]+[0-9]+: luks2')"
  if [ "${slot_count:-0}" -lt 1 ]; then
    die "cannot see a usable key slot on $dev - refusing to touch it.
       Check: cryptsetup luksDump $dev"
  fi
  ok "$slot_count existing key slot(s) - the passphrase fallback survives this"
  # ---- 5. enrol, unless it is already done ---------------------------------------------
  # IDEMPOTENT MEANS CONVERGES, NOT RETURNS. The first version returned here the moment it
  # saw an existing token - which skipped the crypttab and initramfs steps below, so a
  # re-run could not repair the exact thing a re-run is for. Enrolment is skipped; nothing
  # else is.
  local dump already=0
  dump="$(cryptsetup luksDump "$dev" 2>/dev/null || true)"
  case "$dump" in
    *systemd-tpm2*)
      already=1
      ok "a TPM token is already enrolled - skipping enrolment, still checking crypttab and initramfs"
      say "   to re-seal after a firmware change: systemd-cryptenroll --wipe-slot=tpm2 $dev" ;;
  esac

  if [ "$already" -eq 0 ]; then
    say ""
    say "enrolling against PCR 7 (secure boot state) - you will be asked for the EXISTING"
    say "passphrase once, to unlock the volume so a new slot can be added:"
    systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$dev" \
      || die "enrolment failed - nothing changed, the passphrase still works"
  fi

  # ---- 6. tell crypttab to try the TPM ------------------------------------------------
  cp -a /etc/crypttab "/var/backups/crypttab.$(date +%Y%m%dT%H%M%S)"
  if awk -v n="$cname" '$1==n' /etc/crypttab | grep -q 'tpm2-device='; then
    ok "crypttab already names a tpm2-device for $cname"
  else
    # awk, not sed: the options field is comma-separated and the paths contain slashes.
    local ct; ct="$(mktemp)"
    awk -v n="$cname" '
      $1==n {
        if (NF >= 4) { $4 = $4 ",tpm2-device=auto" } else { $4 = "tpm2-device=auto" }
        print; next
      }
      { print }' /etc/crypttab > "$ct"
    cat "$ct" > /etc/crypttab; rm -f "$ct"
    ok "crypttab: $cname now tries tpm2-device=auto first"
  fi
  # NAME THE KERNEL. `update-initramfs -u` targets the NEWEST initramfs, which is not
  # necessarily the one this machine is running - on a host carrying both a generic and a
  # -fips kernel it can rebuild the wrong one, report success, and leave the running kernel's
  # initrd untouched. Measured on host-4 2026-09-16: the script said "initramfs rebuilt" while
  # /boot/initrd.img-6.8.0-138-fips was still hours old.
  local kver; kver="$(uname -r)"
  local initrd="/boot/initrd.img-$kver"
  local before; before="$(stat -c %Y "$initrd" 2>/dev/null || echo 0)"
  if update-initramfs -u -k "$kver" >/dev/null 2>&1; then
    local after; after="$(stat -c %Y "$initrd" 2>/dev/null || echo 0)"
    if [ "$after" -gt "$before" ]; then
      ok "initramfs rebuilt for $kver"
    else
      warn "update-initramfs reported success but $initrd DID NOT CHANGE."
      warn "  the TPM will not be tried at boot. Check: update-initramfs -u -k $kver"
    fi
  else
    warn "update-initramfs failed - the TPM will not be tried at boot until it succeeds"
  fi

  # AND CONFIRM THE STACK IS ACTUALLY IN THERE. The unlock happens in the initramfs, not in
  # the booted system - the library installed above is of no use to the boot path unless the
  # initramfs carries it too. A rebuild that omits it succeeds silently and the host simply
  # falls back to the passphrase, which looks like a wrong PCR seal and is not.
  if command -v lsinitramfs >/dev/null 2>&1; then
    # sync first: listing a large initrd straight after a rebuild can come back short, which
    # is what made the radio and clevis checks cry wolf. Same trap, unused path, one line.
    sync
    local inside; inside="$(lsinitramfs "$initrd" 2>/dev/null | grep -cE 'libtss2-(rc|esys|mu)' || true)"
    case "$inside" in ''|*[!0-9]*) inside=0 ;; esac
    if [ "$inside" -gt 0 ]; then
      ok "initramfs carries the TPM2 libraries ($inside file(s))"
    else
      warn "THE INITRAMFS DOES NOT CARRY THE TPM2 LIBRARIES - the boot unlock cannot work."
      warn "  The host falls back to the passphrase, which is safe but is NOT the TPM failing"
      warn "  a PCR check."
      warn ""
      warn "  DO NOT RE-RUN THIS EXPECTING IT TO FIX ITSELF. An earlier version of this"
      warn "  message said to put tpm2-device= in crypttab and rebuild - that advice was"
      warn "  WRONG and it loops forever. PROVEN ON host-4 2026-09-17: crypttab carried"
      warn "  'crypt-os none luks,tpm2-device=auto', the LUKS header carried a systemd-tpm2"
      warn "  token sealed to PCR 7, the initramfs had been rebuilt for the running kernel -"
      warn "  and the host still prompted."
      warn ""
      warn "  The reason: tpm2-device= is a SYSTEMD-CRYPTSETUP option, and this initramfs"
      warn "  contains only Debian's own cryptroot scripts (scripts/local-top/cryptroot,"
      warn "  usr/bin/cryptroot-unlock). There is no systemd-cryptsetup in the boot path, so"
      warn "  nothing ever reads the option. No rebuild order changes that."
      warn ""
      warn "  The working mechanism on Ubuntu 24.04 server is CLEVIS (clevis-luks,"
      warn "  clevis-tpm2, clevis-initramfs - all present in the enclave mirror), which"
      warn "  ships its own initramfs hook. See runbook 6.3i.1."
      warn ""
      warn "  AND BEFORE YOU DO: check Secure Boot. Sealing to PCR 7 with Secure Boot"
      warn "  DISABLED is not a security control - PCR 7 measures the Secure Boot policy, so"
      warn "  with it off any media boots on this machine and the TPM releases the key to"
      warn "  whatever initramfs asks. Enable Secure Boot FIRST; doing it afterwards changes"
      warn "  PCR 7 and breaks every seal."
    fi
  else
    warn "lsinitramfs not present - cannot confirm the initramfs carries the TPM2 stack"
  fi

  # ---- 7. say what is and is not proven ------------------------------------------------
  say ""
  cryptsetup luksDump "$dev" 2>/dev/null | grep -iE 'tokens|systemd-tpm2|tpm2-pcrs' | sed 's/^/     /'
  say ""
  warn "A REBOOT IS THE ONLY REAL TEST, and nothing here proves it yet."
  say  "  If the seal is wrong the host falls back to prompting for the passphrase - the"
  say  "  behaviour it had before this ran - so the failure mode is the status quo."
  say  "  On a hypervisor, schedule it: rebooting takes every guest with it."
  say ""
  say  "  to undo:  sudo systemd-cryptenroll --wipe-slot=tpm2 $dev"
  say  "            then remove tpm2-device=auto from /etc/crypttab and update-initramfs -u"
}

# =========================================================================================
# accounts - a second named admin and a console-only emergency account (backlog 3.15)
# =========================================================================================
#
# WHY: one admin account plus pam_faillock (deny=3, unlock_time=0, and in common-account so a
# locked account is refused SSH PUBKEY logins too) means three typos is a trip to the rack.
# It reached 2 of 3 on 2026-09-21. The lockout is the control and stays exactly as it is -
# the fix is the single point of failure around it. Approved by the acting AO 2026-09-23:
#
#   ADMIN2     a second NAMED admin. faillock counts per account, so a lockout on one leaves
#              the other working. Same groups as the reference admin, same SSH key login.
#   BREAKGLASS console-only emergency account. Password only, NO key, refused by sshd. Its
#              password is chosen by two custodians, typed here, sealed offline per machine,
#              and rotated after EVERY USE. It does NOT expire: V-270682's own text says
#              emergency ("break glass") accounts "are not subject to manual removal or
#              scheduled expiration requirements", and a sealed password that silently ages
#              out (max 60 + INACTIVE 35 = dead at ~95 days) is worse than none. Decided by
#              the acting AO 2026-09-23 - an earlier 60-day rotation choice rested on my
#              wrong claim that an exemption would be a deviation. Every command it runs is
#              audited by UID (key: breakglass).
#
# PASSWORDS NEVER TOUCH THIS REPOSITORY. Read with `read -rsp`, fed to chpasswd on STDIN (not
# argv, where ps would show it), which runs through PAM common-password - so the STIG hashing
# (SHA512) and pwquality rules apply exactly as for any password change. For the unattended
# build, ADMIN2_PASSWORD_HASH / BREAKGLASS_PASSWORD_HASH may carry a pre-made SHA512 crypt
# instead; nothing else is ever read from a file.
#
# WHERE IT RUNS: runbook 6.0 step 12f, by hand on every machine (05-harden-host.sh does not
# call it - it prompts for passwords). Before the 12e reboot, because audit is immutable
# after `usg fix` and the breakglass rule only loads at boot. ssp-inputs 2.1b.
#   status   read-only (sudo for the real numbers): accounts, expiry, faillock, sshd, audit
#   create   root: both accounts and every control around them; re-run to re-assert
#   rotate   root: new password for one account, default the emergency one
#
# PARAMETERS (environment):
#   ADMIN2_USER          required for create - the second admin's username. Read from
#                        facility-profile.env (a site fact); environment overrides. No script
#                        default: it is a person, and guessing a person is how shared accounts happen.
#   ADMIN2_KEY           path to that person's SSH PUBLIC key (optional; without it the
#                        account works at the console and over SSH only once a key is added)
#   BREAKGLASS_USER      default: breakglass
#   REFERENCE_ADMIN      default: encadmin - ADMIN2 gets this account's supplementary groups
#   ADMIN2_PASSWORD_HASH / BREAKGLASS_PASSWORD_HASH   unattended only, SHA512 crypt ($6$)
#   ...or from the site credentials file (cred_get): ADMIN2_PASSWORD_HASH, and PER MACHINE
#   BREAKGLASS_PASSWORD_HASH_<HOST> (e.g. _HOST_1) - never a shared emergency hash (3.32).
#   ADMIN2_PUBKEY / ADMIN2_KEY_COMMENT (facility-profile.env) - the second admin's key when
#   ADMIN2_KEY is not given: the key text, or the LAST WORD of the comment on the reference
#   admin's key line (matched exactly; more than one match is refused, never guessed).
# SITE VALUES FROM facility-profile.env, so a rebuild creates the same accounts the answer file
# expects. Environment wins; only these two names are read from the file (grep, not source).
_FP="$HERE/../../docs/compliance/baseline/facility-profile.env"
if [ -r "$_FP" ]; then
  [ -n "${ADMIN2_USER:-}" ]     || ADMIN2_USER="$(sed -n "s/^ADMIN2_USER='\([^']*\)'.*/\1/p" "$_FP" | head -1)"
  [ -n "${BREAKGLASS_USER:-}" ] || BREAKGLASS_USER="$(sed -n "s/^BREAKGLASS_USER='\([^']*\)'.*/\1/p" "$_FP" | head -1)"
  # The second admin's SSH key, without anyone passing a path (3.32 / decision A, 2026-09-25):
  # ADMIN2_PUBKEY is the key text itself (a site whose second admin has their own key);
  # otherwise ADMIN2_KEY_COMMENT picks that ONE line out of the reference admin's keys.
  [ -n "${ADMIN2_PUBKEY:-}" ]      || ADMIN2_PUBKEY="$(sed -n "s/^ADMIN2_PUBKEY='\([^']*\)'.*/\1/p" "$_FP" | head -1)"
  [ -n "${ADMIN2_KEY_COMMENT:-}" ] || ADMIN2_KEY_COMMENT="$(sed -n "s/^ADMIN2_KEY_COMMENT='\([^']*\)'.*/\1/p" "$_FP" | head -1)"
fi
BREAKGLASS_USER="${BREAKGLASS_USER:-breakglass}"
REFERENCE_ADMIN="${REFERENCE_ADMIN:-encadmin}"

# ---- the site credentials file (2026-09-25: every typed secret can also come from here) ----
# So a rebuild can run with nobody at the keyboard. It holds HASHES wherever a hash works
# (account passwords, the GRUB password) and a real value only where nothing else will do.
# Precedence everywhere: environment variable > this file > prompt at the terminal. Never
# in the repository; carried on custody-controlled media and deleted from the target once
# hardening succeeds (docs/airgap-media.md, credential custody).
# cred_get / cred_require_safe live in credentials.sh - ONE copy for every consumer. The
# check runs up front in the main shell: from inside $(...) a refusal only ends a subshell.
# shellcheck source=credentials.sh
. "$HERE/credentials.sh"
BG_SSHD_DROPIN=/etc/ssh/sshd_config.d/10-enclave-breakglass.conf
BG_AUDIT_RULES=/etc/audit/rules.d/65-enclave-breakglass.rules

acct_days_left() {   # days until the password expires; "never" if no max age
  local u="$1" sh last max
  # Unprivileged, getent shadow returns NOTHING - which would parse as "no max age" and
  # print "never". Unreadable is '?', not a pass.
  sh="$(getent shadow "$u" 2>/dev/null)" || { echo '?'; return; }
  last="$(echo "$sh" | cut -d: -f3)"; max="$(echo "$sh" | cut -d: -f5)"
  if [ -z "$max" ] || [ "$max" -ge 99999 ] 2>/dev/null; then echo never; return; fi
  echo $(( last + max - $(date +%s) / 86400 ))
}

acct_set_password() {   # $1 user, $2 optional pre-made hash
  local u="$1" hash="${2:-}" P P2
  if [ -n "$hash" ]; then
    case "$hash" in '$6$'*) ;; *) die "the hash for $u is not SHA512 crypt (\$6\$) - refusing" ;; esac
    printf '%s:%s\n' "$u" "$hash" | chpasswd -e || die "chpasswd -e failed for $u"
    ok "password set for $u from a pre-made hash (unattended path)"
    return 0
  fi
  # No terminal and no hash (an unattended run missing its parameter): read would hit EOF and
  # set -e would end the script with no message at all. Say what is missing instead.
  [ -t 0 ] || die "no terminal to read a password for $u, and no pre-made hash was given"
  read -rsp "  new password for $u: " P; echo
  read -rsp "  again: " P2; echo
  [ -n "$P" ] || die "empty password - nothing changed for $u"
  [ "$P" = "$P2" ] || { P=""; P2=""; die "the two entries do not match - nothing changed for $u"; }
  # STDIN, through PAM. A pwquality rejection comes back here as a non-zero exit with its reason.
  local out rc=0
  out="$(printf '%s:%s\n' "$u" "$P" | chpasswd 2>&1)" || rc=$?
  P=""; P2=""
  [ "$rc" -eq 0 ] || die "chpasswd refused the password for $u (exit $rc): $out"
  ok "password set for $u (not shown)"
}

acct_status() {
  local me; me="$(hostname -s)"
  printf '\n  admin and emergency accounts on %s\n\n' "$me"
  [ "$(id -u)" -eq 0 ] || warn "not root: shadow, faillock and the audit rules are unreadable, so the
       password-age and lockout lines below would read EMPTY - which looks like 'fine'. Use sudo."
  local u role
  for u in "$REFERENCE_ADMIN" "${ADMIN2_USER:-}" "$BREAKGLASS_USER"; do
    [ -n "$u" ] || continue
    role="admin"; [ "$u" = "$BREAKGLASS_USER" ] && role="EMERGENCY"
    if ! getent passwd "$u" >/dev/null; then warn "$u ($role): does not exist"; continue; fi
    local left fails
    left="$(acct_days_left "$u" 2>/dev/null || echo '?')"
    fails="$(faillock --user "$u" 2>/dev/null | grep -cE '^[0-9]{4}-' || true)"
    say "$u ($role): groups=[$(id -nG "$u")]  password expires in: ${left} day(s)  failed tries: ${fails:-?}/3"
    # The emergency account must NOT expire. Any number here is drift - a sealed password
    # counting down to a dead account. Re-running create resets it.
    if [ "$u" = "$BREAKGLASS_USER" ] && [ "$left" != never ] && [ "$left" != '?' ]; then
      warn "  $u HAS AN EXPIRY ($left day(s)) - it must not. Fix: sudo $0 accounts create"
    fi
  done
  if getent passwd "$BREAKGLASS_USER" >/dev/null; then
    local deny; deny="$(sshd -T 2>/dev/null | awk '$1=="denyusers"{print $2}')"
    case ",$deny," in
      *",$BREAKGLASS_USER,"*) ok "sshd refuses $BREAKGLASS_USER (denyusers: $deny)" ;;
      *) warn "sshd does NOT refuse $BREAKGLASS_USER - it is not console-only" ;;
    esac
    local n; n="$(auditctl -l 2>/dev/null | grep -c 'key=breakglass' || true)"
    if [ "${n:-0}" -ge 2 ]; then ok "audit: $n live rule(s) keyed breakglass"
    else warn "audit: ${n:-0} live rule(s) keyed breakglass (want 2) - see 'accounts create' output"; fi
    # THE FILE'S MODE TOO: usg fails file_permissions_etc_audit_rulesd on anything but 0600,
    # which this script itself got wrong until 2026-09-24 (backlog 3.31 #2).
    local bm; bm="$(stat -c %a "$BG_AUDIT_RULES" 2>/dev/null || echo '?')"
    if [ "$bm" = 600 ]; then ok "audit rules file is 0600 ($BG_AUDIT_RULES)"
    else warn "audit rules file mode is $bm, want 600 (file_permissions_etc_audit_rulesd). Fix: sudo $0 accounts create"; fi
  fi
  echo
  say "RECOVERY, if an admin is locked out (from any other admin, or $BREAKGLASS_USER at the console):"
  say "    sudo faillock --user <locked-user> --reset"
  say "  and record it. Every use of $BREAKGLASS_USER is an incident record; rotate its password after."
  echo
}

cmd_accounts() {
  local action="${1:-status}"; shift || true
  case "$action" in
    status) acct_status ;;

    create)
      need_root
      cred_require_safe   # before any account is touched - an unsafe file stops the run HERE
      [ -n "${ADMIN2_USER:-}" ] || die "ADMIN2_USER is not set. It is a PERSON - name them in
       docs/compliance/baseline/facility-profile.env (ADMIN2_USER=...), or for one run:
       sudo ADMIN2_USER=<username> ADMIN2_KEY=<path/to/key.pub> $0 accounts create"
      getent passwd "$REFERENCE_ADMIN" >/dev/null || die "reference admin $REFERENCE_ADMIN does not exist here"
      [ "$ADMIN2_USER" != "$REFERENCE_ADMIN" ] && [ "$ADMIN2_USER" != "$BREAKGLASS_USER" ] \
        || die "ADMIN2_USER must differ from $REFERENCE_ADMIN and $BREAKGLASS_USER"
      # THE SECOND ADMIN'S KEY, in order: ADMIN2_KEY (a path, for one run) > ADMIN2_PUBKEY (the
      # key text, facility-profile.env) > the reference admin's key line whose COMMENT is
      # ADMIN2_KEY_COMMENT. Matching on the comment is what keeps the automation key
      # (stage-01 -> build-01) off a person's account: never "copy all of encadmin's keys".
      local akey_tmp=""
      if [ -z "${ADMIN2_KEY:-}" ]; then
        akey_tmp="$(mktemp)"
        if [ -n "${ADMIN2_PUBKEY:-}" ]; then
          printf '%s\n' "$ADMIN2_PUBKEY" > "$akey_tmp"; ADMIN2_KEY="$akey_tmp"
          say "   $ADMIN2_USER key: from ADMIN2_PUBKEY (facility-profile.env)"
        elif [ -n "${ADMIN2_KEY_COMMENT:-}" ]; then
          local rh rmatch; rh="$(getent passwd "$REFERENCE_ADMIN" | cut -d: -f6)"
          rmatch="$(awk -v c="$ADMIN2_KEY_COMMENT" '$NF==c' "$rh/.ssh/authorized_keys" 2>/dev/null)"
          case "$(printf '%s' "$rmatch" | grep -c .)" in
            1) printf '%s\n' "$rmatch" > "$akey_tmp"; ADMIN2_KEY="$akey_tmp"
               say "   $ADMIN2_USER key: copied from $REFERENCE_ADMIN's key with comment '$ADMIN2_KEY_COMMENT'" ;;
            0) warn "no key with comment '$ADMIN2_KEY_COMMENT' in $REFERENCE_ADMIN's authorized_keys - $ADMIN2_USER gets NO key" ;;
            *) warn "MORE than one key with comment '$ADMIN2_KEY_COMMENT' - refusing to guess; $ADMIN2_USER gets NO key" ;;
          esac
        fi
      fi
      if [ -n "${ADMIN2_KEY:-}" ]; then
        [ -r "$ADMIN2_KEY" ] || die "ADMIN2_KEY=$ADMIN2_KEY is not readable"
        ssh-keygen -l -f "$ADMIN2_KEY" >/dev/null 2>&1 || die "$ADMIN2_KEY is not an SSH public key"
      fi

      # ---- ADMIN2: same supplementary groups as the reference admin --------------------
      local groups; groups="$(id -nG "$REFERENCE_ADMIN" | tr ' ' '\n' | grep -vx "$REFERENCE_ADMIN" | paste -sd, -)"
      if getent passwd "$ADMIN2_USER" >/dev/null; then
        ok "$ADMIN2_USER exists - groups and key re-applied, password left alone (use: accounts rotate)"
        # -a APPENDS: adds any missing group, never removes one the account already has.
        usermod -aG "$groups" "$ADMIN2_USER"
      else
        # -m home directory (it holds .ssh), bash (an interactive admin, not a nologin service
        # account), -G the reference admin's supplementary groups computed above.
        useradd -m -s /bin/bash -G "$groups" "$ADMIN2_USER" || die "useradd $ADMIN2_USER failed"
        ok "created $ADMIN2_USER with groups $groups"
        # Hash: environment > site credentials file > prompt (3.32).
        acct_set_password "$ADMIN2_USER" "${ADMIN2_PASSWORD_HASH:-$(cred_get ADMIN2_PASSWORD_HASH)}"
      fi
      if [ -n "${ADMIN2_KEY:-}" ]; then
        local h; h="$(getent passwd "$ADMIN2_USER" | cut -d: -f6)"
        # 700 / 600, owned by the user: sshd's StrictModes ignores authorized_keys when the
        # file or its directory is writable by anyone else. The key is added only if absent.
        install -d -m 700 -o "$ADMIN2_USER" -g "$ADMIN2_USER" "$h/.ssh"
        grep -qxF "$(cat "$ADMIN2_KEY")" "$h/.ssh/authorized_keys" 2>/dev/null \
          || cat "$ADMIN2_KEY" >> "$h/.ssh/authorized_keys"
        chown "$ADMIN2_USER:$ADMIN2_USER" "$h/.ssh/authorized_keys"; chmod 600 "$h/.ssh/authorized_keys"
        ok "$ADMIN2_USER key: $(ssh-keygen -l -f "$ADMIN2_KEY" | awk '{print $2, $NF}')"
      fi
      [ -n "$akey_tmp" ] && rm -f "$akey_tmp"

      # ---- BREAKGLASS: sudo only, no key, console only, audited -------------------------
      if getent passwd "$BREAKGLASS_USER" >/dev/null; then
        ok "$BREAKGLASS_USER exists - controls re-applied, password left alone (use: accounts rotate)"
      else
        # sudo and no other group: it exists to recover the machine - `faillock --reset` for a
        # locked-out admin is the case it was made for.
        useradd -m -s /bin/bash -G sudo "$BREAKGLASS_USER" || die "useradd $BREAKGLASS_USER failed"
        ok "created $BREAKGLASS_USER (group: sudo)"
        # PER MACHINE, AND NO SHARED FALLBACK (AO decision 2026-09-23): the file key names this
        # host - BREAKGLASS_PASSWORD_HASH_HOST_1 - so one envelope can never open two machines.
        local bgk bgh; bgk="BREAKGLASS_PASSWORD_HASH_$(hostname -s | tr '[:lower:]-' '[:upper:]_')"
        bgh="${BREAKGLASS_PASSWORD_HASH:-$(cred_get "$bgk")}"
        [ -n "$bgh" ] || say "   TWO CUSTODIANS: choose it, type it, seal it for THIS machine ($(hostname -s)) only."
        [ -n "$bgh" ] && say "   $BREAKGLASS_USER: hash from ${BREAKGLASS_PASSWORD_HASH:+the environment}${BREAKGLASS_PASSWORD_HASH:-$bgk in $ENCLAVE_CREDENTIALS}"
        acct_set_password "$BREAKGLASS_USER" "$bgh"
      fi
      # NO EXPIRY, explicitly. useradd applied login.defs (max 60) and useradd's INACTIVE (35)
      # at creation; left alone, the sealed password dies at ~95 days. V-270682 exempts
      # emergency accounts from scheduled expiration - see the header.
      # -M 99999 no maximum password age, -I -1 no inactivity lock, -E -1 no account expiry.
      chage -M 99999 -I -1 -E -1 "$BREAKGLASS_USER"
      local bh; bh="$(getent passwd "$BREAKGLASS_USER" | cut -d: -f6)"
      if [ -s "$bh/.ssh/authorized_keys" ]; then
        warn "$bh/.ssh/authorized_keys is NOT empty - an emergency account must have no key. Emptying it."
        backup_file "$bh/.ssh/authorized_keys"; : > "$bh/.ssh/authorized_keys"
      fi

      # sshd: refuse it outright. Checked with sshd -t BEFORE reload - a bad drop-in plus a
      # reload is how a remote machine loses SSH for everyone.
      printf '# backlog 3.15 - the emergency account is console-only. Written by stig-tailor.sh accounts.\nDenyUsers %s\n' \
        "$BREAKGLASS_USER" > "$BG_SSHD_DROPIN.new"
      # Written as .new and renamed, so sshd never reads a half-written file.
      chmod 600 "$BG_SSHD_DROPIN.new"; mv "$BG_SSHD_DROPIN.new" "$BG_SSHD_DROPIN"
      if ! sshd -t 2>/dev/null; then
        sshd -t 2>&1 | sed 's/^/       /'
        rm -f "$BG_SSHD_DROPIN"
        die "sshd -t failed with the drop-in - REMOVED it, sshd not reloaded"
      fi
      # reload = re-read the config in place. The unit is `ssh` on Ubuntu, `sshd` elsewhere.
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "sshd reload failed - reload it by hand"
      case ",$(sshd -T 2>/dev/null | awk '$1=="denyusers"{print $2}')," in
        *",$BREAKGLASS_USER,"*) ok "sshd now refuses $BREAKGLASS_USER" ;;
        *) warn "sshd -T does NOT list $BREAKGLASS_USER in denyusers - the drop-in did not take effect. Check sshd_config.d and do not rely on console-only." ;;
      esac

      # audit: every command it runs, keyed by its UID.
      # auid is the LOGIN uid, which survives sudo - so commands run as root after logging in
      # as breakglass are still attributed to it. b64 and b32 both, or 32-bit execs escape.
      local uid; uid="$(id -u "$BREAKGLASS_USER")"
      printf '%s\n' "## backlog 3.15 - every command run by the emergency account, by login UID" \
        "-a always,exit -F arch=b64 -S execve -F auid=$uid -k breakglass" \
        "-a always,exit -F arch=b32 -S execve -F auid=$uid -k breakglass" > "$BG_AUDIT_RULES"
      # 0600, NOT 0640 - USG's file_permissions_etc_audit_rulesd wants 0600 on every rules.d
      # file (see the v1r6 note above). This line said 640 until 2026-09-24 and the rescan
      # failed that rule on all eight machines (backlog 3.31 #2). Re-running `accounts create`
      # rewrites the file, so it also repairs a machine built with the old mode.
      chmod 600 "$BG_AUDIT_RULES"
      # IMMUTABLE AUDIT (-e 2) REFUSES NEW RULES UNTIL REBOOT, and says so only as an error from
      # augenrules. Name it rather than let it read as a failure.
      if auditctl -s 2>/dev/null | grep -q '^enabled 2'; then
        warn "audit rules are IMMUTABLE (enabled 2): the breakglass rule is written but goes live only"
        warn "  at the next reboot. Until then the account is NOT audited - reboot before relying on it."
      else
        # Merge rules.d into audit.rules and load it now (only possible while not immutable).
        local ar; ar="$(augenrules --load 2>&1)" || { printf '%s\n' "$ar" | sed 's/^/       /'; warn "augenrules --load failed - output above"; }
      fi
      acct_status
      ;;

    rotate)
      need_root
      local u="${1:-$BREAKGLASS_USER}"
      getent passwd "$u" >/dev/null || die "$u does not exist here"
      [ "$u" = "$BREAKGLASS_USER" ] && say "   TWO CUSTODIANS: new password, new envelope for $(hostname -s); destroy the old one."
      acct_set_password "$u"
      # Re-assert "never expires" after the change - the same chage flags as `create`.
      [ "$u" = "$BREAKGLASS_USER" ] && chage -M 99999 -I -1 -E -1 "$u"
      ok "$u: password expires in $(acct_days_left "$u") day(s)"
      ;;

    *) die "usage: $0 accounts {status|create|rotate [user]}" ;;
  esac
}

# ---- say WHICH COPY is running, before it says anything else (backlog 3.22) ------------
# A stale copy does not error - it offers a shorter menu. On 2026-09-23 `fixups` on three
# service VMs listed items 1-6 and never mentioned item 7, because their copy predated it; the
# output was truthful and still read as "covered". Nothing in a plan can reveal a missing
# item, so the only defence is to show the revision and let it be compared with the repo.
# Same precedence as install-runtime.sh. To stderr, so `show` stays clean when piped.
script_revision() {
  if command -v git >/dev/null 2>&1 && git -C "$HERE" rev-parse --short HEAD >/dev/null 2>&1; then
    printf '%s%s (git working copy)\n' "$(git -C "$HERE" rev-parse --short HEAD)" \
      "$(git -C "$HERE" diff --quiet HEAD -- "$HERE" 2>/dev/null || echo '-dirty')"
  elif [ -r "$HERE/../../.pushed-from" ]; then
    head -1 "$HERE/../../.pushed-from"
  elif [ -r "$HERE/.source" ]; then
    printf '%s (runtime copy)\n' "$(head -1 "$HERE/.source")"
  fi
}
_rev="$(script_revision || true)"
if [ -n "$_rev" ]; then
  printf '  stig-tailor.sh %s  [%s]\n' "$_rev" "$HERE" >&2
else
  printf '  [!]  stig-tailor.sh revision UNKNOWN - no .pushed-from, no git. Re-push before trusting a plan from this copy.  [%s]\n' "$HERE" >&2
fi

# Dispatch. The one-line usage below is the only built-in help; the long form, with the
# runbook 6.0 step for each subcommand, is the header at the top of this file.
case "${1:-}" in
  generate) shift; cmd_generate "$@" ;;
  fixups)   shift; cmd_fixups "$@" ;;
  preflight) shift; cmd_preflight "$@" ;;
  usb)      shift; cmd_usb "$@" ;;
  radio)    shift; cmd_radio "$@" ;;
  ufw)      shift; cmd_ufw "$@" ;;
  aide)     shift; cmd_aide "$@" ;;
  v1r6)     shift; cmd_v1r6 "$@" ;;
  grubpw)   shift; cmd_grubpw "$@" ;;
  luksenroll) shift; cmd_luksenroll "$@" ;;
  accounts) shift; cmd_accounts "$@" ;;
  audit)    shift; cmd_audit "$@" ;;
  show)     shift; cmd_show "$@" ;;
  *) printf 'usage: %s {generate|audit|show|preflight|aide {status|exclude [--apply]|init}|v1r6 [--apply|--verify]|grubpw {status|prep|set}|luksenroll [--method=clevis|systemd] [--force]|accounts {status|create|rotate [user]}|fixups [...]|ufw [--apply]|usb {status|enable|disable}|radio {status|disable|enable}}\n' "$0" >&2; exit 2 ;;
esac
