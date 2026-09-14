#!/usr/bin/env bash
# =========================================================================================
# apply-addresses.sh - publish enclave-addresses.env to every node's /etc/hosts.
#
#   ./apply-addresses.sh render          print the block, change nothing
#   ./apply-addresses.sh apply           write it into THIS machine's /etc/hosts  (sudo)
#   ./apply-addresses.sh push            apply it on every reachable enclave node
#
# NOTE: 'push' needs PASSWORDLESS sudo on the targets. The enclave hosts deliberately do not
# have it, so on those run 'apply' locally instead - same result, one step per machine. VMs
# built by 03-compose-vm.sh get this block from cloud-init and need neither.
#   ./apply-addresses.sh verify          check every node resolves every name
#
# Renumbering is: edit enclave-addresses.env, run 'push', done. That is the whole point -
# an address that appears in ten places by hand is an address nobody dares change.
#
# The managed region is delimited by markers. Anything outside them is never touched, so a
# node's own 127.0.1.1 line and any local additions survive.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDRS="${ADDRS:-$SELF/enclave-addresses.env}"
KEY="${ENCLAVE_KEY:-$HOME/.ssh/build01}"
USER_NAME="${ENCLAVE_USER:-encadmin}"

BEGIN='# BEGIN enclave-addresses -- managed by apply-addresses.sh, do not edit inside'
END='# END enclave-addresses'

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

[ -r "$ADDRS" ] || die "no address file at $ADDRS"
# shellcheck disable=SC1090
. "$ADDRS"
: "${ENCLAVE_DOMAIN:?}"

# name<TAB>variable. Order is the order they appear in /etc/hosts.
#
# THIS LIST IS HAND-MAINTAINED AND THAT IS ITS WEAKNESS. svc-obs-01 was built, addressed in
# enclave-addresses.env, given a certificate and put into the ufw table - and was still absent
# here, so no machine in the enclave could resolve it. Adding a machine means adding it HERE
# too, and the symptom of forgetting is not an error, it is a name that quietly does not
# resolve from anywhere except the machine itself.
MAP="
host-1:HOST_1
host-2:HOST_2
host-3:HOST_3
host-4:HOST_4
svc-mgmt-01:SVC_MGMT_01
svc-repo-01:SVC_REPO_01
svc-harbor-01:SVC_HARBOR_01
svc-obs-01:SVC_OBS_01
k8s-api:K8S_API_VIP
k8s-cp-01:K8S_CP_01
k8s-cp-02:K8S_CP_02
k8s-cp-03:K8S_CP_03
k8s-wk-01:K8S_WK_01
k8s-wk-02:K8S_WK_02
k8s-wk-03:K8S_WK_03
k8s-wk-04:K8S_WK_04
"

render() {
  echo "$BEGIN"
  echo "# Generated $(date -Is) from enclave-addresses.env. Edit that file, not this block."
  echo "# /etc/hosts is the PRIMARY resolver here - nsswitch reads 'files dns', so these"
  echo "# entries win over MAAS DNS and keep working when svc-mgmt-01 is down."
  local line name var ip
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%%:*}"; var="${line##*:}"
    ip="${!var:-}"
    [ -n "$ip" ] || { warn "$var is unset in $ADDRS - skipping $name"; continue; }
    printf '%-15s %-15s %s\n' "$ip" "$name" "$name.$ENCLAVE_DOMAIN"
  done <<< "$MAP"
  echo "$END"
}

# Rewrite /etc/hosts, replacing only the managed region.
apply_local() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 apply"
  local new; new=$(mktemp)
  # everything before BEGIN, plus everything after END - i.e. drop the old managed region
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    !skip   {print}
  ' /etc/hosts > "$new"
  # trim trailing blank lines, then append the fresh block
  printf '%s\n' "$(< "$new")" > "$new.t" && mv "$new.t" "$new"
  render >> "$new"
  # A truncated /etc/hosts breaks sudo hostname lookups and is miserable to recover from
  # on an air-gapped box. Prove the new file before it replaces the old one.
  grep -q '^127.0.0.1' "$new" || { rm -f "$new"; die "refusing to write an /etc/hosts with no 127.0.0.1 line"; }
  cp /etc/hosts "/etc/hosts.bak-$(date +%Y%m%d%H%M%S)"
  install -m 0644 "$new" /etc/hosts; rm -f "$new"
  ok "$(hostname): /etc/hosts updated, $(grep -c "$ENCLAVE_DOMAIN" /etc/hosts) name(s)"
}

