#!/usr/bin/env bash
# =========================================================================================
# pg-stig.sh - assess pg-01..03 against DISA's Crunchy Data PostgreSQL 16 STIG V1R3 (111 rules)
# (backlog B-06a slice 6). Evaluate-STIG only covers PostgreSQL 9.x, so this check is ours.
#
#     sudo ./pg-stig.sh scan            MACHINE: a pg node. Reads settings, catalogs and file
#                                       modes - NEVER a table's contents - judges every rule it
#                                       can, writes a results file. Prints a summary. Read-only.
#     sudo ./pg-stig.sh scan --probe    MACHINE: the LEADER. The same, plus the AUDIT PROBE: a
#                                       throwaway role tries what the STIG forbids, and every
#                                       denial must be found in the log. WRITES - see below.
#     ./pg-stig.sh cklb [HOST...]       MACHINE: stage-01, after `stig-tools.sh collect` has
#                                       pulled the nodes' evidence. Builds each node's checklist
#                                       from its results and DISA's own text in the STIG zip.
#     ./pg-stig.sh show <results.json>  MACHINE: any. The summary again.
#
# THE SPLIT. DISA's rule text stays where it already is - the zip in docs/compliance/stigs on
#   stage-01 (gitignored, SHA-256 in stig-manifest.md). A node writes only its verdicts and the
#   evidence behind them, under $EVIDENCE/<HOST>/Postgres16/, owned by the operator so `collect`
#   can pull it; `cklb` writes the checklist beside Evaluate-STIG's in <HOST>/Checklist/, where
#   the CCI harvest already looks.
#
# NOTHING PASSES BY DEFAULT. A rule this script does not judge is not_reviewed, with the reason.
#   A rule whose check has two halves - a setting AND "verify the event was logged" - is judged on
#   the setting, and stays not_reviewed until the log half is proven (the audit probe, slice 6.2):
#   a correct setting is not evidence that the log holds the record.
#
# THE APPLICATION'S NAMES ARE MASKED (PG_STIG_MASK_APP=1, decided 2026-09-30). Role and database
#   names outside the platform's own (postgres, replicator, rewinder, the monitor role, pg_*,
#   the template databases) and the vendor's (azure_*) are written as "application role N" /
#   "application database N". The map is root-only on the node: $PG_STIG_MAP (0600).
#   Passwords never leave the query - only whether each role has none, a SCRAM hash, or other.
#
# pending_restart IS CHECKED, NOT JUST THE VALUE (runbook 9a.2a): a setting judged on its running
#   value carries a warning when the configuration holds a different one not yet applied.
#
# THE AUDIT PROBE (--probe, slice 6.2) - 16 rules say "do X as an unprivileged role, then find the
#   denial in the log". A correct setting proves none of them. So, on the leader only: create a
#   throwaway role stigprobe_<tag> (NOLOGIN, no privileges) and schema, do the audited things, SET
#   ROLE to it and try each forbidden thing, try one logon as a role that does not exist, then DROP
#   everything. Every target is a probe object: where the STIG alters "joe", the probe alters its
#   OWN second role - never postgres, never an application role. The evidence kept is only the
#   probe sessions' own log lines, found by their session ID (%c), so no other session's line and
#   no application data can reach the results. A standby cannot run it (the probe writes); there
#   those rules stay not_reviewed and the leader's checklist carries the proof.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDRS="$SELF/enclave-addresses.env"
EVIDENCE="${STIG_EVIDENCE:-/srv/stig-evidence}"
PG_STIG_ZIP="${PG_STIG_ZIP:-$SELF/../../docs/compliance/stigs/U_CD_Postgres_16_V1R3_STIG.zip}"
PG_STIG_MASK_APP="${PG_STIG_MASK_APP:-1}"
PG_STIG_MAP="${PG_STIG_MAP:-/var/lib/enclave-pg-stig/names.map}"
PG_STIG_PLATFORM_ROLES="${PG_STIG_PLATFORM_ROLES:-postgres replicator rewinder pgmonitor}"
PG_DATA="${PG_DATA:-/var/lib/postgresql/16/enclave-pg}"
TOOL_VERSION="6.2"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

# ---- the facts, in ONE query as the database superuser over the local socket (peer) ---------
# Only settings and catalog rows. Passwords are classified inside the query and never returned.
FACTS_SQL=$(cat <<'SQL'
SELECT json_build_object(
  'settings', (SELECT json_object_agg(name, json_build_object('v', setting, 'reset', reset_val, 'unit', unit,
                 'pending', pending_restart, 'source', source, 'file', sourcefile))
               FROM pg_settings WHERE name IN (
                 'shared_preload_libraries','pgaudit.log','pgaudit.log_catalog','pgaudit.log_level',
                 'pgaudit.log_parameter','pgaudit.log_relation','pgaudit.role','log_line_prefix',
                 'log_connections','log_disconnections','log_hostname','log_destination',
                 'logging_collector','log_directory','log_filename','log_file_mode','log_timezone',
                 'syslog_facility','syslog_ident','password_encryption','ssl','ssl_ca_file',
                 'ssl_cert_file','ssl_key_file','ssl_crl_file','ssl_min_protocol_version',
                 'ssl_ciphers','client_min_messages','statement_timeout','tcp_keepalives_idle',
                 'tcp_keepalives_interval','tcp_keepalives_count','max_connections','port',
                 'listen_addresses','data_directory','hba_file','ident_file','config_file',
                 'log_min_messages','log_min_error_statement','log_error_verbosity','log_statement')),
  'role_settings', (SELECT json_agg(json_build_object('role', coalesce(r.rolname, '*'), 'db', coalesce(d.datname, '*'),
                      'config', s.setconfig))
                    FROM pg_db_role_setting s LEFT JOIN pg_roles r ON r.oid = s.setrole
                    LEFT JOIN pg_database d ON d.oid = s.setdatabase),
  'hba', (SELECT json_agg(json_build_object('line', line_number, 'type', type, 'db', database, 'user', user_name,
            'addr', address, 'method', auth_method, 'opts', options, 'error', error) ORDER BY line_number)
          FROM pg_hba_file_rules),
  'roles', (SELECT json_agg(json_build_object('name', rolname, 'super', rolsuper, 'createrole', rolcreaterole,
              'createdb', rolcreatedb, 'bypassrls', rolbypassrls, 'replication', rolreplication,
              'login', rolcanlogin, 'connlimit', rolconnlimit,
              'pw', CASE WHEN rolpassword IS NULL THEN 'none'
                         WHEN rolpassword LIKE 'SCRAM-SHA-256$%' THEN 'scram' ELSE 'other' END) ORDER BY oid)
            FROM pg_authid),
  'databases', (SELECT json_agg(datname ORDER BY oid) FROM pg_database),
  'version', version(),
  'server_version_num', current_setting('server_version_num'),
  'in_recovery', pg_is_in_recovery()
)
SQL
)

