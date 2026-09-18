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
#   ./apply-addresses.sh zone            print the BIND zone files, change nothing
#   ./apply-addresses.sh zone-install    write them and reload named   (sudo, DNS host only)
#
# WHY DNS AT ALL, WHEN /etc/hosts ALREADY WORKS.
#
#   Two tiers, deliberately, and the order is in runbook 564: hosts FIRST, DNS second.
#   `nsswitch.conf` reads `hosts: files dns`, so a name pinned in /etc/hosts resolves even
#   when the DNS host is rebooting - apt, containerd and `pro attach` must not depend on a
#   single VM being up.
#
#   DNS covers what a hosts file cannot:
#     * the `*.apps.enclave.internal` wildcard for cluster ingress - a hosts file has no
#       wildcards, and enumerating every app name by hand is the thing this avoids;
#     * CoreDNS. It forwards unknown names to the node's resolver, and with NO resolver at
#       all every lookup TIMES OUT (~5s, with retries) instead of failing. That presents as
#       a performance problem, not a DNS problem, which is the worst kind. runbook 1897.
#     * 17 machines at full build, each with its own /etc/hosts to keep in step.
#
#   THE ZONE COMES FROM THE SAME `MAP` BELOW AS /etc/hosts. One table, two renderers - so
#   they cannot disagree. Adding a machine is still one edit, in one place.
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
pg-01:PG_01
pg-02:PG_02
pg-03:PG_03
k8s-api:K8S_API_VIP
k8s-cp-01:K8S_CP_01
k8s-cp-02:K8S_CP_02
k8s-cp-03:K8S_CP_03
k8s-wk-01:K8S_WK_01
k8s-wk-02:K8S_WK_02
k8s-wk-03:K8S_WK_03
k8s-wk-04:K8S_WK_04
"

# ---------------------------------------------------------------------------------- zone
# AUTHORITATIVE ONLY, AND DELIBERATELY NOT RECURSIVE.
#
# There is no upstream to recurse to - that is what an air gap means. An empty root zone
# makes every name outside enclave.internal return NXDOMAIN *immediately* instead of being
# refused or, worse, retried. Fast, honest failure is the entire point (runbook 1897).
ZONE_DIR="${ZONE_DIR:-/etc/bind/enclave}"
ZONE_NS="${ZONE_NS:-svc-mgmt-01}"          # which machine serves it
# The reverse zone is derived, not typed: 10.2.20.x -> 20.2.10.in-addr.arpa
zone_rev_prefix() {
  local a; a="$(eval "printf '%s' \"\${${ZONE_NS//-/_}}\"" 2>/dev/null)"
  a="${a:-$(eval "printf '%s' \"\${SVC_MGMT_01:-}\"")}"
  printf '%s' "$(printf '%s' "$a" | awk -F. '{print $3"."$2"."$1}')"
}

# SERIAL. Must increase on every change or secondaries and caches keep the old answer.
# Epoch seconds is monotonic, needs no state file, and cannot be fumbled by two edits in
# one day - which is exactly how a hand-kept YYYYMMDDNN serial goes backwards.
zone_serial() { date -u +%s; }

zone_forward() {
  printf '$TTL 300\n'
  printf '@   IN SOA %s.%s. hostmaster.%s. (\n' "$ZONE_NS" "$ENCLAVE_DOMAIN" "$ENCLAVE_DOMAIN"
  printf '        %-12s ; serial - epoch seconds, monotonic\n' "$(zone_serial)"
  printf '        %-12s ; refresh\n' "3600"
  printf '        %-12s ; retry\n' "600"
  printf '        %-12s ; expire\n' "604800"
  printf '        %-12s ) ; negative TTL - keep it SHORT so a new machine appears fast\n' "60"
  printf '@   IN NS  %s.%s.\n\n' "$ZONE_NS" "$ENCLAVE_DOMAIN"
  printf '; Generated from enclave-addresses.env by apply-addresses.sh. DO NOT EDIT.\n'
  printf '; Same MAP that renders /etc/hosts - one table, two renderers.\n'
  local name var addr
  while IFS=: read -r name var; do
    [ -n "${name:-}" ] || continue
    addr="$(eval "printf '%s' \"\${$var:-}\"")"
    [ -n "$addr" ] || continue
    printf '%-16s IN A     %s\n' "$name" "$addr"
  done <<< "$(printf '%s\n' "$MAP" | sed '/^[[:space:]]*$/d')"
  printf '\n; Cluster ingress. A hosts file cannot express this, which is half the reason\n'
  printf '; DNS exists here at all. Points at the k8s API VIP until an ingress LB address\n'
  printf '; is chosen - revisit at step 08.\n'
  printf '%-16s IN A     %s\n' "*.apps" "${K8S_API_VIP:-}"
  printf '%-16s IN A     %s\n' "apps" "${K8S_API_VIP:-}"
}

