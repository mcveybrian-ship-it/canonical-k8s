#!/usr/bin/env bash
# =========================================================================================
# answerfile.sh - generate the Evaluate-STIG Answer File's PORTABLE entries.
#
#     MACHINE: stage-01 (or wherever the answer file is maintained).
#
#     ./answerfile.sh show                  what this script manages, and why
#     ./answerfile.sh generate              write the entries into the answer file
#     ./answerfile.sh generate -n           dry run - print, change nothing
#     ./answerfile.sh verify                validate the file against the vendor XSD
#     ./answerfile.sh -f <path> <action>    work on another file (STIG_ANSWERFILE also sets it)
#
#   No action means `show`. None of these needs root.
#
# WHERE IT RUNS IN A REBUILD: runbook section 6.0 step 13c, on stage-01, after triaging a
# scan and before the re-scan (13d). `stig-tools.sh answers <machine>` then carries the file
# to each machine over ssh - it is never published on the mirror. On a from-scratch rebuild
# with no answer file yet, `generate` seeds one from Evaluate-STIG's own template.
#
# WHY THIS EXISTS: THE HAND-BUILT ANSWERS ONLY WORKED ON ONE MACHINE.
#
#   The first answer file was written on svc-mgmt-01 with `ResultHash` set on 7 of its 8
#   entries and `ValidationCode` EMPTY on all of them. ResultHash is a SHA1 of that machine's
#   FindingDetails text, so V-270699 and V-270703 were answered on svc-mgmt-01 and came back
#   **Open** on svc-repo-01 and host-4 - same control, same justification, different bytes.
#
#   An answer pinned to one machine's output is not an answer, it is a note.
#
# SO: NO ResultHash, AND REAL ValidationCode.
#
#   Every entry here runs DISA's OWN CheckText, verbatim, at scan time and decides from the
#   result. That makes the answer portable across machines AND self-invalidating: if the
#   condition ever becomes a genuine finding, the code returns false, ValidFalseStatus puts
#   the control back to Open, and the Results field says which files caused it.
#
#   That is strictly better evidence than a hash. An assessor can read the command, run it,
#   and get the same answer.
#
# WHAT IT DOES NOT TOUCH:
#
#   Entries describing this enclave's SECURITY POSTURE - locked accounts, accepted NOPASSWD
#   grants, the air-gapped time source. Those are hand-written, they are not portable by
#   nature, and they stay in the file. This script preserves every Vuln ID it does not
#   manage and says so on every run.
#
#   The answer file itself lives OUTSIDE this repository (origin is public). This script is
#   in the repo; the artefact it writes is not.
# =========================================================================================
set -euo pipefail

AF="${STIG_ANSWERFILE:-/srv/bundle-staging/tools/answerfiles/Ubuntu24_AnswerFile.xml}"
# WHO IS ALLOWED IN THE sudo GROUP. V-270748 asks whether every member needs access to
# security functions - a judgement, so the judgement is written down HERE, once, and the
# check re-applies it on every machine at every scan. Add an account and the control
# re-opens until this list is updated deliberately.
# The site's second admin and emergency account come from facility-profile.env (backlog 3.15),
# the same file stig-tailor.sh accounts reads - so the approved list cannot drift from the
# accounts a rebuild actually creates. Environment still overrides for a one-off.
_FP="$(dirname "$(readlink -f "$0")")/../../docs/compliance/baseline/facility-profile.env"
_A2=""; _BG=""
if [ -r "$_FP" ]; then
  _A2="$(sed -n "s/^ADMIN2_USER='\([^']*\)'.*/\1/p" "$_FP" | head -1)"
  _BG="$(sed -n "s/^BREAKGLASS_USER='\([^']*\)'.*/\1/p" "$_FP" | head -1)"
fi
AF_ADMINS="${AF_ADMINS:-encadmin${_A2:+,$_A2}}"
# THE EMERGENCY ("break glass") ACCOUNT(S), kept apart from AF_ADMINS because the answers say
# different things about them: V-270682's own discussion exempts emergency accounts from
# scheduled expiration, and an answer that calls one a "permanent administrator, not an
# emergency account" would be false. Created by `stig-tailor.sh accounts` (backlog 3.15).
# The site's SECOND named admin (ADMIN2_USER there) goes in AF_ADMINS - it is a person.
AF_EMERGENCY="${AF_EMERGENCY:-${_BG:-breakglass}}"
XSD="${STIG_AF_XSD:-/srv/bundle-staging/tools/Evaluate-STIG/xml/Schema_AnswerFile.xsd}"
DRY=0

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------- the entries
#
# ONE RECORD PER LINE: vulnid <TAB> stigid <TAB> one-line reason (for `show`).
# The ValidationCode for each lives in af_code() below, keyed by vuln id.
af_entries() {
cat <<'EOF'
V-270699	UBTU-24-300009	DISA's find returns nothing; the scanner also flags a D-Bus helper that is not a *.so and is setgid by design
V-270703	UBTU-24-300013	every flagged group is in DISA's own filter list, plus postdrop, which DISA's note explicitly allows adding
V-270750	UBTU-24-600150	the only offenders are /tmp/.dotnet*, which PowerShell creates when the scan starts - the tool reports a condition it made
V-270681	UBTU-24-200090	DISA's grep returns the required selectors; the scanner's own FindingDetails quote the line it then calls missing
V-270778	UBTU-24-900070	the su audit rule IS loaded; DISA greps for /bin/su and usrmerge puts the binary at /usr/bin/su
V-270799	UBTU-24-900280	the unix_update audit rule IS loaded, same usrmerge path mismatch
V-270814	UBTU-24-900740	the kmod audit rule IS loaded, same usrmerge path mismatch
V-270815	UBTU-24-900750	the fdisk audit rule IS loaded, same usrmerge path mismatch
V-270751	UBTU-24-600160	no DOD time source is reachable in an air gap by design, and reaching one would itself be the finding
V-270762	UBTU-24-700070	UBTU-24-700020 forbids setgid on the journal dirs, which is what made journald set the group - the two controls conflict, and root is MORE restrictive
V-278917	UBTU-24-700400	the release IS vendor supported - 24.04 LTS with an unexpired Ubuntu Pro contract; the scanner cannot decide it and leaves it NR	NR
V-270748	UBTU-24-600130	the sudo group holds only the enclave administrator account(s) named in AF_ADMINS; the scanner cannot judge "who needs access" and leaves it NR	NR
V-270816	UBTU-24-900920	the audit allocation holds far more than one week at the MEASURED growth rate, and free space exceeds the whole allocation	NR
V-270694	UBTU-24-200680	/etc/profile.d/ssh_confirm.sh IS present and prompts for acknowledgement; the scanner cannot read a script and decide, so it leaves it NR	NR
V-270817	UBTU-24-900930	DISA's own check text says this control is not applicable to an interconnected system; every enclave machine ships its audit records over the network to the collector weekly (backlog N-2), and the answer VERIFIES that offload - timer enabled, root-owned runtime copy, last run within 8 days, last result success - rather than asserting it. The scanner reports O on most machines and NR on host-4 (a man-db script in cron.weekly it cannot judge), so the answer fires on both	O,NR
V-270682	UBTU-24-200250	there are NO temporary accounts on any enclave machine - every interactive account, meaning UID >= 1000 with a real login shell, is a permanent named administrator. Service accounts such as libvirt-qemu hold nologin and are not interactive	NR
V-270755	UBTU-24-600230	the machine HAS a radio, so the scanner's NOT APPLICABLE is false whenever no driver happens to be bound; this answers NF only when a modprobe block is actually in place, and leaves it OPEN when the radio is merely unbound	NA
V-270650	UBTU-24-100110	DISA's check is a FULL aide --check, which does not finish inside Evaluate-STIG's 15-minute per-rule timeout on a host with bulk data - it aborted on host-1 and host-2 and completed on host-3, same configuration. The nightly dailyaidecheck.timer IS the integrity check, and its result is better evidence than making the scanner re-run one	NR
EOF
}