# The probe. @T@ is a random tag per run. Statements run one by one with ON_ERROR_STOP off: the
# denials are the point. Each denied statement's STATEMENT line in the log is the proof it was logged.
PROBE_SQL=$(cat <<'SQL'
CREATE ROLE stigprobe_@T@ NOLOGIN CONNECTION LIMIT 0;
CREATE ROLE stigprobe2_@T@ NOLOGIN CONNECTION LIMIT 0;
CREATE SCHEMA stigprobe_@T@ AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA stigprobe_@T@ FROM PUBLIC;
GRANT USAGE ON SCHEMA stigprobe_@T@ TO stigprobe_@T@;
CREATE TABLE stigprobe_@T@.t (id int);
INSERT INTO stigprobe_@T@.t (id) VALUES (0);
ALTER TABLE stigprobe_@T@.t ADD COLUMN name text;
UPDATE stigprobe_@T@.t SET id = 1 WHERE id = 0;
SELECT count(*) FROM stigprobe_@T@.t;
SELECT r.rolname, r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolcanlogin, r.rolconnlimit FROM pg_catalog.pg_roles r WHERE r.rolname = 'stigprobe_@T@';
GRANT CONNECT ON DATABASE postgres TO stigprobe_@T@;
REVOKE CONNECT ON DATABASE postgres FROM stigprobe_@T@;
ALTER TABLE stigprobe_@T@.t ENABLE ROW LEVEL SECURITY;
CREATE POLICY stigprobe_pol_@T@ ON stigprobe_@T@.t USING (true);
DROP POLICY stigprobe_pol_@T@ ON stigprobe_@T@.t;
ALTER TABLE stigprobe_@T@.t DISABLE ROW LEVEL SECURITY;
SET ROLE stigprobe_@T@;
SELECT * FROM pg_authid WHERE rolname = 'stigprobe_@T@';
INSERT INTO stigprobe_@T@.t (id) VALUES (1);
UPDATE stigprobe_@T@.t SET id = 0 WHERE id = 1;
SELECT * FROM stigprobe_@T@.t;
ALTER TABLE stigprobe_@T@.t DROP COLUMN name;
DROP TABLE stigprobe_@T@.t;
CREATE TABLE stigprobe_@T@.x (id int);
SET pgaudit.role = 'stigprobe_@T@';
GRANT ALL PRIVILEGES ON stigprobe_@T@.t TO stigprobe_@T@;
REVOKE ALL PRIVILEGES ON stigprobe_@T@.t FROM stigprobe_@T@;
UPDATE pg_authid SET rolsuper = 't' WHERE rolname = 'stigprobe_@T@';
ALTER ROLE stigprobe2_@T@ LOGIN;
CREATE ROLE stigprobe3_@T@ SUPERUSER;
RESET ROLE;
CREAT TABLE stigprobe_@T@.syntax (id int);
SQL
)
PROBE_CLEANUP_SQL=$(cat <<'SQL'
DROP SCHEMA IF EXISTS stigprobe_@T@ CASCADE;
DROP ROLE IF EXISTS stigprobe3_@T@;
DROP ROLE IF EXISTS stigprobe2_@T@;
DROP ROLE IF EXISTS stigprobe_@T@;
SQL
)

# run_probe TMP - on the leader. Leaves TMP/probe.log: THIS probe's sessions' log lines, nothing else.
run_probe() {
  local tmp="$1" logdir left
  PROBE_TAG="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
  [ "$(runuser -u postgres -- psql -X -A -t -q -d postgres -c 'SELECT pg_is_in_recovery()')" = f ] \
    || die "--probe runs on the leader only - this node is a standby (the probe writes). Run plain 'scan' here."
  logdir="$(runuser -u postgres -- psql -X -A -t -q -d postgres -c "SELECT CASE WHEN current_setting('log_directory') LIKE '/%' THEN current_setting('log_directory') ELSE current_setting('data_directory') || '/' || current_setting('log_directory') END")"
  [ -d "$logdir" ] || die "the log directory $logdir does not exist - the probe has nothing to read"
  touch "$tmp/probe.start"
  say "audit probe $PROBE_TAG: a throwaway role and schema, the forbidden attempts, one failed logon, then cleanup"
  printf '%s\n' "$PROBE_SQL" | sed "s/@T@/$PROBE_TAG/g" > "$tmp/probe.sql"
  runuser -u postgres -- env PGAPPNAME="pg-stig-probe-$PROBE_TAG" psql -X -v ON_ERROR_STOP=0 -d postgres -f - \
    < "$tmp/probe.sql" > "$tmp/probe.out" 2>&1 || true
  runuser -u postgres -- env PGAPPNAME="pg-stig-probe-$PROBE_TAG-logon" psql -X -d postgres -U "stigprobe_nouser_$PROBE_TAG" \
    -c 'SELECT 1' > "$tmp/logon.out" 2>&1 || true
  printf '%s\n' "$PROBE_CLEANUP_SQL" | sed "s/@T@/$PROBE_TAG/g" \
    | runuser -u postgres -- env PGAPPNAME="pg-stig-probe-$PROBE_TAG-cleanup" psql -X -q -v ON_ERROR_STOP=0 -d postgres -f - \
      > "$tmp/cleanup.out" 2>&1 || true
  left="$(runuser -u postgres -- psql -X -A -t -q -d postgres -c "SELECT count(*) FROM pg_roles WHERE rolname LIKE 'stigprobe%$PROBE_TAG'")"
  [ "$left" = 0 ] || warn "the probe left $left role(s) behind - DROP ROLE ... LIKE 'stigprobe%$PROBE_TAG' by hand"
  [ "$(runuser -u postgres -- psql -X -A -t -q -d postgres -c "SELECT count(*) FROM pg_namespace WHERE nspname = 'stigprobe_$PROBE_TAG'")" = 0 ] \
    || warn "the probe left its schema stigprobe_$PROBE_TAG behind"
  [ "$left" = 0 ] && ok "probe cleaned up: its roles and schema are gone"
  sleep 3   # the logging collector writes asynchronously
  # ONLY this probe's sessions: find their session IDs (%c) from the lines carrying the probe's
  # application name or its non-existent user, then keep every line of those sessions - no other.
  find "$logdir" -maxdepth 1 -type f -newer "$tmp/probe.start" -print0 \
    | xargs -0 -r python3 -c '
import re, sys
tag = sys.argv[1]; files = sys.argv[2:]
mark = re.compile(r"pg-stig-probe-%s|stigprobe_nouser_%s" % (tag, tag))
sidrx = re.compile(r"\s([0-9a-f]{8}\.[0-9a-f]{1,8})\s")
lines = []
for f in files:
    with open(f, errors="replace") as fh:
        lines += fh.readlines()
sids = {m.group(1) for l in lines if mark.search(l) for m in [sidrx.search(l)] if m}
for l in lines:
    m = sidrx.search(l)
    if (m and m.group(1) in sids) or mark.search(l):
        sys.stdout.write(l)
' "$PROBE_TAG" > "$tmp/probe.log"
  say "probe: $(wc -l < "$tmp/probe.log") log line(s) from its own sessions"
}

