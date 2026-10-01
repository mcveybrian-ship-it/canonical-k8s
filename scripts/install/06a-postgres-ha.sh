#!/usr/bin/env bash
# =========================================================================================
# 06a-postgres-ha.sh - PostgreSQL HA on pg-01..03: etcd, then Patroni (backlog B-06a).
#
#     MACHINE: each pg guest (pg-01..03), which must already be hardened and finished
#     (03-compose-vm.sh --harden, then --finish). Runbook 9a is the design; 9a.2a the traps.
#
#     sudo ./06a-postgres-ha.sh etcd <fullchain.crt>   install and start this node's etcd member
#     sudo ./06a-postgres-ha.sh etcd-check             quorum, members, and the TLS it enforces
#     sudo ./06a-postgres-ha.sh patroni                PostgreSQL 16 under Patroni - pg-01 FIRST
#     sudo ./06a-postgres-ha.sh patroni-check          leader, sync standby, and the STIG traps
#     sudo ./06a-postgres-ha.sh monitor                postgres-exporter, local-only, no password
#                                                      - the PRIMARY first (it creates the role)
#     sudo ./06a-postgres-ha.sh switchover [pg-0N]     planned leader handover, TIMED - to the
#                                                      sync standby unless one is named
#     sudo ./06a-postgres-ha.sh leave                  take THIS node down for maintenance: refuses
#                                                      unless the other two are healthy
#   SLICE 5 - BACKUP (pgBackRest, TLS both ways, two live stores - decided 2026-09-28):
#     sudo ./06a-postgres-ha.sh backup-node             on each pg node: pgBackRest + its TLS server
#     sudo ./06a-postgres-ha.sh backup-store <fullchain> on each STORE (host-4, host-3): the store
#     sudo ./06a-postgres-ha.sh backup-enable           on the PRIMARY: WAL archiving on (rolling restart)
#     sudo ./06a-postgres-ha.sh backup-run [full|diff]  on each store: a backup now + the timers
#     sudo ./06a-postgres-ha.sh backup-restore-test     on the PRIMARY: restore to a point in time
#                                                      from EACH store, into scratch, and prove it
#   SLICE 6 PREP - THE APPLICATION'S DATABASE (real records: prints NUMBERS ONLY, see below):
#     sudo ./06a-postgres-ha.sh stig-settings                 on the LEADER: the STIG's org-defined values
#     sudo ./06a-postgres-ha.sh extensions                    on EVERY pg node: PG_EXTENSION_PACKAGES
#     sudo ./06a-postgres-ha.sh app-restore rehearse          on the LEADER: a made-up dump through
#                                                      the whole path - proves no row reaches a screen or log
#     sudo ./06a-postgres-ha.sh app-restore census <file>     what a plain-SQL dump is and needs
#     sudo ./06a-postgres-ha.sh app-restore load <file> <db>  on the LEADER, into a NEW database
#     sudo ./06a-postgres-ha.sh app-restore summary [log]     reprint a load's summary from its log
#     sudo ./06a-postgres-ha.sh app-restore drop <db>         for a reload: only one app-restore made
#     sudo ./06a-postgres-ha.sh app-restore shred <file>...   the dump and the load log, when done
#
# SLICE 2 - THE DATABASE'S OWN etcd, WITH MUTUAL TLS
#
#   Three members, one per pg guest, static bootstrap from enclave-addresses.env. NOT the
#   Kubernetes cluster's etcd: that coupling is what runbook 9a exists to remove.
#
#   The certificate is made the way every enclave certificate is: the key on THIS node
#   (ca.sh request pg-0N - it never leaves), the CSR signed on svc-mgmt-01 with
#   `ca.sh sign-server --peer` (serverAuth AND clientAuth: every member is a server to its
#   peers and a client to them), the fullchain copied back. This script refuses a chain that
#   does not verify against the enclave root, lacks either purpose, does not name this node's
#   address, or does not match the key made here.
#
# FIPS - READ THIS BEFORE CLAIMING ANYTHING (decided 2026-09-27, backlog B-06a):
#
#   Ubuntu's etcd 3.4.30 is Go 1.22.2 built WITHOUT BoringCrypto (its embedded build info has
#   no GOEXPERIMENT, and it has no _goboringcrypto_ symbols). Its TLS is Go's own crypto, NOT
#   the host's FIPS-validated OpenSSL module. What this script can do - and does - is restrict
#   it to FIPS-APPROVED ALGORITHMS: TLS 1.2+, ECDHE-RSA with AES-GCM only, and GODEBUG turning
#   off the binary's legacy defaults (DefaultGODEBUG carries tls10server=1,tlsrsakex=1 - a
#   TLS 1.0 server and RSA key exchange). Approved algorithms in a non-validated module is an
#   SC-13 finding (POA&M ENG-68), not a pass. Patroni and PostgreSQL use OpenSSL (FIPS).
#   PROVEN OFFLINE 2026-09-27 against the real 3.4.30 binary with a non-FIPS OpenSSL client:
#   TLS 1.2 ECDHE-RSA AES-GCM accepted; RSA key exchange, CBC, ChaCha20, TLS 1.0 and 1.1 and a
#   client with no certificate all REFUSED, on both 2379 and 2380. ONE THING IT CANNOT DO: TLS 1.3
#   ChaCha20-Poly1305 (not approved) stays negotiable - Go never lets TLS 1.3 suites be set, and
#   3.4 predates --tls-max-version. Only an enclave-CA-certified client can connect, and the pg
#   nodes' own clients pick AES-GCM; it is in ENG-68, stated.
#
# TRAP: THE PACKAGE STARTS ITS OWN SINGLE-NODE etcd ON INSTALL (postinst enables and starts
#   etcd.service, name = hostname, data in /var/lib/etcd/default). A static three-member
#   bootstrap on top of that fails on a cluster-ID mismatch. So: install with policy-rc.d
#   blocking the start, and run from our OWN data dir (ETCD_DIR) so the default can never
#   collide - the same shape as postgresql-16 creating a cluster Patroni must not inherit.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENC="$(cd "$SELF/../enclave" && pwd)"
ADDRS="$ENC/enclave-addresses.env"

ETCD_PKI="${ETCD_PKI:-/etc/etcd/pki}"
ETCD_DIR="${ETCD_DIR:-/var/lib/etcd/enclave-pg}"
ETCD_ENV="${ETCD_ENV:-/etc/default/etcd}"
ETCD_TOKEN="${ETCD_TOKEN:-enclave-pg-etcd}"
ETCD_WAIT="${ETCD_WAIT:-300}"                 # seconds to wait for quorum after starting
# ECDHE-RSA + AES-GCM only: FIPS-approved key exchange, cipher and MAC for RSA certificates
# (ca.sh issues RSA). No CBC, no ChaCha20 (not approved), no static-RSA key exchange.
ETCD_CIPHERS="${ETCD_CIPHERS:-TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384}"
ETCD_GODEBUG="${ETCD_GODEBUG:-tlsrsakex=0,tls10server=0}"
CA_ROOT="${CA_ROOT:-$ENC/trust-anchors/enclave-root.crt}"
SSL_DIR="${SSL_DIR:-/etc/ssl/enclave}"         # where `ca.sh request` put this node's key

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

[ -r "$ADDRS" ] || die "no address file at $ADDRS"
# shellcheck disable=SC1090
. "$ADDRS"

# WHICH pg node this is, from its address - the same rule as 05's guard: never a typed name.
ME=""; ME_ADDR=""
whoami_pg() {
  local k a mine
  mine="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '='); do
    a="${!k:-}"
    if [ -n "$a" ] && printf '%s\n' "$mine" | grep -qx "$a"; then
      ME="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"; ME_ADDR="$a"; return 0
    fi
  done
  die "this machine ($(hostname -s)) holds no PG_* address in $ADDRS - 06a runs on pg-01..03 only"
}

# The member list, from the address file: pg-01=https://10.2.20.165:2380,...
initial_cluster() {
  local k out=""
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    out="${out:+$out,}$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')=https://${!k}:2380"
  done
  printf '%s' "$out"
}
client_endpoints() {
  local k out=""
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do out="${out:+$out,}https://${!k}:2379"; done
  printf '%s' "$out"
}

# /etc/default/etcd, rendered. A function so it can be tested away from a pg node.
# render_etcd_env NAME ADDR CLUSTER
render_etcd_env() {
  cat <<ENV
# MANAGED by 06a-postgres-ha.sh etcd - the database's own etcd (backlog B-06a). Edits are
# overwritten by the next run; change the script or its parameters instead.
ETCD_NAME="$1"
ETCD_DATA_DIR="$ETCD_DIR"
ETCD_LISTEN_PEER_URLS="https://$2:2380"
ETCD_LISTEN_CLIENT_URLS="https://$2:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="https://$2:2380"
ETCD_ADVERTISE_CLIENT_URLS="https://$2:2379"
ETCD_INITIAL_CLUSTER="$3"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="$ETCD_TOKEN"
ETCD_CERT_FILE="$ETCD_PKI/member.crt"
ETCD_KEY_FILE="$ETCD_PKI/member.key"
ETCD_TRUSTED_CA_FILE="$ETCD_PKI/ca.crt"
ETCD_CLIENT_CERT_AUTH="true"
ETCD_PEER_CERT_FILE="$ETCD_PKI/member.crt"
ETCD_PEER_KEY_FILE="$ETCD_PKI/member.key"
ETCD_PEER_TRUSTED_CA_FILE="$ETCD_PKI/ca.crt"
ETCD_PEER_CLIENT_CERT_AUTH="true"
ETCD_CIPHER_SUITES="$ETCD_CIPHERS"
# Go's TLS, not OpenSSL (see the script header): these switch off the binary's legacy
# defaults, TLS 1.0 on the server and RSA key exchange.
GODEBUG="$ETCD_GODEBUG"
ENV
}

# check_member_cert FULLCHAIN KEY ADDR ROOT - every way a wrong certificate has to be refused.
check_member_cert() {
  local fc="$1" key="$2" addr="$3" root="$4" tmp eku san
  tmp="$(mktemp -d)"
  # leaf first, then the issuing CA (sign-server writes them in that order)
  awk -v d="$tmp" '/BEGIN CERT/ {n++} n {print > (d "/c" n ".pem")}' "$fc"
  if [ ! -s "$tmp/c1.pem" ]; then rm -rf "$tmp"; die "$fc holds no certificate"; fi
  if [ -s "$tmp/c2.pem" ]; then
    openssl verify -CAfile "$root" -untrusted "$tmp/c2.pem" "$tmp/c1.pem" >/dev/null 2>&1 \
      || { rm -rf "$tmp"; die "$fc does not verify against the enclave root through its issuing CA"; }
  else
    openssl verify -CAfile "$root" "$tmp/c1.pem" >/dev/null 2>&1 \
      || { rm -rf "$tmp"; die "$fc does not verify against the enclave root (and carries no issuing CA)"; }
  fi
  eku="$(openssl x509 -in "$tmp/c1.pem" -noout -ext extendedKeyUsage 2>/dev/null | tail -n +2)"
  case "$eku" in
    *"Server Authentication"*"Client Authentication"*|*"Client Authentication"*"Server Authentication"*) ;;
    *) rm -rf "$tmp"; die "$fc is not a peer certificate (needs serverAuth AND clientAuth; has:${eku:- none}). Sign with: ca.sh sign-server --peer" ;;
  esac
  san="$(openssl x509 -in "$tmp/c1.pem" -noout -ext subjectAltName 2>/dev/null | tail -n +2)"
  case "$san" in *"IP Address:$addr"*) ;; *) rm -rf "$tmp"; die "$fc does not name this node's address $addr (SAN:$san)" ;; esac
  if [ "$(openssl x509 -in "$tmp/c1.pem" -noout -pubkey | sha256sum)" != "$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum)" ]; then
    rm -rf "$tmp"; die "$fc was not made from $key - this node's key. Was the CSR from another node?"
  fi
  rm -rf "$tmp"
  ok "certificate: verifies to the enclave root, serverAuth+clientAuth, names $addr, matches this node's key"
}

cmd_etcd() {
  need_root; whoami_pg
  local fc="${1:-}" name="$ME"
  [ -n "$fc" ] && [ -r "$fc" ] || die "usage: sudo $0 etcd <$name.fullchain.crt from svc-mgmt-01>"
  [ -r "$CA_ROOT" ] || die "no enclave root at $CA_ROOT"
  local key="$SSL_DIR/$name.key"
  [ -r "$key" ] || die "no key at $key - make it on THIS node first: sudo $ENC/ca.sh request $name"

  # ---- the certificate, checked before anything is installed ----
  check_member_cert "$fc" "$key" "$ME_ADDR" "$CA_ROOT"

  # ---- the package, WITHOUT its self-start ----
  if ! dpkg -s etcd-server >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive apt-get install -y etcd-server etcd-client \
      || { rm -f /usr/sbin/policy-rc.d; die "apt could not install etcd-server etcd-client"; }
    rm -f /usr/sbin/policy-rc.d
    ok "etcd-server $(dpkg-query -W -f='${Version}' etcd-server) installed, its self-start blocked"
  fi
  systemctl stop etcd >/dev/null 2>&1 || true
  if [ -d /var/lib/etcd/default ]; then
    rm -rf /var/lib/etcd/default && say "removed the package's default single-node data (/var/lib/etcd/default)"
  fi

  # ---- files etcd (the user) can read ----
  install -d -m 0750 -o root -g etcd "$ETCD_PKI"
  install -m 0644 -o root -g root "$CA_ROOT" "$ETCD_PKI/ca.crt"
  install -m 0644 -o root -g root "$fc" "$ETCD_PKI/member.crt"
  install -m 0640 -o root -g etcd "$key" "$ETCD_PKI/member.key"
  install -d -m 0700 -o etcd -g etcd "$ETCD_DIR"
  render_etcd_env "$name" "$ME_ADDR" "$(initial_cluster)" > "$ETCD_ENV.new"
  chown root:etcd "$ETCD_ENV.new"; chmod 0640 "$ETCD_ENV.new"; mv -f "$ETCD_ENV.new" "$ETCD_ENV"
  ok "config: $ETCD_ENV (member $name at $ME_ADDR, cluster $(initial_cluster | tr ',' ' '))"

  # ---- start, and wait for QUORUM rather than for systemd ----
  # --no-block: with Type=notify the first member only reports ready once a quorum exists, so a
  # blocking start on pg-01 would time out waiting for pg-02 and pg-03. Start all three, then wait.
  systemctl enable etcd >/dev/null 2>&1
  systemctl restart --no-block etcd
  say "waiting up to ${ETCD_WAIT}s for a quorum (start this on all three pg nodes)"

  for _ in $(seq 1 "$((ETCD_WAIT / 5))"); do
    if etcd_ctl endpoint health >/dev/null 2>&1; then ok "etcd member $name is healthy - a quorum exists"; etcd_ctl member list -w table; return 0; fi
    sleep 5
  done
  journalctl -u etcd -n 20 --no-pager | sed 's/^/     /'
  die "no quorum after ${ETCD_WAIT}s - are the other pg nodes started? (the log above says what etcd sees)"
}

# etcdctl as this member - its own certificate is also a client certificate (clientAuth).
etcd_ctl() {
  ETCDCTL_API=3 etcdctl --endpoints="https://$ME_ADDR:2379" \
    --cacert "$ETCD_PKI/ca.crt" --cert "$ETCD_PKI/member.crt" --key "$ETCD_PKI/member.key" "$@"
}

