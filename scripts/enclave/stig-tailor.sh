#!/usr/bin/env bash
# =========================================================================================
# stig-tailor.sh - generate the enclave's STIG tailoring file, with justifications.
#
#     MACHINE: any enclave machine being hardened. Needs `usg` installed and Pro attached.
#
#     sudo ./stig-tailor.sh generate
#     sudo ./stig-tailor.sh audit
#     ./stig-tailor.sh show
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

# ---------------------------------------------------------------------------- deviations
#
# Fields, tab-separated:  kind | xccdf id (without the content_ prefix) | value | why
#
# ACTIVE. These are decided.
#
deviations() {
cat <<'EOF'
set-value	value_var_multiple_time_servers	__TIME_MASTER__	chronyd_specify_remote_server (STIG ID: __STIG_ID__ - take it from the comment above the rule in the generated file). The DISA profile pins the approved time source to 0.us.pool.ntp.mil, which is unreachable from inside the boundary BY DESIGN - reaching it would be the finding. The enclave's authoritative source is __TIME_MASTER_NAME__ (__TIME_MASTER__), a physical machine serving the enclave subnet only. The rule's INTENT - synchronise only to an organisation-approved source - is met in full; only the list of approved sources differs. This is a retarget, not an exception.
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

  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  say "generating from profile $PROFILE"
  ( cd "$tmp" && usg generate-tailoring "$PROFILE" base.xml >/dev/null ) \
    || die "usg generate-tailoring failed - is '$PROFILE' the right name? check 'usg list'"

  grep -q '</Profile>' "$tmp/base.xml" || die "generated file has no </Profile> - unexpected format"

  # Build the deviation block, then splice it in before </Profile>. XCCDF 1.2 allows
  # select/set-value in any order within a Profile, so appending is schema-valid and does
  # not depend on where usg happened to put the rule we are overriding.
  local block="$tmp/dev.xml" n=0 missing=0
  : > "$block"
  echo "    <!-- ================= ENCLAVE DEVIATIONS - generated $(date -Is) ================= -->" >> "$block"
  while IFS=$'\t' read -r kind id value why; do
    [ -n "${kind:-}" ] || continue
    value="${value//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER__/$TIME_MASTER}"
    why="${why//__TIME_MASTER_NAME__/$TIME_MASTER_NAME}"

    # A deviation naming a rule the benchmark no longer has is a SILENT no-op otherwise -
    # exactly the failure this script exists to prevent. Say so loudly and keep going.
    if ! grep -q "content_${id}" "$tmp/base.xml"; then
      warn "NOT IN THIS BENCHMARK: $id - deviation skipped, review it"
      missing=$((missing + 1))
      continue
    fi
    {
      echo "    <!-- DEVIATION: $why -->"
      case "$kind" in
        set-value) echo "    <set-value idref=\"xccdf_org.ssgproject.content_${id}\">${value}</set-value>" ;;
        deselect)  echo "    <select idref=\"xccdf_org.ssgproject.content_${id}\" selected=\"false\"/>" ;;
        *) die "unknown deviation kind: $kind" ;;
      esac
    } >> "$block"
    n=$((n + 1))
  done < <(deviations)

  awk -v blockfile="$block" '
    /<\/Profile>/ && !done { while ((getline line < blockfile) > 0) print line; done=1 }
    { print }
  ' "$tmp/base.xml" > "$tmp/out.xml"

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
  # The customised profile id is fixed by usg's generator: <profile>_customized.
  local cprof; cprof="$(grep -oE 'Profile id="[^"]+_customized"' "$OUT" | head -1 | sed 's/.*id="//; s/"//')"
  [ -n "$cprof" ] || die "cannot find the customised profile id in $OUT"
  say "auditing with $cprof"
  usg audit --tailoring-file "$OUT" "$cprof"
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

case "${1:-}" in
  generate) shift; cmd_generate "$@" ;;
  audit)    shift; cmd_audit "$@" ;;
  show)     shift; cmd_show "$@" ;;
  *) printf 'usage: %s {generate|audit|show}\n' "$0" >&2; exit 2 ;;
esac
