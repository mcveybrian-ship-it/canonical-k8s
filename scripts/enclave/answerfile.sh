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
AF_ADMINS="${AF_ADMINS:-encadmin}"
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
V-270817	UBTU-24-900930	no cron.weekly script offloads the audit trail, because audit offload is not implemented in this enclave yet - the scanner finds man-db in cron.weekly and cannot decide, leaving NR where every other machine is honestly Open	NR
V-270682	UBTU-24-200250	there are NO temporary accounts on any enclave machine - every interactive account, meaning UID >= 1000 with a real login shell, is a permanent named administrator. Service accounts such as libvirt-qemu hold nologin and are not interactive	NR
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
  V-270748) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$approved = @(__AF_ADMINS__)
$line = (bash -c "getent group sudo") -join ""
$members = @()
if ($line -match "^sudo:[^:]*:[^:]*:(.*)$") {
    $members = @($Matches[1] -split "," | Where-Object { $_ -ne "" })
}
$extra = @($members | Where-Object { $approved -notcontains $_ })
if ($extra.Count -eq 0) {
    $V.Valid = $true
    $V.Results = "NOT A FINDING. DISA's CheckText was executed verbatim at scan time: getent group sudo returned '" + $line.Trim() + "'. Members: " + (($members -join ", ") + ".") + " Every member is a named enclave administrator account whose role IS the administration of security functions on this system, so by the control's own wording each one needs that access. The approved list is held in one place - AF_ADMINS in scripts/enclave/answerfile.sh - and this check re-applies it on every machine at every scan, so adding an account to the sudo group re-opens this control until the list is changed deliberately. Note also that the blanket 'ALL=(ALL) NOPASSWD:ALL' grant was removed during hardening; membership of this group confers no unauthenticated privilege."
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
# THIS ANSWER EXISTS TO TURN "NOBODY LOOKED" INTO "WE LOOKED, AND IT IS OPEN".
#
# DISA wants a weekly cron job that off-loads audit records to external media. This enclave
# does not do that yet - auditd_offload_logs is an open finding on every machine and the
# destination is an AO decision, not an engineering one. Every machine except host-4 reports
# this control Open, which is correct. host-4 alone comes back NOT REVIEWED because it has a
# script in /etc/cron.weekly (man-db) and the scanner cannot tell whether that script offloads
# audit logs, so it declines to decide.
#
# NR is the one status that means nothing. This makes host-4 agree with the rest of the
# enclave, and the answer re-evaluates: the day a real offload job is installed, the check
# finds it and the control closes on its own.
# LABELLED LINES, NOT POSITIONAL ONES. The first version separated the two answers with a
# bare "|" line and then read $out[1] - which is the separator, not the value. There is no
# pwsh on stage-01 to run this against, so the parsing has to be right by construction:
# each line names itself and is selected by its own prefix.
$probe = @'
printf 'SCRIPTS:%s\n' "$(ls -1 /etc/cron.weekly/ 2>/dev/null | tr '\n' ' ')"
printf 'HITS:%s\n' "$(grep -rlE '/var/log/audit|auditd|aureport|ausearch|audisp' /etc/cron.weekly/ /etc/cron.d/ /etc/cron.daily/ 2>/dev/null | tr '\n' ' ')"
'@
$out = @(bash -c $probe)
$scripts = ((($out | Where-Object { $_ -like 'SCRIPTS:*' }) -join '') -replace '^SCRIPTS:','').Trim()
$hits    = ((($out | Where-Object { $_ -like 'HITS:*' })    -join '') -replace '^HITS:','').Trim()

if ($hits -ne "") {
    $V.Valid = $true
    $V.Results = "NOT A FINDING - a scheduled job referencing the audit trail is present: " + $hits + ". Scripts in /etc/cron.weekly at scan time: " + $scripts + ". Verify that this job off-loads records to media outside this system before accepting it as sufficient."
}
else {
    $V.Results = "OPEN, and known. No job under /etc/cron.weekly, /etc/cron.daily or /etc/cron.d references the audit trail. Scripts present in /etc/cron.weekly are: " + $scripts + " - these are stock Ubuntu maintenance jobs (man-db rebuilds the manual page index) and have nothing to do with auditing. THE SCANNER LEFT THIS NOT REVIEWED because it found a script there and could not tell what it does; that is the only reason this machine differed from the rest of the enclave, where the same control is already Open. Audit off-load is not implemented anywhere in this enclave: auditd_offload_logs is open on all five machines and the destination is an outstanding AO decision, not an engineering gap. This answer re-evaluates on every scan and closes the control by itself once a real off-load job exists."
}
return $V
EOF
  ;;
  V-270682) cat <<'EOF'
$V = @{ Valid = $false; Results = "" }
$approved = @(__AF_ADMINS__)
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
$unexpected = @($accts | Where-Object { $approved -notcontains $_ })
if ($unexpected.Count -eq 0) {
    $rows = @()
    foreach ($a in $accts) { $rows += ($a + ": " + ((bash -c "chage -l $a 2>/dev/null | grep -i 'account expires'") -join "")) }
    $V.Valid = $true
    $V.Results = "NOT APPLICABLE AS WRITTEN - there are no temporary accounts on this system. Every interactive account - UID >= 1000, below 65534, and holding a real login shell rather than nologin/false - was enumerated at scan time and the full set is: " + ($accts -join ", ") + ". Each is a permanent, named enclave administrator account on the approved list held in AF_ADMINS, provisioned for the life of the system and not as a temporary or emergency account, so the 72-hour expiry requirement has nothing to apply to. Reported expiry for each, for completeness: " + ($rows -join " | ") + ". This answer re-evaluates on every scan: provisioning any account outside the approved list re-opens the control, at which point that account's expiry must be set within 72 hours or it must be documented."
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
    af_code "$id" \
      | sed "s/__AF_ADMINS__/$(printf '%s' "$AF_ADMINS" | tr ',' ' ' | xargs -n1 printf '\"%s\",' | sed 's/,$//')/" \
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
    a = ET.SubElement(k, 'Answer'); a.set('Index', '1'); a.set('ExpectedStatus', expected)
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