whoami_pg() {
  [ -r "$ADDRS" ] || die "no address file at $ADDRS"
  local mine k a
  mine="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  # shellcheck disable=SC1090
  . "$ADDRS"
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '='); do
    a="${!k:-}"
    if [ -n "$a" ] && printf '%s\n' "$mine" | grep -qx "$a"; then ME_ADDR="$a"; return 0; fi
  done
  die "this machine ($(hostname -s)) holds no PG_* address in $ADDRS - scan runs on pg-01..03 only"
}

cmd_scan() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  whoami_pg
  local host up out tmp facts rc=0 owner probe=0
  case "${1:-}" in "") ;; --probe) probe=1 ;; *) die "usage: sudo $0 scan [--probe]" ;; esac
  PROBE_TAG=""
  host="$(hostname -s)"; up="$(printf '%s' "$host" | tr 'a-z' 'A-Z')"
  out="$EVIDENCE/$up/Postgres16"
  owner="${SUDO_USER:-root}"
  # never re-mode a directory Evaluate-STIG already made - only create what is missing
  [ -d "$EVIDENCE" ] || install -d -m 0755 "$EVIDENCE"
  [ -d "$EVIDENCE/$up" ] || install -d -m 0755 -o "${SUDO_USER:-root}" "$EVIDENCE/$up"
  install -d -m 0755 -o "$owner" "$out"
  install -d -m 0700 "$(dirname "$PG_STIG_MAP")"
  tmp="$(mktemp -d)"; chmod 0700 "$tmp"
  facts="$(runuser -u postgres -- psql -X -A -t -q -v ON_ERROR_STOP=1 -d postgres -c "$FACTS_SQL" 2>&1)" \
    || { printf '%s\n' "$facts" | sed 's/^/     /' >&2; rm -rf "$tmp"; die "the facts query failed - psql's answer is above"; }
  printf '%s' "$facts" > "$tmp/facts.json"
  # host facts the rules need beside the database's own
  {
    printf 'fips_enabled=%s\n' "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo missing)"
    printf 'openssl_version=%s\n' "$(openssl version 2>&1 | head -1)"
    printf 'mac=%s\n' "$(ip -o link show 2>/dev/null | grep -o 'link/ether [0-9a-f:]*' | head -1 | cut -d' ' -f2)"
    printf 'fqdn=%s\n' "$(hostname -f 2>/dev/null || hostname -s)"
  } > "$tmp/host.env"
  openssl list -providers > "$tmp/providers.txt" 2>&1 || true
  [ "$probe" = 1 ] && run_probe "$tmp"
  python3 - "$tmp" "$out" "$host" "$ME_ADDR" "$PG_STIG_MASK_APP" "$PG_STIG_MAP" "$PG_STIG_PLATFORM_ROLES" "$TOOL_VERSION" "$owner" "$PROBE_TAG" <<'SCANPY' || rc=$?
import json, os, re, sys, time, pwd
tmp, out, host, addr, mask, mapfile, platform, toolver, owner, ptag = sys.argv[1:11]
import stat, grp
F = json.load(open(os.path.join(tmp, "facts.json")))
H = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.join(tmp, "host.env")) if "=" in l)
providers = open(os.path.join(tmp, "providers.txt")).read()
S = F["settings"] or {}
PLATFORM = set(platform.split())
SYSDB = {"postgres", "template0", "template1"}

# ---- masking: the application's names never leave this node --------------------------------
# ROLES AND DATABASES ARE MASKED SEPARATELY: a role may share its database's name (the first live
# scan, 2026-09-30, found exactly that - one table had written the role as "application database 1").
rnames, dnames = {}, {}
if mask == "1":
    n = 0
    for r in F["roles"] or []:
        nm = r["name"]
        if nm in PLATFORM or nm.startswith("pg_") or nm.startswith("azure"):
            continue
        n += 1; rnames[nm] = "application role %d" % n
    n = 0
    for d in F["databases"] or []:
        if d in SYSDB: continue
        n += 1; dnames[d] = "application database %d" % n
    old = os.umask(0o077)
    with open(mapfile, "w") as m:
        m.write("# pg-stig.sh name map - root only, never collected. masked -> real\n")
        for real, masked in list(rnames.items()) + list(dnames.items()): m.write("%s\t%s\n" % (masked, real))
    os.umask(old)
def MR(s): return rnames.get(s, s) if isinstance(s, str) else s
def MD(s): return dnames.get(s, s) if isinstance(s, str) else s
def M(s): return MR(s)
def Mlist(xs, f=None): return [(f or MR)(x) for x in (xs or [])]

# ---- helpers ---------------------------------------------------------------------------------
def val(n):
    s = S.get(n)
    return None if s is None else s["v"]
def show(n):
    s = S.get(n)
    if s is None: return "%s: (not present in pg_settings)" % n
    extra = []
    if s.get("pending"): extra.append("PENDING RESTART - the configuration holds a different value, not yet applied")
    if s.get("source") not in (None, "default"): extra.append("source: %s" % s["source"])
    return "%s = '%s'%s" % (n, s["v"], (" (" + "; ".join(extra) + ")") if extra else "")
def pending(*ns): return [n for n in ns if (S.get(n) or {}).get("pending")]
def tokens(v): return set(re.findall(r"%[a-zA-Z]", v or ""))
def has_pgaudit(): return "pgaudit" in [x.strip() for x in (val("shared_preload_libraries") or "").split(",")]
def audit_classes(): return {x.strip().lower() for x in (val("pgaudit.log") or "").split(",") if x.strip()}
def on(n): return (val(n) or "").lower() in ("on", "true", "1", "yes")

R = {}
def res(vid, status, details, comments=""):
    R[vid] = {"status": status, "details": details, "comments": comments}
def settings_rule(vid, checks, names_shown, log_half=False, note=""):
    """checks: list of (ok_bool, failure_text). All ok -> NaF (or not_reviewed if a log half remains)."""
    fails = [t for ok, t in checks if not ok]
    ev = "\n".join(show(n) for n in names_shown)
    p = pending(*names_shown)
    if p: ev += "\nWARNING: pending_restart on %s - judged on the RUNNING value" % ", ".join(p)
    if fails:
        res(vid, "open", ev + "\n\nFINDING: " + "; ".join(fails), note)
    elif log_half:
        res(vid, "not_reviewed", ev + "\n\nThe setting half passes. The check also requires the event to be found in the log; "
            "that is proven by the audit probe (pg-stig.sh slice 6.2), not by a setting.", note)
    else:
        res(vid, "not_a_finding", ev, note)

AUDIT_ALL = {"role", "read", "write", "ddl"}
pre = val("log_line_prefix") or ""
pt = tokens(pre)
def need(*toks):
    miss = [t for t in toks if t not in pt]
    return (not miss, "log_line_prefix lacks %s" % " ".join(miss))
pga = (has_pgaudit(), "shared_preload_libraries does not contain pgaudit")
def cls(*c):
    miss = [x for x in c if x not in audit_classes()]
    return (not miss, "pgaudit.log lacks %s" % ", ".join(miss))