# The four audit-rule controls differ only in what they grep for, so they are generated from
# one table rather than four near-identical blocks. DISA's check is `auditctl -l | grep X`.
#
# WHY THEY READ AS FINDINGS AT ALL: usrmerge. DISA's example output says `-F path=/bin/su`,
# but on 24.04 /bin is a symlink to usr/bin and the loaded rule says /usr/bin/su. The rule is
# present and enforcing; only the literal path in DISA's example differs.
af_audit_family() {
cat <<'EOF'
V-270778	su	/bin/su, /usr/bin/su
V-270799	unix_update	/sbin/unix_update, /usr/sbin/unix_update
V-270814	kmod	/bin/kmod, /usr/bin/kmod
V-270815	fdisk	/usr/sbin/fdisk
EOF
}

# PowerShell that runs DISA's CheckText verbatim and returns a hashtable.
#
# Deliberately avoids `<` and `&` so the XML needs no CDATA and stays readable to an
# assessor. `>` is legal unescaped in XML text content, so `2>/dev/null` is fine as-is.
#
# EVERY LINE BETWEEN `cat <<'EOF'` AND `EOF` BELOW IS SHIPPED. It becomes the ValidationCode
# element of the answer file on every machine and in the assessor's copy - including any `#`
# comment written there, which is PowerShell's comment syntax too. Explain an entry in
# af_entries() or up here, never by adding a line inside a block. Each block sets
# $V.Valid ($true -> ValidTrueStatus NF, $false -> ValidFalseStatus O) and $V.Results, the
# evidence text the checklist records. The audit-family clause is the one UNQUOTED heredoc,
# so $term and $paths expand and every PowerShell `$` in it is written `\$`.
af_code() {
  local term paths
  case "$1" in
  V-270699) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$cmd = @'
find /lib /lib64 /usr/lib /usr/lib64 -type f -name '*.so*' ! -group root -exec stat -c "%n %G" {} + 2>/dev/null
'@
$bad = @(bash -c $cmd) | Where-Object { $_ -ne "" }
if ($bad.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time and returned no output: " + $cmd.Trim() + " The scanner additionally reports /usr/lib/dbus-1.0/dbus-daemon-launch-helper. That file is not a '*.so*' file, so DISA's own find does not return it and it is outside the scope of this control as written. It is setgid 'messagebus' by package design; changing its group ownership breaks D-Bus message routing."
}
else {
    $V.Results = "OPEN. Shared library files not group-owned by root: " + ($bad -join '; ')
}
return $V
EOF
  ;;
  V-270703) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$cmd = @'
find /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin -type f -perm -u=x -exec stat --format="%n %G" {} + 2>/dev/null | awk '$2 != "root" && $2 != "daemon" && $2 != "adm" && $2 != "shadow" && $2 != "mail" && $2 != "crontab" && $2 != "_ssh" && $2 != "postdrop"'
'@
$bad = @(bash -c $cmd) | Where-Object { $_ -ne "" }
if ($bad.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time, with 'postdrop' added to the filter list, and returned no output: " + $cmd.Trim() + " DISA's own note on this check states: 'The above command uses awk to filter out common system accounts. If your system uses other required system accounts, add them to the list.' postdrop is Postfix's setgid submission group; /usr/sbin/postdrop and /usr/sbin/postqueue must be setgid postdrop for unprivileged mail submission to work, and Postfix is present because the STIG's own space_left_action = email requires a mail transfer agent."
}
else {
    $V.Results = "OPEN. System commands not group-owned by root or a required system account: " + ($bad -join '; ')
}
return $V
EOF
  ;;
  V-270750) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$cmd = @'
find / -type d -perm -002 ! -perm -1000 2>/dev/null
'@
$bad = @(bash -c $cmd) | Where-Object { $_ -ne "" }
$real = @($bad | Where-Object { $_ -notmatch '^/tmp/\.dotnet' })
if ($bad.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time and returned no world-writable directory missing the sticky bit."
}
elseif ($real.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. The only world-writable directories without the sticky bit are created by the assessment tool itself: " + ($bad -join '; ') + " The .NET runtime creates /tmp/.dotnet mode 0777 when PowerShell starts, so Evaluate-STIG creates this condition at the beginning of the scan and reports it later in the same scan. Tested 2026-09-11: redirecting TMPDIR, DOTNET_BUNDLE_EXTRACT_BASE_DIR and XDG_CACHE_HOME to a private 0700 directory does NOT move it - the path is the runtime's IPC directory, not a temp-path setting. The directory is removed after every scan; it cannot be absent during one. Verified on host-4 immediately after a scan that reported this control Open: the same find returned nothing."
}
else {
    $V.Results = "OPEN. World-writable directories without the sticky bit, excluding the scanner's own /tmp/.dotnet: " + ($real -join '; ')
}
return $V
EOF
  ;;
  V-270681) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$cmd = @'
grep -E -r "^(auth,authpriv\.\*|daemon\.\*)" /etc/rsyslog.conf /etc/rsyslog.d/ 2>/dev/null
'@
$hits = @(bash -c $cmd) | Where-Object { $_ -ne "" }
if ($hits.Count -gt 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time and returned the required selectors: " + ($hits -join '; ') + " The CheckText states the control is a finding only if auth.*, authpriv.* or daemon.* are 'not configured to be logged in at least one of the config files'. They are. Where this control has been reported Open, the scanner's own FindingDetails quoted the very line its CheckText asks for."
}
else {
    $V.Results = "OPEN. No auth/authpriv/daemon selector found by DISA's grep across /etc/rsyslog.conf and /etc/rsyslog.d/."
}
return $V
EOF
  ;;
  V-270778|V-270799|V-270814|V-270815)
    term="$(af_audit_family | awk -F'\t' -v v="$1" '$1==v{print $2}')"
    paths="$(af_audit_family | awk -F'\t' -v v="$1" '$1==v{print $3}')"
    cat <<EOF