zone_reverse() {
  printf '$TTL 300\n'
  printf '@   IN SOA %s.%s. hostmaster.%s. (\n' "$ZONE_NS" "$ENCLAVE_DOMAIN" "$ENCLAVE_DOMAIN"
  printf '        %-12s ; serial\n' "$(zone_serial)"
  printf '        3600 600 604800 60 )\n'
  printf '@   IN NS  %s.%s.\n\n' "$ZONE_NS" "$ENCLAVE_DOMAIN"
  local name var addr last
  while IFS=: read -r name var; do
    [ -n "${name:-}" ] || continue
    addr="$(eval "printf '%s' \"\${$var:-}\"")"
    [ -n "$addr" ] || continue
    last="${addr##*.}"
    printf '%-6s IN PTR %s.%s.\n' "$last" "$name" "$ENCLAVE_DOMAIN"
  done <<< "$(printf '%s\n' "$MAP" | sed '/^[[:space:]]*$/d')"
}

zone_named_conf() {
  printf '// Generated by apply-addresses.sh. DO NOT EDIT.\n'
  printf '// Authoritative for %s. NOT recursive - there is no upstream in an air gap.\n' "$ENCLAVE_DOMAIN"
  printf 'zone "%s" {\n    type master;\n    file "%s/db.%s";\n};\n\n' \
         "$ENCLAVE_DOMAIN" "$ZONE_DIR" "$ENCLAVE_DOMAIN"
  printf 'zone "%s.in-addr.arpa" {\n    type master;\n    file "%s/db.reverse";\n};\n\n' \
         "$(zone_rev_prefix)" "$ZONE_DIR"
  printf '// EMPTY ROOT. Everything outside the enclave gets an immediate NXDOMAIN rather\n'
  printf '// than a refusal or a timeout. CoreDNS forwards here; a pod that fails fast is\n'
  printf '// debuggable, one that hangs for 5s looks like a performance problem.\n'
  printf 'zone "." {\n    type master;\n    file "/etc/bind/db.empty";\n};\n'
}

cmd_zone() {
  printf '\n===== %s/db.%s =====\n' "$ZONE_DIR" "$ENCLAVE_DOMAIN"; zone_forward
  printf '\n===== %s/db.reverse =====\n' "$ZONE_DIR"; zone_reverse
  printf '\n===== /etc/bind/named.conf.local =====\n'; zone_named_conf
  printf '\n'
}

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
  # COUNT WHAT WAS WRITTEN, NOT WHAT MATCHES. Counting the domain across the whole file also
  # counts cloud-init's "127.0.1.1 <host> <host>.<domain>" line, which this script did not
  # write and does not manage - so `apply` said 17 where `verify` said 16 and neither was
  # wrong about anything. A number that does not mean what its label says invites exactly
  # the hunt it just cost.
  ok "$(hostname): /etc/hosts updated, $(sed -n "/^$BEGIN\$/,/^$END\$/p" /etc/hosts | grep -c "$ENCLAVE_DOMAIN") name(s) in the managed block"
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
  local ip line name var rc=0
  # ONE SSH CONNECTION PER MACHINE, NOT ONE PER NAME.
  #
  # The first version opened a connection for every name - 16 per machine. On the machines
  # where ufw actually enforces (svc-repo-01 and svc-obs-01, the only two), `ufw limit`
  # REJECTS after 6 connections in 30 seconds from one source. Connections 5..16 were
  # refused, `|| true` turned each refusal into an empty string, and an empty string reads
  # exactly like "this name does not resolve". Both machines were reported as missing their
  # entire service block while /etc/hosts on them was complete and correct.
  #
  # A tool that opens a connection per item WILL be rate-limited by a correctly hardened
  # machine, and the failure arrives disguised as the thing the tool set out to measure.
  # Ask once, get everything back.
  local names="" expect=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="${line%%:*}"; var="${line##*:}"
    [ -n "${!var:-}" ] || continue
    names="$names $name.$ENCLAVE_DOMAIN"
    expect="$expect$name ${!var}"$'\n'
  done <<< "$MAP"

  for ip in $(targets); do
    ssh -n -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "$USER_NAME@$ip" true 2>/dev/null || continue
    # The remote side prints "<name> <addr> <addr> ..." once per name, in one session.
    # DEDUPE WITHOUT SORTING. The order getent returns is the order a caller will actually
    # get, and that is the whole point of the 127.0.1.1 check below - `sort -u` puts
    # 10.x before 127.x and quietly destroys the only signal being measured.
    local got
    got="$(ssh -n -i "$KEY" -o BatchMode=yes "$USER_NAME@$ip" \
          "for n in$names; do printf '%s ' \"\${n%%.*}\"; getent ahostsv4 \"\$n\" 2>/dev/null | awk '!s[\$1]++ {print \$1}' | tr '\\n' ' '; echo; done" 2>/dev/null)" || true
    if [ -z "$got" ]; then warn "$ip UNREADABLE - ssh returned nothing"; rc=1; continue; fi

    local bad="" shadowed="" checked=0 want first
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      name="${line%% *}"
      want="$(printf '%s\n' "$expect" | awk -v n="$name" '$1==n {print $2}')"
      [ -n "$want" ] || continue
      checked=$((checked + 1))
      if printf '%s\n' "${line#* }" | tr ' ' '\n' | command grep -qx "$want"; then
        # Present but shadowed: cloud-init writes "127.0.1.1 <fqdn>" on every machine, so a
        # machine answers its OWN name with loopback first. Not a failure - but it is why a
        # daemon told to bind "by hostname" ends up unreachable from everywhere else.
        first="$(printf '%s\n' "${line#* }" | awk '{print $1}')"
        [ "$first" = "$want" ] || shadowed="$shadowed $name"
      else
        bad="$bad $name(${line#* }none)"
      fi
    done <<< "$got"

    if [ -z "$bad" ]; then ok "$ip resolves all $checked name(s)"
    else warn "$ip MISSING:$bad"; rc=1; fi
    [ -z "$shadowed" ] || say "       note: 127.0.1.1 answers first for:$shadowed"
  done
  return $rc
}