rs = F.get("role_settings") or []
overrides = [x for x in rs if any(str(c).startswith("pgaudit.") for c in (x.get("config") or []))]
ov_note = ""
if overrides:
    ov_note = "Role-level pgaudit overrides: " + "; ".join("%s%s: %s" % (MR(x["role"]), "" if x["db"] == "*" else " in " + MD(x["db"]), ", ".join(x["config"])) for x in overrides)
    ov_note += ". The monitor role's 'none' is the decided tailoring (acting AO 2026-09-28, backlog 6a.10)."

# ---- A. the settings rules -------------------------------------------------------------------
settings_rule("V-261860", [need("%m", "%a", "%u", "%d", "%r", "%p"), pga], ["log_line_prefix", "shared_preload_libraries"],
              note="Checked as fields present: this site's prefix has no '< >' delimiters, which carry no information.")
settings_rule("V-261865", [pga, (any(x in (val("log_destination") or "") for x in ("stderr", "syslog")), "log_destination has neither stderr nor syslog")],
              ["shared_preload_libraries", "log_destination"])
settings_rule("V-261866", [need("%m", "%a", "%u", "%d", "%r", "%p", "%s", "%c"), (on("log_connections"), "log_connections is off"),
               (on("log_disconnections"), "log_disconnections is off")], ["log_line_prefix", "log_connections", "log_disconnections"],
              note="The organisation's required fields are the union the other log_line_prefix rules name (%m %a %u %d %r %p %s %c); baseline 6a.10 records it.")
settings_rule("V-261867", [need("%m")], ["log_line_prefix"])
settings_rule("V-261868", [need("%m", "%u", "%d", "%s")], ["log_line_prefix"])
settings_rule("V-261869", [(bool(pt & {"%r", "%h"}), "log_line_prefix carries neither %r nor %h - no source of the event")], ["log_line_prefix", "log_hostname"])
settings_rule("V-261871", [need("%m", "%u", "%d", "%p", "%r", "%a")], ["log_line_prefix"])
settings_rule("V-261922", [need("%m")], ["log_line_prefix"], log_half=True)
settings_rule("V-261961", [(on("log_connections"), "log_connections is off"), (on("log_disconnections"), "log_disconnections is off"),
               need("%m", "%u", "%d", "%c")], ["log_connections", "log_disconnections", "log_line_prefix"])
settings_rule("V-261964", [pga, (on("log_connections"), "log_connections is off"), (on("log_disconnections"), "log_disconnections is off")],
              ["shared_preload_libraries", "log_connections", "log_disconnections"])
settings_rule("V-261956", [(on("log_connections"), "log_connections is off")], ["log_connections"], log_half=True)
settings_rule("V-261960", [(on("log_connections"), "log_connections is off"), (on("log_disconnections"), "log_disconnections is off")],
              ["log_connections", "log_disconnections"], log_half=True)
settings_rule("V-261921", [((val("log_timezone") or "") in ("UTC", "Etc/UTC"), "log_timezone is not UTC")], ["log_timezone"],
              note="The enclave runs on UTC (every machine, chrony-synchronised - backlog 3.39).")
for v in ("V-261938", "V-261949", "V-261950", "V-261953", "V-261954", "V-261955", "V-261958", "V-261962", "V-261948"):
    settings_rule(v, [pga, cls(*sorted(AUDIT_ALL))], ["shared_preload_libraries", "pgaudit.log"], note=ov_note)
settings_rule("V-261946", [pga, cls(*sorted(AUDIT_ALL)), (on("pgaudit.log_catalog"), "pgaudit.log_catalog is off")],
              ["shared_preload_libraries", "pgaudit.log", "pgaudit.log_catalog"], note=ov_note)
for v in ("V-261940", "V-261941"):
    settings_rule(v, [cls("ddl", "write", "role")], ["pgaudit.log"], note=ov_note)
settings_rule("V-261944", [pga, cls("role")], ["shared_preload_libraries", "pgaudit.log"], note=ov_note)
for v in ("V-261900", "V-261932", "V-261933"):
    settings_rule(v, [(on("ssl"), "ssl is off")], ["ssl", "ssl_min_protocol_version"])
settings_rule("V-261908", [((val("client_min_messages") or "").lower() == "error", "client_min_messages is not 'error'")], ["client_min_messages"])
settings_rule("V-261909", [((val("client_min_messages") or "").lower() == "error", "client_min_messages is not 'error'")],
              ["client_min_messages", "log_file_mode"], log_half=True,
              note="The log-file half (who can read the logs) is judged with the file checks (slice 6.2).")
# V-261899: the tcp_keepalives_* values SHOW 0 on a Unix-socket session whatever is configured, so the
# configured value (reset_val) is judged - the check itself says to connect with -h localhost for that reason.
ka = {n: (S.get(n) or {}).get("reset") for n in ("tcp_keepalives_idle", "tcp_keepalives_interval", "tcp_keepalives_count")}
ka_fail = [n for n, v in ka.items() if str(v) in ("0", "None")]
st_fail = (val("statement_timeout") or "0") in ("0", "0ms")
ev = "\n".join("%s configured = '%s'" % (n, v) for n, v in ka.items()) + "\n" + show("statement_timeout")
if ka_fail or st_fail:
    res("V-261899", "open", ev + "\n\nFINDING: " + "; ".join([("%s is 0" % n) for n in ka_fail] + (["statement_timeout is 0"] if st_fail else [])))
else:
    res("V-261899", "not_a_finding", ev)

# passwords: stored hashed and salted
roles = F["roles"] or []
other = [r for r in roles if r["pw"] == "other"]
scram = [r for r in roles if r["pw"] == "scram"]
ev = show("password_encryption") + "\nroles with a SCRAM-SHA-256 verifier: %d; with no password: %d; with any other form: %d" % (
    len(scram), len([r for r in roles if r["pw"] == "none"]), len(other))
f = []
if (val("password_encryption") or "") != "scram-sha-256": f.append("password_encryption is not scram-sha-256")
if other: f.append("stored in another form: " + ", ".join(M(r["name"]) for r in other))
res("V-261891", "open" if f else "not_a_finding", ev + ("\n\nFINDING: " + "; ".join(f) if f else ""),
    "Checked in the catalog (pg_authid.rolpassword classified inside the query); no password value left the database.")

# pg_hba: no md5 or password - read from pg_hba_file_rules, the file as the server parsed it
hba = F["hba"] or []
lines = ["line %s: %s %s %s %s %s%s" % (h["line"], h["type"], ",".join(Mlist(h["db"], MD)), ",".join(Mlist(h["user"], MR)),
         h["addr"] or "", h["method"], (" [ERROR: %s]" % h["error"]) if h["error"] else "") for h in hba]
bad = [h for h in hba if (h["method"] or "") in ("md5", "password")]
errs = [h for h in hba if h["error"]]
f = []
if bad: f.append("md5/password on line(s) %s" % ", ".join(str(h["line"]) for h in bad))
if errs: f.append("pg_hba.conf has lines the server could not parse: %s" % ", ".join(str(h["line"]) for h in errs))
res("V-261892", "open" if f else "not_a_finding",
    "pg_hba.conf as the server parsed it (pg_hba_file_rules), %d rule(s):\n%s%s" % (len(hba), "\n".join(lines), ("\n\nFINDING: " + "; ".join(f)) if f else ""),
    "Patroni writes pg_hba.conf from its configuration (06a); the file is judged as loaded, not as templated.")