cmd_etcd_check() {
  need_root; whoami_pg
  say "the database's etcd, seen from $ME"
  ETCDCTL_API=3 etcdctl --endpoints="$(client_endpoints)" \
    --cacert "$ETCD_PKI/ca.crt" --cert "$ETCD_PKI/member.crt" --key "$ETCD_PKI/member.key" \
    endpoint health -w table || die "not every member is healthy"
  etcd_ctl member list -w table
  # What a client WITHOUT a certificate gets - must be refused (client-cert-auth).
  if curl -s --max-time 5 --cacert "$ETCD_PKI/ca.crt" "https://$ME_ADDR:2379/health" >/dev/null 2>&1; then
    warn "a client with NO certificate was answered - client-cert-auth is not enforced"; exit 1
  fi
  ok "a client with no certificate is refused"
  local pid; pid="$(systemctl show -p MainPID --value etcd)"
  if [ -n "$pid" ] && [ "$pid" != 0 ] && tr '\0' '\n' < "/proc/$pid/environ" | grep -qx "GODEBUG=$ETCD_GODEBUG"; then
    ok "the running etcd carries GODEBUG=$ETCD_GODEBUG"
  else warn "the running etcd does NOT carry GODEBUG=$ETCD_GODEBUG"; exit 1; fi
  say "FIPS: approved algorithms in Go's TLS - NOT a validated module (SC-13, POA&M)."
}

# =========================================================================================
# SLICE 3 - PATRONI AND POSTGRESQL 16 (runbook 9a.3; the traps are 9a.2a / backlog 6a.7)
#
#   Decided 2026-09-27 (HANDOFF 3): automatic failover, synchronous_mode on, strict OFF (an
#   alert will watch the degradation - slice 4), 5432 from the four K8S workers and the three pg
#   nodes only, and NODE-TO-NODE AUTHENTICATION BY CERTIFICATE: replication and rewind connect
#   with each node's enclave-CA identity from slice 2 (pg_hba `cert`, mapped to the roles by
#   pg_ident), the REST API needs a client certificate for anything that changes state. There
#   is no shared password anywhere - nothing to make, carry, keep or rotate.
#
#   TRAPS BUILT IN FROM THE START, not remediated later:
#     - Ubuntu's postgresql-16 creates and starts a "16 main" cluster on install. A drop-in in
#       /etc/postgresql-common/createcluster.d (read by the generated createcluster.conf) sets
#       create_main_cluster = false BEFORE postgresql-16 is installed, so it never exists. The
#       data directory is Patroni's own (PG_DATA), never Debian's 16/main.
#     - Patroni OWNS postgresql.conf and pg_hba.conf and rewrites them on restart: every setting
#       below lives in patroni.yml / the DCS, never in a file edited by hand (6a.7 trap 3).
#     - V-261892: no md5, password or trust line exists - peer locally, cert between nodes,
#       scram-sha-256 for applications, hostssl only.
#     - V-261967 vs 25 rules: log_destination 'stderr,syslog' + logging_collector on +
#       log_file_mode 0600 (6a.7 trap 2), and the union log_line_prefix (6a.2a section 6).
#     - pgaudit preloaded; patroni-check reads pg_settings.pending_restart, the false-pass
#       detector (a node can SHOW the right value and not have applied it).
#     - V-261857: explicit CONNECTION LIMITs on the replication and rewind roles (post_bootstrap).
#     - THE DATA DISK: mounted by LABEL (it moved vdc -> vdb when finish removed the seed), with
#       NO nofail, and patroni.service RequiresMountsFor it - a missing disk stops Patroni instead
#       of letting it initdb an empty database on the OS disk.
# =========================================================================================
PG_MNT="${PG_MNT:-/var/lib/postgresql}"
PG_LABEL="${PG_LABEL:-pgdata}"
PG_DATA="${PG_DATA:-$PG_MNT/16/enclave-pg}"
PG_BIN="${PG_BIN:-/usr/lib/postgresql/16/bin}"
PG_SCOPE="${PG_SCOPE:-enclave-pg}"
PATRONI_CONF="${PATRONI_CONF:-/etc/patroni/config.yml}"
PATRONI_PKI="${PATRONI_PKI:-/etc/patroni/pki}"
PG_MAX_CONN="${PG_MAX_CONN:-100}"
PG_REPL_CONN_LIMIT="${PG_REPL_CONN_LIMIT:-10}"
PG_WAIT="${PG_WAIT:-300}"
# The monitoring login (slice 4, decided 2026-09-28): a read-only role with pg_monitor, reached
# ONLY over the local socket by the exporter's OS account through a pg_ident map - no password.
PG_MON_ROLE="${PG_MON_ROLE:-pgmonitor}"
PG_MON_OSUSER="${PG_MON_OSUSER:-prometheus}"        # the account prometheus-postgres-exporter runs as
PG_MON_CONN_LIMIT="${PG_MON_CONN_LIMIT:-3}"
PG_EXPORTER_PORT="${PG_EXPORTER_PORT:-9187}"
PG_EXPORTER_ENV="${PG_EXPORTER_ENV:-/etc/default/prometheus-postgres-exporter}"
# pgaudit for the monitoring role (decided 2026-09-28, a tailoring for the org baseline 6a.10):
# 'none'. Measured on pg-01: one exporter scrape = 20 audit lines of pgmonitor reading statistics
# views, ~4.5 MB/hour per node at a 15 s scrape - 6x the node's whole syslog - and the role holds
# pg_monitor only, so it cannot read table data. Its LOGINS stay audited (log_connections).
PG_MON_PGAUDIT="${PG_MON_PGAUDIT:-none}"
PG_PGAUDIT_LOG="${PG_PGAUDIT_LOG:-ddl,role,read,write}"
# The Postgres 16 STIG's org-defined values - DECIDED 2026-09-30 by the acting AO, from pg-stig.sh's
# first scan (its four Opens). Baseline 6a.10 records them. Applied by `stig-settings`; render_patroni
# and post_bootstrap carry the same, so a rebuild starts with them.
PG_TCP_KEEPALIVES_IDLE="${PG_TCP_KEEPALIVES_IDLE:-300}"         # V-261899: a vanished client is dropped
PG_TCP_KEEPALIVES_INTERVAL="${PG_TCP_KEEPALIVES_INTERVAL:-30}"  #   within idle + interval x count = 6.5 min
PG_TCP_KEEPALIVES_COUNT="${PG_TCP_KEEPALIVES_COUNT:-3}"
PG_STATEMENT_TIMEOUT="${PG_STATEMENT_TIMEOUT:-60min}"           # V-261899; an admin raises it per session
PG_CLIENT_MIN_MESSAGES="${PG_CLIENT_MIN_MESSAGES:-error}"       # V-261908/909; an admin lowers it per session
# V-261857. PostgreSQL does NOT enforce a role's CONNECTION LIMIT on a superuser - postgres's real bound
# is superuser_reserved_connections inside max_connections. Set so the catalog carries a documented
# value instead of -1, and the baseline says exactly that rather than pretend it limits anything.
PG_SUPERUSER_CONN_LIMIT="${PG_SUPERUSER_CONN_LIMIT:-10}"
# V-261874 (decided 2026-10-01): the local log files roll over a WEEK - one per weekday, each
# overwritten seven days later (oldest first). Before this nothing removed them, and a busy audited
# database would in time fill its own volume and stop. The long-term record is the syslog copy,
# collected centrally (backlog 3.37). Size-driven rotation is off: it would append within the day.
PG_LOG_FILENAME="${PG_LOG_FILENAME:-postgresql-%a.log}"
PG_LOG_ROTATION_AGE="${PG_LOG_ROTATION_AGE:-1d}"
# ---- slice 5: pgBackRest (decided 2026-09-28: TLS both ways; two live stores; LUKS underneath;
# 2 weekly fulls + daily differentials). The stores and their repository paths, in repo order,
# come from vm-specs.env - the planner reads the same line to reserve host-3's space.
PG_BACKUP_STORES="${PG_BACKUP_STORES:-$(awk -F"'" '/^PG_BACKUP_STORES=/{print $2}' "$ENC/vm-specs.env" 2>/dev/null)}"
PGBR_PORT="${PGBR_PORT:-8432}"
PGBR_CONF="${PGBR_CONF:-/etc/pgbackrest/pgbackrest.conf}"
PGBR_PKI="${PGBR_PKI:-/etc/pgbackrest/pki}"
PGBR_LOG="${PGBR_LOG:-/var/log/pgbackrest}"
PGBR_RETENTION_FULL="${PGBR_RETENTION_FULL:-2}"
PGBR_FULL_DAY="${PGBR_FULL_DAY:-Sun}"                 # the weekly full; differentials the other days
PGBR_BACKUP_MINUTE="${PGBR_BACKUP_MINUTE:-30}"        # store N runs at 00:MM + N hours (repo1 01:30, repo2 02:30)
PG_ARCHIVE_TIMEOUT="${PG_ARCHIVE_TIMEOUT:-300}"       # a quiet database still ships a WAL file every 5 min
PGBR_ARCHIVE_CMD="pgbackrest --stanza=${PG_SCOPE:-enclave-pg} archive-push %p"

# The pg nodes, the K8S workers - from the address file, as `ip name` pairs.
addr_pairs() {   # addr_pairs PREFIX_REGEX
  local k
  for k in $(grep -oE "^($1)=" "$ADDRS" | tr -d '=' | sort); do printf '%s %s\n' "${!k}" "$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"; done
}

# patroni.yml, rendered. A function so it can be validated away from a pg node.
# render_patroni NAME ADDR
render_patroni() {
  local name="$1" addr="$2" ip n
  cat <<YML
# MANAGED by 06a-postgres-ha.sh patroni (backlog B-06a slice 3). Edits are overwritten by the
# next run - and Patroni itself rewrites postgresql.conf and pg_hba.conf from this file.
scope: $PG_SCOPE
namespace: /enclave/
name: $name
restapi:
  listen: $addr:8008
  connect_address: $addr:8008
  certfile: $PATRONI_PKI/node.crt
  keyfile: $PATRONI_PKI/node.key
  cafile: $PATRONI_PKI/ca.crt
  # optional = a client certificate is REQUIRED for every endpoint that changes state
  # (switchover, restart, reload, config); reads (/health, /primary, /metrics) stay open
  # to what ufw lets in: the three pg nodes and svc-obs-01.
  verify_client: optional
  allowlist:
YML
  while read -r ip n; do printf '    - %s\n' "$ip"; done < <(addr_pairs 'PG_[0-9]+')
  cat <<YML
ctl:
  cacert: $PATRONI_PKI/ca.crt
  certfile: $PATRONI_PKI/node.crt
  keyfile: $PATRONI_PKI/node.key
etcd3:
  protocol: https
  hosts:
YML
  while read -r ip n; do printf '    - %s:2379\n' "$ip"; done < <(addr_pairs 'PG_[0-9]+')
  cat <<YML
  cacert: $PATRONI_PKI/ca.crt
  cert: $PATRONI_PKI/node.crt
  key: $PATRONI_PKI/node.key
bootstrap:
  dcs:
    # CONSERVATIVE ON PURPOSE (runbook 9a.3): a promotion needs ~30 s of genuine leader loss.
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    # 9a.1 correction 2: synchronous replication is expressed HERE - Patroni overwrites a
    # hand-set synchronous_standby_names. strict is deliberately absent (off) - decided.
    synchronous_mode: true
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        synchronous_commit: "on"
        max_connections: $PG_MAX_CONN
        password_encryption: scram-sha-256
        ssl: "on"
        ssl_min_protocol_version: TLSv1.2
        ssl_cert_file: $PATRONI_PKI/node.crt
        ssl_key_file: $PATRONI_PKI/node.key
        ssl_ca_file: $PATRONI_PKI/ca.crt
        wal_level: replica
        wal_log_hints: "on"
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        # 6a.7 trap 2 and 6a.2a section 6 - decided once, here
        log_destination: stderr,syslog
        logging_collector: "on"
        log_file_mode: "0600"
        log_line_prefix: "%m %a %u %d %r %p %s %c %h "
        log_connections: "on"
        log_disconnections: "on"
        shared_preload_libraries: pgaudit
        pgaudit.log: $PG_PGAUDIT_LOG
        # slice 5 - WAL to both backup stores. On a rebuild the command fails until backup-node
        # has run; PostgreSQL keeps the WAL and retries, so nothing is lost in between.
        archive_mode: "on"
        archive_command: "$PGBR_ARCHIVE_CMD"
        archive_timeout: $PG_ARCHIVE_TIMEOUT
        pgaudit.log_catalog: "on"
        # slice 6 - the Postgres 16 STIG's org-defined values (stig-settings, decided 2026-09-30)
        tcp_keepalives_idle: $PG_TCP_KEEPALIVES_IDLE
        tcp_keepalives_interval: $PG_TCP_KEEPALIVES_INTERVAL
        tcp_keepalives_count: $PG_TCP_KEEPALIVES_COUNT
        statement_timeout: $PG_STATEMENT_TIMEOUT
        client_min_messages: $PG_CLIENT_MIN_MESSAGES
        log_filename: "$PG_LOG_FILENAME"
        log_truncate_on_rotation: "on"
        log_rotation_age: $PG_LOG_ROTATION_AGE
        log_rotation_size: 0
  initdb:
    - encoding: UTF8
    - data-checksums
    - auth-local: peer
    - auth-host: scram-sha-256
  post_bootstrap: $PATRONI_PKI/../post-bootstrap.sh
postgresql:
  listen: $addr:5432
  connect_address: $addr:5432
  use_unix_socket: true
  data_dir: $PG_DATA
  bin_dir: $PG_BIN
  pgpass: $PG_MNT/.pgpass.patroni
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
      sslmode: verify-full
      sslcert: $PATRONI_PKI/node.crt
      sslkey: $PATRONI_PKI/node.key
      sslrootcert: $PATRONI_PKI/ca.crt
    rewind:
      username: rewinder
      sslmode: verify-full
      sslcert: $PATRONI_PKI/node.crt
      sslkey: $PATRONI_PKI/node.key
      sslrootcert: $PATRONI_PKI/ca.crt
  parameters:
    unix_socket_directories: /var/run/postgresql
  # V-261892: peer locally, cert between nodes, scram for applications, hostssl only - no
  # md5, password or trust line exists. Nothing matches = rejected.
  pg_hba:
    - local all postgres peer
    # the exporter, as OS user $PG_MON_OSUSER, logs in as $PG_MON_ROLE - local socket only (slice 4)
    - local postgres $PG_MON_ROLE peer map=$PG_MON_ROLE
YML
  while read -r ip n; do
    printf '    - hostssl replication replicator %s/32 cert map=pgnodes\n' "$ip"
    printf '    - hostssl all rewinder %s/32 cert map=pgnodes\n' "$ip"
  done < <(addr_pairs 'PG_[0-9]+')
  while read -r ip n; do printf '    - hostssl all all %s/32 scram-sha-256\n' "$ip"; done < <(addr_pairs 'K8S_WK_[0-9]+')
  printf '  pg_ident:\n'
  printf '    - %s %s %s\n' "$PG_MON_ROLE" "$PG_MON_OSUSER" "$PG_MON_ROLE"
  while read -r ip n; do
    printf '    - pgnodes %s.%s replicator\n' "$n" "${ENCLAVE_DOMAIN:-enclave.internal}"
    printf '    - pgnodes %s.%s rewinder\n' "$n" "${ENCLAVE_DOMAIN:-enclave.internal}"
  done < <(addr_pairs 'PG_[0-9]+')
}

# Run once by Patroni on the primary after initdb (bootstrap.post_bootstrap). V-261857: no role
# the build creates may have rolconnlimit = -1.
# PATRONI RUNS THIS BEFORE IT CREATES THE REPLICATION AND REWIND ROLES - and creates them only if
# this succeeds (patroni/postgresql/bootstrap.py post_bootstrap). The first live bootstrap on pg-01,
# 2026-09-28, ALTERed a role that did not exist yet, exited 3, and Patroni cancelled the cluster.
# So CREATE them here, with their limits; Patroni's own create-or-alter then runs ALTER ROLE ...
# WITH LOGIN REPLICATION, which leaves CONNECTION LIMIT alone, and grants rewind its functions.
render_post_bootstrap() {
  cat <<SH
#!/bin/sh
# MANAGED by 06a-postgres-ha.sh - run once by Patroni after initdb, BEFORE it creates the
# replication and rewind roles (V-261857 connection limits - see the script for why).
set -e
psql -v ON_ERROR_STOP=1 -X -q -d postgres <<'SQL'
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH LOGIN REPLICATION CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  ELSE
    ALTER ROLE replicator CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'rewinder') THEN
    CREATE ROLE rewinder WITH LOGIN CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  ELSE
    ALTER ROLE rewinder CONNECTION LIMIT $PG_REPL_CONN_LIMIT;
  END IF;
  -- V-261857: documented, not enforced - PostgreSQL exempts superusers from role limits
  ALTER ROLE postgres CONNECTION LIMIT $PG_SUPERUSER_CONN_LIMIT;
