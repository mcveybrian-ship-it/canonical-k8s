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
#   ./apply-addresses.sh verify          check every node resolves every name AND uses the DNS
#   ./apply-addresses.sh resolver-check  print the DNS server, exit 0 only if it answers
#
#   ./apply-addresses.sh zone            print the BIND zone files, change nothing
#   ./apply-addresses.sh zone-install    write them and reload named   (sudo, DNS host only)
#
#   Not in the printed usage above, but dispatched:
#   ./apply-addresses.sh resolver        print the systemd-resolved drop-in, change nothing
#   ./apply-addresses.sh resolver-install  point THIS machine's resolver at the enclave DNS (sudo)
#
# MACHINE: render, zone and resolver print only - any machine with the repo. `apply` and
# `resolver-install` ON each enclave machine. `zone-install` ON $ZONE_NS (svc-mgmt-01).
# `push` and `verify` from a machine holding ENCLAVE_KEY (default ~/.ssh/build01), reaching
# the enclave over ssh. Runbook 3.0 (addressing) and 9a.4 (enclave DNS); backlog 6b.1e.
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
# THE DNS SERVER'S ADDRESS, from ZONE_NS - ONE implementation (backlog 6b.1e).
#
# The four copies this replaced turned `svc-mgmt-01` into `svc_mgmt_01` - LOWERCASE - while
# enclave-addresses.env defines `SVC_MGMT_01`. The lookup therefore ALWAYS came back empty and
# fell through to a hardcoded SVC_MGMT_01, so ZONE_NS never did anything: set it to another
# machine, or to one that does not exist, and every consumer still silently used svc-mgmt-01.
# Found 2026-09-24 only because resolver-check was tested against machines that must FAIL.
# Now: upper-case the key, and an unknown ZONE_NS is an error, never a fallback.
zone_ns_addr() {
  local key; key="$(printf '%s' "$ZONE_NS" | tr '[:lower:]-' '[:upper:]_')"
  printf '%s' "${!key:-}"
}
zone_rev_prefix() {
  local a; a="$(zone_ns_addr)"
  [ -n "$a" ] || die "ZONE_NS='$ZONE_NS' has no address in $ADDRS"
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

# A BLACKHOLE ROOT THAT ACTUALLY LOADS.
#
# The first version pointed the root zone at /etc/bind/db.empty and named refused it:
#   zone ./IN: NS 'localhost' has no address records (A or AAAA)
#   zone ./IN: not loaded due to errors.
# db.empty ships for BIND's AUTOMATIC RFC1918 empty zones, where surrounding context supplies
# what is missing. As an explicit root master zone it is invalid: a zone's NS target needs an
# address record inside that same zone.
#
# Measured consequence on svc-mgmt-01: enclave.internal and the reverse zone loaded, the root
# zone did not, and every out-of-zone query returned SERVFAIL rather than NXDOMAIN. Fast, but
# wrong - CoreDNS RETRIES on SERVFAIL, so a pod fails three times instead of once.
#
# `.nil` is reserved and can never be delegated; 127.0.0.1 is unreachable from anywhere that
# matters. The NS has in-zone glue, so the zone loads.
zone_root() {
  printf '$TTL 3600\n'
  printf '; Blackhole root. Generated by apply-addresses.sh. DO NOT EDIT.\n'
  printf '; Every name outside %s gets an IMMEDIATE NXDOMAIN.\n' "$ENCLAVE_DOMAIN"
  printf '@   IN SOA a.root-servers.nil. hostmaster.%s. (\n' "$ENCLAVE_DOMAIN"
  printf '        %-12s ; serial\n' "$(zone_serial)"
  printf '        3600 600 604800 60 )\n'
  printf '@                   IN NS  a.root-servers.nil.\n'
  printf 'a.root-servers.nil. IN A   127.0.0.1\n'
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
  printf 'zone "." {\n    type master;\n    file "%s/db.root";\n};\n' "$ZONE_DIR"
}

# zone: read-only. The three zone files and named.conf.local, exactly as zone-install writes them.
cmd_zone() {
  printf '\n===== %s/db.%s =====\n' "$ZONE_DIR" "$ENCLAVE_DOMAIN"; zone_forward
  printf '\n===== %s/db.reverse =====\n' "$ZONE_DIR"; zone_reverse
  printf '\n===== %s/db.root =====\n' "$ZONE_DIR"; zone_root
  printf '\n===== /etc/bind/named.conf.local =====\n'; zone_named_conf
  printf '\n'
}

# render: the /etc/hosts managed block, marker to marker, from MAP. Read-only on its own;
# apply and push both append its output.
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
  # THE 127.0.1.1 LINE SHADOWS THE MANAGED BLOCK, AND WE DELIBERATELY DO NOT TOUCH IT.
  #
  # Ubuntu writes `127.0.1.1 <hostname>` by convention. On svc-repo-01 it was written as
  # `127.0.1.1 svc-repo-01 svc-repo-01.enclave.internal` - WITH the FQDN - so the machine's
  # own fully-qualified name resolved to LOOPBACK instead of its enclave address, while the
  # other seven machines resolved it correctly. Measured 2026-09-18.
  #
  # It is benign today: TLS still validates because a certificate is checked against the NAME,
  # not the address it connected to, and the SAN carries DNS:svc-repo-01.enclave.internal.
  # It stops being benign the moment a service binds to a specific address and something on
  # the same box connects to it by name.
  #
  # We warn rather than edit: that line is outside the managed markers, and silently rewriting
  # a region we promised not to touch is worse than a machine with an odd hosts file.
  local myfqdn; myfqdn="$(hostname -s).$ENCLAVE_DOMAIN"
  if grep -qE "^127\.0\.1\.1[[:space:]].*[[:space:]]$myfqdn([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
    warn "127.0.1.1 carries this machine's FQDN ($myfqdn), which SHADOWS the managed entry:"
    grep -nE "^127\.0\.1\.1" /etc/hosts | sed 's/^/         /' >&2
    warn "  '$myfqdn' will resolve to LOOPBACK on this machine, not to its enclave address."
    warn "  Harmless until something binds to a specific address. To fix, drop the FQDN from"
    warn "  that line, leaving just the short hostname - it is OUTSIDE the managed block, so"
    warn "  this script will not do it for you."
  fi
  ok "$(hostname): /etc/hosts updated, $(sed -n "/^$BEGIN\$/,/^$END\$/p" /etc/hosts | grep -c "$ENCLAVE_DOMAIN") name(s) in the managed block"
}