# Install the zone and reload. Runs ONLY on the machine that serves DNS.
cmd_zone_install() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  local me; me="$(hostname -s)"
  [ "$me" = "$ZONE_NS" ] || die "this is $me; the DNS server is $ZONE_NS.
       Set ZONE_NS if that has changed - do not install a zone on a machine that is not
       serving it, or two hosts answer for the same names and only one is right."
  command -v named-checkzone >/dev/null 2>&1 || die "bind9 tools absent - apt install bind9-utils"

  install -d -m 0755 -o root -g bind "$ZONE_DIR"
  local fwd="$ZONE_DIR/db.$ENCLAVE_DOMAIN" rev="$ZONE_DIR/db.reverse"
  zone_forward > "$fwd.new"; zone_reverse > "$rev.new"

  # CHECK BEFORE INSTALLING, not after reloading. A zone that fails to load leaves named
  # serving the PREVIOUS copy silently - which looks exactly like success.
  named-checkzone "$ENCLAVE_DOMAIN" "$fwd.new" >/dev/null \
    || { rm -f "$fwd.new" "$rev.new"; die "forward zone is invalid - nothing installed"; }
  named-checkzone "$(zone_rev_prefix).in-addr.arpa" "$rev.new" >/dev/null \
    || { rm -f "$fwd.new" "$rev.new"; die "reverse zone is invalid - nothing installed"; }

  [ -f "$fwd" ] && cp -a "$fwd" "$fwd.bak-$(date +%Y%m%dT%H%M%S)"
  mv "$fwd.new" "$fwd"; mv "$rev.new" "$rev"
  chown root:bind "$fwd" "$rev"; chmod 0644 "$fwd" "$rev"
  ok "zones written to $ZONE_DIR"

  local nc=/etc/bind/named.conf.local
  [ -f "$nc" ] && cp -a "$nc" "$nc.bak-$(date +%Y%m%dT%H%M%S)"
  zone_named_conf > "$nc"
  named-checkconf || die "named.conf is invalid - FIX IT, named is still serving the old config"
  ok "named.conf.local written and valid"

  systemctl reload named 2>/dev/null || systemctl restart named
  sleep 1
  local probe; probe="$(dig +short +time=2 @127.0.0.1 "svc-repo-01.$ENCLAVE_DOMAIN" 2>/dev/null)"
  if [ -n "$probe" ]; then
    ok "named answers: svc-repo-01.$ENCLAVE_DOMAIN -> $probe"
  else
    warn "named reloaded but did NOT answer a known name - check 'journalctl -u named'"
    return 1
  fi
}

case "${1:-}" in
  render) render ;;
  apply)  apply_local ;;
  push)   push ;;
  verify) verify ;;
  zone)   cmd_zone ;;
  zone-install) cmd_zone_install ;;
  *)      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
