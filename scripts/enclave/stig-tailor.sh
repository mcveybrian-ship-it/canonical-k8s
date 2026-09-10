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
# Fields, tab-separated:  kind | xccdf id (without the content_ prefix) | value | why
#
# ACTIVE. These are decided.
#
deviations() {
cat <<'EOF'
set-value	value_var_multiple_time_servers	__TIME_MASTER__	__STIG_ID__ / chronyd_specify_remote_server. The DISA profile pins the approved time source to 0.us.pool.ntp.mil, which is unreachable from inside the boundary BY DESIGN - reaching it would be the finding. The enclave's authoritative source is __TIME_MASTER_NAME__ (__TIME_MASTER__), a physical machine serving the enclave subnet only. The rule's INTENT - synchronise only to an organisation-approved source - is met in full; only the list of approved sources differs. This is a retarget, not an exception.
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
  while IFS=$'\t' read -r kind id value why; do
    [ -n "${kind:-}" ] || continue
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
  while IFS=$'\t' read -r kind id value why; do
    [ -n "${kind:-}" ] || continue
    value="${value//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER_NAME__/$TIME_MASTER_NAME}"
    printf '  %s\n    %s = %s\n    %s\n\n' "$kind" "$id" "$value" "$why"
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
LOGMODE="${STIG_LOG_MODE:-0640}"

fixups_plan() {
  printf '\n  STIG fixups - what `usg fix` does not fix\n'
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
  # 1. tmpfiles - full copy, three modes tightened.
  [ -f "$VARCONF_SRC" ] || die "$VARCONF_SRC does not exist - has the layout changed?"
  install -d -m 0755 /etc/tmpfiles.d
  if [ -f "$VARCONF_DST" ]; then
    say "$VARCONF_DST exists - leaving it alone. Edit it by hand or remove it first."
  else
    sed -E 's#^(f /var/log/(wtmp|btmp|lastlog)[[:space:]]+)[0-7]{4}#\1'"$LOGMODE"'#' \
      "$VARCONF_SRC" > "$VARCONF_DST"
    chmod 0644 "$VARCONF_DST"
    # Prove the substitution actually hit all three before trusting it.
    local hits; hits=$(grep -cE "^f /var/log/(wtmp|btmp|lastlog)[[:space:]]+$LOGMODE" "$VARCONF_DST" || true)
    [ "$hits" -eq 3 ] || die "expected 3 tightened lines in $VARCONF_DST, found $hits - inspect it"
    ok "wrote $VARCONF_DST (full copy, wtmp/btmp/lastlog at $LOGMODE)"
  fi
  systemd-tmpfiles --create 2>/dev/null || warn "systemd-tmpfiles --create reported an issue"

  # 2. logrotate for apt, then the existing files.
  if grep -q '^\s*create ' "$APT_LOGROTATE" 2>/dev/null; then
    say "$APT_LOGROTATE already has a 'create' line - not touching it"
  elif [ -f "$APT_LOGROTATE" ]; then
    cp -a "$APT_LOGROTATE" "$APT_LOGROTATE.pre-stig"
    sed -i -E "s/^([[:space:]]*)rotate 12$/\1rotate 12\n\1create $LOGMODE root adm/" "$APT_LOGROTATE"
    logrotate -d "$APT_LOGROTATE" >/dev/null 2>&1 \
      || { mv "$APT_LOGROTATE.pre-stig" "$APT_LOGROTATE"; die "logrotate rejected the edit - reverted"; }
    ok "added 'create $LOGMODE root adm' to $APT_LOGROTATE (backup: .pre-stig)"
  else
    warn "$APT_LOGROTATE not present - skipped"
  fi
  find /var/log/apt -type f -exec chmod "$LOGMODE" {} + 2>/dev/null || true
  ok "existing /var/log/apt files set to $LOGMODE"

  # 3. /var/log group ownership.
  if getent group syslog >/dev/null 2>&1; then
    chgrp syslog /var/log && ok "/var/log group set to syslog"
  elif [ "$with_rsyslog" -eq 1 ]; then
    say "installing rsyslog from the enclave mirror"
    apt-get install -y rsyslog >/dev/null 2>&1 || die "rsyslog install failed - is apt working?"
    getent group syslog >/dev/null 2>&1 || die "rsyslog installed but no syslog group appeared"
    chgrp syslog /var/log && ok "rsyslog installed, /var/log group set to syslog"
  else
    warn "no syslog group and --with-rsyslog not given - file_groupowner_var_log STILL FAILS"
    say "   this is the decision in the plan output. Nothing was faked."
  fi
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
  find /var/log/apt -type f -perm /0137 -printf '  [!]  too permissive: %M %p\n' 2>/dev/null
  say ""
  [ "$fail" -eq 0 ] && ok "all checks passed" || warn "some checks failed - see above"
  return 0
}

case "${1:-}" in
  generate) shift; cmd_generate "$@" ;;
  fixups)   shift; cmd_fixups "$@" ;;
  audit)    shift; cmd_audit "$@" ;;
  show)     shift; cmd_show "$@" ;;
  *) printf 'usage: %s {generate|audit|show|fixups [--apply] [--with-rsyslog] [--verify]}\n' "$0" >&2; exit 2 ;;
esac