# Every address MAP resolves to - what push and verify try, including machines not built yet.
targets() {
  local line var ip
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    var="${line##*:}"; ip="${!var:-}"
    [ -n "$ip" ] && echo "$ip"
  done <<< "$MAP"
}

# push: the same replace-the-managed-region edit as apply, done remotely on each reachable
# node. Needs passwordless sudo, which hardened machines no longer have - use apply there.
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

# verify: read-only, over ssh. Per node: every MAP name resolves to its own address, and a
# *.apps name resolves - the proof that the enclave DNS is consulted at all. Non-zero on a miss.
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
          "for n in$names; do printf '%s ' \"\${n%%.*}\"; getent ahostsv4 \"\$n\" 2>/dev/null | awk '!s[\$1]++ {print \$1}' | tr '\\n' ' '; echo; done;
           printf '__DNS__ '; resolvectl dns 2>/dev/null | awk '/^Global/ {for(i=2;i<=NF;i++) printf \"%s \", \$i}'; echo;
           printf '__WILD__ '; getent ahostsv4 test.apps.$ENCLAVE_DOMAIN 2>/dev/null | awk 'NR==1 {print \$1}'; echo" 2>/dev/null)" || true
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
    # AND IS IT USING THE DNS AT ALL. Every name above is also in /etc/hosts, so all of them
    # resolve on a machine with NO resolver - which is how host-3 passed this check for three
    # days after its rebuild had dropped the drop-in (6b.1e). A *.apps name has no hosts
    # entry and can ONLY come from DNS, so it is the one lookup that tells the two apart.
    local gdns wild
    gdns="$(printf '%s\n' "$got" | awk '$1=="__DNS__" {$1=""; sub(/^ /,""); print}')"
    wild="$(printf '%s\n' "$got" | awk '$1=="__WILD__" {print $2}')"
    if [ -n "$wild" ]; then ok "$ip uses the enclave DNS (resolver: ${gdns:-?}; test.apps -> $wild)"
    else warn "$ip does NOT resolve *.apps - no enclave DNS (resolver: ${gdns:-none}). Fix ON $ip: sudo ./apply-addresses.sh resolver-install"; rc=1; fi
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

  # root owns the zone directory and files; group bind so named can read them.
  install -d -m 0755 -o root -g bind "$ZONE_DIR"
  local fwd="$ZONE_DIR/db.$ENCLAVE_DOMAIN" rev="$ZONE_DIR/db.reverse"
  local root="$ZONE_DIR/db.root"
  zone_forward > "$fwd.new"; zone_reverse > "$rev.new"; zone_root > "$root.new"

  # CHECK BEFORE INSTALLING, not after reloading. A zone that fails to load leaves named
  # serving the PREVIOUS copy silently - which looks exactly like success.
  named-checkzone "$ENCLAVE_DOMAIN" "$fwd.new" >/dev/null \
    || { rm -f "$fwd.new" "$rev.new"; die "forward zone is invalid - nothing installed"; }
  named-checkzone "$(zone_rev_prefix).in-addr.arpa" "$rev.new" >/dev/null \
    || { rm -f "$fwd.new" "$rev.new" "$root.new"; die "reverse zone is invalid - nothing installed"; }
  named-checkzone "." "$root.new" >/dev/null \
    || { rm -f "$fwd.new" "$rev.new" "$root.new"; die "root zone is invalid - nothing installed"; }

  [ -f "$fwd" ] && cp -a "$fwd" "$fwd.bak-$(date +%Y%m%dT%H%M%S)"
  mv "$fwd.new" "$fwd"; mv "$rev.new" "$rev"; mv "$root.new" "$root"
  chown root:bind "$fwd" "$rev" "$root"; chmod 0644 "$fwd" "$rev" "$root"
  ok "zones written to $ZONE_DIR"

  # DO NOT CLOBBER SOMEBODY ELSE'S INCLUDES.
  #
  # Found the hard way on svc-mgmt-01 2026-09-18: named.conf.local carried
  # `include "/etc/bind/maas/named.conf.maas"`, which DEFINES the `trusted` ACL, while
  # named.conf.options includes MAAS's options file which USES it. Overwriting this file
  # removed the definition and left the use, so named-checkconf failed with
  # "undefined ACL 'trusted'". Nothing broke - the check runs before the reload - but the
  # config was left inconsistent and needed restoring from the backup.
  #
  # An include we did not write means another package owns part of this server. Refuse, and
  # say whose it is; the answer is almost always "remove that package first".
  local nc=/etc/bind/named.conf.local
  if [ -f "$nc" ]; then
    local foreign; foreign="$(grep -hE '^[[:space:]]*include' "$nc" 2>/dev/null \
                              | grep -v "$ZONE_DIR" || true)"
    if [ -n "$foreign" ] && ! grep -q 'Generated by apply-addresses.sh' "$nc"; then
      warn "$nc is owned by something else - it carries include(s) we did not write:"
      printf '%s\n' "$foreign" | sed 's/^/         /' >&2
      die "REFUSING to overwrite it. Those includes may DEFINE things other config files
       USE - MAAS's 'trusted' ACL is exactly that shape. Remove the owning package first,
       or move its include into $nc yourself and re-run.
       The zone files ARE written and valid; only named.conf.local was left alone."
    fi
    cp -a "$nc" "$nc.bak-$(date +%Y%m%dT%H%M%S)"
  fi
  zone_named_conf > "$nc"
  named-checkconf || die "named.conf is invalid - FIX IT, named is still serving the old config"
  ok "named.conf.local written and valid"

  # Reload keeps named answering through the change; restart only if reload is refused. Then two
  # probes: a known enclave name must answer, and an outside name must be NXDOMAIN.
  systemctl reload named 2>/dev/null || systemctl restart named
  sleep 1
  local probe; probe="$(dig +short +time=2 @127.0.0.1 "svc-repo-01.$ENCLAVE_DOMAIN" 2>/dev/null)"
  local outside; outside="$(dig +time=2 @127.0.0.1 nosuchname.example.invalid 2>/dev/null \
                            | grep -oE 'status: [A-Z]+' | head -1)"
  case "$outside" in
    *NXDOMAIN) ok "out-of-zone names return NXDOMAIN - fast, clean, and not retried" ;;
    *SERVFAIL) warn "out-of-zone names return SERVFAIL - the root zone did NOT load."
               warn "  CoreDNS retries on SERVFAIL. Check: journalctl -u named | grep 'zone ./IN'" ;;
    *)         warn "out-of-zone query returned '${outside:-nothing}' - expected NXDOMAIN" ;;
  esac
  if [ -n "$probe" ]; then
    ok "named answers: svc-repo-01.$ENCLAVE_DOMAIN -> $probe"
  else
    warn "named reloaded but did NOT answer a known name - check 'journalctl -u named'"
    return 1
  fi
}