END
\$\$;
SQL
$(render_monitor_sql)
SH
}

# The monitoring role - read-only statistics (pg_monitor), a connection limit (V-261857), no
# password. Used by post_bootstrap on a new cluster and by `monitor` on an existing one.
render_monitor_sql() {
  cat <<SH
psql -v ON_ERROR_STOP=1 -X -q -d postgres <<'SQL'
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$PG_MON_ROLE') THEN
    CREATE ROLE $PG_MON_ROLE WITH LOGIN CONNECTION LIMIT $PG_MON_CONN_LIMIT;
  ELSE
    ALTER ROLE $PG_MON_ROLE WITH LOGIN CONNECTION LIMIT $PG_MON_CONN_LIMIT;
  END IF;
END
\$\$;
GRANT pg_monitor TO $PG_MON_ROLE;
-- pgaudit.log is superuser-only: $PG_MON_ROLE cannot set it back, or set it for anyone else.
ALTER ROLE $PG_MON_ROLE SET pgaudit.log = '$PG_MON_PGAUDIT';
SQL
SH
}

# patroni --validate-config also checks it could BIND its REST and PostgreSQL ports, which it
# cannot while Patroni is running on them - so on a live node it always prints "Port ... is
# already in use" twice. Drop exactly those lines, say so, and let every other finding through.
validate_patroni_config() {
  local out
  out="$(runuser -u postgres -- patroni --validate-config "$PATRONI_CONF" 2>&1 || true)"
  if systemctl is-active --quiet patroni && printf '%s\n' "$out" | grep -q 'is already in use'; then
    out="$(printf '%s\n' "$out" | grep -v 'is already in use' || true)"
    say "validate-config: the port-in-use findings are Patroni itself holding 8008/5432 - expected on a live node"
  fi
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/     /' | head -20
}

# psql as the postgres OS user over the local socket (peer)
pg_sql() { runuser -u postgres -- psql -X -A -t -q -d postgres -c "$1"; }

cmd_patroni() {
  need_root; whoami_pg
  local name="$ME" key="$SSL_DIR/$ME.key"
  etcd_ctl endpoint health >/dev/null 2>&1 || die "this node's etcd is not healthy - slice 2 first: sudo $0 etcd-check"
  [ -r "$ETCD_PKI/member.crt" ] && [ -r "$key" ] || die "no node certificate/key from slice 2 ($ETCD_PKI/member.crt, $key)"

  # ---- the data disk, by label, never on the OS disk ----
  local dev cand n
  dev="$(blkid -L "$PG_LABEL" 2>/dev/null || true)"
  if [ -z "$dev" ]; then
    # exactly ONE whole disk with no partitions, no filesystem and no mount - or refuse
    cand="$(lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}' | while read -r d; do
              [ "$(lsblk -no NAME "$d" | wc -l)" -eq 1 ] || continue
              [ -z "$(blkid -o value -s TYPE "$d" 2>/dev/null)" ] || continue
              findmnt -rn -S "$d" >/dev/null 2>&1 && continue
              echo "$d"; done)"
    n="$(printf '%s\n' "$cand" | grep -c . || true)"
    [ "$n" -eq 1 ] || die "expected exactly ONE blank data disk, found $n: ${cand:-none}. Refusing to guess which disk to format."
    say "formatting $cand ($(lsblk -dno SIZE "$cand")) as ext4, label $PG_LABEL - it is blank"
    # -E nodiscard: mkfs TRIMs the whole device by default, and on 2026-09-28 that TRIM went
    # through the host's discard=unmap and released every reserved block of all three data
    # disks (backlog 3.42). The host now attaches data disks discard=ignore; this is the second
    # lock, so a disk attached the old way is still not un-reserved by being formatted.
    mkfs.ext4 -q -E nodiscard -L "$PG_LABEL" "$cand"
    dev="$cand"
  fi
  install -d -m 0755 "$PG_MNT"
  if ! grep -qE "^LABEL=${PG_LABEL}[[:space:]]" /etc/fstab; then
    cp -p /etc/fstab "/etc/fstab.bak-06a-$(date +%Y%m%d%H%M%S)"
    printf 'LABEL=%s  %s  ext4  defaults,nodev,nosuid,noexec  0 2\n' "$PG_LABEL" "$PG_MNT" >> /etc/fstab
    systemctl daemon-reload
  fi
  mountpoint -q "$PG_MNT" || mount "$PG_MNT"
  findmnt -n -S "LABEL=$PG_LABEL" -T "$PG_MNT" >/dev/null || [ "$(findmnt -n -o SOURCE "$PG_MNT")" = "$dev" ] \
    || die "$PG_MNT is not the $PG_LABEL disk"
  ok "data disk: $dev (LABEL=$PG_LABEL) mounted at $PG_MNT, $(df -h --output=size "$PG_MNT" | tail -1 | tr -d ' ')"

  # ---- packages, with Ubuntu's default cluster switched off BEFORE postgresql-16 ----
  install -d -m 0755 /etc/postgresql-common/createcluster.d
  printf '# 06a-postgres-ha.sh: Patroni owns the only cluster on this node\ncreate_main_cluster = false\n' \
    > /etc/postgresql-common/createcluster.d/00-no-main-cluster.conf
  DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-16 postgresql-16-pgaudit patroni python3-etcd \
    || die "apt could not install postgresql-16 postgresql-16-pgaudit patroni python3-etcd"
  if pg_lsclusters -h 2>/dev/null | grep -q .; then
    pg_lsclusters | sed 's/^/     /'
    die "a Debian-managed cluster exists - Patroni must be the only thing running PostgreSQL here. Look before removing it."
  fi
  systemctl disable --now postgresql >/dev/null 2>&1 || true
  chown postgres:postgres "$PG_MNT"
  ok "postgresql-16 $(dpkg-query -W -f='${Version}' postgresql-16), patroni $(dpkg-query -W -f='${Version}' patroni), pgaudit installed; no Debian cluster"

  # ---- the node's identity for postgres and patroni (slice 2's certificate) ----
  install -d -m 0750 -o root -g postgres "$PATRONI_PKI"
  install -m 0644 -o root -g root "$CA_ROOT" "$PATRONI_PKI/ca.crt"
  install -m 0644 -o root -g root "$ETCD_PKI/member.crt" "$PATRONI_PKI/node.crt"
  install -m 0640 -o root -g postgres "$key" "$PATRONI_PKI/node.key"
  render_post_bootstrap > /etc/patroni/post-bootstrap.sh
  chown root:postgres /etc/patroni/post-bootstrap.sh; chmod 0750 /etc/patroni/post-bootstrap.sh
  render_patroni "$name" "$ME_ADDR" > "$PATRONI_CONF.new"
  chown root:postgres "$PATRONI_CONF.new"; chmod 0640 "$PATRONI_CONF.new"; mv -f "$PATRONI_CONF.new" "$PATRONI_CONF"
  validate_patroni_config
  install -d -m 0755 /etc/systemd/system/patroni.service.d
  # StartLimit: a bootstrap that keeps failing STOPS after five tries in ten minutes. The package's
  # Restart=on-failure looped every few seconds on pg-01 (restart counter 34), each try running
  # initdb and leaving a *.failed data dir - the same rule as D7: never retry forever.
  printf '[Unit]\n# 06a: no data disk, no Patroni - never initdb an empty cluster on the OS disk\nRequiresMountsFor=%s\nAfter=etcd.service\nWants=etcd.service\nStartLimitIntervalSec=600\nStartLimitBurst=5\n[Service]\nRestartSec=15\n' "$PG_MNT" \
    > /etc/systemd/system/patroni.service.d/06a.conf
  systemctl daemon-reload
  ok "config: $PATRONI_CONF (member $name, scope $PG_SCOPE)"

  # ---- start, and wait for what this node should become ----
  systemctl enable patroni >/dev/null 2>&1
  systemctl reset-failed patroni >/dev/null 2>&1 || true   # a start limit hit by an earlier failed run
  systemctl restart patroni
  say "waiting up to ${PG_WAIT}s for $name to run (the first node bootstraps; the others clone from it)"
  # THE RIGHT ROLE, HELD. The first version accepted State 'running' and passed on pg-01 in the
  # middle of a bootstrap that then failed - the table printed under "[ok] pg-01 is up" said
  # "uninitialized ... Replica ... stopped". Now: Leader+running, or a replica STREAMING from a
  # leader, and three polls in a row (15 s), so a moment in passing does not count.
  local good=0
  for _ in $(seq 1 "$((PG_WAIT / 5))"); do
    if patronictl -c "$PATRONI_CONF" list -f json 2>/dev/null | python3 -c "
import sys, json
m = {x['Member']: x for x in json.load(sys.stdin)}
x = m.get('$name', {})
ok = (x.get('Role') == 'Leader' and x.get('State') == 'running') or \
     (x.get('Role') in ('Replica', 'Sync Standby') and x.get('State') == 'streaming')
sys.exit(0 if ok else 1)"; then good=$((good + 1)); else good=0; fi
    if [ "$good" -ge 3 ]; then ok "$name is up and has held it for 15 s"; patronictl -c "$PATRONI_CONF" list; return 0; fi
    sleep 5
  done
  journalctl -u patroni -n 30 --no-pager | sed 's/^/     /'
  # A STALE `initialize` KEY. Found 2026-09-28: Patroni was stopped in the middle of a bootstrap it
  # had claimed, so the claim stayed in etcd, and every later start sat on "waiting for leader to
  # bootstrap" with no leader anywhere. Patroni removes the key when a bootstrap FAILS, not when it
  # is killed. Say so - but never clear it automatically: another node may really be bootstrapping.
  if journalctl -u patroni -n 30 --no-pager 2>/dev/null | grep -q 'waiting for leader to bootstrap' \
     && ! etcd_ctl get "/enclave/$PG_SCOPE/leader" --keys-only 2>/dev/null | grep -q .; then
    say ""
    say "  'waiting for leader to bootstrap' with NO leader: if no other node is running Patroni, a"
    say "  bootstrap that was killed left its claim (/enclave/$PG_SCOPE/initialize) in etcd. Stop"
    say "  Patroni, confirm there is no leader key, then delete /enclave/$PG_SCOPE/ with etcdctl and"
    say "  remove $PG_DATA before re-running - the cluster never initialized, so nothing is lost."
  fi
  die "$name did not come up in ${PG_WAIT}s - the journal above says why"
}

cmd_patroni_check() {
  need_root; whoami_pg
  local bad=0 role v
  patronictl -c "$PATRONI_CONF" list || die "patronictl could not read the cluster"
  role="$(pg_sql "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END")"
  say "$ME is the $role"
  # 6a.7: pending_restart is the false-pass detector - the right value, not yet applied
  v="$(pg_sql "SELECT setting||' pending_restart='||pending_restart FROM pg_settings WHERE name='shared_preload_libraries'")"
  case "$v" in *pgaudit*"pending_restart=f"*) ok "shared_preload_libraries: $v" ;; *) warn "shared_preload_libraries: $v"; bad=1 ;; esac
  v="$(pg_sql "SELECT string_agg(DISTINCT auth_method, ',') FROM pg_hba_file_rules")"
  case ",$v," in *,md5,*|*,password,*|*,trust,*) warn "pg_hba has a weak method: $v (V-261892)"; bad=1 ;; *) ok "pg_hba methods: $v - no md5, password or trust" ;; esac
  v="$(pg_sql "SELECT string_agg(DISTINCT type, ',') FROM pg_hba_file_rules")"
  case ",$v," in *,host,*|*,hostnossl,*) warn "pg_hba has non-TLS host lines: $v"; bad=1 ;; *) ok "pg_hba line types: $v - TLS only over the network" ;; esac
  # V-261857: the roles the build creates carry an explicit CONNECTION LIMIT (post_bootstrap)
  v="$(pg_sql "SELECT string_agg(rolname||'='||rolconnlimit, ' ' ORDER BY rolname) FROM pg_roles WHERE rolname IN ('$PG_MON_ROLE','replicator','rewinder')")"
  case " $v " in
    *"=-1"*) warn "connection limits: $v - a role has none (V-261857)"; bad=1 ;;
    *" $PG_MON_ROLE="*" replicator="*" rewinder="*) ok "connection limits: $v (V-261857)" ;;
    *) warn "connection limits: '${v}' - $PG_MON_ROLE, replicator or rewinder is missing (V-261857; $PG_MON_ROLE comes from 'monitor')"; bad=1 ;;
  esac
  # pgaudit: the global classes as decided, and pgmonitor the ONLY role with its own pgaudit setting
  # (tailoring 2026-09-28) - a second exempted role is exactly the quiet change this should catch.
  v="$(pg_sql "SELECT setting FROM pg_settings WHERE name='pgaudit.log'")"
  [ "$v" = "$PG_PGAUDIT_LOG" ] && ok "pgaudit.log = $v" || { warn "pgaudit.log = '$v', expected '$PG_PGAUDIT_LOG'"; bad=1; }
  v="$(pg_sql "SELECT string_agg(r.rolname||':'||c, ' ' ORDER BY r.rolname) FROM pg_db_role_setting s JOIN pg_roles r ON r.oid=s.setrole, unnest(s.setconfig) c WHERE c LIKE 'pgaudit.%'")"
  case "$v" in
    "$PG_MON_ROLE:pgaudit.log=$PG_MON_PGAUDIT") ok "pgaudit per-role: only $PG_MON_ROLE (pgaudit.log=$PG_MON_PGAUDIT - the decided tailoring)" ;;
    "") warn "pgaudit per-role: $PG_MON_ROLE carries no pgaudit.log setting - 'monitor' sets it"; bad=1 ;;
    *) warn "pgaudit per-role settings: '$v' - only $PG_MON_ROLE:pgaudit.log=$PG_MON_PGAUDIT is decided"; bad=1 ;;
  esac
  for s in ssl ssl_min_protocol_version password_encryption log_destination logging_collector log_file_mode synchronous_commit; do
    say "  $(pg_sql "SELECT name||' = '||setting FROM pg_settings WHERE name='$s'")"
  done
  if [ "$role" = primary ]; then
    # A real synchronous write, with no object left behind (6a.2a: no stig_test tables): emit a
    # WAL message, then require a SYNC standby to have replayed past it.
    local lsn
    lsn="$(pg_sql "SELECT pg_logical_emit_message(true, '06a', 'sync-check')")"
    pg_sql "SELECT application_name||' '||sync_state||' '||state||' replayed='||(replay_lsn >= '$lsn'::pg_lsn) FROM pg_stat_replication ORDER BY application_name" \
      | sed 's/^/     standby: /'
    [ "$(pg_sql "SELECT count(*) FROM pg_stat_replication WHERE sync_state='sync' AND replay_lsn >= '$lsn'::pg_lsn")" -ge 1 ] \
      && ok "a synchronous standby has replayed a commit made just now" || { warn "no synchronous standby has the commit"; bad=1; }
  fi
  [ "$bad" -eq 0 ] || exit 1
}