targets() {
  local line var ip
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    var="${line##*:}"; ip="${!var:-}"
    [ -n "$ip" ] && echo "$ip"
  done <<< "$MAP"
}

push() {
  local block; block=$(render)
  local ip rc=0
  for ip in $(targets); do
    if ! ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "$USER_NAME@$ip" true 2>/dev/null; then
      say "-- $ip unreachable (not built yet?) - skipped"
      continue
    fi
    # Ship the block and the same awk logic; sudo -n so a node without passwordless sudo
    # fails loudly here rather than half-applying.
    if printf '%s\n' "$block" | ssh -i "$KEY" -o BatchMode=yes "$USER_NAME@$ip" \
        "sudo -n tee /tmp/.enclave-hosts >/dev/null && sudo -n bash -c '
           awk -v b=\"$BEGIN\" -v e=\"$END\" \"\\\$0 == b {skip=1; next} \\\$0 == e {skip=0; next} !skip {print}\" /etc/hosts > /tmp/.hosts.new
           cat /tmp/.enclave-hosts >> /tmp/.hosts.new
           grep -q \"^127.0.0.1\" /tmp/.hosts.new || exit 9
           cp /etc/hosts /etc/hosts.bak-\$(date +%Y%m%d%H%M%S)
           install -m 0644 /tmp/.hosts.new /etc/hosts
           rm -f /tmp/.hosts.new /tmp/.enclave-hosts'" 2>/dev/null; then
      ok "$ip updated"
    else
      warn "$ip FAILED (passwordless sudo? /etc/hosts guard?)"; rc=1
    fi
  done
  return $rc
}

verify() {
  local ip name line var rc=0
  for ip in $(targets); do
    ssh -n -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "$USER_NAME@$ip" true 2>/dev/null || continue
    local bad="" shadowed="" checked=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      name="${line%%:*}"; var="${line##*:}"
      [ -n "${!var:-}" ] || continue
      # -n IS LOAD-BEARING. Without it ssh reads stdin - which is the here-string feeding
      # this while loop - and swallows the ENTIRE remaining table on the first iteration.
      # The loop then ends after one name and reports "resolves every name" having checked
      # exactly one. That is how svc-harbor-01 passed verification on 2026-09-14 while its
      # /etc/hosts had no entry for svc-obs-01 at all. A false pass in the tool whose only
      # job is catching that.
      got=$(ssh -n -i "$KEY" -o BatchMode=yes "$USER_NAME@$ip" \
            "getent hosts $name.$ENCLAVE_DOMAIN 2>/dev/null | awk '{print \$1}'" || true)
      checked=$((checked + 1))
      # getent can return MORE THAN ONE ADDRESS. cloud-init writes "127.0.1.1 <fqdn> <host>"
      # on every machine, so a machine asked for its OWN name answers 127.0.1.1 first and
      # the real address second. Comparing the whole multi-line result to one address makes
      # every machine fail on its own name - and the mangled output ("svc-mgmt-01(127.0.1.1")
      # is what that looks like. Ask the right question instead: IS the expected address in
      # the answer.
      if printf '%s\n' "$got" | command grep -qx "${!var}"; then
        # Present, but shadowed: a service that binds by name here gets loopback and will
        # not be reachable from any other machine. Worth saying, not worth failing.
        [ "$(printf '%s\n' "$got" | head -1)" = "${!var}" ] \
          || shadowed="$shadowed $name"
      else
        bad="$bad $name(${got:-none})"
      fi
    done <<< "$MAP"
    # PRINT THE COUNT. "resolves every name" is unfalsifiable on its own; "resolves all 15"
    # goes wrong visibly the moment the loop stops early again.
    if [ -z "$bad" ]; then ok "$ip resolves all $checked name(s)"
    else warn "$ip MISSING:$bad"; rc=1; fi
    # Not a failure. A machine resolving its own name to 127.0.1.1 is cloud-init's doing and
    # is normal - but it is also why a daemon told to bind "by hostname" ends up on loopback.
    [ -z "$shadowed" ] || say "       note: 127.0.1.1 answers first for:$shadowed"
  done
  return $rc
}

case "${1:-}" in
  render) render ;;
  apply)  apply_local ;;
  push)   push ;;
  verify) verify ;;
  *)      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