# ------------------------------------------------------------------------- resolver-install
# POINT THIS MACHINE'S RESOLVER AT THE ENCLAVE DNS.
#
# A systemd-resolved DROP-IN, not netplan. Netplan means re-applying network configuration on
# a host whose only NIC is a bridge carrying every guest's traffic - for a change that has
# nothing to do with addressing. The drop-in is a file and a service restart.
#
# THIS IS SAFE BY CONSTRUCTION because of the tier order. nsswitch reads `hosts: files dns`,
# so /etc/hosts still wins for every name it carries. If the DNS host is down, or this
# configuration is wrong, every machine and service already pinned in /etc/hosts keeps
# resolving exactly as it does today. DNS only adds what the hosts file cannot express.
#
# DNSSEC is off: the zone is unsigned and there is no chain of trust to a root that this
# enclave can reach. Turning it on would make every lookup fail closed.
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/10-enclave-dns.conf

# resolver: read-only. The drop-in resolver-install writes, printed.
resolver_render() {
  local dns; dns="$(zone_ns_addr)"
  printf '# Enclave DNS. Written by apply-addresses.sh - do not edit.\n'
  printf '#\n'
  printf '# /etc/hosts STILL WINS - nsswitch is "hosts: files dns". This server only answers\n'
  printf '# what a hosts file cannot express: the *.apps wildcard, and a forwarder for CoreDNS\n'
  printf '# so pods fail fast instead of timing out. runbook 9a.4.\n'
  printf '[Resolve]\n'
  printf 'DNS=%s\n' "$dns"
  printf 'Domains=%s\n' "$ENCLAVE_DOMAIN"
  printf 'DNSSEC=no\n'
  printf 'DNSOverTLS=no\n'
  printf 'Cache=yes\n'
}