# connection limits: -1 is unlimited and a finding for every listed role
PRE = {"pg_database_owner", "pg_read_all_data", "pg_write_all_data", "pg_monitor", "pg_read_all_settings", "pg_read_all_stats",
       "pg_stat_scan_tables", "pg_read_server_files", "pg_write_server_files", "pg_execute_server_program", "pg_signal_backend",
       "pg_checkpoint", "pg_use_reserved_connections", "pg_create_subscription", "pg_maintain"}
listed = [r for r in roles if r["name"] not in PRE]
unl = [r for r in listed if r["connlimit"] == -1]
ev = show("max_connections") + "\n" + "\n".join("%s: rolconnlimit %s%s" % (M(r["name"]), r["connlimit"], "" if r["login"] else " (NOLOGIN)") for r in listed)
if unl:
    res("V-261857", "open", ev + "\n\nFINDING: unlimited (-1): " + ", ".join(M(r["name"]) for r in unl),
        "The literal check makes -1 a finding for every listed role, NOLOGIN ones included. The per-role limits and max_connections are compared against baseline 6a.10 in slice 6.3.")
else:
    res("V-261857", "not_reviewed", ev + "\n\nNo role is unlimited. The limits themselves are compared against baseline 6a.10 (slice 6.3).")

# FIPS
fips = H.get("fips_enabled", "missing")
prov = re.findall(r"^\s*(\w+)\s*\n\s*name:\s*(.+)\n(?:\s*version:.*\n)?\s*status:\s*(\w+)", providers, re.M)
fips_prov = [p for p in prov if "fips" in (p[0] + p[1]).lower() and p[2].lower() == "active"]
ev = "/proc/sys/crypto/fips_enabled = %s\n%s\nOpenSSL providers:\n%s" % (fips, H.get("openssl_version", "?"), providers.strip())
res("V-261896", "not_a_finding" if fips == "1" and fips_prov else "open",
    ev + ("" if fips == "1" and fips_prov else "\n\nFINDING: FIPS mode off, or no active FIPS provider"),
    "Ubuntu 24.04's FIPS modules are FIPS 140-3 validated; the acting AO accepts the patched builds (HANDOFF §3, 2026-09-24).")
for v in ("V-261965", "V-261966"):
    res(v, "not_a_finding" if fips == "1" else "open", "/proc/sys/crypto/fips_enabled = %s" % fips)

res("V-261928", "not_applicable", show("ssl"),
    "The enclave holds unclassified information (IL5: CUI) - no classified information, so NSA-approved cryptography for classified data does not apply.")


# ---- B. the files - the STIG's RHEL paths mapped to Ubuntu and Patroni (runbook 9a.2a trap 4) --------
def lst(p):
    try: return os.lstat(p)
    except (FileNotFoundError, PermissionError): return None
def who(x): 
    try: return pwd.getpwuid(x.st_uid).pw_name
    except KeyError: return str(x.st_uid)
def grpn(x):
    try: return grp.getgrgid(x.st_gid).gr_name
    except KeyError: return str(x.st_gid)
def mo(x): return stat.S_IMODE(x.st_mode)
def desc(p):
    x = lst(p)
    return "%s: missing" % p if x is None else "%s: %s:%s %04o" % (p, who(x), grpn(x), mo(x))
def walk(root):
    for d, dirs, files in os.walk(root, followlinks=False):
        for n in dirs + files:
            yield os.path.join(d, n)
PGDATA = val("data_directory") or ""
ld = val("log_directory") or "log"
PGLOG = ld if ld.startswith("/") else os.path.join(PGDATA, ld)
BIN_DIRS = [d for d in ("/usr/lib/postgresql/16/bin", "/usr/lib/postgresql/16/lib", "/usr/share/postgresql/16", "/usr/include/postgresql") if os.path.isdir(d)]
SYSLOG_FILES = [f for f in ("/var/log/syslog", "/var/log/messages") if os.path.exists(f)]

data_not_pg, data_go = [], []
for p in walk(PGDATA):
    x = lst(p)
    if x is None or stat.S_ISLNK(x.st_mode): continue
    if who(x) != "postgres": data_not_pg.append(os.path.relpath(p, PGDATA))
    if mo(x) & 0o077: data_go.append("%s %04o" % (os.path.relpath(p, PGDATA), mo(x)))
root_st = lst(PGDATA)
data_ok_owner = root_st is not None and who(root_st) == "postgres" and grpn(root_st) == "postgres" and not data_not_pg
data_ok_mode = root_st is not None and not (mo(root_st) & 0o077) and not data_go
ev_data = "%s\nentries not owned by postgres: %d%s\nentries with any group/other permission: %d%s" % (
    desc(PGDATA), len(data_not_pg), (" (" + ", ".join(data_not_pg[:5]) + ")") if data_not_pg else "",
    len(data_go), (" (" + ", ".join(data_go[:5]) + ")") if data_go else "")

logs = [os.path.join(PGLOG, f) for f in sorted(os.listdir(PGLOG))] if os.path.isdir(PGLOG) else []
log_bad = [f for f in logs if (lst(f) and (mo(lst(f)) & 0o077 or who(lst(f)) != "postgres"))]
logdir_st = lst(PGLOG)
syslog_bad = [f for f in SYSLOG_FILES if mo(lst(f)) & 0o007]
ev_logs = "%s\n%s\nfiles in it: %d, not 0600-postgres: %d%s\nsyslog files (PostgreSQL also logs there): %s" % (
    show("log_file_mode"), desc(PGLOG), len(logs), len(log_bad), (" (" + ", ".join(os.path.basename(f) for f in log_bad[:5]) + ")") if log_bad else "",
    "; ".join(desc(f) for f in SYSLOG_FILES) or "none")
lfm_ok = (val("log_file_mode") or "") in ("0600", "600")
logs_read_ok = lfm_ok and not log_bad and not syslog_bad
logdir_ok = logdir_st is not None and who(logdir_st) == "postgres" and not (mo(logdir_st) & 0o022)

bin_bad = []
for d in BIN_DIRS:
    for p in [d] + list(walk(d)):
        x = lst(p)
        if x is None or stat.S_ISLNK(x.st_mode): continue
        if who(x) != "root" or (mo(x) & 0o022): bin_bad.append("%s %s %04o" % (p, who(x), mo(x)))
ev_bin = "PostgreSQL's software on Ubuntu (the STIG's /usr/pgsql-16): %s\nfiles not root-owned or writable by group/other: %d%s" % (
    ", ".join(BIN_DIRS), len(bin_bad), (" (" + "; ".join(bin_bad[:5]) + ")") if bin_bad else "")
pga_files = [os.path.join("/usr/share/postgresql/16/extension", f) for f in sorted(os.listdir("/usr/share/postgresql/16/extension")) if f.startswith("pgaudit")] if os.path.isdir("/usr/share/postgresql/16/extension") else []
pga_files += [f for f in ("/usr/lib/postgresql/16/lib/pgaudit.so",) if os.path.exists(f)]
pga_bad = [f for f in pga_files if who(lst(f)) != "root"]