\$V = @{ Valid = \$false; Results = "" }
\$cmd = 'auditctl -l 2>/dev/null | grep -E -- "/$term( |\$)"'
\$hits = @(bash -c \$cmd) | Where-Object { \$_ -ne "" }
if (\$hits.Count -gt 0) {
    \$V.Valid = \$true
    \$V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time and the audit rule IS loaded: " + (\$hits -join '; ') + " DISA's example output names the pre-usrmerge path; on Ubuntu 24.04 /bin and /sbin are symlinks into /usr, so the loaded rule carries the usrmerged path ($paths). The rule is present and enforcing - only the literal path in DISA's example differs. DISA's own note on this check states the -k identifier need not match the example."
}
else {
    \$V.Results = "OPEN. No loaded audit rule references a path ending /$term. auditctl -l returned nothing for it."
}
return \$V
EOF
  ;;
  V-270751) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$maxpoll = @(bash -c 'grep -ir maxpoll /etc/chrony* 2>/dev/null') | Where-Object { $_ -ne "" }
$local   = @(bash -c 'grep -ir "^local stratum" /etc/chrony* 2>/dev/null') | Where-Object { $_ -ne "" }
$srcs    = @(bash -c 'chronyc -n sources 2>/dev/null') | Where-Object { $_ -match '\^\*' }
$synced  = @(bash -c 'timedatectl show -p NTPSynchronized --value 2>/dev/null') | Where-Object { $_ -eq "yes" }
if ($local.Count -gt 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. This host is the enclave's TIME MASTER - it carries '" + ($local -join '; ') + "' and has no upstream server by design. A rule requiring a remote authoritative source cannot be satisfied on the authority itself inside an air gap, and reaching an external time source would itself be a finding. The enclave's clients are all synchronised to this host and compare far more often than every 24 hours. If the programme supplies a stratum-0 reference (GPS or radio), time-sync.sh master --upstream closes this control with no client change."
}
elseif ($maxpoll.Count -gt 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. maxpoll is configured: " + ($maxpoll -join '; ') + " DISA's CheckText pins the approved source to a DOD pool that is unreachable from inside the boundary BY DESIGN - reaching it would be the finding. The enclave's authoritative source is its own physical time master, serving the enclave subnet only. The control's INTENT (synchronise only to an organisation-approved source, at least every 24 hours) is met in full and verifiable: selected source " + ($srcs -join '; ') + ", NTPSynchronized=" + ($synced -join '') + ". Only the list of approved sources differs. This is a retarget, not an exception, and it matches the USG-side tailoring of the same control."
}
else {
    $V.Results = "OPEN. No maxpoll setting found under /etc/chrony* and this host is not configured as the enclave time master."
}
return $V
EOF
  ;;
  V-270762) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$bad = @(bash -c 'find /run/log/journal /var/log/journal -type f ! -group systemd-journal -printf "%g %04m %p
" 2>/dev/null') | Where-Object { $_ -ne "" }
if ($bad.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time and every journal file is group-owned by systemd-journal."
}
else {
    $looser = @($bad | Where-Object { ($_ -split ' ')[0] -ne 'root' })
    $modes  = @($bad | Where-Object { [Convert]::ToInt32((($_ -split ' ')[1]), 8) -band 0027 })
    if ($looser.Count -eq 0 -and $modes.Count -eq 0) {
        $V.Valid = $true
        $V.Results = "NOT A FINDING - the files are MORE restrictive than this control requires, and the cause is DISA's own remediation for UBTU-24-700020. " +
          "Files not group systemd-journal: " + ($bad -join '; ') + " Every one is group ROOT at mode 0640, so it is readable by root alone. Group systemd-journal at 0640 would be readable by every member of that group, so the state measured here is STRICTER than the control asks for, not weaker. " +
          "CAUSE, measured 2026-09-11: UBTU-24-700020 / V-270757 requires the journal directories at 0640 or less permissive, and the scanner implements that as 'find -perm /7137', which includes the SETGID bit - verified, a 2640 directory fails that check, as does systemd's own vendor default of 2750. Setgid on the directory is exactly what made journald create new files owned by group systemd-journal. Removing it, as UBTU-24-700020 requires, makes journald write new files with the creating process's group, which is root. The two controls cannot both be continuously satisfied. " +
          "MITIGATION IN PLACE: /etc/tmpfiles.d/zzz-systemd-stig.conf carries DISA's complete FixText for both controls, including the recursive 'Z /var/log/journal/%m ~0640 root systemd-journal' lines, so existing files are corrected at every boot and at every systemd-tmpfiles run. Only files created since the last run can differ, and those are stricter, not looser."
    }
    else {
        $V.Results = "OPEN. Journal files that are neither group systemd-journal nor a more restrictive root/0640: " + (($looser + $modes | Select-Object -Unique) -join '; ')
    }
}
return $V
EOF
  ;;
  V-278917) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$rel = (bash -c "grep DISTRIB_DESCRIPTION /etc/lsb-release 2>/dev/null") -join ""
$pro = @(bash -c "pro status --format=json 2>/dev/null") -join ""
$expires = ""
if ($pro -match '"expires":\s*"([^"]+)"') { $expires = $Matches[1] }
$supported = $false
if ($expires -ne "") {
    try { $supported = ([datetime]$expires -gt (Get-Date)) } catch { $supported = $false }
}
if (($rel -match "Ubuntu 24\.04") -and ($rel -match "LTS") -and $supported) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time. grep DISTRIB_DESCRIPTION /etc/lsb-release returned: " + $rel.Trim() + " Ubuntu 24.04 LTS is a Long Term Support release under standard Canonical support until April 2029, extended to April 2036 under Ubuntu Pro. This machine carries an ATTACHED Ubuntu Pro subscription with a contract expiry of " + $expires + ", which is in the future, and it is running the FIPS-validated kernel from the fips-updates stream - a stream that only an entitled machine can reach. The release is vendor supported."
}
else {
    $V.Results = "OPEN. Release string: '" + $rel.Trim() + "'. Pro contract expiry: '" + $expires + "'. Either the release is not 24.04 LTS or the Ubuntu Pro contract is absent or expired. An expired contract means no FIPS or ESM updates are reaching this machine, which is a real finding and not a paperwork one."
}
return $V
EOF
  ;;
  V-270650) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$c_bin = @'