# =========================================================================================
# SLICE 4 - postgres-exporter (decided 2026-09-28: its own role, local peer, no password)
#
#   1. patroni.yml gains one local pg_hba line and one pg_ident map (OS user prometheus ->
#      role pgmonitor); Patroni applies them on reload - never an edit to pg_hba.conf.
#   2. On the PRIMARY: the role, idempotently. Replicas receive it by replication.
#   3. The exporter, installed with its self-start BLOCKED - its postinst starts it with an
#      empty connection string on every interface - then bound to this node's IP only.
# =========================================================================================
cmd_monitor() {
  need_root; whoami_pg
  local role v
  role="$(pg_sql "SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END" 2>/dev/null || true)"
  [ -n "$role" ] || die "PostgreSQL is not answering on $ME - slice 3 first (patroni-check)"

  # ---- 1. the login path, through Patroni ----
  cp -p "$PATRONI_CONF" "$PATRONI_CONF.bak-06a-$(date +%Y%m%d%H%M%S)"
  render_patroni "$ME" "$ME_ADDR" > "$PATRONI_CONF.new"
  chown root:postgres "$PATRONI_CONF.new"; chmod 0640 "$PATRONI_CONF.new"; mv -f "$PATRONI_CONF.new" "$PATRONI_CONF"
  validate_patroni_config
  render_post_bootstrap > /etc/patroni/post-bootstrap.sh     # a rebuilt cluster gets the role at bootstrap
  systemctl reload patroni
  for _ in $(seq 1 12); do
    v="$(pg_sql "SELECT count(*) FROM pg_hba_file_rules WHERE type='local' AND '$PG_MON_ROLE'=ANY(user_name)" || true)"
    [ "$v" = 1 ] && break; sleep 5
  done
  [ "$v" = 1 ] || die "Patroni did not apply the $PG_MON_ROLE pg_hba line within 60 s (journalctl -u patroni)"
  ok "pg_hba: local $PG_MON_ROLE by peer, mapped from OS user $PG_MON_OSUSER - applied by Patroni"

  # ---- 2. the role, on the primary only ----
  if [ "$role" = primary ]; then
    render_monitor_sql | runuser -u postgres -- sh -s || die "could not create $PG_MON_ROLE"
    ok "role $PG_MON_ROLE: pg_monitor, CONNECTION LIMIT $PG_MON_CONN_LIMIT, no password, pgaudit.log=$PG_MON_PGAUDIT (set on the primary)"
  else
    [ "$(pg_sql "SELECT count(*) FROM pg_roles WHERE rolname='$PG_MON_ROLE'")" = 1 ] \
      || die "$ME is a replica and $PG_MON_ROLE does not exist yet - run 'monitor' on the primary first"
    ok "role $PG_MON_ROLE present (replicated from the primary)"
  fi

  # ---- 3. the exporter ----
  if ! dpkg -s prometheus-postgres-exporter >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus-postgres-exporter \
      || { rm -f /usr/sbin/policy-rc.d; die "apt could not install prometheus-postgres-exporter"; }
    rm -f /usr/sbin/policy-rc.d
    ok "prometheus-postgres-exporter $(dpkg-query -W -f='${Version}' prometheus-postgres-exporter) installed, its self-start blocked"
  fi
  id "$PG_MON_OSUSER" >/dev/null 2>&1 || die "no OS user $PG_MON_OSUSER - the exporter package should have made it"
  [ -f "$PG_EXPORTER_ENV" ] && cp -p "$PG_EXPORTER_ENV" "/var/backups/$(basename "$PG_EXPORTER_ENV").$(date +%Y%m%dT%H%M%S)"
  {
    echo "# MANAGED by 06a-postgres-ha.sh monitor (B-06a slice 4). No password: peer over the local"
    echo "# socket, OS user $PG_MON_OSUSER mapped to role $PG_MON_ROLE by Patroni's pg_ident."
    echo "DATA_SOURCE_NAME='host=/var/run/postgresql user=$PG_MON_ROLE dbname=postgres'"
    echo "ARGS='--web.listen-address=$ME_ADDR:$PG_EXPORTER_PORT'"
  } > "$PG_EXPORTER_ENV.new"
  chown "root:$PG_MON_OSUSER" "$PG_EXPORTER_ENV.new"; chmod 0640 "$PG_EXPORTER_ENV.new"; mv -f "$PG_EXPORTER_ENV.new" "$PG_EXPORTER_ENV"
  systemctl enable prometheus-postgres-exporter >/dev/null 2>&1
  systemctl restart prometheus-postgres-exporter
  local up=""
  for _ in $(seq 1 12); do
    # `|| true` INSIDE the pipeline: the first poll comes before the exporter listens, curl
    # fails, and under set -e + pipefail that killed the script SILENTLY - no [ok], no [x] -
    # after the work was done (pg-01, 2026-09-28). A failed poll means "not yet", not "stop".
    up="$({ curl -s --max-time 5 "http://$ME_ADDR:$PG_EXPORTER_PORT/metrics" 2>/dev/null || true; } | awk '$1=="pg_up"{print $2}')"
    [ "$up" = 1 ] && break; sleep 5
  done
  [ "$up" = 1 ] || { journalctl -u prometheus-postgres-exporter -n 15 --no-pager | sed 's/^/     /'; die "the exporter is not reaching PostgreSQL (pg_up=${up:-no answer}) - the log above says why"; }
  ok "postgres-exporter on $ME_ADDR:$PG_EXPORTER_PORT: pg_up 1 - logged in as $PG_MON_ROLE with no password"
  ss -Htln "sport = :$PG_EXPORTER_PORT" | awk '{print "     listening: "$4}'
}

# =========================================================================================
# SLICE 4 - maintenance without an outage: one node at a time, and never the wrong one.
#
#   The cluster survives ONE node down: etcd keeps 2 of 3, PostgreSQL keeps a leader and a
#   synchronous standby. It does not survive two. So taking a node down is refused unless the
#   OTHER two are healthy right now - a guard in the script, not a line in a runbook, because
#   the day it matters is the day someone is in a hurry.
# =========================================================================================

# cluster_json: `patronictl list` as JSON (Member, Role, State, Lag in MB). Dies if unreadable.
cluster_json() { patronictl -c "$PATRONI_CONF" list -f json 2>/dev/null || die "patronictl could not read the cluster"; }

# cluster_verdict JSON [EXCLUDE] -> "ok <leader> <sync>" or "bad <reason>". Healthy = one Leader
# running, and every other member (except EXCLUDE) a Replica/Sync Standby streaming at 0 MB lag.
cluster_verdict() {
  printf '%s' "$1" | python3 -c '
import sys, json
m = json.load(sys.stdin); ex = sys.argv[1] if len(sys.argv) > 1 else ""
leaders = [x for x in m if x.get("Role") == "Leader"]
sync = [x["Member"] for x in m if x.get("Role") == "Sync Standby"]
if len(leaders) != 1: print("bad %d leaders" % len(leaders)); sys.exit()
if leaders[0].get("State") != "running": print("bad leader %s is %s" % (leaders[0]["Member"], leaders[0].get("State"))); sys.exit()
for x in m:
    if x["Member"] in (ex, leaders[0]["Member"]): continue
    if x.get("Role") not in ("Replica", "Sync Standby") or x.get("State") != "streaming" or (x.get("Lag in MB") or 0) != 0:
        print("bad %s is %s/%s lag %s" % (x["Member"], x.get("Role"), x.get("State"), x.get("Lag in MB"))); sys.exit()
if len(m) < 3: print("bad only %d members" % len(m)); sys.exit()
print("ok %s %s" % (leaders[0]["Member"], sync[0] if sync else "-"))
' "${2:-}"
}

cmd_switchover() {
  need_root; whoami_pg
  local cand="${1:-}" j v leader sync t0 tl="" tr="" now
  j="$(cluster_json)"; v="$(cluster_verdict "$j")"
  case "$v" in ok*) ;; *) patronictl -c "$PATRONI_CONF" list; die "the cluster is not healthy (${v#bad }) - a switchover now could leave it with no leader" ;; esac
  read -r _ leader sync <<<"$v"
  [ -n "$cand" ] || cand="$sync"
  [ "$cand" != "-" ] || die "there is no synchronous standby to hand over to - name a candidate, or wait for one"
  [ "$cand" != "$leader" ] || die "$cand is already the leader"
  say "switchover: $leader -> $cand ($( [ "$cand" = "$sync" ] && echo 'the synchronous standby - no commit can be lost' || echo 'NOT the sync standby - Patroni will refuse if it is behind'))"
  t0="$(date +%s.%N)"
  patronictl -c "$PATRONI_CONF" switchover "$PG_SCOPE" --leader "$leader" --candidate "$cand" --force 2>&1 | sed 's/^/     /'
  for _ in $(seq 1 240); do
    j="$(patronictl -c "$PATRONI_CONF" list -f json 2>/dev/null || true)"
    now="$(date +%s.%N)"
    if [ -z "$tl" ] && printf '%s' "$j" | python3 -c 'import sys,json; m={x["Member"]:x for x in json.load(sys.stdin)}; x=m.get(sys.argv[1],{}); sys.exit(0 if x.get("Role")=="Leader" and x.get("State")=="running" else 1)' "$cand" 2>/dev/null; then
      tl="$(echo "$now - $t0" | bc -l)"
    fi
    if [ -n "$tl" ] && [ "$(cluster_verdict "$j" | cut -d' ' -f1)" = ok ]; then tr="$(echo "$now - $t0" | bc -l)"; break; fi
    sleep 0.5
  done
  patronictl -c "$PATRONI_CONF" list
  [ -n "$tl" ] || die "$cand did not become a running leader within 120 s"
  ok "$cand is the leader $(printf '%.1f' "$tl") s after the switchover was asked for"
  [ -n "$tr" ] && ok "every member healthy again (the old leader streaming, lag 0) after $(printf '%.1f' "$tr") s" \
               || warn "$cand leads, but the cluster was not fully healthy within 120 s - look at the list above"
}

cmd_leave() {
  need_root; whoami_pg
  local j v leader
  j="$(cluster_json)"
  v="$(cluster_verdict "$j" "$ME")"
  case "$v" in ok*) ;; *) patronictl -c "$PATRONI_CONF" list; die "refusing: without $ME the cluster must still be healthy, and it is not (${v#bad })" ;; esac
  read -r _ leader _ <<<"$v"
  [ "$leader" != "$ME" ] || die "$ME is the LEADER - hand it over first:  sudo $0 switchover"
  ETCDCTL_API=3 etcdctl --endpoints="$(client_endpoints)" --cacert "$ETCD_PKI/ca.crt" --cert "$ETCD_PKI/member.crt" \
    --key "$ETCD_PKI/member.key" endpoint health >/dev/null 2>&1 \
    || die "refusing: not every etcd member is healthy - taking $ME down could cost the quorum (etcd-check)"
  ok "$ME is not the leader ($leader is); the other two are healthy; all three etcd members healthy"
  systemctl stop patroni && ok "patroni stopped - PostgreSQL shut down with it"
  pgrep -u postgres -x postgres >/dev/null && die "a postgres process is still running after Patroni stopped - look before going further"
  systemctl stop etcd && ok "etcd stopped - two members keep the quorum"
  say "powering $ME off. Then, on its host:  sudo ./03-compose-vm.sh $ME --reserve-data"
  systemctl poweroff
}

# =========================================================================================
# SLICE 5 - BACKUP: pgBackRest 2.50, TLS both ways, two live stores (decided 2026-09-28)
#
#   pg-01..03 ─ each WAL file ─► host-4 (repo1, spare NVMe)  and  host-3 (repo2, images pool)
#   host-4 / host-3 ─ full / differential backups ─► reach INTO the primary
#
#   pgBackRest REQUIRES the backup command on the repository host, so traffic runs both ways and
#   every machine in it runs pgBackRest's TLS server on $PGBR_PORT: the stores accept the pg nodes'
#   certificates, the pg nodes accept the stores'. tls-server-auth names each certificate CN that
#   may use stanza $PG_SCOPE - nothing else gets in. Names, not addresses, on the client side:
#   the certificates carry DNS names, and every machine resolves the others from /etc/hosts.
#   Encryption is the volumes' LUKS underneath - no pgBackRest passphrase to hold (decided).
# =========================================================================================
PGBR_STANZA="$PG_SCOPE"

# store_lines -> "INDEX NAME ADDR PATH" per store, in repo order, from PG_BACKUP_STORES.
store_lines() {
  local i=0 st n k
  for st in $PG_BACKUP_STORES; do
    i=$((i + 1)); n="${st%%=*}"; k="$(printf '%s' "$n" | tr 'a-z-' 'A-Z_')"
    printf '%s %s %s %s\n' "$i" "$n" "${!k:-}" "${st#*=}"
  done
}

# install pgBackRest with its unit's self-start blocked: pgbackrest.service is `Restart=always`
# with no start limit, so a server started before its TLS settings exist would fail every second.
install_pgbackrest() {
  if ! dpkg -s pgbackrest >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod 0755 /usr/sbin/policy-rc.d
    DEBIAN_FRONTEND=noninteractive apt-get install -y pgbackrest \
      || { rm -f /usr/sbin/policy-rc.d; die "apt could not install pgbackrest"; }
    rm -f /usr/sbin/policy-rc.d
  fi
  ok "pgbackrest $(dpkg-query -W -f='${Version}' pgbackrest) installed"
  id postgres >/dev/null 2>&1 || die "no OS user postgres - pgbackrest's dependency should have made it"
  install -d -m 0750 -o postgres -g postgres "$PGBR_LOG"
}

# place_pgbr_pki FULLCHAIN KEY - the node certificate and a copy of its key, readable by postgres
place_pgbr_pki() {
  install -d -m 0750 -o root -g postgres "$PGBR_PKI"
  install -m 0644 -o root -g root "$CA_ROOT" "$PGBR_PKI/ca.crt"
  install -m 0644 -o root -g root "$1" "$PGBR_PKI/node.crt"
  install -m 0640 -o root -g postgres "$2" "$PGBR_PKI/node.key"
}

# start_pgbr_server ADDR - the TLS server, then PROVE it listens on this address only
start_pgbr_server() {
  systemctl enable pgbackrest >/dev/null 2>&1
  systemctl restart pgbackrest || die "pgbackrest (the TLS server) did not start - journalctl -u pgbackrest"
  local l=""
  for _ in $(seq 1 10); do l="$(ss -Htln "sport = :$PGBR_PORT" | awk '{print $4}' | sort -u | tr '\n' ' ')"; [ -n "$l" ] && break; sleep 1; done
  [ "$l" = "$1:$PGBR_PORT " ] || die "the pgBackRest server listens on '${l:-nothing}', expected $1:$PGBR_PORT only"
  ok "pgBackRest TLS server listening on $1:$PGBR_PORT only"
}

# render_pgbr_node NAME ADDR - a pg node's pgbackrest.conf
render_pgbr_node() {
  local i n a pth
  printf '# MANAGED by 06a-postgres-ha.sh backup-node (B-06a slice 5). Edits are overwritten.\n[global]\n'
  while read -r i n a pth; do
    printf 'repo%s-host=%s.%s\nrepo%s-host-type=tls\nrepo%s-host-port=%s\n' "$i" "$n" "${ENCLAVE_DOMAIN:-enclave.internal}" "$i" "$i" "$PGBR_PORT"
    printf 'repo%s-host-cert-file=%s/node.crt\nrepo%s-host-key-file=%s/node.key\nrepo%s-host-ca-file=%s/ca.crt\n' "$i" "$PGBR_PKI" "$i" "$PGBR_PKI" "$i" "$PGBR_PKI"
  done < <(store_lines)
  printf 'log-path=%s\nlog-level-file=info\n' "$PGBR_LOG"
  printf '# the stores reach in for backups - only their certificates, only this stanza\n'
  printf 'tls-server-address=%s\ntls-server-port=%s\n' "$2" "$PGBR_PORT"
  printf 'tls-server-cert-file=%s/node.crt\ntls-server-key-file=%s/node.key\ntls-server-ca-file=%s/ca.crt\n' "$PGBR_PKI" "$PGBR_PKI" "$PGBR_PKI"
  while read -r i n a pth; do printf 'tls-server-auth=%s.%s=%s\n' "$n" "${ENCLAVE_DOMAIN:-enclave.internal}" "$PGBR_STANZA"; done < <(store_lines)
  printf '\n[%s]\npg1-path=%s\npg1-socket-path=/var/run/postgresql\n' "$PGBR_STANZA" "$PG_DATA"
}