conf = val("config_file") or os.path.join(PGDATA, "postgresql.conf")
conf_st = lst(conf)
conf_ok = conf_st is not None and who(conf_st) == "postgres" and mo(conf_st) == 0o600
other_conf = [val("hba_file"), val("ident_file")]
oc_bad = [f for f in other_conf if f and lst(f) and (who(lst(f)) != "postgres" or mo(lst(f)) & 0o022)]

ssl_files = [val(n) for n in ("ssl_cert_file", "ssl_key_file", "ssl_ca_file", "ssl_crl_file") if val(n)]
ssl_files = [f if f.startswith("/") else os.path.join(PGDATA, f) for f in ssl_files]
ssl_dirs = sorted({os.path.dirname(f) for f in ssl_files})
ssl_bad = [d for d in ssl_dirs if lst(d) is None or mo(lst(d)) & 0o007]
key = val("ssl_key_file") or ""
key = key if key.startswith("/") else os.path.join(PGDATA, key)
if key and lst(key) and mo(lst(key)) & 0o027: ssl_bad.append("%s %04o" % (key, mo(lst(key))))

def frule(vid, checks, ev, half=None, note=""):
    fails = [t for ok, t in checks if not ok]
    if fails: res(vid, "open", ev + "\n\nFINDING: " + "; ".join(fails), note)
    elif half: res(vid, "not_reviewed", ev + "\n\nThe file half passes. " + half, note)
    else: res(vid, "not_a_finding", ev, note)
BASE = "The role half is judged against the org baseline (6a.10) in slice 6.3."
frule("V-261875", [(lfm_ok, "log_file_mode is not 0600"), (not log_bad, "log files not 0600-postgres"), (not syslog_bad, "a syslog file is readable by others")], ev_logs)
frule("V-261876", [(lfm_ok, "log_file_mode is not 0600"), (not log_bad, "log files not 0600-postgres"), (not syslog_bad, "a syslog file is writable by others")], ev_logs)
frule("V-261877", [(lfm_ok, "log_file_mode is not 0600"), (not log_bad, "log files not 0600-postgres"), (logdir_ok, "the log directory is not postgres-owned or is writable by others - its files could be deleted")], ev_logs)
frule("V-261878", [(logdir_ok, "the log directory is not postgres-owned"), (data_ok_owner, "PGDATA is not wholly postgres-owned"), (not pga_bad, "pgaudit files not root-owned: %s" % ", ".join(pga_bad))],
      ev_logs + "\n" + ev_data + "\npgaudit's files: " + "; ".join(desc(f) for f in pga_files), half=BASE)
frule("V-261879", [(conf_ok, "postgresql.conf is not postgres-owned 0600"), (lfm_ok, "log_file_mode is not 0600"), (not syslog_bad, "a syslog file is open to others")],
      desc(conf) + "\n" + ev_logs, note="Patroni writes postgresql.conf from its configuration (06a); the file on disk is what is judged.")
frule("V-261880", [(data_ok_owner and data_ok_mode, "PGDATA is not postgres:postgres with no access for others"), (not bin_bad, "software files not root-owned or writable by others")], ev_data + "\n" + ev_bin)
frule("V-261881", [(data_ok_owner, "PGDATA files not postgres-owned"), (not oc_bad, "configuration files writable by others: %s" % ", ".join(oc_bad)), (not bin_bad, "software files not root-owned or writable by others")],
      ev_data + "\n" + "; ".join(desc(f) for f in other_conf if f) + "\n" + ev_bin)
frule("V-261862", [(data_ok_owner, "PGDATA is not wholly postgres-owned")], ev_data, half="The superuser half is judged against the org baseline (6a.10) in slice 6.3.")
frule("V-261885", [(data_ok_mode, "PGDATA grants access beyond its owner")], ev_data, half="The privilege half (\\dp) is judged against the org baseline (6a.10) in slice 6.3.")
frule("V-261894", [(not ssl_bad, "unprotected: %s" % ", ".join(ssl_bad))], "\n".join(desc(f) for f in ssl_files) + "\ndirectories: " + "; ".join(desc(d) for d in ssl_dirs),
      note="The files are Patroni's copies of the node certificate (06a §6).")
frule("V-261904", [(data_ok_owner, "entries not owned by postgres"), (data_ok_mode, "entries readable or writable by group/other")], ev_data)
cmm_ok = (val("client_min_messages") or "").lower() == "error"
frule("V-261909", [(cmm_ok, "client_min_messages is not 'error'"), (logs_read_ok, "the logs are readable beyond their owner")], show("client_min_messages") + "\n" + ev_logs)

# ---- D. the audit probe: each denial must be FOUND in the log --------------------------------------
PL = open(os.path.join(tmp, "probe.log"), errors="replace").read().splitlines() if ptag and os.path.exists(os.path.join(tmp, "probe.log")) else []
T = ptag
def pf(rx): return [l for l in PL if re.search(rx, l)]
def probe_rule(vid, needs, pre=None, note=""):
    if not T:
        standby = F.get("in_recovery")
        res(vid, "not_reviewed", "", ("Judged on the leader by the audit probe; a standby cannot run it (the probe writes). See the leader's checklist."
             if standby else "Needs the audit probe: sudo ./pg-stig.sh scan --probe (on the leader)."))
        return
    pre = pre or []
    bad = [t for ok, t in pre if not ok]
    rows, missing = [], []
    for d, rx in needs:
        hit = pf(rx)
        rows.append("%s:\n    %s" % (d, hit[0].strip()[:300] if hit else "NOT FOUND in the probe's log lines"))
        if not hit: missing.append(d)
    ev = "audit probe %s, %d line(s) of its own sessions\n%s" % (T, len(PL), "\n".join(rows))
    if bad or missing:
        res(vid, "open", ev + "\n\nFINDING: " + "; ".join(bad + ["not in the log: " + m for m in missing]), note)
    else:
        res(vid, "not_a_finding", ev, note)
S_ = r"STATEMENT:\s+"
probe_rule("V-261861", [("CREATE TABLE audited (the STIG's example event)", r"AUDIT: SESSION,.*,DDL,CREATE TABLE,.*stigprobe_%s\.t" % T)], [pga])
probe_rule("V-261863", [("the role listing audited", r"AUDIT: SESSION,.*,READ,SELECT,.*pg_roles.*stigprobe_%s" % T)], [pga])
probe_rule("V-261864", [("the denied read of pg_authid", S_ + r"SELECT \* FROM pg_authid WHERE rolname = 'stigprobe_%s'" % T), ("its error", r"ERROR:.*permission denied for table pg_authid")])
probe_rule("V-261870", [("the denied INSERT", S_ + r"INSERT INTO stigprobe_%s\.t \(id\) VALUES \(1\)" % T), ("the denied UPDATE", S_ + r"UPDATE stigprobe_%s\.t SET id = 0" % T),
                        ("the denied ALTER", S_ + r"ALTER TABLE stigprobe_%s\.t DROP COLUMN" % T), ("an error for them", r"ERROR:.*(permission denied for table t|must be owner of table t)")])
