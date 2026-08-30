#!/usr/bin/env bash
#
# 01 — Answer open questions 11 and 12 on a throwaway Ubuntu 24.04 machine.
#
#   Q11  Can a FIPS stream be enabled on 24.04 today?
#   Q12  Does USG carry a disa_stig profile for 24.04?
#
# Both block the build. Neither needs a vendor. Run this on a DISPOSABLE VM built from the
# Ubuntu Minimal 24.04 image — Minimal, not the server ISO, because the six cluster nodes
# run Minimal and this also proves USG behaves on the stripped base.
#
# A free personal Ubuntu Pro token works: https://ubuntu.com/pro/dashboard
# Free-token entitlements are not guaranteed to match an enterprise contract, so treat a
# positive result as reliable and confirm a negative one with Canonical.
#
# This script READS state and enables nothing. It ends by printing the exact enable command
# so that turning FIPS on stays a deliberate act.
#
# Usage:
#   sudo ./01-capability-test.sh [-t PRO_TOKEN] [-o REPORT]
#
set -uo pipefail   # deliberately not -e: we want every probe to run and be recorded

TOKEN=""
REPORT="capability-test-$(date -u +%Y%m%dT%H%M%SZ).txt"

while getopts ":t:o:h" opt; do
  case "$opt" in
    t) TOKEN="$OPTARG" ;;
    o) REPORT="$OPTARG" ;;
    h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

exec > >(tee "$REPORT") 2>&1

rule() { printf '\n%s\n%s\n' "$1" "$(printf '=%.0s' $(seq ${#1}))"; }

rule "Ubuntu 24.04 capability test — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "host:    $(hostname)"
echo "release: $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "kernel:  $(uname -r)"
echo "arch:    $(dpkg --print-architecture)"
# Minimal images carry a far smaller package set than the server image — recorded so the
# result is attributable to the right base.
echo "packages installed: $(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)"

rule "Ubuntu Pro client"
if ! command -v pro >/dev/null; then
  echo "pro not found — installing ubuntu-advantage-tools"
  apt-get update -qq && apt-get install -y -qq ubuntu-advantage-tools
fi
pro version

if [[ -n "$TOKEN" ]]; then
  rule "Attaching Pro subscription"
  # --no-auto-enable keeps this a measurement, not a change to the machine.
  pro attach "$TOKEN" --no-auto-enable || echo "ATTACH FAILED — everything below will be unattached"
fi

if ! pro status --format json 2>/dev/null | grep -q '"attached": true'; then
  echo
  echo "!! NOT ATTACHED to Ubuntu Pro."
  echo "!! Unattached output shows what EXISTS for this release, not what you are entitled to."
  echo "!! Re-run with -t <token> for a conclusive answer."
fi

# ---------------------------------------------------------------------------- Q11: FIPS ----
rule "Q11 — FIPS streams available on this release"
pro status --all

echo
echo "-- FIPS-related services only --"
pro status --all 2>/dev/null | awk 'NR==1 || /^fips/'

# Availability is the STATUS column, NOT entitled.
#   n/a       - contract covers it, but it is NOT available on this release/machine
#   disabled  - available here, simply not turned on
#   enabled   - available and on
# Reading ENTITLED gives a false positive on every service the subscription covers.
FIPS_FOUND=""
for svc in fips fips-updates fips-preview; do
  st="$(pro status --all 2>/dev/null | awk -v s="$svc" '$1==s {print $3; exit}')"
  case "$st" in
    enabled|disabled)
      echo "  AVAILABLE ($st): $svc"
      FIPS_FOUND="${FIPS_FOUND}${svc} " ;;
    n/a)
      echo "  NOT available on this release (n/a): $svc" ;;
    "")
      echo "  not listed: $svc" ;;
    *)
      echo "  unknown status '$st': $svc" ;;
  esac
done

echo
echo "current FIPS mode: $(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo 'n/a (kernel not FIPS)')"

# ---------------------------------------------------------------------------- Q12: USG -----
rule "Q12 — USG DISA-STIG profile for 24.04"
if pro status --all 2>/dev/null | awk '$1=="usg" {print $2}' | grep -q "yes"; then
  echo "usg entitlement: available"
  pro enable usg --assume-yes 2>&1 | tail -2
  apt-get install -y -qq usg 2>&1 | tail -2
else
  echo "usg entitlement: NOT available on this release/subscription"
fi

if command -v usg >/dev/null; then
  echo
  echo "-- usg --version --"
  usg --version 2>&1 | head -2
  echo
  echo "-- usg list --"
  # 'usg list' is the correct subcommand. ('list-profiles' does not exist and errors out,
  # which an earlier version of this script mistook for "no profile".)
  usg list 2>&1
  echo
  # Profile naming differs by release. 22.04 used a bare 'disa_stig'; 24.04 uses versioned
  # names like 'stig-v1r1'. Match on 'stig' and report the exact name found.
  STIG_PROFILE="$(usg list 2>/dev/null | awk '/stig/ && !/cis_/ {print $1; exit}')"
  if [[ -n "$STIG_PROFILE" ]]; then
    echo "  RESULT: STIG profile present -> $STIG_PROFILE"
    echo "          Use it verbatim:  usg fix $STIG_PROFILE"
    USG_STIG=yes
    echo
    echo "-- all profile revisions on offer --"
    usg list --all 2>&1 | grep -i stig || echo "  (usg list --all returned nothing for stig)"
  else
    echo "  RESULT: no STIG profile in 'usg list' output."
    echo "          Fall back to DISA SCAP content directly. See runbook section 11.4."
    USG_STIG=no
  fi
else
  echo "usg binary not installed — cannot enumerate profiles"
  USG_STIG=unknown
fi

# ---------------------------------------------------------------------------- verdict ------
rule "VERDICT"
if [[ -n "$FIPS_FOUND" ]]; then
  echo "Q11  FIPS streams available: $FIPS_FOUND"
  echo "     The 24.04 decision has a mechanism. Runbook 6.2 stands."
else
  echo "Q11  NO FIPS stream available on this release."
  echo "     This is the blocking result. There is no workaround inside Ubuntu — FIPS"
  echo "     modules are a Pro entitlement. Options are to get a preview date from"
  echo "     Canonical, or revert the OS decision to 22.04 and accept the certificate"
  echo "     sunsets. See runbook 11.4. Escalate before anything is ordered."
fi
echo
if [[ "${USG_STIG:-no}" == "yes" ]]; then
  echo "Q12  STIG profile present: ${STIG_PROFILE:-?}"
  echo "     Check its BENCHMARK VERSION against DISA current before relying on it."
else
  echo "Q12  No disa_stig profile. Survivable — DISA publishes the benchmark and SCAP"
  echo "     content, so OpenSCAP can apply it until Canonical ships the USG profile."
  echo "     Budget days, not hours, and agree the evidence format with your assessor."
fi

rule "To enable FIPS (not done by this script)"
cat <<'EOF'
Enabling is deliberate and needs an AO position on record first (open question 13):

    sudo pro enable <stream>          # use a stream reported AVAILABLE above
    sudo reboot
    cat /proc/sys/crypto/fips_enabled # expect 1
    uname -r                          # expect the FIPS kernel

Record the posture as "submitted and pending NIST validation", never "FIPS 140-3
validated". There are no CMVP certificate numbers for 24.04 yet.
EOF

echo
echo "Report written to: $REPORT"
echo "Attach it to open questions 11 and 12 in docs/open-questions.md."