# render_pgbr_store INDEX ADDR PATH - a store's pgbackrest.conf
render_pgbr_store() {
  local k=0 kk
  printf '# MANAGED by 06a-postgres-ha.sh backup-store (B-06a slice 5). Edits are overwritten.\n[global]\n'
  printf 'repo%s-path=%s\nrepo%s-retention-full=%s\nrepo%s-retention-full-type=count\n' "$1" "$3" "$1" "$PGBR_RETENTION_FULL" "$1"
  printf 'start-fast=y\ncompress-type=zst\nprocess-max=2\nlog-path=%s\nlog-level-file=info\n' "$PGBR_LOG"
  printf '# the pg nodes push WAL here - only their certificates, only this stanza\n'
  printf 'tls-server-address=%s\ntls-server-port=%s\n' "$2" "$PGBR_PORT"
  printf 'tls-server-cert-file=%s/node.crt\ntls-server-key-file=%s/node.key\ntls-server-ca-file=%s/ca.crt\n' "$PGBR_PKI" "$PGBR_PKI" "$PGBR_PKI"
  for kk in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    printf 'tls-server-auth=%s.%s=%s\n' "$(printf '%s' "$kk" | tr 'A-Z_' 'a-z-')" "${ENCLAVE_DOMAIN:-enclave.internal}" "$PGBR_STANZA"
  done
  printf '\n[%s]\n' "$PGBR_STANZA"
  for kk in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    k=$((k + 1))
    printf 'pg%s-host=%s.%s\npg%s-host-type=tls\npg%s-host-port=%s\n' "$k" "$(printf '%s' "$kk" | tr 'A-Z_' 'a-z-')" "${ENCLAVE_DOMAIN:-enclave.internal}" "$k" "$k" "$PGBR_PORT"
    printf 'pg%s-host-cert-file=%s/node.crt\npg%s-host-key-file=%s/node.key\npg%s-host-ca-file=%s/ca.crt\n' "$k" "$PGBR_PKI" "$k" "$PGBR_PKI" "$k" "$PGBR_PKI"
    printf 'pg%s-path=%s\npg%s-socket-path=/var/run/postgresql\n' "$k" "$PG_DATA" "$k"
  done
}

# write_pgbr_conf < rendered text - 0640 root:postgres, atomically
write_pgbr_conf() {
  install -d -m 0755 "$(dirname "$PGBR_CONF")"
  cat > "$PGBR_CONF.new"; chown root:postgres "$PGBR_CONF.new"; chmod 0640 "$PGBR_CONF.new"
  mv -f "$PGBR_CONF.new" "$PGBR_CONF"
  ok "config: $PGBR_CONF"
}

pgbr() { runuser -u postgres -- pgbackrest --stanza="$PGBR_STANZA" "$@"; }

cmd_backup_node() {
  need_root; whoami_pg
  [ -n "$PG_BACKUP_STORES" ] || die "PG_BACKUP_STORES is empty (vm-specs.env) - where would the backups go?"
  local key="$SSL_DIR/$ME.key"
  [ -r "$ETCD_PKI/member.crt" ] && [ -r "$key" ] || die "no node certificate/key from slice 2"
  install_pgbackrest
  place_pgbr_pki "$ETCD_PKI/member.crt" "$key"
  render_pgbr_node "$ME" "$ME_ADDR" | write_pgbr_conf
  start_pgbr_server "$ME_ADDR"
  say "stores this node will push WAL to: $(store_lines | awk '{printf "repo%s=%s ", $1, $2}')"
}

# on a store: which one am I? - by address, like whoami_pg; never a typed name
whoami_store() {
  local i n a pth mine
  mine="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  while read -r i n a pth; do
    if [ -n "$a" ] && printf '%s\n' "$mine" | grep -qx "$a"; then
      ST_IDX="$i"; ST_NAME="$n"; ST_ADDR="$a"; ST_PATH="$pth"; return 0
    fi
  done < <(store_lines)
  die "this machine ($(hostname -s)) is not a backup store in PG_BACKUP_STORES ($PG_BACKUP_STORES)"
}

cmd_backup_store() {
  need_root; whoami_store
  local fc="${1:-}" key="$SSL_DIR/$ST_NAME.key" parent
  [ -n "$fc" ] && [ -r "$fc" ] || die "usage: sudo $0 backup-store <$ST_NAME.fullchain.crt from svc-mgmt-01>"
  [ -r "$key" ] || die "no key at $key - make it on THIS machine first: sudo $ENC/ca.sh request $ST_NAME"
  check_member_cert "$fc" "$key" "$ST_ADDR" "$CA_ROOT"
  # A STORE MUST NEVER LAND ON AN OS DISK: the repository's parent has to be its own mount.
  parent="$(dirname "$ST_PATH")"
  mountpoint -q "$parent" || die "$parent is not a mount point - the repository $ST_PATH would land on the OS disk.
       host-4: sudo ./03-host-services.sh cryptdisk first (CRYPT_DISKS in services-params.env)."
  install_pgbackrest
  # pgbackrest pulls postgresql-common, which ENABLES Debian's postgresql.service - on a store that
  # runs no PostgreSQL server that is a database unit enabled on a hypervisor, and nothing more.
  if ! dpkg -s postgresql-16 >/dev/null 2>&1 && systemctl is-enabled --quiet postgresql 2>/dev/null; then
    systemctl disable postgresql >/dev/null 2>&1 && ok "Debian's postgresql.service disabled - no PostgreSQL server on a store"
  fi
  install -d -m 0750 -o postgres -g postgres "$ST_PATH"
  ok "repository repo$ST_IDX: $ST_PATH on $parent ($(df -h --output=avail "$parent" | tail -1 | tr -d ' ') free)"
  place_pgbr_pki "$fc" "$key"
  render_pgbr_store "$ST_IDX" "$ST_ADDR" "$ST_PATH" | write_pgbr_conf
  start_pgbr_server "$ST_ADDR"
  # the stanza, created from HERE (the repository host): it reaches every pg node's server, finds
  # the primary and records the cluster's identity - so this also proves the TLS path store -> nodes.
  # (no --repo: stanza-create always works on every repository in the config - here, just this one.
  # And the failure message names no cause: the first version guessed "servers down" while the real
  # reason, an invalid option, was printed on the line above it. The output IS the diagnosis.)
  pgbr stanza-create 2>&1 | sed 's/^/     /' || die "stanza-create failed - the lines above say why"
  pgbr info 2>&1 | sed 's/^/     /'
  ok "store repo$ST_IDX on $ST_NAME ready - next: backup-enable on the primary, then backup-run here"
}

cmd_backup_enable() {
  need_root; whoami_pg
  local j v leader m
  j="$(cluster_json)"; v="$(cluster_verdict "$j")"
  case "$v" in ok*) ;; *) patronictl -c "$PATRONI_CONF" list; die "the cluster is not healthy (${v#bad }) - a rolling restart now is not safe" ;; esac
  read -r _ leader _ <<<"$v"
  [ "$leader" = "$ME" ] || die "run this on the primary - $leader is the leader"
  # ---- the settings, in the DCS - where a running cluster's parameters live ----
  # config.yml's bootstrap section applies only when a cluster is first created (render_patroni
  # carries the same values so a rebuild has them); an existing cluster changes through the DCS.
  patronictl -c "$PATRONI_CONF" edit-config "$PG_SCOPE" --force \
    -s "postgresql.parameters.archive_mode=on" \
    -s "postgresql.parameters.archive_command=$PGBR_ARCHIVE_CMD" \
    -s "postgresql.parameters.archive_timeout=$PG_ARCHIVE_TIMEOUT" 2>&1 | sed 's/^/     /'
  ok "DCS: archive_mode=on, archive_command='$PGBR_ARCHIVE_CMD', archive_timeout=$PG_ARCHIVE_TIMEOUT"
  sleep 12   # one Patroni loop: every member notices the change and flags a pending restart
  # ---- archive_mode needs a RESTART: replicas one at a time, the leader last ----
  for m in $(printf '%s' "$j" | python3 -c 'import sys,json; print(" ".join(x["Member"] for x in json.load(sys.stdin) if x.get("Role")!="Leader"))'); do
    say "restarting $m (a replica)"
    patronictl -c "$PATRONI_CONF" restart "$PG_SCOPE" "$m" --force 2>&1 | sed 's/^/     /'
    for _ in $(seq 1 60); do
      [ "$(cluster_verdict "$(cluster_json)" | cut -d' ' -f1)" = ok ] && break; sleep 2
    done
    [ "$(cluster_verdict "$(cluster_json)" | cut -d' ' -f1)" = ok ] || die "$m did not come back healthy in 120 s - stopping the rolling restart here"
    ok "$m back, streaming"
  done
  say "restarting $leader (the leader - writes pause for a few seconds)"
  patronictl -c "$PATRONI_CONF" restart "$PG_SCOPE" "$leader" --force 2>&1 | sed 's/^/     /'
  for _ in $(seq 1 60); do [ "$(cluster_verdict "$(cluster_json)" | cut -d' ' -f1)" = ok ] && break; sleep 2; done
  [ "$(cluster_verdict "$(cluster_json)" | cut -d' ' -f1)" = ok ] || die "the cluster is not healthy after the leader's restart - look: patronictl list"
  patronictl -c "$PATRONI_CONF" list
  [ "$(pg_sql "SHOW archive_mode")" = on ] || die "archive_mode is not on after the restart"
  ok "archive_mode = on, applied (no restart pending)"
  # ---- PROVE it: pgBackRest's own check forces a WAL switch and waits for it in EVERY repo ----
  pgbr check 2>&1 | sed 's/^/     /' || die "pgbackrest check failed - the lines above say which store and why"
  ok "a WAL file was archived to every store (pgbackrest check)"
}

cmd_backup_run() {
  need_root; whoami_store
  local type="${1:-full}" u
  case "$type" in full|diff) ;; *) die "usage: sudo $0 backup-run [full|diff]" ;; esac
  say "a $type backup to repo$ST_IDX now - reaching into the primary"
  pgbr --repo="$ST_IDX" --type="$type" backup 2>&1 | sed 's/^/     /' || die "the backup failed - the lines above say why"
  pgbr info 2>&1 | sed 's/^/     /'
  # ---- the timers: the weekly full, differentials the other days, stores an hour apart ----
  local hh; hh="$(printf '%02d' "$ST_IDX")"
  for u in full diff; do
    printf '[Unit]\nDescription=pgBackRest %s backup of %s to repo%s (06a, B-06a slice 5)\nAfter=network-online.target pgbackrest.service\n[Service]\nType=oneshot\nUser=postgres\nExecStart=/usr/bin/pgbackrest --stanza=%s --repo=%s --type=%s backup\n' \
      "$u" "$PGBR_STANZA" "$ST_IDX" "$PGBR_STANZA" "$ST_IDX" "$u" > "/etc/systemd/system/pgbackrest-$u.service"
    if [ "$u" = full ]; then
      printf '[Unit]\nDescription=weekly full backup (06a)\n[Timer]\nOnCalendar=%s *-*-* %s:%s:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' "$PGBR_FULL_DAY" "$hh" "$PGBR_BACKUP_MINUTE" > "/etc/systemd/system/pgbackrest-$u.timer"
    else
      printf '[Unit]\nDescription=daily differential backup (06a)\n[Timer]\nOnCalendar=%s *-*-* %s:%s:00\nPersistent=true\n[Install]\nWantedBy=timers.target\n' "$(printf 'Mon Tue Wed Thu Fri Sat Sun' | tr ' ' '\n' | grep -vx "$PGBR_FULL_DAY" | tr '\n' ',' | sed 's/,$//')" "$hh" "$PGBR_BACKUP_MINUTE" > "/etc/systemd/system/pgbackrest-$u.timer"
    fi
    chmod 0644 "/etc/systemd/system/pgbackrest-$u.service" "/etc/systemd/system/pgbackrest-$u.timer"
  done
  systemctl daemon-reload
  systemctl enable --now pgbackrest-full.timer pgbackrest-diff.timer >/dev/null 2>&1 || die "could not enable the backup timers"
  systemctl list-timers 'pgbackrest-*' --no-pager | sed 's/^/     /'
  ok "repo$ST_IDX: full on $PGBR_FULL_DAY, differential the other days, at $hh:$PGBR_BACKUP_MINUTE; $PGBR_RETENTION_FULL fulls kept"
}

# ---- the proof: a point-in-time restore from EACH store (B-06a slice 5) --------------------------
# A backup nobody has restored from is a hope. On the primary: a throwaway database gets a row
# 'before-target', the time T is taken, a row 'after-target' follows, and that WAL is archived. Then,
# from each store in turn, the backup + WAL are restored TO T into a scratch directory on the data
# disk - never the live one - started as a throwaway instance on a private socket with archiving
# OFF (a promoted copy must never push its new timeline into the real stores), and read: it must
# hold 'before-target' and NOT 'after-target'. Everything it made is removed afterwards.
PITR_PROBE_DB="${PITR_PROBE_DB:-pitr_probe}"
PITR_PORT="${PITR_PORT:-5499}"
cmd_backup_restore_test() {
  need_root; whoami_pg
  local j v leader scratch="$PG_MNT/pitr-restore-test" sockd="$PG_MNT/pitr-restore-sock" T seg i n a pth rows rc
  j="$(cluster_json)"; v="$(cluster_verdict "$j")"
  case "$v" in ok*) ;; *) die "the cluster is not healthy (${v#bad }) - fix that first" ;; esac
  read -r _ leader _ <<<"$v"
  [ "$leader" = "$ME" ] || die "run this on the primary - $leader is the leader"
  [ "$scratch" != "$PG_DATA" ] && [ "${scratch#"$PG_DATA"}" = "$scratch" ] || die "the scratch path overlaps the live data directory - refusing"
  [ ! -e "$scratch" ] || die "$scratch exists - a previous test left it. Look, then remove it by hand."
  [ "$(pg_sql "SELECT count(*) FROM pg_database WHERE datname='$PITR_PROBE_DB'")" = 0 ] || die "database $PITR_PROBE_DB exists - a previous test left it. Look, then drop it by hand."
  pdb() { runuser -u postgres -- psql -X -A -t -q -v ON_ERROR_STOP=1 -d "$PITR_PROBE_DB" -c "$1"; }
  # ---- 1. the marker ----
  pg_sql "CREATE DATABASE $PITR_PROBE_DB" >/dev/null
  pdb "CREATE TABLE probe (v text, at timestamptz DEFAULT clock_timestamp())"
  pdb "INSERT INTO probe (v) VALUES ('before-target')"
  sleep 2; T="$(pg_sql "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US')")+00"; sleep 2
  pdb "INSERT INTO probe (v) VALUES ('after-target')"
  seg="$(pg_sql "SELECT pg_walfile_name(pg_switch_wal())")"
  ok "marker: 'before-target', then T = $T, then 'after-target' - in WAL $seg"
  for _ in $(seq 1 60); do
    [ "$(pg_sql "SELECT coalesce(last_archived_wal,'') >= '$seg' FROM pg_stat_archiver")" = t ] && break; sleep 1
  done
  [ "$(pg_sql "SELECT coalesce(last_archived_wal,'') >= '$seg' FROM pg_stat_archiver")" = t ] || die "$seg was not archived within 60 s - pg_stat_archiver says: $(pg_sql "SELECT failed_count||' failures, last '||coalesce(last_failed_wal,'-') FROM pg_stat_archiver")"
  ok "$seg archived to the stores"
  # ---- 2. restore to T from EACH store, and read it ----
  rc=0
  while read -r i n a pth; do
    install -d -m 0700 -o postgres -g postgres "$scratch" "$sockd"
    say "repo$i ($n): restoring to $T into $scratch"
    runuser -u postgres -- pgbackrest --stanza="$PGBR_STANZA" --repo="$i" --pg1-path="$scratch" \
      --type=time --target="$T" --target-action=promote restore 2>&1 | sed 's/^/     /' \
      || { rm -rf "$scratch" "$sockd"; rc=1; warn "repo$i: the restore failed - the lines above say why"; continue; }
    say "     restore_command written: $(grep -h '^restore_command' "$scratch/postgresql.auto.conf" | cut -c1-140)"
    runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$scratch" -w -t 180 -l "$scratch.log" \
      -o "-p $PITR_PORT -c listen_addresses='' -c unix_socket_directories='$sockd' -c archive_mode=off -c archive_command='' -c synchronous_standby_names='' -c ssl=off -c logging_collector=off -c log_destination=stderr" start >/dev/null \
      || { tail -20 "$scratch.log" | sed 's/^/     /'; rm -rf "$scratch" "$sockd" "$scratch.log"; rc=1; warn "repo$i: the restored copy did not start - its log is above"; continue; }
    for _ in $(seq 1 60); do
      [ "$(runuser -u postgres -- psql -X -A -t -h "$sockd" -p "$PITR_PORT" -d postgres -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" = f ] && break; sleep 1
    done
    rows="$(runuser -u postgres -- psql -X -A -t -h "$sockd" -p "$PITR_PORT" -d "$PITR_PROBE_DB" -c "SELECT string_agg(v, ',' ORDER BY at) FROM probe" 2>&1)"
    runuser -u postgres -- "$PG_BIN/pg_ctl" -D "$scratch" -m fast -w stop >/dev/null 2>&1 || true
    rm -rf "$scratch" "$sockd" "$scratch.log"
    if [ "$rows" = before-target ]; then
      ok "repo$i ($n): restored to T - 'before-target' present, 'after-target' absent. Point-in-time restore PROVEN"
    else
      rc=1; warn "repo$i ($n): the restored copy holds '$rows' - expected exactly 'before-target'"
    fi
  done < <(store_lines)
  # ---- 3. leave nothing behind ----
  pg_sql "DROP DATABASE $PITR_PROBE_DB" >/dev/null && ok "database $PITR_PROBE_DB dropped; scratch removed"
  [ "$rc" -eq 0 ] || die "the restore test FAILED for at least one store - see above"
}