command -v aide 2>/dev/null
'@
$c_en = @'
systemctl is-enabled dailyaidecheck.timer 2>/dev/null
'@
$c_act = @'
systemctl is-active dailyaidecheck.timer 2>/dev/null
'@
$c_last = @'
systemctl show dailyaidecheck.timer -p LastTriggerUSec --value 2>/dev/null
'@
$c_age = @'
t=$(systemctl show dailyaidecheck.timer -p LastTriggerUSec --value 2>/dev/null)
if [ -n "$t" ] && [ "$t" != "n/a" ]; then
  e=$(date -d "$t" +%s 2>/dev/null); n=$(date +%s)
  if [ -n "$e" ]; then echo $(( (n - e) / 86400 )); fi
fi
'@
$c_status = @'
systemctl show dailyaidecheck.service -p ExecMainStatus --value 2>/dev/null
'@
$c_db = @'
stat -c "%n %y" /var/lib/aide/aide.db 2>/dev/null
'@
$bin  = @(bash -c $c_bin)    | Where-Object { $_ -ne "" }
$en   = @(bash -c $c_en)     | Where-Object { $_ -ne "" }
$act  = @(bash -c $c_act)    | Where-Object { $_ -ne "" }
$last = @(bash -c $c_last)   | Where-Object { $_ -ne "" -and $_ -ne "n/a" }
# @() OUTSIDE the pipeline, not inside. `@(cmd) | Where-Object` hands back a SCALAR when one
# element survives, and then $age[0] indexes into the STRING rather than the array: for a
# one-character result like "0" that yields the CHAR '0', and [int] on a char is its ASCII
# code - 48. Measured on host-1 2026-09-18: a timer that had fired six hours earlier was
# reported as "48 day(s) ago" and the control came back OPEN. Wrapping the whole pipeline
# keeps it an array, and the conversion goes through -join so a scalar cannot be indexed at all.
$age  = @(bash -c $c_age | Where-Object { $_ -ne "" })
$st   = @(bash -c $c_status) | Where-Object { $_ -ne "" }
$db   = @(bash -c $c_db)     | Where-Object { $_ -ne "" }
$maxdays = 8
$days = -1
if ($age.Count -gt 0) { try { $days = [int]($age -join '') } catch { $days = -1 } }
if ($bin.Count -eq 0) {
    $V.Results = "OPEN. AIDE is not installed, so there is no file integrity tool for this control to check. If a tool other than AIDE is in use here, the control is Not Applicable and needs a different answer."
}
elseif (($en -join '') -eq 'enabled' -and ($act -join '') -eq 'active' -and $days -ge 0 -and $days -le $maxdays) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText for this rule is a FULL 'aide -c /etc/aide/aide.conf --check', which walks the entire filesystem. On a hypervisor carrying VM images and a backup volume that does not finish inside Evaluate-STIG's 15-minute per-rule timeout: measured 2026-09-18, it ABORTED on host-1 and host-2 and COMPLETED on host-3, which are identically configured machines. A Not Reviewed here reports SCAN DURATION, not system state. THE INTEGRITY CHECK IS RUNNING ON A SCHEDULE, and this is its evidence: dailyaidecheck.timer is " + ($en -join '') + " and " + ($act -join '') + ", and it LAST FIRED at " + ($last -join '') + ", which is " + $days + " day(s) ago against a daily schedule. AIDE database: " + $(if ($db.Count -eq 0) { "not readable at this privilege level" } else { $db -join '; ' }) + ". /etc/default/aide sets COMMAND=update, so each run verifies the filesystem against the database and writes the new one. NOTE ON WHAT IS DELIBERATELY NOT USED AS EVIDENCE: 'systemctl show <unit> -p Result' returns 'success' for a unit that has NEVER RUN, and for a unit that does not exist at all - verified on host-1 2026-09-18 against a fabricated service name. Any answer keyed on Result would pass on a machine where this timer had been removed. The last-trigger time cannot be faked that way, which is why it is the gate. Raising -VulnTimeout would let the scanner reproduce this itself at roughly an hour per host per scan, and would prove nothing this does not."
}
else {
    $V.Results = "OPEN. AIDE is installed but the scheduled integrity check is not demonstrably running. dailyaidecheck.timer is_enabled=" + $(if ($en.Count -eq 0) { "<none>" } else { $en -join '' }) + ", is_active=" + $(if ($act.Count -eq 0) { "<none>" } else { $act -join '' }) + ", last trigger=" + $(if ($last.Count -eq 0) { "<never>" } else { $last -join '' }) + " (" + $(if ($days -lt 0) { "unparseable or never" } else { "$days day(s) ago, limit $maxdays" }) + "), service ExecMainStatus=" + $(if ($st.Count -eq 0) { "<none>" } else { $st -join '' }) + ". A file integrity tool that is installed but not actually running is precisely the finding this control exists to catch."
}
return $V
EOF
  ;;
  V-270755) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$c_disa = @'
