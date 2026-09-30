#!/usr/bin/env bash
# =========================================================================================
# pg-stig.sh - assess pg-01..03 against DISA's Crunchy Data PostgreSQL 16 STIG V1R3 (111 rules)
# (backlog B-06a slice 6). Evaluate-STIG only covers PostgreSQL 9.x, so this check is ours.
#
#     sudo ./pg-stig.sh scan            MACHINE: a pg node. Reads settings, catalogs and file
#                                       modes - NEVER a table's contents - judges every rule it
#                                       can, writes a results file. Prints a summary.
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
TOOL_VERSION="6.1"

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
  local host up out tmp facts rc=0 owner
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
  python3 - "$tmp" "$out" "$host" "$ME_ADDR" "$PG_STIG_MASK_APP" "$PG_STIG_MAP" "$PG_STIG_PLATFORM_ROLES" "$TOOL_VERSION" "$owner" <<'SCANPY' || rc=$?
import json, os, re, sys, time, pwd
tmp, out, host, addr, mask, mapfile, platform, toolver, owner = sys.argv[1:10]
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

# ---- everything else: said, not guessed ------------------------------------------------------
LATER = {
 "6.2 (the audit probe and the file checks)": "V-261861 V-261862 V-261863 V-261864 V-261870 V-261875 V-261876 V-261877 V-261878 V-261879 V-261880 V-261881 V-261885 V-261894 V-261904 V-261925 V-261934 V-261939 V-261942 V-261943 V-261945 V-261947 V-261951 V-261952 V-261957 V-261959 V-261963",
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
  scan) cmd_scan ;;
  show) shift; cmd_show "$@" ;;
  cklb) shift; cmd_cklb "$@" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