# Print the enclave DNS server's address and exit 0 ONLY if it answers for an enclave name.
# Shared by resolver-install and 03-compose-vm.sh, so "never point a machine at a server
# that is not serving" is one rule in one place (backlog 6b.1e).
cmd_resolver_check() {
  local dns; dns="$(zone_ns_addr)"
  [ -n "$dns" ] || { printf 'no address for the DNS server (%s) in %s\n' "$ZONE_NS" "$ADDRS" >&2; return 2; }
  command -v dig >/dev/null 2>&1 || { printf 'dig absent - apt install dnsutils\n' >&2; return 3; }
  # AN ADDRESS, NOT "ANY OUTPUT". `dig +short` prints ";; communications error ... timed out"
  # on STDOUT when nothing answers, so a test for non-empty output passed against a machine
  # running no DNS server at all - this guard, and the copy in resolver-install before it,
  # could never refuse anything. Found 2026-09-24 by testing against svc-repo-01 (no named).
  dig +short +time=3 +tries=1 "@$dns" "svc-repo-01.$ENCLAVE_DOMAIN" 2>/dev/null \
    | grep -qE '^[0-9]+(\.[0-9]+){3}$' \
    || { printf '%s did not answer for svc-repo-01.%s\n' "$dns" "$ENCLAVE_DOMAIN" >&2; return 1; }
  printf '%s\n' "$dns"
}