# =========================================================================================
# SLICE 6 PREP - THE APPLICATION'S DATABASE, AND NONE OF ITS CONTENT ON ANY SCREEN (2026-09-29)
#
#   The application's dump holds real people's records. It is restored at full size because that
#   is the real test of slice 5 (backup time, WAL volume) and what the slice-6 STIG scan must see
#   (the real roles, grants and ownership). Everything these subcommands PRINT is numbers - sizes,
#   times, counts, error counts by SQLSTATE - so their output is safe to paste anywhere. Rows
#   exist in two places only:
#     * the database itself;
#     * the load log under $APP_LOG_DIR, root 0600 - psql quotes the offending ROW in a failed
#       COPY's CONTEXT line, so its full output never goes to a terminal.
#   The load session keeps rows out of the PostgreSQL log and the audit trail too (all three
#   are superuser-settable, per session):
#     pgaudit.log=$APP_LOAD_PGAUDIT        DDL and role changes still audited; COPY/INSERT not, so
#                                          an INSERT-format dump's values never enter the audit log
#     log_min_messages=log                 the session's ERRORs - which quote the bad VALUE - are
#                                          not written; pgaudit's LOG-level entries still are
#     log_min_error_statement=panic        and no statement text with an error
#   `rehearse` proves all of it with a made-up dump carrying a unique marker row, before a real
#   dump is touched: the marker must reach the load log and must NOT reach the screen, the
#   PostgreSQL log or syslog - while this run's DDL must still reach the audit (the control).
#
#   Plain-SQL, ONE database. A pg_dump --create dump (CREATE DATABASE + \connect at the top - how
#   the application's arrived) loads under the name you give: its CREATE DATABASE and \connect are
#   skipped (its locale does not exist here anyway) and its ALTER DATABASE / GRANT ... ON DATABASE
#   lines are pointed at the new database. The original name is never printed - it may name the
#   client. A cluster dump (pg_dumpall, several databases) is refused.
# =========================================================================================
APP_LOG_DIR="${APP_LOG_DIR:-/var/log/enclave-app-restore}"
PG_EXTENSION_PACKAGES="${PG_EXTENSION_PACKAGES:-$(awk -F"'" '/^PG_EXTENSION_PACKAGES=/{print $2}' "$ENC/vm-specs.env" 2>/dev/null)}"
APP_LOAD_PGAUDIT="${APP_LOAD_PGAUDIT:-ddl,role}"
APP_SPACE_FACTOR="${APP_SPACE_FACTOR:-4}"        # free bytes needed on the data disk per byte of dump
APP_REHEARSAL_DB="${APP_REHEARSAL_DB:-app_rehearsal}"
# The stream between the dump and psql. Passes every byte through EXCEPT, for a pg_dump --create
# dump (APP_ORIG_DB set - by environment, not argv, so the name is not in the process list):
# its CREATE DATABASE and \connect become comments, and DATABASE <original> in ALTER DATABASE /
# COMMENT / GRANT / REVOKE / SECURITY LABEL lines becomes the new name. COPY data and INSERT
# statements are never touched. And for CREATE EXTENSION postgis*: pgaudit.log is set to 'none' for
# that one statement and restored right after (APP_AUDIT) - PostGIS's installer REFUSES to run under
# pgaudit (P0001 'Set pgaudit.log to none before installing PostGIS'; the first real load, 2026-09-29).
# A bounded, recorded audit exception: the load log shows every place it applied.
APP_FILTER_PY="$(cat <<'FILTERPY'
import os, re, sys
orig, new = os.environ.get("APP_ORIG_DB", "").encode(), os.environ["APP_NEW_DB"].encode()
audit = os.environ.get("APP_AUDIT", "ddl,role").encode()
out = sys.stdout.buffer; in_copy = in_insert = False
for raw in sys.stdin.buffer:
    if in_copy:
        in_copy = raw.rstrip(b"\r\n") != b"\\."
    elif in_insert:
        in_insert = not raw.rstrip().endswith(b");")
    elif raw.startswith(b"INSERT INTO "):
        in_insert = not raw.rstrip().endswith(b");")
    elif raw.startswith(b"COPY ") and raw.rstrip(b"\r\n").endswith(b" FROM stdin;"):
        in_copy = True
    elif re.match(rb"CREATE EXTENSION (IF NOT EXISTS )?\"?postgis", raw):
        raw = (b"SET pgaudit.log = 'none';  -- [06a app-restore] PostGIS will not install under pgaudit\n" + raw
               + b"SET pgaudit.log = '" + audit + b"';  -- [06a app-restore] audit restored\n")
    elif orig and raw.startswith((b"CREATE DATABASE ", b"\\connect ")):
        raw = b"-- [06a app-restore] skipped the dump's own " + (b"CREATE DATABASE" if raw.startswith(b"CREATE") else b"\\connect") + b"\n"
    elif orig and raw.startswith((b"ALTER DATABASE ", b"COMMENT ON DATABASE ", b"GRANT ", b"REVOKE ", b"SECURITY LABEL ")):
        raw = re.sub(rb"\bDATABASE " + re.escape(orig) + rb"(?=[\s;])", b"DATABASE " + new, raw)
    out.write(raw)
FILTERPY
)"
APP_REHEARSING="${APP_REHEARSING:-0}"             # set by `rehearse` for its own load run