probe_rule("V-261925", [("the denied SET of a superuser parameter", S_ + r"SET pgaudit\.role = 'stigprobe_%s'" % T), ("its error", r'permission denied to set parameter "pgaudit\.role"')])
probe_rule("V-261934", [("the syntax error", r'syntax error at or near "CREAT"'), ("its statement", S_ + r"CREAT TABLE stigprobe_%s" % T)])
probe_rule("V-261939", [("the denied CREATE in a schema", S_ + r"CREATE TABLE stigprobe_%s\.x" % T), ("its error", r"permission denied for schema stigprobe_%s" % T)])
probe_rule("V-261942", [("GRANT audited", r"AUDIT: SESSION,.*,ROLE,GRANT,.*GRANT CONNECT ON DATABASE postgres TO stigprobe_%s" % T),
                        ("REVOKE audited", r"AUDIT: SESSION,.*,ROLE,REVOKE,.*REVOKE CONNECT ON DATABASE postgres FROM stigprobe_%s" % T)], [pga])
probe_rule("V-261943", [("the denied GRANT", S_ + r"GRANT ALL PRIVILEGES ON stigprobe_%s\.t TO stigprobe_%s" % (T, T))])
probe_rule("V-261945", [("the denied GRANT", S_ + r"GRANT ALL PRIVILEGES ON stigprobe_%s\.t TO stigprobe_%s" % (T, T)), ("the denied REVOKE", S_ + r"REVOKE ALL PRIVILEGES ON stigprobe_%s\.t FROM stigprobe_%s" % (T, T))])
probe_rule("V-261947", [("the denied UPDATE of pg_authid", S_ + r"UPDATE pg_authid SET rolsuper = 't' WHERE rolname = 'stigprobe_%s'" % T)])
probe_rule("V-261951", [("the denied ALTER ROLE", S_ + r"ALTER ROLE stigprobe2_%s LOGIN" % T)], note="The target is the probe's own second role, never a real one.")
probe_rule("V-261952", [("DROP POLICY audited", r"AUDIT: SESSION,.*,DDL,DROP POLICY,.*stigprobe_pol_%s" % T), ("row-level security disabled, audited", r"AUDIT: SESSION,.*,DDL,ALTER TABLE,.*DISABLE ROW LEVEL SECURITY")], [pga])
probe_rule("V-261957", [("the failed logon of a role that does not exist", r"FATAL:.*stigprobe_nouser_%s|stigprobe_nouser_%s.*FATAL:" % (T, T))])
probe_rule("V-261959", [("the denied CREATE ROLE ... SUPERUSER", S_ + r"CREATE ROLE stigprobe3_%s SUPERUSER" % T)])
probe_rule("V-261963", [("the denied SELECT", S_ + r"SELECT \* FROM stigprobe_%s\.t" % T), ("the denied INSERT", S_ + r"INSERT INTO stigprobe_%s\.t \(id\) VALUES \(1\)" % T),
                        ("the denied UPDATE", S_ + r"UPDATE stigprobe_%s\.t SET id = 0" % T), ("the denied DROP", S_ + r"DROP TABLE stigprobe_%s\.t" % T)])
# the log halves of rules 6.1 judged on their settings
probe_rule("V-261956", [("the probe's own connection, logged", r"connection authorized: user=postgres database=postgres")], [(on("log_connections"), "log_connections is off")])
probe_rule("V-261960", [("its connection", r"connection authorized: user=postgres database=postgres"), ("its disconnection", r"disconnection: session time:")],
           [(on("log_connections"), "log_connections is off"), (on("log_disconnections"), "log_disconnections is off")])
probe_rule("V-261922", [("a millisecond timestamp (first line shown)", r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} ")], [need("%m")])
# ...and on EVERY line of the probe's sessions, not just one - the label says every, so the check does.
if T and R["V-261922"]["status"] == "not_a_finding":
    nots = [l for l in PL if not re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} ", l)]
    R["V-261922"]["details"] += "\nlines of the probe's sessions without a millisecond timestamp: %d of %d" % (len(nots), len(PL))
    if nots:
        R["V-261922"]["status"] = "open"
        R["V-261922"]["details"] += "\n\nFINDING: %d line(s) without a millisecond timestamp" % len(nots)

# ---- everything else: said, not guessed ------------------------------------------------------
LATER = {
 "6.3 (the org baseline, 6a.10)": "V-261859 V-261872 V-261884 V-261886 V-261887 V-261888 V-261889 V-261890 V-261897 V-261898 V-261914 V-261916 V-261923 V-261924 V-261926 V-261929 V-261935 V-261936 V-283674 V-261883",
 "6.4 (written answers and evidence)": "V-261858 V-261873 V-261874 V-261882 V-261893 V-261895 V-261901 V-261902 V-261903 V-261905 V-261906 V-261907 V-261910 V-261911 V-261912 V-261913 V-261915 V-261917 V-261918 V-261919 V-261920 V-261927 V-261930 V-261931 V-261967",
}
for piece, vids in LATER.items():
    for v in vids.split():
        if v not in R:
            res(v, "not_reviewed", "", "Not assessed yet: pg-stig.sh slice %s." % piece)

# ---- write -----------------------------------------------------------------------------------
now = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
role = "leader" if not F.get("in_recovery") else "standby"
doc = {"tool": "pg-stig.sh", "tool_version": toolver, "stig": "CD_Postgres_16_V1R3", "host": host, "ip": addr,
       "mac": H.get("mac", ""), "fqdn": H.get("fqdn", host), "time_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
       "node_role": role, "server_version": F.get("server_version_num"), "masked": mask == "1", "results": R}
path = os.path.join(out, "pg16-results-%s.json" % now)
with open(path, "w") as o: json.dump(doc, o, indent=1)
u = pwd.getpwnam(owner); os.chown(path, u.pw_uid, u.pw_gid); os.chmod(path, 0o644)
# ---- SELF-CHECK: no real application name may be in what leaves this node ----
txt = open(path).read()
leaks = sum(len(re.findall(r"(?<![\w$])" + re.escape(real) + r"(?![\w$])", txt)) for real in list(rnames) + list(dnames))
if leaks:
    os.remove(path)
    sys.exit("  [x] masking FAILED: %d occurrence(s) of a real application name in the results - the file was deleted; nothing was written" % leaks)
print("  [ok] masking verified: %d application role(s) and %d database(s) masked, 0 real names in the results file" % (len(rnames), len(dnames)))
print(path)
SCANPY
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] || die "the evaluation failed - its error is above"
  cmd_show "$(ls -t "$out"/pg16-results-*.json | head -1)"
}