# resolver-install: ON each enclave machine. Probe the DNS server, write the drop-in (keeping a
# backup), restart systemd-resolved, then prove the hosts tier, the wildcard and an outside name.
cmd_resolver_install() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  # DO NOT POINT AT A SERVER THAT IS NOT ANSWERING. A resolver configured at a dead address
  # adds a timeout to every lookup that /etc/hosts does not already cover - which is the exact
  # failure this whole design exists to avoid. ONE probe, shared with 03-compose-vm.sh.
  local dns why
  if ! dns="$(cmd_resolver_check 2>/tmp/.resolver-check.$$)"; then
    why="$(cat /tmp/.resolver-check.$$ 2>/dev/null)"; rm -f /tmp/.resolver-check.$$
    die "${why:-the DNS server did not answer}.
       REFUSING to point this machine at a server that is not serving. Run
       'apply-addresses.sh zone-install' on $ZONE_NS first."
  fi
  rm -f /tmp/.resolver-check.$$
  ok "$dns answers (svc-repo-01 -> $(dig +short +time=3 +tries=1 "@$dns" "svc-repo-01.$ENCLAVE_DOMAIN" 2>/dev/null | head -1))"

  install -d -m 0755 "$(dirname "$RESOLVED_DROPIN")"
  [ -f "$RESOLVED_DROPIN" ] && cp -a "$RESOLVED_DROPIN" "$RESOLVED_DROPIN.bak-$(date +%Y%m%dT%H%M%S)"
  resolver_render > "$RESOLVED_DROPIN"
  chmod 0644 "$RESOLVED_DROPIN"
  ok "wrote $RESOLVED_DROPIN"

  systemctl restart systemd-resolved || die "systemd-resolved would not restart - $RESOLVED_DROPIN is suspect"
  sleep 1

  # PROVE ALL THREE TIERS, not just that something resolved.
  local viahosts wildcard outside
  # `|| true` ON EVERY LOOKUP. getent exits 2 for "not found", and under pipefail that failed
  # assignment ended the script SILENTLY - on the third lookup, whose whole point is to find
  # nothing. So these three proofs never printed on any machine, and resolver-install exited
  # non-zero after doing its job (found 2026-09-24 on host-3, backlog 6b.1e). A lookup that
  # fails must reach its warning below, not end the script before it.
  viahosts="$(getent hosts "svc-repo-01.$ENCLAVE_DOMAIN" | awk '{print $1}' || true)"
  wildcard="$(getent hosts "test.apps.$ENCLAVE_DOMAIN" | awk '{print $1}' || true)"
  outside="$(getent hosts nosuchname.example.invalid 2>/dev/null | awk '{print $1}' || true)"
  [ -n "$viahosts" ] && ok "hosts-file name still resolves: svc-repo-01 -> $viahosts" \
                     || warn "svc-repo-01 no longer resolves - THIS IS A REGRESSION"
  [ -n "$wildcard" ] && ok "wildcard now resolves via DNS: test.apps -> $wildcard" \
                     || warn "the *.apps wildcard did not resolve - DNS is not being consulted"
  [ -z "$outside" ]  && ok "an outside name returns nothing, immediately" \
                     || warn "an outside name resolved to $outside - unexpected"
}

case "${1:-}" in
  render) render ;;
  apply)  apply_local ;;
  push)   push ;;
  verify) verify ;;
  zone)   cmd_zone ;;
  zone-install) cmd_zone_install ;;
  resolver)     resolver_render ;;
  resolver-check) cmd_resolver_check ;;
  resolver-install) cmd_resolver_install ;;
  *)      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