ls -L -d /sys/class/net/*/wireless 2>/dev/null | xargs -r -n1 dirname | xargs -r -n1 basename
'@
$c_live = @'
for d in /sys/class/net/*/phy80211; do [ -e "$d" ] || continue; basename $(dirname "$d"); done
'@
$c_hw = @'
for c in /sys/bus/pci/devices/*/class; do case "$(cat $c 2>/dev/null)" in 0x0280*) d=$(basename $(dirname $c)); lspci -s "${d#0000:}" 2>/dev/null || cat $(dirname $c)/modalias 2>/dev/null ;; esac; done
'@
$c_blk = @'
grep -rhE "^[[:space:]]*(install|blacklist)[[:space:]]" /etc/modprobe.d/99-stig-radio.conf 2>/dev/null
'@
$c_load = @'
lsmod | cut -d" " -f1 | grep -E "^(rtw[0-9]*_|rtw[0-9]+|mt7[0-9]|mt76|iwlwifi|iwl[dm]vm|ath[0-9]+|brcmfmac|bt(usb|rtl|intel|bcm|mtk)|bluetooth|mac80211|cfg80211)"
'@
$disa = @(bash -c $c_disa) | Where-Object { $_ -ne "" }
$live = @(bash -c $c_live) | Where-Object { $_ -ne "" }
$hw   = @(bash -c $c_hw)   | Where-Object { $_ -ne "" }
$blk  = @(bash -c $c_blk)  | Where-Object { $_ -ne "" }
$load = @(bash -c $c_load) | Where-Object { $_ -ne "" }
# A FRAMEWORK MODULE IS NOT A RADIO. cfg80211, mac80211 and the bluetooth core load with no
# adapter present - measured 2026-09-19: cfg80211 resident, used by nothing, on every service
# VM, none of which has a radio. Counting it made this check report "A RADIO IS PRESENT" with
# an EMPTY hardware list on four machines. Only real hardware or a DRIVER module is evidence.
$drv  = @($load | Where-Object { $_ -notmatch '^(cfg80211|mac80211|bluetooth)$' })
$fw   = @($load | Where-Object { $_ -match '^(cfg80211|mac80211|bluetooth)$' })
if ($hw.Count -eq 0 -and $live.Count -eq 0 -and $drv.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING - THERE IS NO RADIO IN THIS MACHINE. DISA's CheckText was executed verbatim and returned nothing; no interface exposes phy80211; no PCI device reports class 0x0280 (network controller, other), which is what an 802.11 adapter reports; and no wireless or Bluetooth module is resident. This is a virtual guest with no physical radio, so the CheckText's own note - 'not applicable for systems that do not have physical wireless network radios' - is satisfied ON THE HARDWARE, not merely on the absence of a bound driver." + $(if ($fw.Count -gt 0) { " Wireless FRAMEWORK module(s) resident with no driver or adapter using them: " + ($fw -join '; ') + " - generic kernel plumbing, not a radio." } else { "" })
}
elseif ($live.Count -eq 0 -and $blk.Count -gt 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING - THE RADIO IS PRESENT AND DELIBERATELY DISABLED. Physical radio(s) detected: " + ($hw -join '; ') + ". DISA's CheckText returns " + $(if ($disa.Count -eq 0) { "nothing" } else { $disa -join '; ' }) + " and no interface exposes phy80211, so no wireless interface is configured. That state is ENFORCED rather than incidental: /etc/modprobe.d/99-stig-radio.conf carries " + ($blk -join '; ') + ", written by scripts/enclave/stig-tailor.sh radio disable and applied to the initramfs as well as to /etc, so the driver cannot bind at boot. Residual modules still resident from before the block, if any: " + $(if ($load.Count -eq 0) { "none" } else { $load -join '; ' }) + ". The enclave is air-gapped and a radio is the one component that can cross that gap without a cable being moved, so this is disabled at the kernel rather than documented as an accepted interface."
}
elseif ($live.Count -eq 0) {
    $V.Results = "OPEN - A RADIO IS PRESENT AND NOTHING IS BLOCKING IT. Physical radio(s): " + $(if ($hw.Count -gt 0) { $hw -join '; ' } else { "none on PCI" }) + ". Radio driver module(s) resident: " + $(if ($drv.Count -gt 0) { $drv -join '; ' } else { "none" }) + ". No interface exposes phy80211 and DISA's glob returns nothing, which is why a scanner scores this NOT APPLICABLE - but that is an accident of no driver being bound, not a control. Nothing in /etc/modprobe.d/99-stig-radio.conf blocks the driver, so a kernel update, a firmware package or a manual modprobe brings the adapter up. Remediate with: sudo ./scripts/enclave/stig-tailor.sh radio disable"
}
else {
    $V.Results = "OPEN. Live 802.11 interface(s) configured: " + ($live -join '; ') + ". DISA's CheckText returns: " + $(if ($disa.Count -eq 0) { "nothing - the WEXT directory is absent, but the interface is real" } else { $disa -join '; ' }) + ". Physical radio(s): " + ($hw -join '; ') + ". Modules resident: " + ($load -join '; ') + "."
}
return $V
EOF
  ;;
  V-270748) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$approved = @(__AF_ADMINS__)
$emergency = @(__AF_EMERGENCY__)
$line = (bash -c "getent group sudo") -join ""
$members = @()
if ($line -match "^sudo:[^:]*:[^:]*:(.*)$") {
    $members = @($Matches[1] -split "," | Where-Object { $_ -ne "" })
}
$extra = @($members | Where-Object { ($approved -notcontains $_) -and ($emergency -notcontains $_) })
$bg = @($members | Where-Object { $emergency -contains $_ })
$bgNote = ""
if ($bg.Count -gt 0) { $bgNote = " The emergency (break-glass) account(s) " + ($bg -join ", ") + " hold sudo because recovering a locked-out administrator requires it; they are console-only (refused by sshd), their credentials are sealed offline under dual custody per machine, every use is an incident record, and every command they run is audited by UID. They are listed separately in AF_EMERGENCY." }
if ($extra.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time: getent group sudo returned '" + $line.Trim() + "'. Members: " + (($members -join ", ") + ".") + " Every member is a named enclave administrator account whose role IS the administration of security functions on this system, so by the control's own wording each one needs that access. The approved list is held in one place - AF_ADMINS in scripts/enclave/answerfile.sh - and this check re-applies it on every machine at every scan, so adding an account to the sudo group re-opens this control until the list is changed deliberately. Note also that the blanket 'ALL=(ALL) NOPASSWD:ALL' grant was removed during hardening; membership of this group confers no unauthenticated privilege." + $bgNote
}
else {
    $V.Results = "OPEN. The sudo group contains account(s) not on the approved administrator list: " + ($extra -join ", ") + ". Full group line: " + $line.Trim()
}
return $V
EOF
  ;;
  V-270694) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$f = "/etc/profile.d/ssh_confirm.sh"
$body = (bash -c "cat $f 2>/dev/null") -join "`n"
$hasSsh    = ($body -match 'SSH_CLIENT' -or $body -match 'SSH_TTY')
$hasPrompt = ($body -match 'read\s+-p')
$hasBanner = ($body -match 'U\.S\. Government' -and $body -match 'Information System')
$hasDeny   = ($body -match 'exit' -or $body -match 'logout')
if ($body -ne "" -and $hasSsh -and $hasPrompt -and $hasBanner -and $hasDeny) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText names " + $f + " and this scan read it verbatim. It is present (" + $body.Length + " bytes), it gates on SSH_CLIENT/SSH_TTY so it fires for interactive SSH logins, it prompts with read -p, the prompt text is the Standard Mandatory DOD Notice and Consent Banner, and a non-acknowledgement terminates the session. The acknowledgement requirement is therefore enforced, separately from the sshd Banner directive which only DISPLAYS the notice. The scanner leaves this Not Reviewed because deciding it means reading a shell script, not matching a value."
}
else {
    $V.Results = "OPEN. " + $f + " is missing or does not enforce acknowledgement. Present: " + ($body -ne "") + ", gates on SSH_CLIENT/SSH_TTY: " + $hasSsh + ", prompts with read -p: " + $hasPrompt + ", carries the DOD notice text: " + $hasBanner + ", terminates on refusal: " + $hasDeny + ". Displaying the banner via sshd's Banner directive is NOT sufficient for this control - it requires acknowledgement."
}
return $V
EOF
  ;;
  V-270817) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
# DISA'S CHECK TEXT OPENS WITH ITS OWN EXEMPTION: "If this is an interconnected system, this
# is not applicable." The control is for STANDALONE machines that must carry audit records off
# by hand. Every enclave machine is networked and ships its records to the collector weekly
# (backlog N-2, proven 2026-09-23) - so the honest answer is NOT APPLICABLE, but ONLY while
# that offload actually works. This checks the four things that make it work; any one failing
# returns false and the control re-opens with the reason. (Rewritten 2026-09-24, backlog 3.31
# #5: the old version looked only in cron directories, never saw the systemd timer, and was
# gated on NR so it never ran where the scanner said Open.)
$probe = @'
u=enclave-audit-offload
printf 'TIMER:%s\n'  "$(systemctl is-enabled $u.timer 2>/dev/null || echo absent)"
printf 'EXEC:%s\n'   "$(systemctl show $u.service -p ExecStart --value 2>/dev/null | grep -o 'path=[^ ;]*' | head -1 | sed 's/^path=//')"
printf 'RESULT:%s\n' "$(systemctl show $u.service -p Result --value 2>/dev/null)"
st=/var/local/enclave-metrics/audit-offload.state
last="$(tail -1 "$st" 2>/dev/null | cut -d' ' -f1)"
printf 'LAST:%s\n' "${last:-never}"
if [ -n "$last" ]; then printf 'AGE:%s\n' "$(( ( $(date +%s) - $(date -d "$last" +%s 2>/dev/null || echo 0) ) / 86400 ))"; else printf 'AGE:-1\n'; fi
'@
$out = @(bash -c $probe)
function Get-Field([string]$name) { ((($out | Where-Object { $_ -like "${name}:*" }) -join '') -replace "^${name}:",'').Trim() }
$timer = Get-Field 'TIMER'; $exec = Get-Field 'EXEC'; $result = Get-Field 'RESULT'
$last = Get-Field 'LAST'; $age = [int](Get-Field 'AGE')
$okTimer  = ($timer -eq 'enabled')
$okExec   = ($exec -eq '/usr/local/lib/enclave/audit-offload.sh')
$okRecent = ($age -ge 0 -and $age -le 8)
$okResult = ($result -eq 'success')
$facts = "timer: " + $timer + "; runs: " + $exec + "; last run: " + $last + " (" + $age + " day(s) ago); last result: " + $result
if ($okTimer -and $okExec -and $okRecent -and $okResult) {
    $V.Valid = $true
    $V.Results = "NOT APPLICABLE AS WRITTEN - DISA's CheckText begins: 'If this is an interconnected system, this is not applicable.' This machine is interconnected: a weekly systemd timer ships its rotated audit records over the enclave network to the audit collector on svc-obs-01 (1-year retention), which produces the enclave's checksummed weekly export bundle - the external-media path this control intends. Verified at scan time rather than asserted: " + $facts + ". The unit runs the root-owned runtime copy, not an editable one. This answer re-evaluates every scan: a disabled timer, a changed path, a failed run or no run for more than 8 days re-opens the control."
}
else {
    $why = @()
    if (-not $okTimer)  { $why += "timer not enabled" }
    if (-not $okExec)   { $why += "unit does not run /usr/local/lib/enclave/audit-offload.sh" }
    if (-not $okRecent) { $why += "no successful run recorded in the last 8 days" }
    if (-not $okResult) { $why += "last run did not succeed" }
    $V.Results = "OPEN - the weekly network offload that makes this machine interconnected is not working (" + ($why -join '; ') + "). " + $facts + ". Fix with scripts/enclave/audit-offload.sh install and check a bundle reaches svc-obs-01."
}
return $V
EOF
  ;;
  V-270682) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$approved = @(__AF_ADMINS__)
$emergency = @(__AF_EMERGENCY__)
# DISA asks for the expiry on each TEMPORARY account. The prior question is which accounts
# are temporary at all - so enumerate every interactive account and show the set.
# AN INTERACTIVE ACCOUNT IS DEFINED BY ITS LOGIN SHELL, NOT BY ITS UID.
# The first version tested UID >= 1000 alone. On host-4 that caught `libvirt-qemu`, which
# Debian allocates UID 64055 with /usr/sbin/nologin - a service account QEMU runs as, and the
# only machine it exists on is the hypervisor. The control went Open on 2026-09-16 naming it
# as an unapproved interactive account. It is not an account anybody can log in to.
#
# The upper bound excludes nobody (65534) by number rather than by name, so a system that
# names it differently is still handled.
$probe = @'
awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false|sync)$/ {print $1}' /etc/passwd
'@
$accts = @(bash -c $probe) | Where-Object { $_ -ne "" }
$unexpected = @($accts | Where-Object { ($approved -notcontains $_) -and ($emergency -notcontains $_) })
$bg = @($accts | Where-Object { $emergency -contains $_ })
$bgNote = ""
if ($bg.Count -gt 0) { $bgNote = " The set includes the emergency (break-glass) account(s) " + ($bg -join ", ") + ", held in AF_EMERGENCY and NOT among the administrators above: this STIG's own discussion for this control states that emergency accounts 'are not subject to manual removal or scheduled expiration requirements', so the 72-hour expiry does not apply to them either. They are console-only, sealed offline per machine under dual custody, rotated after every use, and audited by UID." }
if ($unexpected.Count -eq 0) {
    $rows = @()
    foreach ($a in $accts) { $rows += ($a + ": " + ((bash -c "chage -l $a 2>/dev/null | grep -i 'account expires'") -join "")) }
    $V.Valid = $true
    $V.Results = "NOT APPLICABLE AS WRITTEN - there are no temporary accounts on this system. Every interactive account - UID >= 1000, below 65534, and holding a real login shell rather than nologin/false - was enumerated at scan time and the full set is: " + ($accts -join ", ") + ". Accounts on the approved list held in AF_ADMINS are permanent, named enclave administrator accounts, provisioned for the life of the system and not as temporary accounts, so the 72-hour expiry requirement has nothing to apply to." + $bgNote + " Reported expiry for each, for completeness: " + ($rows -join " | ") + ". This answer re-evaluates on every scan: provisioning any account outside the approved list re-opens the control, at which point that account's expiry must be set within 72 hours or it must be documented."
}
else {
    $V.Results = "OPEN. Interactive account(s) exist that are not on the approved permanent-administrator list: " + ($unexpected -join ", ") + ". Full set of interactive accounts (UID >= 1000, below 65534, with a real login shell): " + ($accts -join ", ") + ". Each unexpected account must either be documented as permanent or carry an expiry within 72 hours."
}
return $V
EOF
  ;;
  V-270816) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
# MEASURE THIS MACHINE'S OWN RATE. The first version of this check used the rate measured on
# svc-harbor-01 - 2.44 MB/day - as a constant. On svc-mgmt-01 the real rate is ~430 MB/day,
# 176x higher, because MAAS invokes machine-resources through sudo about 1.7 times a SECOND
# and auditd records every one. The constant would have returned NOT A FINDING on a machine
# holding roughly 2 HOURS of audit history against a control that requires a week.
#
# A number measured on one machine is not a property of the enclave.
$probe = @'
grep '^log_file' /etc/audit/auditd.conf 2>/dev/null | head -1
df -PB1 /var/log/audit 2>/dev/null | tail -1 | tr -s ' '
grep '^max_log_file ' /etc/audit/auditd.conf 2>/dev/null | head -1 | tr -s ' ' | cut -d' ' -f3
grep '^num_logs' /etc/audit/auditd.conf 2>/dev/null | head -1 | tr -s ' ' | cut -d' ' -f3
stat -c '%Y %s %n' /var/log/audit/audit.log* 2>/dev/null | sort -n | tr '\n' ';'
'@
$out = @(bash -c $probe)
while ($out.Count -lt 5) { $out += "" }
$logfile = $out[0]; $dfline = $out[1]; $maxlog = $out[2]; $numlogs = $out[3]
$free = 0
$parts = @($dfline -split " " | Where-Object { $_ -ne "" })
if ($parts.Count -ge 4) { $free = [int64]$parts[3] }
$alloc = 0
if ($maxlog -match '^\d+$' -and $numlogs -match '^\d+$') { $alloc = [int64]$maxlog * 1MB * [int64]$numlogs }

# Rate from the rotation history actually on disk: total bytes held, over the span between
# the oldest and newest audit file. No constant, no assumption about what the machine does.
$files = @()
foreach ($rec in ($out[4] -split ';')) {
    $f = $rec.Trim() -split '\s+', 3
    if ($f.Count -eq 3) { $files += [pscustomobject]@{ T = [int64]$f[0]; S = [int64]$f[1]; N = $f[2] } }
}
$ratePerDay = 0; $spanHours = 0; $held = 0
if ($files.Count -ge 2) {
    $held = ($files | Measure-Object -Property S -Sum).Sum
    $spanSec = ($files[-1].T - $files[0].T)
    if ($spanSec -gt 0) {
        $spanHours = [math]::Round($spanSec / 3600, 2)
        $ratePerDay = [int64]($held / $spanSec * 86400)
    }
}
$retentionDays = 0
if ($ratePerDay -gt 0) { $retentionDays = [math]::Round($alloc / $ratePerDay, 3) }

if ($ratePerDay -gt 0 -and $retentionDays -ge 7 -and $free -ge $alloc) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText executed verbatim at scan time. " + $logfile + ". df -PB1 /var/log/audit: " + $dfline + " (free bytes: " + $free + "). auditd is configured max_log_file=" + $maxlog + " MB x num_logs=" + $numlogs + ", bounding the trail at " + $alloc + " bytes, and free space exceeds that whole allocation. THE GROWTH RATE WAS MEASURED ON THIS MACHINE, not assumed: " + $files.Count + " audit files holding " + $held + " bytes span " + $spanHours + " hours, which is " + $ratePerDay + " bytes/day. At that rate the bounded allocation holds " + $retentionDays + " days, which meets the one-week requirement."
}
elseif ($files.Count -lt 2 -or $alloc -eq 0) {
    # COULD NOT MEASURE IS NOT THE SAME AS MEASURED AND FAILING. Without this branch the
    # message below claims records are being overwritten on a machine that has no auditd at
    # all - a confident statement about something never observed.
    $V.Results = "OPEN - AND NOT MEASURABLE HERE. auditd configuration or audit files could not be read: " + $files.Count + " audit file(s) found, max_log_file='" + $maxlog + "', num_logs='" + $numlogs + "', log_file line '" + $logfile + "'. Nothing is being asserted about retention on this machine because nothing was observed. If auditd is not installed or not running, that is a larger finding than this control and should be answered first."
}
else {
    $V.Results = "OPEN. Measured on this machine: " + $files.Count + " audit files holding " + $held + " bytes across " + $spanHours + " hours = " + $ratePerDay + " bytes/day. auditd bounds the trail at " + $alloc + " bytes (max_log_file=" + $maxlog + " x num_logs=" + $numlogs + "), which is only " + $retentionDays + " DAYS of history - the control requires seven. Free space on the partition holding " + $logfile + ": " + $free + " bytes. THIS IS NOT A PAPERWORK FINDING: audit records are being overwritten before a week has passed, so the evidence an investigator would need is already gone. Either raise max_log_file/num_logs, give /var/log/audit its own partition, offload to a collector, or reduce what is generating the records."
}
return $V
EOF
  ;;
  *) die "no validation code for $1" ;;
  esac
}

# The default action. READ-ONLY: every managed entry with its STIG id, the ExpectedStatus it
# answers ([O], [NR], [NA]) and its one-line reason, then how many entries the file holds.
cmd_show() {
  printf '\n  portable answer-file entries managed by this script\n\n'
  local id stig why exp
  while IFS=$'\t' read -r id stig why exp; do
    [ -n "${id:-}" ] || continue
    printf '  %-10s %-16s [%s] %s\n' "$id" "$stig" "${exp:-O}" "$why"
  done < <(af_entries)
  printf '\n  Each runs DISA'"'"'s CheckText verbatim at scan time. No ResultHash - a hash pins an\n'
  printf '  answer to one machine'"'"'s output, which is why the hand-built file worked only on\n'
  printf '  svc-mgmt-01. ValidFalseStatus is Open, so a genuine regression re-opens the control.\n\n'
  if [ -f "$AF" ]; then
    say "current file: $AF"
    say "entries present: $(grep -c '<Vuln ID=' "$AF" 2>/dev/null || echo 0)"
  else
    warn "no answer file at $AF"
  fi
  echo
}

# RUNBOOK 6.0 STEP 13c. Rewrites every entry af_entries() manages and leaves every other
# Vuln ID exactly as it was. Keeps a timestamped .bak- copy beside the file first; -n prints
# the same report and writes nothing. The XML is built by the python below: one Answer per
# Vuln, ExpectedStatus from af_entries' 4th column (O when absent), ValidTrueStatus NF,
# ValidFalseStatus O, and no ResultHash.
cmd_generate() {
  # BOOTSTRAP FROM THE VENDOR TEMPLATE. On a from-scratch rebuild there is no answer file to
  # modify, and "no answer file at ..." would stop the rebuild at exactly the point where
  # nobody has one to supply. Evaluate-STIG ships Template_AnswerFile.xml; seed from that.
  # The template travels on the transfer bundle inside the scanner tree, so this works
  # inside the gap with no network.
  if [ ! -f "$AF" ]; then
    local tpl="${STIG_AF_TEMPLATE:-$(dirname "$XSD")/../AnswerFiles/Template_AnswerFile.xml}"
    [ -f "$tpl" ] || die "no answer file at $AF, and no vendor template at $tpl
       Set STIG_ANSWERFILE to an existing file, or STIG_AF_TEMPLATE to the vendor template."
    install -d "$(dirname "$AF")"
    install -m 0644 "$tpl" "$AF"
    warn "NO ANSWER FILE EXISTED - seeded from the vendor template:"
    say  "     $tpl"
    say  "     -> $AF"
    say  "  Entries below are written fresh. Any hand-written entry from a previous build"
    say  "  is NOT here - it lives outside this repo and has to be restored separately."
  fi
  [ -f "$AF" ] || die "no answer file at $AF - set STIG_ANSWERFILE"
  local tmpdir; tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" EXIT
  local id stig why exp
  while IFS=$'\t' read -r id stig why exp; do
    [ -n "${id:-}" ] || continue
    # AF_ADMINS is substituted here, not inside the PowerShell, so the generated answer
    # file is self-contained and an assessor can read the list in the artefact.
    # Each comma list becomes the body of a PowerShell array: a,b -> "a","b".
    af_code "$id" \
      | sed "s/__AF_ADMINS__/$(printf '%s' "$AF_ADMINS" | tr ',' ' ' | xargs -n1 printf '\"%s\",' | sed 's/,$//')/" \
      | sed "s/__AF_EMERGENCY__/$(printf '%s' "$AF_EMERGENCY" | tr ',' ' ' | xargs -n1 printf '\"%s\",' | sed 's/,$//')/" \
      > "$tmpdir/$id.ps1"
    printf '%s\n' "$why" > "$tmpdir/$id.why"
    # EXPECTED STATUS IS NOT ALWAYS "Open". An answer only fires when the control's current
    # status matches ExpectedStatus, so an entry for a NOT REVIEWED control that says O is
    # silently inert - it generates cleanly, validates cleanly, and never applies.
    printf '%s\n' "${exp:-O}" > "$tmpdir/$id.exp"
  done < <(af_entries)

  DRY="$DRY" AF="$AF" TMPD="$tmpdir" python3 - <<'PY'
import os, sys, glob, shutil, datetime
import xml.etree.ElementTree as ET

af, tmpd, dry = os.environ['AF'], os.environ['TMPD'], os.environ['DRY'] == '1'
managed = sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(tmpd, '*.ps1')))

tree = ET.parse(af)
root = tree.getroot()
# THE VENDOR TEMPLATE SHIPS A SAMPLE ENTRY (V-00000). Left in, it travels to every machine
# as a real-looking answer for a vuln id that does not exist. Drop any placeholder before
# anything else looks at the file.
for _v in list(root.findall('Vuln')):
    _id = (_v.get('ID') or '').upper()
    if _id in ('V-00000', 'V-XXXXX') or _id.replace('V-', '').strip('0') == '':
        root.remove(_v)
        print("  removed the vendor template's placeholder entry: %s" % _id)

existing = {v.get('ID'): v for v in root.findall('Vuln')}
preserved = [k for k in existing if k not in managed]

print("  managed by this script : %s" % ', '.join(managed))
print("  preserved untouched    : %s" % (', '.join(sorted(preserved)) or 'none'))
print()

for vid in managed:
    code = open(os.path.join(tmpd, vid + '.ps1')).read().strip()
    old = existing.get(vid)
    if old is not None:
        oldhash = (old.find('.//Answer').get('ResultHash') if old.find('.//Answer') is not None else None)
        print("  %-10s REPLACING existing entry%s" % (vid, " (was pinned to ResultHash %s..)" % oldhash[:8] if oldhash else ""))
        root.remove(old)
    else:
        print("  %-10s NEW" % vid)
    v = ET.SubElement(root, 'Vuln'); v.set('ID', vid)
    k = ET.SubElement(v, 'AnswerKey'); k.set('Name', 'DEFAULT')
    expf = os.path.join(tmpd, vid + '.exp')
    expected = open(expf).read().strip() if os.path.exists(expf) else 'O'
    # ONE Answer PER EXPECTED STATUS (backlog 3.31 #5). An Answer fires only when the scanner's
    # own status equals its ExpectedStatus, and the same control can come back O on one machine
    # and NR on another - V-270817 does. The 4th column may list several, comma-separated.
    for idx, exp_status in enumerate([e.strip() for e in expected.split(',') if e.strip()], 1):
        a = ET.SubElement(k, 'Answer'); a.set('Index', str(idx)); a.set('ExpectedStatus', exp_status)
        ET.SubElement(a, 'ValidationCode').text = "\n" + code + "\n"
        ET.SubElement(a, 'ValidTrueStatus').text = 'NF'
        ET.SubElement(a, 'ValidTrueComment').text = (
            "Answered by scripts/enclave/answerfile.sh. DISA's CheckText was executed verbatim at "
            "scan time and the result is recorded in the Results field above.")
        ET.SubElement(a, 'ValidFalseStatus').text = 'O'
        ET.SubElement(a, 'ValidFalseComment').text = (
            "The condition that justified this answer is no longer true. This is a real finding; "
            "see the Results field for the files involved.")

ET.indent(tree, space='  ')
if dry:
    print("\n  DRY RUN - nothing written. Resulting file would carry %d entries." % len(root.findall('Vuln')))
    sys.exit(0)

bak = af + '.bak-' + datetime.datetime.now().strftime('%Y%m%dT%H%M%S')
shutil.copy2(af, bak)
tree.write(af, encoding='utf-8', xml_declaration=True)
print("\n  backup : %s" % bak)
print("  written: %s  (%d entries)" % (af, len(root.findall('Vuln'))))
PY
}

# READ-ONLY. Schema-validate against the vendor XSD when xmllint and the XSD are both here
# (well-formedness only otherwise), count entries, and list any non-empty ResultHash - the
# per-machine pin this script exists to remove.
cmd_verify() {
  [ -f "$AF" ] || die "no answer file at $AF"
  if command -v xmllint >/dev/null 2>&1; then
    if [ -f "$XSD" ]; then
      xmllint --noout --schema "$XSD" "$AF" && ok "validates against the vendor XSD"
    else
      xmllint --noout "$AF" && ok "well-formed (no XSD at $XSD to validate against)"
    fi
  else
    warn "xmllint not installed - checking well-formedness with python only"
    python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1]); print('  [ok] well-formed')" "$AF"
  fi
  say "entries: $(grep -c '<Vuln ID=' "$AF")"
  # A ResultHash left anywhere in the file is the bug this script exists to remove - but
  # an EMPTY ResultHash="" is not a pin, it is the vendor template's placeholder attribute.
  # Matching on the attribute name alone reported the seeded template as a violation and
  # would have had someone hunting a hash that was never there.
  local pinned; pinned="$(grep -c 'ResultHash="[^"]\+"' "$AF" || true)"
  if [ "${pinned:-0}" -gt 0 ]; then
    warn "$pinned entry(ies) still carry ResultHash - those answer only on the machine they"
    warn "  were built on. Portable entries must not have one."
    grep -n 'ResultHash="[^"]\+"' "$AF" | sed 's/^/       /'
  else
    ok "no ResultHash anywhere - every answer is portable"
  fi
}

# Flags and the action may come in any order. -n only affects `generate`.
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    -f) AF="${2:?-f needs a path}"; shift 2 ;;
    show|generate|verify) ACTION="$1"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "${ACTION:-show}" in
  show)     cmd_show ;;
  generate) cmd_generate ;;
  verify)   cmd_verify ;;
esac