app_file_ok() {
  local f="${1:-}" r
  [ -n "$f" ] || die "name the dump file"
  [ -f "$f" ] && [ ! -L "$f" ] || die "$f: not a regular file, or a symlink - refusing"
  r="$(readlink -f "$f")"
  case "$r" in "$PG_MNT"/*|/etc/*|/usr/*) die "$r is under $PG_MNT, /etc or /usr - a dump belongs in a home or temp directory" ;; esac
  chmod 0600 "$r"
}

# app_census FILE [NAMES_OUT] - reads the dump, prints numbers only. The names of roles that would
# have to be created go to NAMES_OUT (a root-only temp file of load's), never to the screen.
# Returns 3 when this script will not load the file.
app_census() {
  local f="$1" out="${2:-/dev/null}" tmp rc=0
  tmp="$(mktemp -d)"
  pg_sql "SELECT rolname FROM pg_roles" > "$tmp/roles"
  pg_sql "SELECT name FROM pg_available_extensions" > "$tmp/exts"
  pg_sql "SELECT collname FROM pg_collation" > "$tmp/colls"
  python3 - "$f" "$tmp/roles" "$tmp/exts" "$tmp/colls" "$out" "$(psql --version | awk '{print $3}')" <<'CENSUSPY' || rc=$?
import collections, os, re, sys
path, roles_f, exts_f, colls_f, out_f, psqlv = sys.argv[1:7]
rd = lambda p: {l.rstrip("\n") for l in open(p, encoding="utf-8", errors="replace") if l.strip()}
existing, available, collations = rd(roles_f), rd(exts_f), rd(colls_f)
if not existing or not available:
    print("  [x] could not read this cluster's roles or extensions - is PostgreSQL up here?"); sys.exit(3)
# Vendor and platform roles are products, not people - the only role names ever printed.
VENDOR = re.compile(r"^(azure|pg_|rds|cloudsql|alloydb)|^(postgres|replication)$")
NOTROLE = {"public", "current_user", "session_user", "current_role", "group", "default", "none"}
TOK = r'"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*'
unq = lambda t: t[1:-1].replace('""', '"') if t.startswith('"') else t.lower()
def names(s):
    s = re.split(r"\s+(?:WITH\s+\w+\s+(?:OPTION|TRUE|FALSE)|CASCADE|RESTRICT)\b", s.rstrip().rstrip(";"))[0]
    return [unq(t) for t in re.findall(TOK, s) if t.startswith('"') or t.lower() not in NOTROLE]
c = collections.Counter(); refs, defined, colls, hdr, exts = set(), set(), set(), {}, []
in_copy = in_insert = False; this = 0; srcdb = None; dbopts = {}; cur = None; spatial = set(); copy_spatial = False
SPATIAL = re.compile(r"\b(?:public\.)?(?:geometry|geography|raster|topogeometry)\b")
with open(path, "rb") as fh:
    for raw in fh:
        c["lines"] += 1
        if in_copy:                                   # COPY data: rows, counted and never parsed
            if raw.rstrip(b"\r\n") == b"\\.":
                in_copy = False; c["tables_with_rows"] += 1 if this else 0
            else:
                c["rows"] += 1; this += 1; c["spatial_rows"] += copy_spatial
                # pg_dump escapes a CR inside a value as \r, so a raw CR ending a ROW was added in
                # transit - and would land in the row's last column. That is what refuses a load.
                c["crlf_copy"] += raw.endswith(b"\r\n")
            continue
        c["crlf_text"] += raw.endswith(b"\r\n")      # inside the dump's own SQL text: kept as written
        l = raw.decode("utf-8", "replace").rstrip("\r\n")
        if in_insert:                                 # a multi-line INSERT value: data, not parsed
            in_insert = not l.rstrip().endswith(");"); continue
        if l.startswith("INSERT INTO "):
            c["insert"] += 1; in_insert = not l.rstrip().endswith(");"); continue
        if l.startswith("COPY ") and l.endswith(" FROM stdin;"):
            m = re.match(r"COPY ((?:" + TOK + r")(?:\.(?:" + TOK + r"))?)", l)
            copy_spatial = bool(m and m.group(1) in spatial)
            in_copy = True; this = 0; c["copy"] += 1; continue
        m = re.match(r"CREATE (?:UNLOGGED )?TABLE ((?:" + TOK + r")(?:\.(?:" + TOK + r"))?) \($", l)
        if m: cur = m.group(1)                        # inside a table definition until its ")" line
        elif cur and l.startswith(")"): cur = None
        elif cur and SPATIAL.search(l): spatial.add(cur)
        if l.startswith("--"):
            m = re.match(r"-- Dumped from database version (\S+)", l); hdr.update({"from": m.group(1)} if m else {})
            m = re.match(r"-- Dumped by pg_dump version (\S+)", l); hdr.update({"by": m.group(1)} if m else {})
            c["cluster_header"] += l.startswith("-- PostgreSQL database cluster dump")
            continue
        for k, rx in (("table", r"CREATE (UNLOGGED )?TABLE "), ("schema", r"CREATE SCHEMA "),
                      ("index", r"CREATE (UNIQUE )?INDEX "), ("function", r"CREATE (OR REPLACE )?(FUNCTION|PROCEDURE|AGGREGATE) "),
                      ("view", r"CREATE (OR REPLACE )?(MATERIALIZED )?VIEW "), ("trigger", r"CREATE (CONSTRAINT )?TRIGGER "),
                      ("policy", r"CREATE POLICY "), ("sequence", r"CREATE SEQUENCE "), ("create_db", r"CREATE DATABASE "),
                      ("connect", r"\\connect "), ("restrict", r"\\restrict ")):
            if re.match(rx, l): c[k] += 1
        m = re.match(r"CREATE DATABASE (" + TOK + r")(.*)", l)
        if m:                                         # pg_dump --create: keep the token, print only its settings
            srcdb = m.group(1)
            for k in ("ENCODING", "LOCALE_PROVIDER", "LOCALE", "LC_COLLATE", "ICU_LOCALE"):
                mm = re.search(r"\b" + k + r" = '?([^' ;]+)'?", m.group(2))
                if mm: dbopts[k.lower()] = mm.group(1)
        m = re.match(r"CREATE EXTENSION (?:IF NOT EXISTS )?(" + TOK + ")", l)
        if m: exts.append(unq(m.group(1)))
        m = re.match(r"CREATE ROLE (" + TOK + ")", l)
        if m: defined.add(unq(m.group(1))); c["create_role"] += 1
        if re.match(r"(CREATE|ALTER) ROLE ", l) and " PASSWORD " in l: c["password"] += 1
        for m in re.finditer(r"\bCOLLATE (?:pg_catalog\.)?(" + TOK + ")", l):
            colls.add(m.group(1)[1:-1] if m.group(1).startswith('"') else m.group(1))
        for m in re.finditer(r"\bOWNER TO (" + TOK + ")", l): refs.update(names(m.group(1)))
        for m in re.finditer(r"\b(?:FOR ROLE|FOR USER|GRANTED BY|AUTHORIZATION|SET ROLE|USER MAPPING FOR) (" + TOK + ")", l):
            refs.update(names(m.group(1)))
        m = re.match(r"SET SESSION AUTHORIZATION '((?:[^']|'')+)'", l)
        if m: refs.add(m.group(1).replace("''", "'"))
        if l.startswith(("GRANT ", "REVOKE ", "ALTER DEFAULT PRIVILEGES ")):
            kw = " FROM " if re.search(r"(^|\s)REVOKE\s", l) else " TO "
            i = l.rfind(kw)
            if i >= 0: refs.update(names(l[i + len(kw):].split(" GRANTED BY ")[0]))
def human(b):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or u == "TB": return ("%d %s" % (b, u)) if u == "B" else ("%.1f %s" % (b, u))
        b /= 1024.0
n = lambda x: "{:,}".format(x)
P = lambda k, v: print("     %-11s %s" % (k, v))
allroles = refs | defined
missing = sorted((refs - existing) - defined)
vendor = sorted(r for r in allroles if VENDOR.search(r))
print("  census (numbers only - safe to paste):")
P("source", "PostgreSQL %s, dumped by pg_dump %s" % (hdr.get("from", "?"), hdr.get("by", "?")))
if srcdb: P("database", "the dump creates its own (pg_dump --create, name not shown): %s - it loads under the name you give" % (", ".join("%s %s" % kv for kv in dbopts.items()) or "no settings"))
P("size", "%s, %s lines" % (human(os.path.getsize(path)), n(c["lines"])))
P("rows", "%s in %s COPY blocks (%s tables with rows); %s INSERT statements" % (n(c["rows"]), n(c["copy"]), n(c["tables_with_rows"]), n(c["insert"])))
P("objects", "%d schemas, %d tables, %d indexes, %d functions, %d views, %d triggers, %d policies, %d sequences" % tuple(c[k] for k in ("schema", "table", "index", "function", "view", "trigger", "policy", "sequence")))
P("extensions", ", ".join("%s (%s)" % (e, "available" if e in available else "NOT AVAILABLE here") for e in exts) or "none")
odd = [x for x in colls if x not in collations and x != "default"]
P("collations", "%d referenced, %d not on this node%s" % (len(colls), len(odd), " - those objects will fail to create" if odd else ""))
P("roles", "%d referenced - vendor/platform: %s; application: %d (names not shown)" % (len(allroles), ", ".join(vendor) or "none", len(allroles) - len(vendor)))
P("", "%d already on this cluster; %d would be created NOLOGIN" % (len(allroles & existing), len(missing)))
if c["create_role"]: P("", "%d CREATE ROLE in the file, %d carrying a password" % (c["create_role"], c["password"]))
if c["restrict"]:
    ok = tuple(int(x) for x in re.findall(r"\d+", psqlv)[:2]) >= (16, 10)
    P("psql", "the dump uses \\restrict (pg_dump 16.10+/17.6+); psql %s here %s" % (psqlv, "understands it" if ok else "does NOT - upgrade postgresql-client-16"))
if spatial: P("PostGIS", "%d tables have PostGIS columns, holding %s rows - without PostGIS they and their rows fail to load" % (len(spatial), n(c["spatial_rows"])))
if c["crlf_copy"]: P("line ends", "CRLF on %s DATA rows - added in transit" % n(c["crlf_copy"]))
elif c["crlf_text"]: P("line ends", "LF; CRLF on %s lines of the dump's own SQL text (function or comment source written on Windows) - kept as written, harmless" % n(c["crlf_text"]))
else: P("line ends", "LF")
why = []
if c["cluster_header"] or c["create_db"] > 1:
    why.append("a cluster dump (pg_dumpall), %d databases - one database per load" % c["create_db"])
elif c["connect"] and not c["create_db"]:
    why.append("it switches database (\\connect) without creating one")
if c["crlf_copy"]: why.append("Windows line endings on data rows - re-send it in BINARY mode (an ASCII transfer rewrote it)")
if in_copy: why.append("it ends inside a COPY block - the file is truncated")
if c["lines"] == 0: why.append("it is empty")
if why:
    print("  [x] this script will NOT load it: " + "; ".join(why)); sys.exit(3)
if out_f != "/dev/null":
    with open(out_f, "w", encoding="utf-8") as o: o.write("".join(r + "\n" for r in missing))
    if srcdb:
        with open(out_f + ".dbname", "w", encoding="utf-8") as o: o.write(srcdb)
print("  [ok] loadable: one database, rows as %s%s" % ("COPY" if c["copy"] else "INSERT" if c["insert"] else "none (schema only)",
      " - its CREATE DATABASE and \\connect will be skipped, its ALTER DATABASE lines pointed at the new one" if srcdb else ""))
CENSUSPY
  rm -rf "$tmp"
  return "$rc"
}

# app_summary LOG SECONDS - the load log, reduced to numbers.
app_summary() {
  python3 - "$1" "$2" <<'SUMMARYPY'
import collections, re, sys
log, secs = sys.argv[1], sys.argv[2]
NAME = {"42704": "undefined_object - a role, type or collation that does not exist",
        "42P01": "undefined_table", "42883": "undefined_function",
        "58P01": "undefined_file", "0A000": "feature_not_supported - e.g. an extension not available here (measured live 2026-09-29)",
        "42501": "insufficient_privilege", "42710": "duplicate_object", "42P07": "duplicate_table",
        "42601": "syntax_error", "22P02": "invalid_text_representation - a value its column rejects",
        "23505": "unique_violation", "23503": "foreign_key_violation", "23502": "not_null_violation",
        "22021": "character_not_in_repertoire", "42P16": "invalid_table_definition",
        "?????": "(no SQLSTATE - read the load log)",
        "psql": "psql itself, not the server - e.g. 'invalid command' after a COPY whose table was missing"}
# psql prefixes "psql:<stdin>:LINE: " only when it reads a file (-f); piped input gets none. Accept
# both - and count an error line with no readable SQLSTATE rather than let it vanish: the first
# live rehearsal (2026-09-29) reported "0 errors, a clean load" because every error lacked the prefix.
codes = collections.Counter(); copies = rows = warns = 0
for l in open(log, encoding="utf-8", errors="replace"):
    m = re.match(r"(?:psql:\S*: )?(?:ERROR|FATAL):\s+(?:([0-9A-Z]{5}):)?", l)
    if m: codes[m.group(1) or "?????"] += 1; continue
    if re.match(r"(?:psql:\S*: )?WARNING:", l): warns += 1; continue
    # psql's OWN errors carry no ERROR: - e.g. 'invalid command \.' when a COPY's table was missing
    if re.match(r"psql:\S*: (?!(?:ERROR|FATAL|WARNING|NOTICE|INFO|DETAIL|HINT|CONTEXT|LOCATION|STATEMENT):)", l):
        codes["psql"] += 1; continue
    m = re.fullmatch(r"COPY (\d+)\n?", l)
    if m: copies += 1; rows += int(m.group(1))
print("  load (numbers only - safe to paste):")
print("     %-11s %s" % ("time", secs + " s" if secs else "not recorded in this log (a load before 2026-09-29 22:30Z)"))
print("     %-11s %s loaded by %d COPY statements" % ("rows", "{:,}".format(rows), copies))
print("     %-11s %d%s" % ("errors", sum(codes.values()), "" if codes else " - a clean load"))
for k, v in sorted(codes.items(), key=lambda x: -x[1]):
    print("     %-11s %5d x %s %s" % ("", v, k.ljust(5), NAME.get(k, "- read the load log")))
print("     %-11s %d" % ("warnings", warns))
SUMMARYPY
}

app_load() {
  need_root; whoami_pg
  local f="${1:-}" db="${2:-}" j v leader tmp log size free need made=0 t0 secs lsn0 a0 a1 seg rc=0 opts orig=""
  [ -n "$f" ] && [ -n "$db" ] || die "usage: sudo $0 app-restore load <file> <database>"
  printf '%s' "$db" | grep -qxE '[a-z_][a-z0-9_]{0,62}' || die "database name '$db': lower-case letters, digits and _ only"
  j="$(cluster_json)"; v="$(cluster_verdict "$j")"
  case "$v" in ok*) ;; *) die "the cluster is not healthy (${v#bad }) - fix that first" ;; esac
  read -r _ leader _ <<<"$v"
  [ "$leader" = "$ME" ] || die "run this on the leader - $leader leads, $ME is a standby"
  [ "$(pg_sql "SELECT count(*) FROM pg_database WHERE datname='$db'")" = 0 ] \
    || die "database $db already exists - a load goes into a NEW database only. If it is a failed earlier attempt, look, then drop it by hand."
  app_file_ok "$f"; f="$(readlink -f "$f")"
  size="$(stat -c %s "$f")"; free="$(df -B1 --output=avail "$PG_MNT" | tail -1 | tr -d ' ')"; need=$(( size * APP_SPACE_FACTOR ))
  [ "$free" -ge "$need" ] || die "$PG_MNT has $(numfmt --to=iec "$free")B free; a $(numfmt --to=iec "$size")B dump wants $(numfmt --to=iec "$need")B (x$APP_SPACE_FACTOR)"
  umask 077
  install -d -m 0700 "$APP_LOG_DIR"
  tmp="$(mktemp -d)"
  app_census "$f" "$tmp/missing" || { rm -rf "$tmp"; die "not loaded - the census says why, above"; }
  [ -s "$tmp/missing.dbname" ] && orig="$(cat "$tmp/missing.dbname")"
  log="$APP_LOG_DIR/$db-$(date -u +%Y%m%dT%H%M%SZ).log"
  : > "$log"; chmod 0600 "$log"
  # ---- 1. the roles it refers to, as NOLOGIN - names passed to psql on stdin, never printed ----
  if [ -s "$tmp/missing" ]; then
    made="$(wc -l < "$tmp/missing")"
    python3 -c '
import sys
for n in open(sys.argv[1], encoding="utf-8"):
    n = n.rstrip("\n")
    if n: print("CREATE ROLE \"%s\" NOLOGIN CONNECTION LIMIT 0;" % n.replace("\"", "\"\""))' "$tmp/missing" > "$tmp/roles.sql"
    runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres < "$tmp/roles.sql" >> "$log" 2>&1 \
      || { rm -rf "$tmp"; die "creating the $made missing roles failed - the reason is in $log (root only)"; }
    ok "$made role(s) the dump refers to created NOLOGIN (names not shown)"
  fi
  rm -rf "$tmp"
  # ---- 2. the database and the load ----
  pg_sql "CREATE DATABASE $db TEMPLATE template0" >/dev/null
  lsn0="$(pg_sql "SELECT pg_current_wal_lsn()")"; a0="$(pg_sql "SELECT archived_count||' '||failed_count FROM pg_stat_archiver")"
  # client_min_messages=warning: the cluster default is error (V-261908), which would hide the
  # warnings this summary counts. statement_timeout=0: one COPY of a large table may run past the
  # cluster's 60 min - a superuser maintenance session, bounded by the load itself.
  opts="-c pgaudit.log=$APP_LOAD_PGAUDIT -c log_min_messages=log -c log_min_error_statement=panic -c client_min_messages=warning -c statement_timeout=0"
  say "loading into $db - the full psql output goes to $log (root 0600: it can quote rows)"
  t0="$(date +%s)"
  APP_ORIG_DB="$orig" APP_NEW_DB="$db" APP_AUDIT="$APP_LOAD_PGAUDIT" python3 -c "$APP_FILTER_PY" < "$f" 2>> "$log" \
    | runuser -u postgres -- env PGOPTIONS="$opts" psql -X -v ON_ERROR_STOP=0 -v VERBOSITY=verbose -d "$db" -f - >> "$log" 2>&1 || rc=$?
  secs=$(( $(date +%s) - t0 ))
  printf -- '-- [06a app-restore] load seconds=%s exit=%s\n' "$secs" "$rc" >> "$log"   # so `summary` can reprint it
  [ "$rc" -eq 0 ] || warn "psql itself exited $rc (a lost connection or a fatal error, not a failed statement) - the load is INCOMPLETE; the log says where it stopped"
  app_summary "$log" "$secs"
  runuser -u postgres -- psql -X -q -d "$db" -c ANALYZE >> "$log" 2>&1 || warn "ANALYZE failed - see $log"
  # ---- 3. what it made: numbers from the catalog, never from the application's tables ----
  say "   database    $(pg_sql "SELECT pg_size_pretty(pg_database_size('$db'))||', '||pg_encoding_to_char(encoding)||', collation '||datcollate FROM pg_database WHERE datname='$db'")"
  say "   catalog     $(runuser -u postgres -- psql -X -A -t -q -d "$db" -c "SELECT count(*) FILTER (WHERE c.relkind IN ('r','p'))||' tables, '||count(*) FILTER (WHERE c.relkind='i')||' indexes, '||count(*) FILTER (WHERE c.relkind IN ('v','m'))||' views' FROM pg_class c JOIN pg_namespace s ON s.oid=c.relnamespace WHERE s.nspname NOT IN ('pg_catalog','information_schema') AND s.nspname NOT LIKE 'pg_toast%'")"
  say "   roles made  $made (NOLOGIN)"
  say "   WAL         $(pg_sql "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), '$lsn0'))") generated by the load"
  # ---- 4. did it reach the standbys and the stores? ----
  for _ in $(seq 1 300); do
    v="$(cluster_verdict "$({ patronictl -c "$PATRONI_CONF" list -f json 2>/dev/null || echo '[]'; })")"
    case "$v" in ok*) break ;; esac; sleep 1
  done
  case "$v" in ok*) ok "both standbys streaming at 0 MB lag" ;; *) warn "the standbys have not caught up after 300 s (${v#bad })" ;; esac
  seg="$(pg_sql "SELECT pg_walfile_name(pg_switch_wal())")"
  for _ in $(seq 1 120); do
    [ "$(pg_sql "SELECT coalesce(last_archived_wal,'') >= '$seg' FROM pg_stat_archiver")" = t ] && break; sleep 1
  done
  a1="$(pg_sql "SELECT archived_count||' '||failed_count FROM pg_stat_archiver")"
  if [ "$(pg_sql "SELECT coalesce(last_archived_wal,'') >= '$seg' FROM pg_stat_archiver")" = t ]; then
    ok "WAL archived to the stores: $(( ${a1% *} - ${a0% *} )) segments, $(( ${a1#* } - ${a0#* } )) failures"
  else
    warn "the last WAL segment was not archived within 120 s - $(( ${a1#* } - ${a0#* } )) archive failures during the load"
  fi
  [ "$rc" -eq 0 ] || die "psql did not finish the file - read $log before anything else"
  [ "$APP_REHEARSING" = 1 ] && return 0
  ok "loaded. Next:"
  say "   1. on host-4:  sudo ./scripts/install/06a-postgres-ha.sh backup-run full   (the real-size backup, timed)"
  say "   2. when you have read the error lines you need:  sudo $0 app-restore shred $f $log"
}

# ---- extensions the application needs (PG_EXTENSION_PACKAGES, vm-specs.env) - on EVERY pg node:
# a standby that a failover promotes must hold the same libraries as the leader it replaces.
cmd_extensions() {
  need_root; whoami_pg
  local before after
  [ -n "$PG_EXTENSION_PACKAGES" ] || die "PG_EXTENSION_PACKAGES is empty in vm-specs.env - nothing to install"
  before="$(pg_sql "SELECT name FROM pg_available_extensions ORDER BY 1")"
  say "$ME: installing $PG_EXTENSION_PACKAGES from the enclave mirror (server libraries only, no recommends)"
  # NO TERMINAL for apt: `timeout` runs it in a background process group, and apt resets the
  # terminal when dpkg finishes - the kernel then STOPS it (state T) with the packages already
  # installed, and the timeout reports a failure that did not happen (2026-09-29, all three nodes).
  # stdin from /dev/null and Dpkg::Use-Pty=0 mean apt never touches the tty.
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive timeout 900 apt-get install -y --no-install-recommends -o Dpkg::Use-Pty=0 \
    $PG_EXTENSION_PACKAGES < /dev/null 2>&1 | sed 's/^/     /' \
    || die "apt-get failed or timed out - the lines above say why"
  after="$(pg_sql "SELECT name FROM pg_available_extensions ORDER BY 1")"
  ok "$ME: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -c . || true) extensions newly available: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | tr '\n' ' ')"
  say "   AIDE will report the new files at its next run - expected, this change"
}

cmd_app_census() {
  need_root; whoami_pg
  app_file_ok "${1:-}"
  app_census "$(readlink -f "$1")"
}

# Reprint a load's numbers-only summary from its log - the terminal that showed it can be gone
# (the first real load's was: a session timeout, 2026-09-29). The newest log unless one is named.
cmd_app_summary() {
  need_root
  local log="${1:-}"
  [ -n "$log" ] || log="$(ls -t "$APP_LOG_DIR"/*.log 2>/dev/null | head -1 || true)"
  [ -n "$log" ] && [ -f "$log" ] || die "no load log in $APP_LOG_DIR"
  case "$(readlink -f "$log")" in "$APP_LOG_DIR"/*) ;; *) die "$log is not a load log under $APP_LOG_DIR" ;; esac
  say "load log $(basename "$log"), last written $(date -u -r "$log" +%Y-%m-%dT%H:%M:%SZ)"
  app_summary "$log" "$(sed -n 's/^-- \[06a app-restore\] load seconds=\([0-9]*\).*$/\1/p' "$log" | tail -1)"
}

# Drop a database app-restore loaded - for a reload. Refuses anything app-restore did not create
# (there must be a load log for it), the system databases, and a standby; asks for the name typed.
cmd_app_drop() {
  need_root; whoami_pg
  local db="${1:-}" j v leader ans
  [ -n "$db" ] || die "usage: sudo $0 app-restore drop <database>"
  printf '%s' "$db" | grep -qxE '[a-z_][a-z0-9_]{0,62}' || die "database name '$db': lower-case letters, digits and _ only"
  case "$db" in postgres|template0|template1) die "$db is a system database - refusing" ;; esac
  j="$(cluster_json)"; v="$(cluster_verdict "$j")"
  case "$v" in ok*) ;; *) die "the cluster is not healthy (${v#bad }) - fix that first" ;; esac
  read -r _ leader _ <<<"$v"
  [ "$leader" = "$ME" ] || die "run this on the leader - $leader leads"
  [ "$(pg_sql "SELECT count(*) FROM pg_database WHERE datname='$db'")" = 1 ] || die "there is no database $db"
  ls "$APP_LOG_DIR/$db"-*.log >/dev/null 2>&1 || die "$db was not loaded by app-restore (no $APP_LOG_DIR/$db-*.log) - refusing"
  say "$db: $(pg_sql "SELECT pg_size_pretty(pg_database_size('$db'))"), loaded by app-restore. Its backups in the stores are untouched."
  read -r -p "  type the database name to drop it: " ans
  [ "$ans" = "$db" ] || die "name mismatch - nothing dropped"
  pg_sql "DROP DATABASE $db" && ok "$db dropped - the roles it made stay (NOLOGIN), a reload reuses them"
}

cmd_app_shred() {
  need_root
  [ "$#" -gt 0 ] || die "usage: sudo $0 app-restore shred <file>..."
  local f r
  # every argument is checked BEFORE anything is shredded
  for f in "$@"; do
    [ -f "$f" ] && [ ! -L "$f" ] || die "$f: not a regular file, or a symlink - nothing shredded"
    r="$(readlink -f "$f")"
    case "$r" in /home/*|/tmp/*|/var/tmp/*|"$APP_LOG_DIR"/*) ;; *) die "$r: shred takes a dump under /home, /tmp or /var/tmp, or a log under $APP_LOG_DIR - nothing shredded" ;; esac
  done
  for f in "$@"; do r="$(readlink -f "$f")"; shred -u "$r" && ok "shredded: $r"; done
}

# ---- the rehearsal: the whole path, a made-up dump, and the privacy claims proven ----------------
cmd_app_rehearse() {
  need_root; whoami_pg
  local tmp f out rc=0 r made=() log srv bad=0 tag marker schema srcdb n
  [ "$(pg_sql "SELECT count(*) FROM pg_database WHERE datname='$APP_REHEARSAL_DB'")" = 0 ] \
    || die "database $APP_REHEARSAL_DB exists - a previous rehearsal left it. Look, then drop it by hand."
  tag="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  marker="ENCLAVE-REHEARSAL-ROW-MARKER-$tag"; schema="rehearsal_$tag"; srcdb="rehearsal_src_$tag"
  for r in "Rehearsal Owner" rehearsal_reader azure_pg_admin; do   # drop afterwards only the ones WE made
    [ "$(pg_sql "SELECT count(*) FROM pg_roles WHERE rolname='$r'")" = 1 ] || made+=("$r")
  done
  tmp="$(mktemp -d)"; f="$tmp/rehearsal.sql"
  {
    printf -- '--\n-- PostgreSQL database dump\n--\n\n-- Dumped from database version 16.4\n-- Dumped by pg_dump version 16.4\n\n'
    printf "SET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\nSELECT pg_catalog.set_config('search_path', '', false);\n\n"
    printf "CREATE DATABASE %s WITH TEMPLATE = template0 ENCODING = 'UTF8' LOCALE_PROVIDER = libc LOCALE = 'en_US.utf8';\n" "$srcdb"
    printf 'ALTER DATABASE %s OWNER TO "Rehearsal Owner";\n\\connect %s\n\n' "$srcdb" "$srcdb"
    printf 'CREATE EXTENSION IF NOT EXISTS enclave_rehearsal_absent WITH SCHEMA public;\n'
    printf 'CREATE SCHEMA %s;\nALTER SCHEMA %s OWNER TO "Rehearsal Owner";\n' "$schema" "$schema"
    printf 'CREATE TABLE %s.people (\n    id integer NOT NULL,\n    label text\n);\nALTER TABLE %s.people OWNER TO "Rehearsal Owner";\n' "$schema" "$schema"
    printf 'CREATE TABLE %s.broken (\n    id integer NOT NULL\n);\n\n' "$schema"
    printf 'COPY %s.people (id, label) FROM stdin;\n' "$schema"
    seq 1 1000 | awk '{printf "%d\tlabel-%d\n", $1, $1}'
    printf '\\.\n\n'
    printf 'COPY %s.broken (id) FROM stdin;\n%s\n\\.\n\n' "$schema" "$marker"
    printf 'GRANT USAGE ON SCHEMA %s TO rehearsal_reader;\nGRANT SELECT ON TABLE %s.people TO rehearsal_reader;\nGRANT ALL ON SCHEMA %s TO azure_pg_admin;\n' "$schema" "$schema" "$schema"
  } > "$f"
  say "rehearsal: a made-up pg_dump --create dump - 1,000 good rows, one bad row carrying the marker, three roles, one absent extension"
  # A SEPARATE PROCESS, not a subshell: under `|| rc=$?` bash ignores set -e for everything the
  # command runs, so an in-process load would carry on past its own failures.
  out="$(APP_REHEARSING=1 bash "$SELF/$(basename "$0")" app-restore load "$f" "$APP_REHEARSAL_DB" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  log="$(ls -t "$APP_LOG_DIR/$APP_REHEARSAL_DB"-*.log 2>/dev/null | head -1)"
  sleep 3                                                          # rsyslog writes asynchronously
  say "the checks:"
  chk() { if [ "$2" = pass ]; then ok "$1"; else warn "FAILED: $1"; bad=1; fi; }
  chk "the load ran to the end (exit $rc)" "$([ "$rc" -eq 0 ] && echo pass)"
  chk "1,000 rows loaded" "$(printf '%s' "$out" | grep -qE 'rows +1,000 loaded by 1 COPY' && echo pass)"
  chk "2 errors counted - the absent extension and the marker row" "$(printf '%s' "$out" | grep -qE 'errors +2$' && echo pass)"
  chk "the bad row counted as 1 x 22P02" "$(printf '%s' "$out" | grep -qE '1 x 22P02' && echo pass)"
  chk "CONTROL: the marker IS in the load log - psql really quoted it" "$([ -n "$log" ] && grep -q "$marker" "$log" && echo pass)"
  chk "the dump's own CREATE DATABASE was skipped - no database $srcdb" "$([ "$(pg_sql "SELECT count(*) FROM pg_database WHERE datname='$srcdb'")" = 0 ] && echo pass)"
  chk "its ALTER DATABASE ... OWNER TO landed on $APP_REHEARSAL_DB" "$([ "$(pg_sql "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$APP_REHEARSAL_DB'")" = 'Rehearsal Owner' ] && echo pass)"
  chk "the rows are in $APP_REHEARSAL_DB, and nothing leaked into the postgres database" "$([ "$(runuser -u postgres -- psql -X -A -t -q -d "$APP_REHEARSAL_DB" -c "SELECT count(*) FROM $schema.people" 2>/dev/null)" = 1000 ] && [ "$(pg_sql "SELECT count(*) FROM pg_namespace WHERE nspname='$schema'")" = 0 ] && echo pass)"
  chk "the marker is NOT on the screen" "$(printf '%s' "$out" | grep -q "$marker" || echo pass)"
  # CONTROL 2: an ordinary session's error DOES reach the server log - so the no-leak check below
  # is one that can fail. Its own made-up value, which the marker check cannot match.
  runuser -u postgres -- psql -X -q -d postgres -c "SELECT 'ENCLAVE-REHEARSAL-CONTROL-$tag'::integer" >/dev/null 2>&1 || true
  sleep 3
  srv=("$PG_DATA"/log/* /var/log/syslog /var/log/messages)
  n="$(cat "${srv[@]}" 2>/dev/null | grep -c "ENCLAVE-REHEARSAL-CONTROL-$tag" || true)"
  chk "CONTROL: an ordinary session's error IS in the server log ($n lines) - the no-leak check can fail" "$([ "${n:-0}" -ge 1 ] && echo pass)"
  n="$(cat "${srv[@]}" 2>/dev/null | grep -c "$schema.people" || true)"
  chk "CONTROL: this run's DDL IS in the server log ($n lines) - the audit still works, and the check reads the live log" "$([ "${n:-0}" -ge 1 ] && echo pass)"
  n="$(cat "${srv[@]}" 2>/dev/null | grep -c "$marker" || true)"
  chk "the marker is NOT in the PostgreSQL log or syslog ($n lines)" "$([ "${n:-0}" -eq 0 ] && echo pass)"
  # ---- leave nothing behind ----
  pg_sql "DROP DATABASE IF EXISTS $APP_REHEARSAL_DB" >/dev/null; pg_sql "DROP DATABASE IF EXISTS $srcdb" >/dev/null
  for r in "${made[@]}"; do pg_sql "DROP ROLE IF EXISTS \"$r\"" >/dev/null; done
  shred -u "$f"; rm -rf "$tmp"; [ -n "$log" ] && shred -u "$log"
  ok "cleaned up: database $APP_REHEARSAL_DB dropped, ${#made[@]} rehearsal role(s) dropped, the dump and its log shredded"
  [ "$bad" -eq 0 ] || die "the REHEARSAL FAILED - do not load a real dump until the failure above is understood"
  ok "REHEARSAL PASSED - a real dump can be loaded the same way"
}

cmd_app_restore() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    census)   cmd_app_census "$@" ;;
    load)     app_load "$@" ;;
    rehearse) cmd_app_rehearse ;;
    summary)  cmd_app_summary "$@" ;;
    drop)     cmd_app_drop "$@" ;;
    shred)    cmd_app_shred "$@" ;;
    *) die "usage: sudo $0 app-restore rehearse | census <file> | load <file> <database> | summary [log] | drop <database> | shred <file>..." ;;
  esac
}

# ---- the Postgres 16 STIG's org-defined settings (slice 6, decided 2026-09-30) -------------------
# pg-stig.sh's first scan found four Opens, all values the STIG leaves to the site. Fixed where they
# live: the DCS for the parameters (a reload - no restart, no outage) and the catalog for the role
# limits. Safe to re-run. Prints every value before and after.
stig_settings_state() {
  pg_sql "SELECT string_agg(name || '=' || coalesce(nullif(reset_val, ''), setting) || coalesce(' ' || nullif(unit, ''), '') || CASE WHEN pending_restart THEN ' (PENDING RESTART)' ELSE '' END, '  ' ORDER BY name) FROM pg_settings WHERE name IN ('tcp_keepalives_idle','tcp_keepalives_interval','tcp_keepalives_count','statement_timeout','client_min_messages','log_filename','log_truncate_on_rotation','log_rotation_age','log_rotation_size')" | sed 's/^/     /'
  pg_sql "SELECT 'unlimited (-1): ' || count(*) FILTER (WHERE rolconnlimit = -1) || ' of ' || count(*) || ' roles (pg_* excluded); postgres = ' || max(rolconnlimit) FILTER (WHERE rolname = 'postgres') FROM pg_roles WHERE rolname !~ '^pg_'" | sed 's/^/     /'
}
cmd_stig_settings() {
  need_root; whoami_pg
  local j v leader n ms sql
  j="$(cluster_json)"; v="$(cluster_verdict "$j")"
  case "$v" in ok*) ;; *) die "the cluster is not healthy (${v#bad }) - fix that first" ;; esac
  read -r _ leader _ <<<"$v"
  [ "$leader" = "$ME" ] || die "run this on the leader - $leader leads"
  say "before:"; stig_settings_state
  # ---- 1. the parameters, in the DCS: every member reloads them within one Patroni loop ----
  patronictl -c "$PATRONI_CONF" edit-config "$PG_SCOPE" --force \
    -s "postgresql.parameters.tcp_keepalives_idle=$PG_TCP_KEEPALIVES_IDLE" \
    -s "postgresql.parameters.tcp_keepalives_interval=$PG_TCP_KEEPALIVES_INTERVAL" \
    -s "postgresql.parameters.tcp_keepalives_count=$PG_TCP_KEEPALIVES_COUNT" \
    -s "postgresql.parameters.statement_timeout=$PG_STATEMENT_TIMEOUT" \
    -s "postgresql.parameters.client_min_messages=$PG_CLIENT_MIN_MESSAGES" \
    -s "postgresql.parameters.log_filename=$PG_LOG_FILENAME" \
    -s "postgresql.parameters.log_truncate_on_rotation=on" \
    -s "postgresql.parameters.log_rotation_age=$PG_LOG_ROTATION_AGE" \
    -s "postgresql.parameters.log_rotation_size=0" 2>&1 | sed 's/^/     /'
  ms="$(pg_sql "SELECT (extract(epoch FROM '$PG_STATEMENT_TIMEOUT'::interval) * 1000)::bigint")"
  for _ in $(seq 1 30); do
    [ "$(pg_sql "SELECT count(*) FROM pg_settings WHERE (name = 'statement_timeout' AND setting = '$ms') OR (name = 'client_min_messages' AND setting = '$PG_CLIENT_MIN_MESSAGES') OR (name = 'tcp_keepalives_idle' AND reset_val = '$PG_TCP_KEEPALIVES_IDLE') OR (name = 'log_filename' AND setting = '$PG_LOG_FILENAME') OR (name = 'log_truncate_on_rotation' AND setting = 'on')")" = 5 ] && break
    sleep 2
  done
  [ "$(pg_sql "SELECT count(*) FROM pg_settings WHERE (name = 'statement_timeout' AND setting = '$ms') OR (name = 'client_min_messages' AND setting = '$PG_CLIENT_MIN_MESSAGES') OR (name = 'tcp_keepalives_idle' AND reset_val = '$PG_TCP_KEEPALIVES_IDLE') OR (name = 'log_filename' AND setting = '$PG_LOG_FILENAME') OR (name = 'log_truncate_on_rotation' AND setting = 'on')")" = 5 ] \
    || die "the new values are not live after 60 s - 'patronictl list' and 'patronictl show-config' say why"
  ok "parameters live on the leader (a reload - no restart); the standbys reload them from the DCS too"
  # ---- 2. the role limits. Names never printed - counts only ----
  n="$(pg_sql "SELECT count(*) FROM pg_roles WHERE NOT rolcanlogin AND rolconnlimit = -1 AND rolname !~ '^pg_'")"
  sql='DO $$ DECLARE r record; BEGIN
         FOR r IN SELECT rolname FROM pg_roles WHERE NOT rolcanlogin AND rolconnlimit = -1 AND rolname !~ '"'"'^pg_'"'"' LOOP
           EXECUTE format('"'"'ALTER ROLE %I CONNECTION LIMIT 0'"'"', r.rolname);
         END LOOP; END $$'
  pg_sql "$sql"
  pg_sql "ALTER ROLE postgres CONNECTION LIMIT $PG_SUPERUSER_CONN_LIMIT"
  ok "$n NOLOGIN role(s) set to CONNECTION LIMIT 0 (they cannot log in; 0 says so); postgres = $PG_SUPERUSER_CONN_LIMIT - documented, NOT enforced for a superuser (its bound: superuser_reserved_connections $(pg_sql "SHOW superuser_reserved_connections") inside max_connections $(pg_sql "SHOW max_connections"))"
  n="$(pg_sql "SELECT count(*) FROM pg_roles WHERE rolcanlogin AND NOT rolsuper AND rolconnlimit = -1")"
  [ "$n" = 0 ] || warn "$n login role(s) still unlimited - their limit is the application's decision (B-07), not set here"
  say "after:"; stig_settings_state
}

case "${1:-}" in
  etcd)       shift; cmd_etcd "$@" ;;
  etcd-check) cmd_etcd_check ;;
  patroni)       cmd_patroni ;;
  patroni-check) cmd_patroni_check ;;
  monitor)       cmd_monitor ;;
  switchover)    shift; cmd_switchover "$@" ;;
  leave)         cmd_leave ;;
  backup-node)   cmd_backup_node ;;
  backup-store)  shift; cmd_backup_store "$@" ;;
  backup-enable) cmd_backup_enable ;;
  backup-run)    shift; cmd_backup_run "$@" ;;
  backup-restore-test) cmd_backup_restore_test ;;
  extensions)    cmd_extensions ;;
  stig-settings) cmd_stig_settings ;;
  app-restore)   shift; cmd_app_restore "$@" ;;
  *) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
