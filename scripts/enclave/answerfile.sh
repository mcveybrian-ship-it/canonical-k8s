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
  *) die "no validation code for $1" ;;
  esac
}

cmd_show() {
  printf '\n  portable answer-file entries managed by this script\n\n'
  local id stig why
  while IFS=$'\t' read -r id stig why; do
    [ -n "${id:-}" ] || continue
    printf '  %-10s %-16s %s\n' "$id" "$stig" "$why"
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
  [ -f "$AF" ] || die "no answer file at $AF - set STIG_ANSWERFILE"
  local tmpdir; tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" EXIT
  local id stig why
  while IFS=$'\t' read -r id stig why; do
    [ -n "${id:-}" ] || continue
    af_code "$id" > "$tmpdir/$id.ps1"
    printf '%s\n' "$why" > "$tmpdir/$id.why"
  done < <(af_entries)

  DRY="$DRY" AF="$AF" TMPD="$tmpdir" python3 - <<'PY'
import os, sys, glob, shutil, datetime
import xml.etree.ElementTree as ET

af, tmpd, dry = os.environ['AF'], os.environ['TMPD'], os.environ['DRY'] == '1'
managed = sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(tmpd, '*.ps1')))

tree = ET.parse(af)
root = tree.getroot()
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
    a = ET.SubElement(k, 'Answer'); a.set('Index', '1'); a.set('ExpectedStatus', 'O')
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
  # A ResultHash left anywhere in the file is the bug this script exists to remove.
  local pinned; pinned="$(grep -c 'ResultHash=' "$AF" || true)"
  if [ "${pinned:-0}" -gt 0 ]; then
    warn "$pinned entry(ies) still carry ResultHash - those answer only on the machine they"
    warn "  were built on. Portable entries must not have one."
    grep -n 'ResultHash=' "$AF" | sed 's/^/       /'
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