# ---- the summary: counts, then every open rule with its reason -------------------------------
cmd_show() {
  local f="${1:-}"
  [ -n "$f" ] && [ -r "$f" ] || die "usage: $0 show <results.json>"
  python3 - "$f" <<'SHOWPY'
import json, sys, collections
d = json.load(open(sys.argv[1]))
R = d["results"]
c = collections.Counter(r["status"] for r in R.values())
print("  %s (%s), %s, pg-stig.sh %s - %d of %d rules judged; the rest not_reviewed, each with its reason" % (
    d["host"], d["node_role"], d["time_utc"], d["tool_version"], len(R) - c["not_reviewed"], len(R)))
print("     not_a_finding %3d   open %3d   not_applicable %3d   not_reviewed %3d" % (
    c["not_a_finding"], c["open"], c["not_applicable"], c["not_reviewed"]))
for v, r in sorted(R.items()):
    if r["status"] == "open":
        why = r["details"].split("FINDING: ", 1)[-1].splitlines()[0]
        print("     OPEN %-9s %s" % (v, why[:150]))
print("  results: %s" % sys.argv[1])
SHOWPY
}

# ---- the checklist, on stage-01: results + DISA's text from the zip --------------------------
cmd_cklb() {
  [ -r "$PG_STIG_ZIP" ] || die "no STIG zip at $PG_STIG_ZIP (PG_STIG_ZIP overrides) - this runs on stage-01"
  local into="${STIG_COLLECT_DIR:-$EVIDENCE}" hosts=("$@") h
  if [ "${#hosts[@]}" -eq 0 ]; then
    for h in "$into"/*/Postgres16; do [ -d "$h" ] && hosts+=("$(basename "$(dirname "$h")")"); done
  fi
  [ "${#hosts[@]}" -gt 0 ] || die "no <HOST>/Postgres16 results under $into - collect the pg nodes first"
  for h in "${hosts[@]}"; do
    h="$(printf '%s' "$h" | tr 'a-z' 'A-Z')"
    python3 - "$PG_STIG_ZIP" "$into/$h" <<'CKLBPY'
import glob, html, json, os, re, sys, uuid, zipfile
zpath, hdir = sys.argv[1:3]
res = sorted(glob.glob(os.path.join(hdir, "Postgres16", "pg16-results-*.json")))
if not res: sys.exit("  [x] no results in %s/Postgres16" % hdir)
d = json.load(open(res[-1]))
z = zipfile.ZipFile(zpath)
xn = [n for n in z.namelist() if n.endswith("-xccdf.xml")][0]
x = z.read(xn).decode("utf-8")
bench = re.search(r'<Benchmark[^>]*\bid="([^"]+)"', x).group(1)
stig_title = html.unescape(re.search(r"<Benchmark.*?<title>(.*?)</title>", x, re.S).group(1))
release = html.unescape(re.search(r'<plain-text id="release-info">(.*?)</plain-text>', x).group(1))
version = re.search(r"</status>.*?<version>(.*?)</version>", x, re.S).group(1)
refid = re.search(r"<dc:identifier>(.*?)</dc:identifier>", x)
stig_uuid = str(uuid.uuid4())
rules = []
for g in re.finditer(r'<Group id="(V-\d+)">(.*?)</Group>', x, re.S):
    vid, body = g.group(1), g.group(2)
    attr = dict(re.findall(r'(\w+)="([^"]*)"', re.search(r"<Rule ([^>]*)>", body).group(1)))
    desc = html.unescape(re.search(r"<Rule[^>]*>.*?<description>(.*?)</description>", body, re.S).group(1))
    disc = re.search(r"<VulnDiscussion>(.*?)</VulnDiscussion>", desc, re.S)
    r = d["results"].get(vid, {"status": "not_reviewed", "details": "", "comments": "Not in the results file."})
    stamp = "pg-stig.sh %s on %s (%s), %s\n" % (d["tool_version"], d["host"], d["node_role"], d["time_utc"])
    rules.append({
        "group_id_src": vid,
        "group_tree": [{"id": vid, "title": re.search(r"<title>(.*?)</title>", body).group(1), "description": "<GroupDescription></GroupDescription>"}],
        "group_id": vid, "severity": attr["severity"],
        "group_title": html.unescape(re.search(r"<Rule[^>]*>.*?<title>(.*?)</title>", body, re.S).group(1)),
        "rule_id_src": attr["id"], "rule_id": attr["id"].replace("_rule", ""),
        "rule_version": re.search(r"<version>(.*?)</version>", body).group(1),
        "rule_title": html.unescape(re.search(r"<Rule[^>]*>.*?<title>(.*?)</title>", body, re.S).group(1)),
        "fix_text": html.unescape(re.search(r"<fixtext[^>]*>(.*?)</fixtext>", body, re.S).group(1)),
        "weight": attr.get("weight", "10.0"),
        "check_content": html.unescape(re.search(r"<check-content>(.*?)</check-content>", body, re.S).group(1)),
        "check_content_ref": {"href": os.path.basename(xn), "name": "M"},
        "classification": "UNCLASSIFIED",
        "discussion": disc.group(1).strip() if disc else "",
        "false_positives": "", "false_negatives": "", "documentable": "false", "security_override_guidance": "",
        "potential_impacts": "", "third_party_tools": "", "ia_controls": "", "responsibility": "", "mitigations": "",
        "mitigation_control": "",
        "ccis": re.findall(r'<ident system="http://cyber.mil/cci">(CCI-\d+)</ident>', body),
        "reference_identifier": refid.group(1) if refid else "",
        "uuid": str(uuid.uuid4()), "stig_uuid": stig_uuid,
        "status": r["status"], "overrides": {},
        "comments": r.get("comments", ""),
        "finding_details": (stamp + r["details"]) if r.get("details") else stamp.rstrip("\n"),
    })
ck = {"title": "pg-stig_CD_Postgres_16", "id": str(uuid.uuid4()),
      "stigs": [{"stig_name": stig_title, "display_name": "Crunchy Data Postgres 16", "stig_id": bench,
                 "release_info": release, "version": version, "uuid": stig_uuid,
                 "reference_identifier": refid.group(1) if refid else "", "size": len(rules), "rules": rules}],
      "active": False, "mode": 1, "has_path": True,
      "target_data": {"target_type": "Computing", "host_name": d["host"].upper(), "ip_address": d["ip"], "mac_address": d["mac"],
                      "fqdn": d["fqdn"], "comments": "", "role": "Member Server", "is_web_database": True,
                      "technology_area": "Database", "web_db_site": "", "web_db_instance": "enclave-pg (Patroni, %s)" % d["node_role"],
                      "classification": ""},
      "cklb_version": "1.0"}
os.makedirs(os.path.join(hdir, "Checklist"), exist_ok=True)
stamp = os.path.basename(res[-1])[len("pg16-results-"):-len(".json")]
p = os.path.join(hdir, "Checklist", "%s_CD_Postgres16_V1R3_%s.cklb" % (d["host"].upper(), stamp))
json.dump(ck, open(p, "w"), indent=1)
from collections import Counter
c = Counter(r["status"] for r in rules)
print("  [ok] %s: %d rules - NotAFinding %d, Open %d, Not_Applicable %d, Not_Reviewed %d -> %s" % (
    d["host"], len(rules), c["not_a_finding"], c["open"], c["not_applicable"], c["not_reviewed"], p))
CKLBPY
  done
}

case "${1:-}" in
  scan) shift; cmd_scan "$@" ;;
  show) shift; cmd_show "$@" ;;
  cklb) shift; cmd_cklb "$@" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
