#!/usr/bin/env python3
"""
facility-design.py - a facility scenario's ANSWERS in; its design, checks, diagram and open list out.

    python3 docs/facility-setups/facility-design.py show  01-facility-a                # print the design and checks
    python3 docs/facility-setups/facility-design.py show  01-facility-a SITE_HA=S1     # WHAT-IF: a variant, writes nothing
    python3 docs/facility-setups/facility-design.py set   01-facility-a SITE_HA=M1 [KEY=value ...] [--note "why"] [--by NAME]
    python3 docs/facility-setups/facility-design.py ask   01-facility-a                # every question, one at a time
    python3 docs/facility-setups/facility-design.py ask   01-facility-a A9 A5          # just these (ids or keys)
    python3 docs/facility-setups/facility-design.py ask   01-facility-a --open         # only what is unanswered
    python3 docs/facility-setups/facility-design.py build 01-facility-a                # regenerate the .md block and the .drawio
    python3 docs/facility-setups/facility-design.py new   02-facility-b "Facility B"   # a new scenario, every question open
    python3 docs/facility-setups/facility-design.py keys                               # every key, its question and its values
    python3 docs/facility-setups/facility-design.py serve [--port 8765]                # the same, as a web form on 127.0.0.1
    python3 docs/facility-setups/facility-design.py --check                            # exit 1 if any scenario's output is stale

ONE HOME PER ANSWER. A scenario's answers live in NN-name.env, one KEY='value' per line, with who set
it and when in the trailing comment. Everything derived from them - the block between the BEGIN/END
markers in NN-name.md, and the whole of NN-name.drawio - is generated here. Change an answer,
rebuild, read the diff. Never edit inside the markers or the .drawio: the pre-push hook runs --check
and refuses a push whose generated files do not match their .env.

THE CHECKS ARE THE POINT. Answers interact - a site recovery that needs a person (A9 S1/S2) with
nobody at the site (A8), a disconnect longer than the enclave CRL lasts (A5 against ca.sh) - and a
document written by hand lets the contradiction sit there. Every build prints them.

Numbers come from the script that owns them (ca.sh, 06a-postgres-ha.sh) or are measurements with
their source named in MEASURED below; any of them can be overridden in the .env, and the design says
where each came from. Standard library only - runs wherever python3 runs (stage-01 owns the repo).
FACILITY_DIR=<dir> points it at another folder of scenarios, for testing.
"""
import datetime
import importlib.util
import os
import re
import shlex
import subprocess
import sys
import textwrap
import xml.dom.minidom

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DIR = os.environ.get("FACILITY_DIR") or HERE
BEGIN = "<!-- BEGIN facility-design.py: generated from the .env - change answers with set or ask, never edit inside this block -->"
END = "<!-- END facility-design.py -->"


# ================================================================================== the questions
def C(id_, key, text, who, why, options, ask_if=None, free=None, done=None):
    """done: the one value that closes the question; any other answer still counts as open."""
    return dict(id=id_, key=key, text=text, who=who, why=why, kind="choice", options=options,
                ask_if=ask_if or (lambda a: True), free=free, done=done)


def N(id_, key, text, who, why, ask_if=None):
    return dict(id=id_, key=key, text=text, who=who, why=why, kind="number", options=[],
                ask_if=ask_if or (lambda a: True), free=None)


def T(id_, key, text, who, why, ask_if=None):
    return dict(id=id_, key=key, text=text, who=who, why=why, kind="text", options=[],
                ask_if=ask_if or (lambda a: True), free=None)


def g(a, k):
    return (a.get(k) or "").strip()


UNKNOWN = ("unknown", "Not known yet", "recorded as open")

# Asked in this order: A4 and A3 decide bought or built, A2 and A1 the accreditation shape and the
# hardware; the rest refine. A question whose ask_if is false does not apply and is never shown.
Q = [
    C("A4", "VENDOR_SYNC", "Does the mission application (COTS) support an external site that runs disconnected "
      "and syncs its data back?", "vendor", "bought or built: the vendor's feature, or a merge somebody builds and owns",
      [("yes", "Yes, it has that mode", "the merge is BOUGHT - the vendor's feature; the platform gives each site what it needs"),
       ("no", "No, it does not", "the merge is BUILT - through the product's own interfaces, owned by whoever builds it"),
       UNKNOWN]),
    C("A3", "RECORD_CASES", "During a disconnect, what does an external site do to records?", "mission owner",
      "what the merge must handle: an append, changes applied on top, or real conflicts",
      [("create", "Only creates new records", "case 1: the merge is an append - safe only with a number range per site"),
       ("update", "Also changes old records", "cases 1-2: sites also change records that existed before the cut; "
        "the main never touches those same records meanwhile"),
       ("both-edit", "Both sides may edit the same record", "cases 1-3: real conflicts, decided by a rule or a person (A3b)"),
       UNKNOWN]),
    C("A3b", "CONFLICT_RULE", "When both sides changed one record, how is it decided?", "mission owner",
      "what applies automatically, what waits for a person, what is lost",
      [("field-merge", "Field merge + a person for clashes", "different fields: both apply; same field: the record "
        "carries both values, flagged, until a named role decides - nothing is lost silently"),
       ("person-all", "A person decides every one", "any record changed on both sides waits for review - the simplest "
        "rule, and the most manual work after a long disconnect"),
       ("main-wins", "The main facility always wins", "the main's version stands; the site's change is kept for review "
        "but not applied"),
       ("newest-wins", "Newest change wins", "the later timestamp stands - silently drops the other side's change, and "
        "needs trusted clocks at every site"),
       UNKNOWN], ask_if=lambda a: g(a, "RECORD_CASES") == "both-edit"),
    T("A3c", "REVIEW_ROLE", "Which role works the review queue?", "mission owner",
      "someone named has to own every flagged clash",
      ask_if=lambda a: g(a, "RECORD_CASES") == "both-edit" and g(a, "CONFLICT_RULE") in ("field-merge", "person-all", "main-wins")),
    C("A2a", "LINK", "What physically carries the link between the main and the external sites?", "facility",
      "whether the link needs its own validated encryption and becomes part of the boundary",
      [("own-fibre", "The facility's own fibre, on its ground", "no bulk link encryption needed for crossing "
        "uncontrolled space; the services' own TLS still protects the traffic"),
       ("leased", "A leased circuit through uncontrolled space", "the link needs FIPS-validated encryption and is part "
        "of the security boundary"),
       ("tunnel", "An encrypted tunnel over another network", "FIPS-validated tunnel endpoints at the main and every "
        "site; the carrying network stays outside the boundary"),
       UNKNOWN]),
    C("A2b", "BOUNDARY", "One system in one accreditation boundary, or separate systems with interconnection "
      "agreements?", "AO", "one SSP, or one per site plus an agreement for every link",
      [("one", "One system, one authorization", "one SSP covers every site - so every site meets the full control "
        "set, physical protection included"),
       ("separate", "Separate systems + agreements", "each site authorized on its own, an interconnection agreement for "
        "every linked pair, and the merge moves records between systems"),
       UNKNOWN]),
    C("A1a", "SITES", "How many external sites?", "facility", "how many site builds, merges after a disconnect, licences",
      [("1", "1 site", "a single external site"),
       ("2-3", "2-3 sites", "a handful of sites"),
       ("4-10", "4-10 sites", "enough that a site must be one repeatable build with a parameter file per site"),
       UNKNOWN], free=r"^\d+(-\d+)?$"),
    C("A1b", "SITE_SCOPE", "What runs at each site during a disconnect?", "mission owner",
      "which record types the merge covers",
      [("whole", "The whole application", "every function at every site; the merge covers every record type"),
       ("part", "Only part of it", "a subset of functions and fewer record types to merge - name the part in the scenario"),
       UNKNOWN]),
    C("A1c", "USERS", "How many people use one site at the same time?", "facility", "each site's hardware size",
      [("under-10", "Under 10", "small hardware - a site is sized by its recovery model (A9), not by load"),
       ("10-50", "10-50", "a working office"),
       ("50-plus", "50+", "close to the main facility's own size"),
       UNKNOWN]),
    C("A9", "SITE_HA", "A site's host fails during a disconnect, and nobody from the main can help. What is "
      "acceptable?", "mission owner, AO accepts", "machines per site, and whether recovery needs a person there",
      [("M1", "Three hosts - keeps running", "the main enclave in miniature: keeps running automatically through one "
        "host loss, then degraded until the host is replaced"),
       ("M2", "Two hosts + a witness - keeps running", "keeps running automatically through either host's loss; the "
        "witness is a small box holding only quorum votes, at the site (the 2.8 witness design)"),
       ("S1", "One host + a warm standby", "no data lost; down for minutes while a PERSON promotes the standby"),
       ("S2", "One host + backup device + spare", "loses up to archive_timeout of changes; down for hours while a "
        "PERSON restores onto the spare"),
       UNKNOWN]),
    C("A8", "SITE_ADMIN", "During a disconnect, who can fix a site when something other than a host failure breaks it?",
      "facility", "admin access held at the sites, or a site that waits",
      [("local-admin", "A trained admin at each site", "local admin accounts and break-glass envelopes at every site, "
        "each in the audit scope"),
       ("nobody", "Nobody - wait for the reconnect", "a site runs the whole disconnect untended; staff at a broken site "
        "use paper, entered at the reconnect"),
       ("travel", "Main staff travel to it", "the disconnect cuts the network, not people: an admin goes to the site's "
        "console"),
       UNKNOWN]),
    N("A5", "DISCONNECT_DAYS", "What is the longest disconnect a site must survive untended, in days?", "facility",
      "clock, revocation lists, certificates, passwords and logs all have to last it"),
    C("A6c", "ORDERED_BY", "The main can disconnect at will - who may order a disconnect?", "facility",
      "whose will: the role that can cut every site off, and is trained for it",
      [("security", "The security officer", "the same role that restores the link at the reconnect (A6b)"),
       ("owner", "The system owner or ISSO", "a disconnect is an operational decision as well as a security one"),
       ("either", "Either of them", "both roles hold the procedure; whoever is on duty orders it"),
       UNKNOWN]),
    C("A6a", "CUT", "How is the link cut when the main disconnects?", "facility", "the procedure, and what proves the cut",
      [("physical", "Physically", "a person disconnects or powers off the link at the main"),
       ("config", "By configuration", "the network shuts the inter-site ports - fast, and only as good as the configuration"),
       ("both", "Both", "configuration first for speed, then a physical disconnect to make it certain"),
       UNKNOWN]),
    C("A6b", "RECONNECT", "Who authorises the reconnect?", "facility",
      "plugging the link back in starts nothing - who releases the merge",
      [("two-step", "Two steps, two roles", "security ends the disconnect and restores the link; the system owner or "
        "ISSO then releases each site's merge after its checks"),
       ("security", "The security officer alone", "ending the disconnect releases every site's merge"),
       ("owner", "The system owner or ISSO alone", "one person decides both the reconnect and the merge"),
       UNKNOWN]),
    C("A7", "SITE_DATA", "What does each external site hold?", "mission owner, privacy office",
      "which lookups work during a disconnect, and how many copies of the records exist",
      [("full", "A full copy of everything", "any lookup works during a disconnect; one complete copy of the records per "
        "site, each encrypted at rest and in the destruction scope"),
       ("subset", "Only what the site needs", "its own area, open records and recent history; a lookup for anything "
        "else fails during a disconnect"),
       UNKNOWN]),
    C("A10", "TOPOLOGY", "Are the external sites linked to each other, or only to the main?", "facility",
      "whether sites can reach each other without the main",
      [("hub", "Only to the main", "every site talks only to the main; a disconnect cuts every site from every other"),
       ("mesh", "Also to each other", "site-to-site links too - what they do in a disconnect is A10b"),
       UNKNOWN]),
    C("A10b", "DISCONNECT_SITE_SYNC", "During a disconnect, do the external sites sync each other, and how?", "facility",
      "a batch merge at the reconnect, or a sync engine running through the disconnect",
      [("none", "No - each site alone", "site-to-site links carry no data in a disconnect; one merge per site at the reconnect"),
       ("lead", "Yes, through a lead site", "a pre-named lead (and backup) runs the same hub as the main; the others "
        "sync with it"),
       ("p2p", "Yes, peer to peer", "every site merges with every site it reaches - a general multi-writer engine, the "
        "hardest thing to build and prove"),
       UNKNOWN], ask_if=lambda a: g(a, "TOPOLOGY") == "mesh"),
    C("A11", "UNPLANNED", "Is an unplanned link failure (cut fibre, dead switch) handled exactly like an ordered disconnect?",
      "mission owner", "one path or two",
      [("same", "Yes - one mechanism", "every loss of contact takes the disconnect path, so every link failure exercises it"),
       ("different", "No - an ordered disconnect is special", "two paths to build; the everyday one is not the one an "
        "ordered disconnect uses"),
       UNKNOWN]),
    C("A12", "REVOCATION", "Someone's access is withdrawn at the main during a disconnect. How do the sites stop that "
      "person?", "AO", "a procedure at the sites, or an accepted risk",
      [("phone-supervisor", "Phone + a site supervisor", "security phones the sites; a supervisor role in the "
        "application disables the user - vendor question V6"),
       ("accept", "Accepted risk until the reconnect", "the person stays valid at the sites for the whole disconnect"),
       UNKNOWN]),
    C("A14", "DRILL", "How often is a full disconnect drilled, merge included?", "facility",
      "a reconcile that has never run fails the first time it is real",
      [("quarterly", "Quarterly", "four full drills a year; the review queue becomes routine"),
       ("twice", "Twice a year", "two full drills a year"),
       ("yearly", "Yearly", "one full drill a year - the contingency-plan test cadence"),
       ("none", "Not drilled", "the reconcile first runs when it is real"),
       UNKNOWN]),
    C("A15a", "SPACE", "What space does a site have for its equipment?", "facility", "form factor and physical controls",
      [("room", "A locked room", "a dedicated, access-controlled room with its own rack"),
       ("cabinet", "A locking cabinet in a shared room", "the cabinet key and an access log become the controls"),
       ("varies", "Varies by site", "one site build that fits the smallest; physical controls written per site"),
       UNKNOWN]),
    C("A15b", "POWER", "What power does a site have?", "facility", "whether a site must survive a total power loss alone",
      [("generator", "Generator + UPS", "outages rare and short - the unattended restart is still needed, rarely"),
       ("ups", "UPS only", "a long cut takes the site down; it must restart unattended"),
       ("varies", "Varies by site", "design for the weakest: UPS only"),
       UNKNOWN]),
    T("V1", "VENDOR_FEATURE", "What is the vendor's sync feature called, and where is it documented?", "vendor",
      "the bought merge has to be named to be assessed", ask_if=lambda a: g(a, "VENDOR_SYNC") == "yes"),
    T("V2", "VENDOR_LICENCE", "Can an independent instance run at each site, and what does each cost in licences?",
      "vendor", "the per-site cost, times the site count"),
    T("V3", "VENDOR_NUMBERING", "How does the product number records - can numbering be split by site?", "vendor",
      "case 1 is safe only if numbers cannot collide"),
    T("V4", "VENDOR_INTERFACES", "What interfaces read and write records (API, import, export), and does writing "
      "through them keep the product's validation and audit trail?", "vendor", "the built merge goes through these, "
      "never the database", ask_if=lambda a: g(a, "VENDOR_SYNC") == "no"),
    T("V5", "VENDOR_PLATFORM", "Is an instance supported on Canonical Kubernetes and PostgreSQL 16?", "vendor",
      "every site runs it on this platform"),
    T("V6", "VENDOR_SUPERVISOR", "Can a supervisor role - not an administrator - disable a user in one instance, and "
      "are user accounts data the sync can carry?", "vendor", "A12 depends on it",
      ask_if=lambda a: g(a, "REVOCATION") == "phone-supervisor"),
    N("CRL", "DOD_CRL_DAYS", "How many days are DoD revocation lists valid from issue (their nextUpdate)?",
      "measured when CAC is built (6a.23)", "CAC logins at a site depend on them lasting the disconnect"),
    C("SURVEY", "SITE_SURVEY", "Has each site been surveyed - space, power, GPS antenna, key holders?", "facility",
      "the per-site facts the site build needs",
      [("not-started", "Not started", "no site surveyed"),
       ("in-progress", "In progress", "some sites surveyed"),
       ("done", "Done", "every site surveyed")], done="done"),
]
QBY = {q["id"]: q for q in Q}
QBY.update({q["key"]: q for q in Q})

# Measured or assumed numbers, with their source. Any can be overridden by the same key in the .env.
MEASURED = {
    "DRIFT_S_PER_DAY": ("0.583", "measured on lab hardware 2026-09-27/28 (poam.md AO-13)"),
    "AUDIT_MB_PER_DAY": ("25", "measured audit-log rate per machine (stig-tailor.sh; backlog N-2)"),
    "OS_PW_CEILING_DAYS": ("95", "STIG password max 60 + inactive 35 (stig-tailor.sh accounts)"),
    "CLOCK_TOLERANCE_S": ("5", "ASSUMED - how far a site clock may drift before it needs its own GPS"),
    "CERT_MARGIN_DAYS": ("14", "ASSUMED - margin before any certificate or list expires"),
}
# Read from the script that owns the value, so a changed default changes the design.
READ = {
    "CA_CRL_DAYS": ("scripts/enclave/ca.sh", r"CA_CRL_DAYS:-(\d+)"),
    "CA_LEAF_DAYS": ("scripts/enclave/ca.sh", r"CA_LEAF_DAYS:-(\d+)"),
    "PG_ARCHIVE_TIMEOUT": ("scripts/install/06a-postgres-ha.sh", r"PG_ARCHIVE_TIMEOUT:-(\d+)"),
}
KNOWN = set(q["key"] for q in Q) | set(MEASURED) | set(READ) | {"FACILITY"}


def facts(a):
    out = {}
    for k, (v, src) in MEASURED.items():
        out[k] = (float(g(a, k)), "set in the .env") if g(a, k) else (float(v), src)
    for k, (rel, pat) in READ.items():
        if g(a, k):
            out[k] = (float(g(a, k)), "set in the .env")
            continue
        try:
            m = re.search(pat, open(os.path.join(REPO, rel)).read())
        except OSError:
            m = None
        # Not found is said out loud, never defaulted silently: a check against a guessed number
        # would pass for the wrong reason.
        out[k] = (float(m.group(1)), "%s default" % rel) if m else (None, "NOT FOUND in %s" % rel)
    return out


# ============================================================================ the answers file
def split_comment(line):
    """(code, comment) - the first # outside single quotes; a shell-style '\\'' escape is honoured."""
    q, i = False, 0
    while i < len(line):
        c = line[i]
        if c == "'":
            q = not q
        elif c == "\\" and not q:
            i += 1
        elif c == "#" and not q:
            return line[:i], line[i + 1:].strip()
        i += 1
    return line, ""


def read_answers(path):
    vals, prov, lines = {}, {}, open(path).read().splitlines()
    for raw in lines:
        code, note = split_comment(raw)
        if not code.strip():
            continue
        for tok in shlex.split(code):
            if "=" in tok:
                k, v = tok.split("=", 1)
                vals[k], prov[k] = v, note
    return vals, prov, lines


def quote(v):
    return "'" + v.replace("'", "'\\''") + "'"


def fmt_line(k, v, note):
    s = "%s=%s" % (k, quote(v))
    return ("%-34s # %s" % (s, note)) if note else s


def write_answers(path, lines, changes):
    """changes: {key: (value, note)}. Replaces each key's line in place, appends new keys; atomic."""
    out, seen = [], set()
    for raw in lines:
        m = re.match(r"\s*([A-Z0-9_]+)=", split_comment(raw)[0])
        if m and m.group(1) in changes:
            k = m.group(1)
            out.append(fmt_line(k, *changes[k]))
            seen.add(k)
        else:
            out.append(raw)
    out += [fmt_line(k, *vn) for k, vn in changes.items() if k not in seen]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(out) + "\n")
    os.replace(tmp, path)


def by_default():
    try:
        n = subprocess.run(["git", "-C", REPO, "config", "user.name"], capture_output=True, text=True).stdout.strip()
    except OSError:
        n = ""
    return n or os.environ.get("USER") or os.environ.get("USERNAME") or "unknown"


def today():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")


def validate(k, v):
    """None if fine, else the reason."""
    if k not in KNOWN:
        return "unknown key %s - run: facility-design.py keys" % k
    if "\n" in v or "\r" in v:
        return "%s takes one line - the .env holds one answer per line" % k
    q = QBY.get(k)
    if v and (k in MEASURED or k in READ) and not re.match(r"^\d+(\.\d+)?$", v):
        return "%s takes a number" % k
    if v == "" or q is None:
        return None
    if q["kind"] == "choice":
        vals = [o[0] for o in q["options"]]
        if v in vals or (q["free"] and re.match(q["free"], v)):
            return None
        return "%s takes one of: %s" % (k, ", ".join(vals))
    if q["kind"] == "number" and not re.match(r"^\d+$", v):
        return "%s takes a whole number of days" % k
    return None


# ================================================================================= the engine
def is_open(q, a):
    if q.get("done"):
        return g(a, q["key"]) != q["done"]
    return g(a, q["key"]) in ("", "unknown")


def asked(a):
    return [q for q in Q if q["ask_if"](a)]


def opt(q, v):
    for o in q["options"]:
        if o[0] == v:
            return o
    return None


def says(a, key):
    o = opt(QBY[key], g(a, key))
    return o[2] if o else ""


def cap(s):
    return s[:1].upper() + s[1:]   # not str.capitalize(): that lowercases the rest, "A10b" -> "a10b"


def site_range(a):
    m = re.match(r"^(\d+)(?:-(\d+))?$", g(a, "SITES"))
    return (int(m.group(1)), int(m.group(2) or m.group(1))) if m else None


def span(lo, hi):
    return str(lo) if lo == hi else "%d-%d" % (lo, hi)


HA = {"M1": (3, 0), "M2": (2, 1), "S1": (2, 0), "S2": (1, 0)}
HA_SHORT = {"M1": "3 hosts", "M2": "2 hosts + witness", "S1": "host + warm standby", "S2": "1 host + backup + spare"}


def derive(a):
    f = facts(a)
    D = dict(checks=[], open=[], numbers=[], changes=[], adds=[], cost=[], sections=[])
    chk = lambda lvl, s: D["checks"].append((lvl, s))
    sec = lambda title, items: D["sections"].append((title, [i for i in items if i]))
    v = lambda k: g(a, k)
    sr = site_range(a)
    days = int(v("DISCONNECT_DAYS")) if v("DISCONNECT_DAYS").isdigit() else None
    built, bought = v("VENDOR_SYNC") == "no", v("VENDOR_SYNC") == "yes"
    sync = v("DISCONNECT_SITE_SYNC") if v("TOPOLOGY") == "mesh" else ("none" if v("TOPOLOGY") == "hub" else "")
    margin = int(f["CERT_MARGIN_DAYS"][0])
    for k in READ:
        if f[k][0] is None:
            chk("CONFLICT", "**%s** was %s - the checks that use it cannot run. Fix the pattern in READ, or set %s in the "
                ".env." % (k, f[k][1], k))

    # ---- numbers
    if sr:
        D["numbers"].append(("External sites (A1a)", span(*sr), "the answer"))
        if v("SITE_HA") in HA:
            h, w = HA[v("SITE_HA")]
            D["numbers"].append(("Hosts at the sites (A9 %s)" % v("SITE_HA"), span(sr[0] * h, sr[1] * h), "%d per site" % h))
            if w:
                D["numbers"].append(("Witness boxes", span(*sr), "one per site, at the site"))
    drift = gps = None
    if days is not None:
        rate, tol = f["DRIFT_S_PER_DAY"][0], f["CLOCK_TOLERANCE_S"][0]
        drift = rate * days
        gps = drift > tol or v("CONFLICT_RULE") == "newest-wins"
        D["numbers"].append(("Clock drift over %d days, no GPS" % days, "%.1f s" % drift,
                             "%.3f s/day, %s; tolerance %.0f s, %s" % (rate, f["DRIFT_S_PER_DAY"][1], tol, f["CLOCK_TOLERANCE_S"][1])))
        mb = f["AUDIT_MB_PER_DAY"][0] * days
        D["numbers"].append(("Audit logs per machine over %d days" % days, ("%.1f GB" % (mb / 1024)) if mb >= 1024 else "%.0f MB" % mb,
                             "%.0f MB/day, %s" % (f["AUDIT_MB_PER_DAY"][0], f["AUDIT_MB_PER_DAY"][1])))
        D["numbers"].append(("Everything that expires must outlast", "%d days" % (days + margin),
                             "the longest disconnect + %d days margin (%s)" % (margin, f["CERT_MARGIN_DAYS"][1])))
    for k, label in (("CA_CRL_DAYS", "Enclave CRL lifetime"), ("CA_LEAF_DAYS", "Enclave certificate lifetime")):
        if f[k][0] is not None:
            D["numbers"].append((label, "%d days" % f[k][0], f[k][1]))
    if v("SITE_HA") == "S2" and f["PG_ARCHIVE_TIMEOUT"][0] is not None:
        D["numbers"].append(("Changes lost if a site host dies (S2)", "up to %d s" % f["PG_ARCHIVE_TIMEOUT"][0], f["PG_ARCHIVE_TIMEOUT"][1]))

    # ---- checks: 🔴 two answers cannot both hold · 🟠 a cost to accept knowingly · 🔵 depends on work not done
    if v("SITE_HA") in ("S1", "S2") and v("SITE_ADMIN") == "nobody":
        chk("CONFLICT", "**A9 %s needs a person at the site** to %s, but **A8 says nobody fixes a site during a disconnect**. "
            "Choose M1 or M2, or put a trained person at each site." % (v("SITE_HA"), "promote the standby" if v("SITE_HA") == "S1" else "restore onto the spare"))
    if v("SITE_HA") in ("S1", "S2") and v("SITE_ADMIN") == "travel":
        chk("COST", "A9 %s recovers only when someone from the main reaches the site (A8 travel) - the site is down until then." % v("SITE_HA"))
    if days is not None:
        for k, what in (("CA_CRL_DAYS", "the enclave CRL"), ("CA_LEAF_DAYS", "an enclave certificate issued just before the cut")):
            life = f[k][0]
            if life is not None and days + margin > life:
                chk("CONFLICT", "**A5 %d days + %d margin outlasts %s** (%d days, %s): it expires mid-disconnect and TLS checks fail. "
                    "Raise %s (ca-params.env) above %d and set it here, or shorten A5." % (days, margin, what, life, f[k][1], k, days + margin))
        ceil = f["OS_PW_CEILING_DAYS"][0]
        if days > ceil and v("SITE_ADMIN") == "local-admin":
            chk("CONFLICT", "**A5 %d days outlasts the OS account ceiling** (%d, %s) - site admins' accounts are disabled "
                "mid-disconnect. Exempt them as break-glass is exempted, or shorten A5." % (days, ceil, f["OS_PW_CEILING_DAYS"][1]))
        if v("DOD_CRL_DAYS").isdigit() and int(v("DOD_CRL_DAYS")) < days + margin:
            chk("CONFLICT", "**DoD revocation lists last %s days; the longest disconnect needs %d.** When they expire, CAC logins at the "
                "site fail or revocation checking is relaxed - an AO decision either way." % (v("DOD_CRL_DAYS"), days + margin))
    if v("CONFLICT_RULE") == "newest-wins":
        chk("COST", "A3b newest-wins **silently drops the other side's change** - a stated, accepted loss - and needs a GPS clock "
            "at every site whatever the drift.")
    if v("CONFLICT_RULE") == "main-wins":
        chk("COST", "A3b main-wins: a site's correction never reaches the live record without a person applying it.")
    if built and sync == "lead":
        chk("COST", "**A4 no + A10b lead: the merge is a sync engine running through the disconnect**, not a batch job at the "
            "reconnect - a software product of its own around a COTS product that does not support it.")
    if built and sync == "p2p":
        chk("COST", "**A4 no + A10b peer to peer: a general multi-writer engine** that must converge after any partition - the "
            "hardest thing in this design to build and to prove correct.")
    if built and sync == "none":
        chk("COST", "A4 no: the merge is a built batch job around a product that does not support it, owned by whoever builds it.")
    if sync in ("lead", "p2p"):
        chk("COST", "**Checks are bypassed between sites** (A10b): a bad change at one site reaches the others before anything "
            "checks it; the main's staging sees it only at the reconnect.")
    if v("BOUNDARY") == "separate" and sr:
        mesh = v("TOPOLOGY") == "mesh"
        n = lambda s: s + (s * (s - 1) // 2 if mesh else 0)
        chk("COST", "A2b separate: **%s interconnection agreements** (every site to the main%s), and %s site authorizations "
            "besides the main's." % (span(n(sr[0]), n(sr[1])), ", plus every pair of sites" if mesh else "", span(*sr)))
    if v("DRILL") == "none":
        chk("COST", "A14: not drilled - the reconcile first runs when it is real.")
    if v("UNPLANNED") == "different":
        chk("COST", "A11: two paths - the everyday link failure does not exercise the ordered-disconnect path.")
    if v("REVOCATION") == "accept" and days is not None:
        chk("COST", "A12: a withdrawn person stays valid at the sites for up to %d days." % days)
    if v("SITE_DATA") == "full" and sr:
        chk("COST", "A7: **up to %d complete copies of records retrieved by personal identifier** outside the main "
            "facility - tell the privacy office; the records notice has to cover them." % sr[1])
    if v("POWER") in ("ups", "varies", "generator"):
        chk("DEPENDS", "A15b: a site must restart unattended after a total power loss - an **ordered cold start of the database "
            "and the cluster**, which the main build does not do yet (backlog 3.57).")
    if v("SITE_HA") == "M2":
        chk("DEPENDS", "A9 M2: the witness design (backlog 2.8) becomes required, and anything the main keeps on Ceph needs a "
            "two-host answer at a site.")
    if built and v("VENDOR_INTERFACES") == "":
        chk("DEPENDS", "A4 no: the built merge depends on **V4** - which interfaces the product offers to read and write records.")
    if v("REVOCATION") == "phone-supervisor" and v("VENDOR_SUPERVISOR") == "":
        chk("DEPENDS", "A12 depends on **V6** - a supervisor role that can disable a user in one instance.")
    if v("REVOCATION") == "phone-supervisor" and sync in ("none", ""):
        chk("COST", "A12: with no site-to-site sync in a disconnect, a disable does not travel - every site is phoned.")

    # ---- open
    for q in asked(a):
        if is_open(q, a):
            D["open"].append("**%s** %s - *%s*" % (q["id"], q["text"], q["who"]))

    # ---- what it changes in the current design
    D["changes"] = [
        ("Network: **fully disconnected, no egress** - locked", "**Still holds.** Every site is a closed system; a disconnect makes it more closed", "`HANDOFF.md` §1"),
        ("One site, one room", "%s external sites plus the main%s" % (span(*sr) if sr else "N (A1a open)",
                                                                       ", linked to each other" if v("TOPOLOGY") == "mesh" else ""), "`HANDOFF.md` §1, §4"),
        ("One database, one writer", "A writer at every site through a disconnect" +("; the lead also merges the others" if sync == "lead" else
                                                                                     "; every site merges with every site" if sync == "p2p" else ""), "B-06a"),
        ("The mission application is COTS", "The merge is %s" % ("the vendor's feature" if bought else "built around it, through its interfaces"
                                                               if built else "open - bought or built (A4)"), "6a.21"),
        ("One clock, the main's time master", ("A GPS time source at every site" if gps else
                                               "Drift accepted: %.1f s over the longest disconnect" % drift if drift is not None else "open (A5)"), "AO-13"),
        ("One authorization", {"one": "Still one - every site inside it", "separate": "One per site, plus interconnection agreements"}.get(v("BOUNDARY"), "open (A2b)"), "A2b"),
    ]

    # ---- the design
    lo_hi = span(*sr) if sr else "N"
    site_bits = []
    if v("SITE_HA") in HA:
        site_bits.append("%s (A9 %s)" % (QBY["SITE_HA"]["options"][[o[0] for o in QBY["SITE_HA"]["options"]].index(v("SITE_HA"))][1].split(" - ")[0].lower(), v("SITE_HA")))
    if gps:
        site_bits.append("a receive-only GPS time source (A5)")
    if v("POWER") in ("ups", "varies"):
        site_bits.append("a UPS, and nothing more assumed (A15b)")
    elif v("POWER") == "generator":
        site_bits.append("generator-backed power (A15b)")
    if v("SPACE") in ("cabinet", "varies"):
        site_bits.append("sized to fit a locking cabinet (A15a)")
    sec("Shape", [
        "The main facility is today's enclave, unchanged in shape%s." % (", plus a **sync hub**" if built else ", plus the vendor's sync feature" if bought else ""),
        "**%s external sites** (A1a)%s: %s." % (lo_hi, ", identical - one build procedure and a parameter file per site" if sr and sr[1] >= 2 else "",
                                                 "; ".join(site_bits) if site_bits else "hardware open (A9, A15)"),
        "Links: %s (A2a). %s (A10)." % (says(a, "LINK") or "open", {"hub": "Sites linked only to the main",
                                                                    "mesh": "Sites linked to each other as well as to the main"}.get(v("TOPOLOGY"), "Topology open")),
        ("**%s** (A2b)." % cap(says(a, "BOUNDARY"))) if says(a, "BOUNDARY") else "Boundary open (A2b).",
    ])
    sec("Data", [
        ("Each site holds %s: %s (A7)." % (opt(QBY["SITE_DATA"], v("SITE_DATA"))[1].lower(), says(a, "SITE_DATA"))) if v("SITE_DATA") in ("full", "subset") else "What each site holds is open (A7).",
        "Each site numbers new records from **its own range** (A3, V3) - decided before the first disconnect." if v("RECORD_CASES") in ("create", "update", "both-edit") else None,
        "**A site always works on its local copy**; the links carry sync, so a cut pauses sync instead of switching anything over.",
        "The scope is %s (A1b)." % says(a, "SITE_SCOPE") if says(a, "SITE_SCOPE") else None,
    ])
    merge = []
    if bought:
        merge.append("**Bought (A4):** the vendor's feature - %s." % (v("VENDOR_FEATURE") or "name and documentation open (V1)"))
    elif built:
        merge.append("**Built, not bought (A4):** reads and writes **through the product's own interfaces** (V4), never its database.")
        if v("RECORD_CASES") in ("update", "both-edit"):
            merge.append("Every change carries **site, record, field, before, after and version**; *changed* is judged against the "
                         "record **as it stood at the cut**.")
    else:
        merge.append("**Bought or built is open (A4)** - nothing below is settled until it is answered.")
    merge.append({"create": "**Case 1 only:** an append.", "update": "**Cases 1-2:** append, and apply changes the main did not touch.",
                  "both-edit": "**Cases 1-3** (A3). " + (cap(says(a, "CONFLICT_RULE")) + " (A3b)." if says(a, "CONFLICT_RULE") else "How a clash is decided is open (A3b).")}.get(v("RECORD_CASES"), "What the merge handles is open (A3)."))
    if v("RECORD_CASES") == "both-edit" and v("SITE_DATA") == "full":
        merge.append("A record **destroyed on one side and edited on the other** is a clash too.")
    if QBY["REVIEW_ROLE"]["ask_if"](a):
        merge.append(("The review queue is worked by **%s** (A3c)." % v("REVIEW_ROLE")) if v("REVIEW_ROLE") else "**Who works the review queue is open** (A3c).")
    merge.append({"lead": "**One component in two places:** the main normally, and the **pre-named lead site** during a disconnect, with a pre-named backup lead (A10b).",
                  "p2p": "**Every site runs a peer of the engine** during a disconnect and merges with every site it reaches (A10b).",
                  "none": "During a disconnect each site is alone; its changes wait for the reconnect."}.get(sync))
    sec("Sync and merge", merge)
    sec("Disconnected", [
        "**The main disconnects from the external sites at will** - for any reason, whenever it chooses.",
        ("**Ordered by:** %s (A6c)." % opt(QBY["ORDERED_BY"], v("ORDERED_BY"))[1].lower()) if v("ORDERED_BY") in ("security", "owner", "either") else "**Who may order a disconnect is open** (A6c).",
        "**Cut:** %s (A6a)." % says(a, "CUT") if says(a, "CUT") else "How the link is cut is open (A6a).",
        ("**Untended for up to %d days** (A5)%s." % (days, ": " + says(a, "SITE_ADMIN") + " (A8)" if says(a, "SITE_ADMIN") else "")) if days else "The longest disconnect is open (A5).",
        {"lead": "The sites keep syncing each other **through the lead**; a site that cannot reach the lead runs alone.",
         "p2p": "The sites keep syncing each other, **peer to peer**, through whatever links remain."}.get(sync),
        ("**Any loss of contact uses this same mechanism** (A11)%s." % ("; a site tries the main **through the mesh** first" if v("TOPOLOGY") == "mesh" else "")) if v("UNPLANNED") == "same" else
        ("An unplanned failure has its own path (A11)." if v("UNPLANNED") == "different" else None),
        "**Withdrawn access:** %s (A12)." % says(a, "REVOCATION") if says(a, "REVOCATION") else None,
    ])
    rc = {"two-step": ["**Step 1 - security** ends the disconnect and restores the link. Nothing syncs.",
                       "**Step 2 - the system owner or ISSO** releases the merge, site by site, after its checks."],
          "security": ["**The security officer** ends the disconnect, and that releases every site's merge."],
          "owner": ["**The system owner or ISSO** decides both the reconnect and the merge."]}.get(v("RECONNECT"), ["Who authorises the reconnect is open (A6b)."])
    inputs = (["the lead's merged state (every change tagged with its site)"] if sync == "lead" else []) + ["any lone site's changes"] + \
             (["paper records from a site that broke"] if v("SITE_ADMIN") == "nobody" else [])
    sec("Reconnect", ["Plugging the link back in **starts nothing** (A6b)."] + rc + [
        "In: %s -> **staging** at the main -> checks -> the merge%s -> the system of record%s." % (
            ", ".join(inputs), " -> clashes to the review queue" if v("RECORD_CASES") == "both-edit" else "",
            " -> back out to every site" if v("SITE_DATA") in ("full", "subset") else ""),
        "After an unplanned loss, with no disconnect ordered: step 2 alone (proposed, A11)." if v("UNPLANNED") == "same" and v("RECONNECT") == "two-step" else None,
    ])
    if days is not None:
        crl, dod = f["CA_CRL_DAYS"][0], v("DOD_CRL_DAYS")
        sec("Running untended for %d days" % days, [
            "Disks, logs and backups sized for it - nothing scheduled needs a person.",
            ("**Clock:** %.1f s of drift without GPS, over the %.0f s tolerance - **a receive-only GPS at every site**." % (drift, f["CLOCK_TOLERANCE_S"][0]) if gps and drift > f["CLOCK_TOLERANCE_S"][0] else
             "**Clock:** a GPS at every site - newest-wins needs trusted clocks." if gps else
             "**Clock:** %.1f s of drift without GPS, within the %.0f s tolerance - at the reconnect the clock steps by that much (STIG `makestep 1 -1`)." % (drift, f["CLOCK_TOLERANCE_S"][0])),
            "**Revocation lists** must outlast %d days: the enclave CRL is %s days; DoD lists %s." % (days + margin, "%.0f" % crl if crl else "?",
                                                                                                        "%s days" % dod if dod else "are not measured yet (CRL)"),
            "**Application passwords** must outlive %d days, or logins use CAC." % days,
            "**An alert** on any site certificate within %d days of expiry." % (days + margin),
            "**A total power loss restarts by itself:** power-on after AC loss, TPM disk unlock, a clean shutdown on the UPS signal, "
            "and an ordered cold start of the database and the cluster (3.57)." if v("POWER") in ("ups", "varies", "generator") else None,
        ])
    sec("Testing", ["%s (A14)%s." % (opt(QBY["DRILL"], v("DRILL"))[1], " - merge included; the untended length is proven by sizing and measurement, not by the drill"
                                      if v("DRILL") != "none" else "") if opt(QBY["DRILL"], v("DRILL")) and v("DRILL") != "unknown" else "Drills are open (A14)."])

    # ---- what it adds to this repo
    if built:
        D["adds"].append(("New", "**The sync and merge component**, with staging, checks and the review queue - the largest item, with no vendor support", "-"))
    D["adds"].append(("New", "**A site build**: the unattended build parameterised for %s, a parameter file per site" % HA_SHORT.get(v("SITE_HA"), "a site"),
                      "2.6" + (", the 2.8 witness design" if v("SITE_HA") == "M2" else "")))
    D["adds"].append(("Required", "**An unattended cold start** of Postgres and Kubernetes after a total power loss", "3.57"))
    if gps:
        D["adds"].append(("Changed", "**Time**: a GPS at every site, not just the main", "AO-13"))
    if v("LINK") in ("leased", "tunnel"):
        D["adds"].append(("New", "**FIPS-validated encryption on every inter-site link**", "A2a"))
    if v("SITE_ADMIN") == "local-admin":
        D["adds"].append(("New", "**Local admin accounts and break-glass envelopes at every site**", "stig-tailor.sh accounts"))
    D["adds"].append(("Changed", "**The SSP**: several sites, the links, physical controls per site, PPSM rows for the sync traffic", "baseline documents"))
    if v("SITE_DATA") in ("full", "subset"):
        D["adds"].append(("Changed", "**Records destruction at every site**, and the privacy office told about the copies", "3.27"))
    if built:
        D["cost"] = [
            "The sites are buildable from what this repository already does. **The merge is a software product of its own**%s, "
            "around a COTS product whose vendor does not support it. It needs an owner, a test suite and a lifecycle." % (
                ": a continuously running, multi-site, field-level sync" if sync in ("lead", "p2p") else ""),
            "**Every product upgrade is re-tested against it** before it reaches any site - the interfaces it relies on can change.",
            "**The main and every site run the same product version**, so an upgrade is one coordinated event - never during a disconnect.",
        ]
    D.update(gps=gps, drift=drift, days=days, sync=sync, built=built, bought=bought, sr=sr)
    return D


# ============================================================================== the markdown
ICON = {"CONFLICT": "🔴", "COST": "🟠", "DEPENDS": "🔵"}


def md_block(name, a, prov):
    D = derive(a)
    A = asked(a)
    n_open = sum(1 for q in A if is_open(q, a))
    n_conf = sum(1 for c in D["checks"] if c[0] == "CONFLICT")
    L = []
    L.append("**Status:** %d of %d questions answered · **%d conflict%s** · %d open. Answers: [`%s.env`](%s.env) · "
             "diagram: [`%s.drawio`](%s.drawio) · generated by [`facility-design.py`](facility-design.py)."
             % (len(A) - n_open, len(A), n_conf, "" if n_conf == 1 else "s", n_open, name, name, name, name))
    L.append("")
    L.append("## Checks")
    L.append("")
    L.append("🔴 conflict - two answers cannot both hold · 🟠 cost - a consequence to accept knowingly · 🔵 depends on work "
             "not done yet · ⬜ open")
    L.append("")
    order = {"CONFLICT": 0, "COST": 1, "DEPENDS": 2}
    for lvl, s in sorted(D["checks"], key=lambda c: order[c[0]]):
        L.append("- %s %s" % (ICON[lvl], s))
    if not D["checks"]:
        L.append("- none")
    L += ["", "## What it changes in the current design", "", "| The design today | This facility | Source |", "|---|---|---|"]
    L += ["| %s | %s | %s |" % r for r in D["changes"]]
    L += ["", "## Answers", "", "| # | Question | Who answers | Answer | Set by |", "|---|---|---|---|---|"]
    for q in A:
        val = g(a, q["key"])
        o = opt(q, val)
        if is_open(q, a):
            ans = "⬜ open"
        elif o:
            ans = "**%s** - %s" % (o[1], o[2])
        else:
            ans = "**%s**%s" % (val, " days" if q["kind"] == "number" else "")
        L.append("| **%s** | %s | %s | %s | %s |" % (q["id"], q["text"], q["who"], ans, (prov.get(q["key"]) or "").replace("|", "/")))
    L += ["", "## The design", ""]
    for title, items in D["sections"]:
        L.append("**%s.**" % title)
        L.append("")
        L += ["- " + i for i in items]
        L.append("")
    if D["numbers"]:
        L += ["## Numbers", "", "| | Value | From |", "|---|---|---|"]
        L += ["| %s | **%s** | %s |" % r for r in D["numbers"]]
        L.append("")
    L += ["## What it adds to this repo, when built", "", "| | Item | Builds on |", "|---|---|---|"]
    L += ["| **%s** | %s | %s |" % r for r in D["adds"]]
    if D["cost"]:
        L += ["", "## The honest cost", ""] + [D["cost"][0], ""] + ["- " + c for c in D["cost"][1:]]
    L += ["", "## Still open", ""]
    L += ["- ⬜ " + o for o in D["open"]] or ["- nothing"]
    L += ["", "## Every question's options", "", "So a change is a choice between known alternatives. ✅ marks the answer.", ""]
    for q in A:
        if q["kind"] != "choice":
            continue
        L.append("**%s** %s" % (q["id"], q["text"]))
        L.append("")
        L += ["| | Option | What it means |", "|---|---|---|"]
        for o in q["options"]:
            if o[0] == "unknown":
                continue
            L.append("| %s | `%s` %s | %s |" % ("✅" if g(a, q["key"]) == o[0] else "", o[0], o[1], o[2]))
        L.append("")
    return "\n".join(L).rstrip("\n")


def splice(md_text, block):
    if BEGIN in md_text and END in md_text:
        pre, rest = md_text.split(BEGIN, 1)
        post = rest.split(END, 1)[1]
        return pre + BEGIN + "\n" + block + "\n" + END + post
    return md_text.rstrip("\n") + "\n\n" + BEGIN + "\n" + block + "\n" + END + "\n"


# =============================================================================== the diagram
def load_md():
    spec = importlib.util.spec_from_file_location("make_diagrams", os.path.join(REPO, "docs/diagrams/make-diagrams.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def drawio(name, a):
    m = load_md()
    Page, BASE, FLOW_DASH = m.Page, m.BASE, m.FLOW_DASH
    D = derive(a)
    v = lambda k: g(a, k)
    sync, sr = D["sync"], D["sr"]
    LINK = "endArrow=none;html=1;rounded=0;strokeColor=#6c8ebf;strokeWidth=3;fontSize=11;"
    CUT = "endArrow=none;html=1;rounded=0;strokeColor=#cc0000;strokeWidth=3;dashed=1;"
    LOW = "exitX=1;exitY=0.95;entryX=0;entryY=0.5;"
    PGP = BASE + "fillColor=#d5e8d4;strokeColor=#82b366;dashed=1;"
    SVP = BASE + "fillColor=#fff2cc;strokeColor=#d6b656;dashed=1;"
    src = "Answers in docs/facility-setups/%s.env; the design in %s.md. GENERATED by facility-design.py - change an answer and " \
          "rebuild, never edit this file." % (name, name)
    title = v("FACILITY") or name

    def st(ok, style="planned"):
        return style if ok else "option"

    def legend(p, x=1700, y=100):
        p.box(x, y, 270, 260, "<b>Notation</b>", "zone")
        p.box(x + 10, y + 28, 250, 24, "exists today", BASE + "fillColor=#ffffff;strokeColor=#333333;", 10)
        p.box(x + 10, y + 58, 250, 24, "designed, not built", "planned", 10)
        p.box(x + 10, y + 88, 250, 24, "still open", "option", 10)
        p.box(x + 14, y + 120, 22, 22, "", "gap")
        p.box(x + 44, y + 118, 210, 26, "link cut (disconnect)", "text", 10)
        p.box(x + 10, y + 152, 250, 100, src, "text", 9)

    def boundary(p, label):
        p.box(30, 100, 1640, 780, label, "zone", 12)
        p.box(835, 893, 30, 30, "", "gap")
        p.box(30, 935, 1640, 60, "<b>OUTSIDE</b> - internet and every other network. No connection from any site, in any state.", "zone_out", 12)

    def main_facility(p, db_label, note):
        z = p.box(60, 150, 640, 600, "<b>MAIN FACILITY</b> - the internal system, the system of record", "host", 13)
        p.box(90, 195, 580, 80, "<b>Mission application (COTS)</b><br>on Kubernetes - 3 control planes, 4 workers", "k8s", 12)
        p.box(90, 290, 580, 80, db_label, "pg", 12)
        p.box(90, 385, 580, 80, "<b>Services</b><br>DNS - CA - mirror - Harbor - monitoring - time master", "svc", 12)
        p.box(90, 480, 580, 60, "<b>Backups</b> - vm-backup.sh - pgBackRest", "svc", 12)
        hub = {"no": "<b>Sync hub</b> - built, not bought (A4)<br>field merge - staging - checks - review queue",
               "yes": "<b>The vendor's sync feature</b> (A4)<br>%s" % (v("VENDOR_FEATURE") or "named in V1")}.get(v("VENDOR_SYNC"), "<b>Merge: bought or built?</b> (A4 open)")
        p.box(90, 555, 580, 85, hub, st(v("VENDOR_SYNC") in ("yes", "no")), 12)
        p.box(90, 655, 580, 80, note, "note")
        return z

    def site(p, ttl, y, a1, b1, c1):
        z = p.box(1000, y, 640, 240, ttl, "host", 13)
        p.box(1020, y + 35, 600, 50, a1, "planned", 11)
        p.box(1020, y + 95, 600, 70, b1, PGP, 11)
        p.box(1020, y + 175, 600, 50, c1, SVP, 11)
        return z

    hw = HA_SHORT.get(v("SITE_HA"), "hosts: A9 open")
    hw += " - GPS clock" if D["gps"] else ""
    hw += {"generator": " - generator + UPS", "ups": " - UPS", "varies": " - UPS"}.get(v("POWER"), "")
    hw += " - fits a locking cabinet" if v("SPACE") in ("cabinet", "varies") else ""
    data = {"full": "a full copy of every record", "subset": "the records it needs"}.get(v("SITE_DATA"), "what it holds: A7 open")
    scope = {"whole": "the whole of it", "part": "part of it"}.get(v("SITE_SCOPE"), "scope: A1b open")
    numbered = ", own number range" if v("RECORD_CASES") in ("create", "update", "both-edit") else ""
    lead = sync == "lead"
    t1 = "<b>EXTERNAL SITE 1</b>" + (" - lead during a disconnect (A10b)" if lead else "")
    t2 = "<b>EXTERNAL SITE 2</b>" + (" - backup lead" if lead else "")
    count = span(*sr) if sr else "N (A1a open)"
    linklab = {"own-fibre": "own fibre, controlled ground - sync", "leased": "leased circuit, encrypted - sync",
               "tunnel": "encrypted tunnel - sync"}.get(v("LINK"), "link: A2a open")
    bound = {"one": "<b>ONE CLOSED SYSTEM, ONE AUTHORIZATION</b> - no egress in any state (A2b)",
             "separate": "<b>CLOSED SYSTEMS</b> - each site its own authorization, joined by interconnection agreements (A2b)"}.get(
        v("BOUNDARY"), "<b>CLOSED</b> - one authorization or several is open (A2b)")
    mesh = v("TOPOLOGY") == "mesh"
    untended = ("untended up to %d days" % D["days"]) if D["days"] else "disconnect length: A5 open"

    # 1. normal operation
    p1 = Page("1 - Normal operation", 1990, 1100)
    p1.title("%s - 1. Normal operation: one closed system across sites" % title,
             "The main facility and %s identical external sites%s. Every site works on its own copy; the links carry sync." % (count, ", linked to each other too" if mesh else ""))
    legend(p1)
    boundary(p1, bound)
    m1 = main_facility(p1, "<b>PostgreSQL HA</b> - pg-01..03, Patroni, synchronous<br>the system of record", "Today's enclave, unchanged in shape.")
    s1 = site(p1, t1, 150, "<b>%s</b> (A9)" % hw, "<b>Mission application</b> - %s<br><b>Local database</b> - %s%s" % (scope, data, numbered),
              "own monitoring - backups - CRL cache - TPM unlock, unattended restart")
    s2 = site(p1, t2, 410, "<b>%s</b>" % hw, "<b>Mission application</b> - %s<br><b>Local database</b> - %s%s" % (scope, data, numbered),
              "own monitoring - backups - CRL cache - TPM unlock, unattended restart")
    sn = p1.box(1000, 670, 640, 80, "<b>... SITES 3 to N</b> - %s in all (A1a), identical: one build procedure, one parameter file per site" % count,
                st(bool(sr)), 12)
    p1.edge(m1, s1, linklab, LINK)
    p1.edge(m1, s2, "", LINK)
    p1.edge(m1, sn, "", LINK + LOW)
    if mesh:
        p1.edge(s1, s2, "mesh (A10)", LINK)
    p1.box(720, 140, 260, 170, "<b>Every site always works on its local copy</b>; the links carry sync. When the main disconnects, "
           "sync with it pauses - nothing at the site switches over.", "planned", 11)
    p1.box(720, 540, 260, 130, "<b>Link (A2a):</b> " + (says(a, "LINK") or "open"), st(bool(says(a, "LINK"))), 11)
    p1.box(30, 1010, 1640, 40, src, "text", 11)

    # 2. disconnected
    p2 = Page("2 - Disconnected", 1990, 1100)
    sub2 = {"lead": "the sites sync through the lead", "p2p": "the sites sync peer to peer", "none": "every site runs alone"}.get(sync, "site-to-site sync open (A10b)")
    p2.title("%s - 2. Disconnected: the main has cut the link at will, %s" % (title, sub2),
             "Every site keeps running, %s (A5, A8)." % untended)
    legend(p2)
    boundary(p2, "<b>CLOSED</b> - the main cut off" + ("; the external sites still linked to each other" if mesh else ""))
    ordered = {"security": "the security officer", "owner": "the system owner or ISSO", "either": "the security officer or the system owner/ISSO"}
    m2 = main_facility(p2, "<b>PostgreSQL HA</b> - keeps writing<br>records numbered from the main's range",
                       "<b>Ordered by:</b> " + (ordered.get(v("ORDERED_BY")) or "still open") + " (A6c). <b>Cut:</b> " + (says(a, "CUT") or "A6a open") + " (A6a).")
    if lead:
        a1, b1 = "<b>Sync hub</b> - the SAME component as the main's (A10b)", "<b>Local database</b> - its own writes, plus every change from the sites that reach it; clashes flagged for the main's review queue"
    elif sync == "p2p":
        a1, b1 = "<b>Sync engine peer</b> - merges with every site it reaches (A10b)", "<b>Local database</b> - its own writes plus every reachable site's"
    else:
        a1, b1 = "<b>Mission application</b> - keeps running alone", "<b>Local database</b> - its own writes%s; every change since the cut kept for the merge" % numbered
    clock = ("GPS clock" if D["gps"] else "clock drifts %.1f s" % D["drift"] if D["drift"] is not None else "clock: A5 open")
    s1 = site(p2, t1 if lead else "<b>EXTERNAL SITE 1</b>", 150, a1, b1, "%s - CRLs must outlast the disconnect - %s" % (clock, untended))
    s2 = site(p2, t2 if lead else "<b>EXTERNAL SITE 2</b>", 410, "<b>Mission application</b> - keeps running",
              "<b>Local database</b> - its own writes%s%s" % (numbered, "; syncs with the lead" if lead else "; syncs with every site it reaches" if sync == "p2p" else ""),
              "power cut: restarts by itself - power-on, TPM unlock, ordered cold start (3.57)")
    lone = "<b>SITE N - cannot reach %s</b>: runs alone, its changes merge at the reconnect" % ("the lead" if lead else "another site" if sync == "p2p" else "anything")
    if v("UNPLANNED") == "same":
        lone += " (A11: the same path as a cut fibre)"
    sn = p2.box(1000, 670, 640, 80, lone, "planned", 12)
    p2.edge(m2, s1, "", CUT)
    p2.edge(m2, s2, "", CUT)
    p2.edge(m2, sn, "", CUT + LOW)
    p2.box(845, 343, 30, 30, "", "gap")
    p2.box(845, 476, 30, 30, "", "gap")
    p2.box(835, 700, 30, 30, "", "gap")
    if lead:
        p2.edge(s2, s1, "syncs through the lead", FLOW_DASH)
    elif sync == "p2p":
        p2.edge(s2, s1, "peer sync", FLOW_DASH)
    rev = {"phone-supervisor": "<b>Withdrawn access (A12):</b> security phones the sites; a supervisor role in the application disables the user%s." % (
        ", and it syncs through the lead" if lead else ""), "accept": "<b>Withdrawn access (A12):</b> accepted risk - the person stays valid at the sites until the reconnect."}
    p2.box(720, 140, 260, 170, rev.get(v("REVOCATION"), "<b>Withdrawn access:</b> A12 open"), st(v("REVOCATION") in rev), 11)
    broken = {"nobody": "<b>A site that breaks:</b> nobody fixes it during the disconnect (A8). Staff use paper, entered at the reconnect.",
              "local-admin": "<b>A site that breaks:</b> its trained admin fixes it (A8).",
              "travel": "<b>A site that breaks:</b> an admin from the main travels to it (A8)."}
    p2.box(720, 525, 260, 130, broken.get(v("SITE_ADMIN"), "<b>A site that breaks:</b> A8 open"), st(v("SITE_ADMIN") in broken), 11)
    p2.box(30, 1010, 1640, 40, src, "text", 11)

    # 3. reconnect and reconcile
    p3 = Page("3 - Reconnect and reconcile", 1990, 1100)
    p3.title("%s - 3. Reconnect and reconcile" % title,
             "Plugging the link back in starts nothing. What comes back is checked in staging, then merged.")
    legend(p3)
    if v("RECONNECT") == "two-step":
        r1 = p3.box(40, 110, 560, 80, "<b>Step 1 - security</b> ends the disconnect and restores the link (A6b). Nothing syncs.", "planned", 12)
        r2 = p3.box(660, 110, 980, 80, "<b>Step 2 - the system owner or ISSO</b> releases the merge, site by site, after the checks (A6b)"
                    + (". After an unplanned loss, with no disconnect ordered: this step alone (A11)" if v("UNPLANNED") == "same" else ""), "planned", 12)
        p3.edge(r1, r2, "", FLOW_DASH)
    else:
        txt = {"security": "<b>The security officer</b> ends the disconnect, which releases every site's merge (A6b)",
               "owner": "<b>The system owner or ISSO</b> decides the reconnect and the merge (A6b)"}.get(v("RECONNECT"), "<b>Who authorises the reconnect</b> - A6b open")
        p3.box(40, 110, 1600, 80, txt, st(v("RECONNECT") in ("security", "owner")), 12)
    i1 = p3.box(40, 230, 500, 80, "<b>The lead's merged state</b><br>every change tagged with the site that made it" if lead else
                "<b>Each site's changes since the cut</b><br>one set per site, checksummed", "planned", 12)
    i2 = p3.box(580, 230, 500, 80, "<b>Changes from any site that ran alone</b>", "planned", 12)
    ins = [i1, i2]
    if v("SITE_ADMIN") == "nobody":
        ins.append(p3.box(1120, 230, 520, 80, "<b>Paper records</b> from a site that broke (A8)<br>entered by hand", "planned", 12))
    stg = p3.box(40, 360, 720, 70, "<b>STAGING at the main facility</b> - not the live system", "planned", 12)
    chk = p3.box(820, 360, 820, 70, "<b>Checks</b> - checksums - valid records - content scan - clashes found", "planned", 12)
    for x in ins:
        p3.edge(x, stg, "", FLOW_DASH)
    p3.edge(stg, chk, "", FLOW_DASH)
    cases = []
    rcases = v("RECORD_CASES")
    if rcases in ("create", "update", "both-edit"):
        cases.append(p3.box(40, 480, 380, 100, "<b>Case 1 - new records</b><br>append. Numbers cannot collide: a range per site", "planned", 12))
    if rcases in ("update", "both-edit"):
        cases.append(p3.box(440, 480, 380, 100, "<b>Case 2 - a record changed on one side only</b><br>apply", "planned", 12))
    if rcases == "both-edit":
        rule = {"field-merge": "different fields: both apply. Same field: REVIEW QUEUE", "person-all": "REVIEW QUEUE - a person decides every one",
                "main-wins": "the main's version stands; the site's kept for review", "newest-wins": "the later timestamp stands (trusted clocks)"}.get(v("CONFLICT_RULE"), "how decided: A3b open")
        cases.append(p3.box(840, 480, 400, 100, "<b>Case 3 - both sides changed it</b><br>" + rule, st(v("CONFLICT_RULE") in ("field-merge", "person-all", "main-wins", "newest-wins")), 12))
        if v("SITE_DATA") == "full":
            cases.append(p3.box(1260, 480, 380, 100, "<b>Destroyed on one side, edited on the other</b><br>a clash: REVIEW QUEUE", "planned", 12))
        if QBY["REVIEW_ROLE"]["ask_if"](a):
            p3.box(1260, 610, 380, 60, ("<b>Queue worked by:</b> %s (A3c)" % v("REVIEW_ROLE")) if v("REVIEW_ROLE") else "<b>Who works the queue</b> - still open (A3c)",
                   st(bool(v("REVIEW_ROLE"))), 11)
    if not cases:
        cases.append(p3.box(40, 480, 1200, 100, "<b>What the merge handles</b> - A3 open", "option", 12))
    for x in cases:
        p3.edge(chk, x, "", FLOW_DASH)
    sor_txt = {"no": "written through the product's own interfaces (V4), never its database",
               "yes": "merged by the vendor's own sync feature (A4)"}.get(v("VENDOR_SYNC"), "bought or built: A4 open")
    sor = p3.box(380, 630, 840, 80, "<b>Internal system - the system of record</b><br>" + sor_txt, "pg", 12)
    for x in cases:
        p3.edge(x, sor, "", FLOW_DASH)
    back = p3.box(380, 750, 840, 60, "<b>Then back out to every site</b> - " + ({"full": "a full copy, two-way (A7)", "subset": "the records each needs (A7)"}.get(v("SITE_DATA"), "A7 open")),
                  st(v("SITE_DATA") in ("full", "subset")), 12)
    p3.edge(sor, back, "", FLOW_DASH)
    p3.box(30, 840, 530, 160, "<b>Why the database cannot do this:</b> streaming replication has one writer - rejoining a promoted copy "
           "(pg_rewind) discards its writes. Logical replication stops at the first conflicting row. The merge is application logic.", "note")
    p3.box(580, 840, 530, 160, "<b>Whatever the reason for the disconnect</b>, the sites ran outside the main's control" +
           (" - and synced each other unchecked (A10b)" if sync in ("lead", "p2p") else "") + ". Staging and checks come before the merge.", "note")
    if D["built"]:
        p3.box(1130, 840, 540, 160, "<b>Product upgrades:</b> the main and every site run the same version, and each upgrade is re-tested "
               "against the sync engine first - one coordinated event, never during a disconnect.", "note")
    p3.box(30, 1010, 1640, 40, src, "text", 11)
    content = m.render([p1, p2, p3])
    xml.dom.minidom.parseString(content)   # refuse to hand back anything that is not well-formed XML
    return content


# ==================================================================================== commands
def paths(name):
    name = re.sub(r"\.(env|md|drawio)$", "", os.path.basename(name))
    return name, os.path.join(DIR, name + ".env"), os.path.join(DIR, name + ".md"), os.path.join(DIR, name + ".drawio")


def scenarios():
    return sorted(f[:-4] for f in os.listdir(DIR) if re.match(r"^\d\d-.+\.env$", f))


def expected(name):
    name, env, md, dio = paths(name)
    a, prov, _ = read_answers(env)
    cur = open(md).read() if os.path.exists(md) else "# %s\n" % (a.get("FACILITY") or name)
    return splice(cur, md_block(name, a, prov)), drawio(name, a)


def rebuild(name):
    """Write the .md block and the .drawio where they changed. [(path relative to the repo, 'wrote'|'current')]"""
    name, env, md, dio = paths(name)
    new_md, new_dio = expected(name)
    out = []
    for path, content in ((md, new_md), (dio, new_dio)):
        old = open(path).read() if os.path.exists(path) else None
        if old != content:
            with open(path, "w") as f:
                f.write(content)
        out.append((os.path.relpath(path, REPO), "wrote" if old != content else "current"))
    return out


def cmd_build(name):
    for rel, what in rebuild(name):
        print("%-8s %s" % (what, rel))
    summary(name)


def summary(name, a=None):
    if a is None:
        a = read_answers(paths(name)[1])[0]
    D = derive(a)
    n = {k: sum(1 for c in D["checks"] if c[0] == k) for k in ICON}
    print("\n%s: %d conflict(s), %d cost(s), %d depends, %d open" % (name, n["CONFLICT"], n["COST"], n["DEPENDS"], len(D["open"])))
    for lvl, s in D["checks"]:
        if lvl == "CONFLICT":
            print("  CONFLICT  " + re.sub(r"\*\*", "", s))


def wrap(s, first, rest=None):
    return textwrap.fill(re.sub(r"\*|`", "", s), 100, initial_indent=first,
                         subsequent_indent=" " * len(first) if rest is None else rest)


def cmd_show(name, overrides):
    name, env, md, dio = paths(name)
    a, prov, _ = read_answers(env)
    for k, val in overrides.items():
        err = validate(k, val)
        if err:
            sys.exit("show: " + err)
        a[k] = val
    D = derive(a)
    print("%s%s" % (a.get("FACILITY") or name, "  -- WHAT-IF: " + " ".join("%s=%s" % kv for kv in overrides.items()) + " (nothing written)" if overrides else ""))
    print("\nCHECKS  (CONFLICT = two answers cannot both hold, COST = accept knowingly, DEPENDS = work not done yet)")
    for lvl, s in sorted(D["checks"], key=lambda c: ["CONFLICT", "COST", "DEPENDS"].index(c[0])):
        print(wrap(s, "  %-9s " % lvl))
    for title, items in D["sections"]:
        print("\n" + title.upper())
        for i in items:
            print(wrap(i, "  - "))
    if D["numbers"]:
        print("\nNUMBERS")
        for r in D["numbers"]:
            print("  %-42s %-12s %s" % (r[0], r[1], r[2]))
    print("\nSTILL OPEN")
    for o in D["open"] or ["nothing"]:
        print(wrap(o, "  - "))


def prov_note(by, old, note=""):
    return "%s %s (was %s)%s" % (by, today(), old or "open", ": " + note if note else "")


def apply_answers(name, pairs, note, by):
    """Validate EVERY pair before writing ANY, then write only the changed ones. {key: (old, new)}; ValueError if invalid."""
    name, env, md, dio = paths(name)
    a, prov, lines = read_answers(env)
    for k, val in pairs.items():
        err = validate(k, val)
        if err:
            raise ValueError(err)
    changed = {k: (g(a, k), val) for k, val in pairs.items() if g(a, k) != val}
    if changed:
        write_answers(env, lines, {k: (new, prov_note(by, old, note)) for k, (old, new) in changed.items()})
    return changed


def cmd_set(name, pairs, note, by):
    try:
        changed = apply_answers(name, pairs, note, by)
    except ValueError as e:
        sys.exit("set: %s" % e)
    for k, val in pairs.items():
        print(("set       %s=%s   (was %s)" % (k, val, changed[k][0] or "open")) if k in changed else "unchanged %s=%s" % (k, val))
    cmd_build(name)


def cmd_ask(name, ids, only_open, by):
    name, env, md, dio = paths(name)
    done = set()
    print("%s - Enter keeps the current answer, s skips, q stops. Each answer is saved as you give it." % name)
    while True:
        a, prov, lines = read_answers(env)
        todo = [q for q in Q if q["id"] not in done and q["ask_if"](a)
                and (not ids or q["id"] in ids or q["key"] in ids) and (not only_open or is_open(q, a))]
        if not todo:
            break
        q = todo[0]
        done.add(q["id"])
        cur = g(a, q["key"])
        print("\n[%s] %s" % (q["id"], q["text"]))
        print(wrap("who answers: %s - why: %s" % (q["who"], q["why"]), "      "))
        if q["kind"] == "choice":
            for i, o in enumerate(q["options"], 1):
                print("   %s %d) %-10s %s" % ("*" if o[0] == cur else " ", i, o[0], o[1]))
                print(wrap(o[2], "                   "))
        print("      now: %s%s" % (cur or "open", "   (%s)" % prov.get(q["key"]) if prov.get(q["key"]) else ""))
        while True:
            try:
                r = input("  %s > " % ("number" if q["kind"] == "choice" else "days" if q["kind"] == "number" else "text, - clears")).strip()
            except EOFError:
                r = "q"
            if r in ("", "s"):
                val = None
            elif r == "q":
                cmd_build(name)
                return
            elif q["kind"] == "choice" and r.isdigit() and 1 <= int(r) <= len(q["options"]):
                val = q["options"][int(r) - 1][0]
            elif q["kind"] == "text":
                val = "" if r == "-" else r
            else:
                val = r
            if val is not None:
                err = validate(q["key"], val)
                if err:
                    print("  " + err)
                    continue
                if val != cur:
                    write_answers(env, lines, {q["key"]: (val, prov_note(by, cur))})
            break
    cmd_build(name)


NAME_RE = r"^\d\d-[a-z0-9][a-z0-9-]*$"


def create_scenario(name, title):
    """A new scenario's .env (every question open) and .md; ValueError rather than overwrite anything."""
    if not re.match(NAME_RE, name):
        raise ValueError("a scenario is named like 02-facility-b: two digits, a dash, lowercase letters, digits and dashes")
    if not title or "\n" in title or "\r" in title:
        raise ValueError("give the facility a one-line title - its characteristics, never its identity")
    name, env, md, dio = paths(name)
    if os.path.exists(env) or os.path.exists(md):
        raise ValueError("%s already exists - refusing to overwrite it" % name)
    head = ["# %s.env - %s's answers. ONE HOME PER ANSWER: the block in %s.md and the whole of %s.drawio are" % (name, title, name, name),
            "# generated from this file by facility-design.py. origin is PUBLIC: describe the facility by its",
            "# characteristics, never its identity.", "FACILITY=%s" % quote(title), ""]
    with open(env, "w") as f:
        f.write("\n".join(head + ["%s=''" % q["key"] for q in Q]) + "\n")
    with open(md, "w") as f:
        f.write("# %s\n\n## The scenario as given\n\n- (describe it - characteristics, never identity)\n" % title)
    return name


def cmd_new(name, title):
    try:
        create_scenario(name, title)
    except ValueError as e:
        sys.exit("new: %s" % e)
    print("created  %s" % os.path.relpath(paths(name)[1], REPO))
    cmd_build(name)


def cmd_keys():
    for q in Q:
        vals = "|".join(o[0] for o in q["options"]) if q["kind"] == "choice" else ("<days>" if q["kind"] == "number" else "<text>")
        print("%-5s %-20s %-40s %s" % (q["id"], q["key"], vals, q["text"]))
    print("\nnumbers (override in the .env):")
    for k, (val, src) in MEASURED.items():
        print("      %-20s %-40s %s" % (k, val, src))
    for k, (rel, _) in READ.items():
        print("      %-20s %-40s read from %s" % (k, "(read)", rel))


def cmd_check():
    stale = []
    for name in scenarios():
        _, env, md, dio = paths(name)
        new_md, new_dio = expected(name)
        for path, content in ((md, new_md), (dio, new_dio)):
            if not os.path.exists(path) or open(path).read() != content:
                stale.append(os.path.relpath(path, REPO))
    if stale:
        print("facility designs STALE - they do not match their .env:")
        for s in stale:
            print("   " + s)
        print("fix:  python3 docs/facility-setups/facility-design.py build <scenario>   then commit docs/facility-setups/")
        sys.exit(1)
    print("facility designs current: %d scenario(s)" % len(scenarios()))


# ================================================================================= the web form
# `serve` is the same engine behind a browser form: every question as choices, the checks redrawn on
# every click (a what-if until Save), and Save writes the .env and rebuilds exactly as `set` does -
# same validation, same who-and-when comment. It listens on 127.0.0.1 ONLY: reach it through VS
# Code's port forwarding or a SecureCRT tunnel. Every API call must carry the key printed at start,
# and the Host header must be localhost, so another web page open in the same browser cannot post
# answers to it (cross-site requests cannot set the key header; a rebound DNS name fails the Host check).
GROUPS = [("1 - Bought or built", ("A4", "A3", "A3b", "A3c")),
          ("2 - Boundary, sites and size", ("A2a", "A2b", "A1a", "A1b", "A1c")),
          ("3 - Running alone", ("A9", "A8", "A5")),
          ("4 - Disconnect and reconnect", ("A6c", "A6a", "A6b", "A7", "A10", "A10b", "A11", "A12")),
          ("5 - Drills, space and power", ("A14", "A15a", "A15b")),
          ("6 - The vendor's answers", ("V1", "V2", "V3", "V4", "V5", "V6")),
          ("7 - Measured later", ("CRL", "SURVEY"))]


def group(q):
    for title, ids in GROUPS:
        if q["id"] in ids:
            return title
    return "Other"


def num(x):
    return "" if x is None else "%g" % x


def clean_answers(answers):
    """Posted answers -> (valid {key: value}, {key: reason})."""
    clean, errors = {}, {}
    for k, v in (answers or {}).items():
        v = str(v if v is not None else "").strip()
        err = validate(k, v)
        if err:
            errors[k] = err
        else:
            clean[k] = v
    return clean, errors


def view(name, a=None, prov=None):
    name, env, md, dio = paths(name)
    if a is None:
        a, prov, _ = read_answers(env)
    D = derive(a)
    f0 = facts({})
    n = {k: sum(1 for c in D["checks"] if c[0] == k) for k in ICON}
    return dict(
        name=name, facility=g(a, "FACILITY") or name, scenarios=scenarios(), by=by_default(),
        questions=[dict(id=q["id"], key=q["key"], text=q["text"], who=q["who"], why=q["why"], kind=q["kind"], group=group(q),
                        free=bool(q["free"]), options=[dict(value=o[0], label=o[1], says=o[2]) for o in q["options"]],
                        applies=bool(q["ask_if"](a)), open=is_open(q, a)) for q in Q],
        assumptions=[dict(key=k, default=num(f0[k][0]), source=f0[k][1]) for k in list(MEASURED) + list(READ)],
        answers={k: g(a, k) for k in sorted(KNOWN)}, prov=prov or {},
        checks=D["checks"], open=D["open"], sections=D["sections"], numbers=D["numbers"],
        counts=dict(conflict=n["CONFLICT"], cost=n["COST"], depends=n["DEPENDS"], open=len(D["open"])), errors={})


def preview(name, answers):
    """A what-if over the saved answers: invalid values are reported and left out, nothing is written."""
    a, prov, _ = read_answers(paths(name)[1])
    clean, errors = clean_answers(answers)
    a.update(clean)
    out = view(name, a, prov)
    out["errors"] = errors
    return out


def serve(port, by):
    import http.server
    import json
    import secrets
    import urllib.parse
    token = secrets.token_urlsafe(18)

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version, sys_version = "facility-design", ""

        def log_message(self, fmt, *args):
            sys.stderr.write("  %s %s\n" % (self.command, self.path.split("?")[0]))

        def host_ok(self):
            host = (self.headers.get("Host") or "").strip()
            host = host[1:host.index("]")] if host.startswith("[") and "]" in host else host.rsplit(":", 1)[0]
            return host in ("127.0.0.1", "localhost", "::1")

        def send(self, code, obj, ctype="application/json"):
            data = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
            self.send_response(code)
            for k, v in (("Content-Type", ctype + "; charset=utf-8"), ("Content-Length", str(len(data))),
                         ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("X-Frame-Options", "DENY"),
                         ("Referrer-Policy", "no-referrer"),
                         ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                          "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")):
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def scenario(self, n):
            if not n:
                s = scenarios()
                if not s:
                    raise LookupError("no scenarios yet - click New facility")
                return s[0]
            if not re.match(NAME_RE, n) or not os.path.exists(paths(n)[1]):
                raise LookupError("no scenario named %s" % n)
            return n

        def gate(self):
            if not self.host_ok():
                self.send(403, {"error": "refused: the Host must be localhost"})
                return False
            if self.path != "/" and not self.path.startswith("/?") and not secrets.compare_digest(self.headers.get("X-Token") or "", token):
                self.send(403, {"error": "refused: missing or wrong key - open the URL that serve printed"})
                return False
            return True

        def do_GET(self):
            if not self.gate():
                return
            u = urllib.parse.urlparse(self.path)
            try:
                if u.path == "/":
                    return self.send(200, PAGE.encode(), "text/html")
                if u.path == "/api/state":
                    return self.send(200, view(self.scenario(urllib.parse.parse_qs(u.query).get("name", [""])[0])))
                return self.send(404, {"error": "not found"})
            except LookupError as e:
                return self.send(404, {"error": str(e)})

        def do_POST(self):
            if not self.gate():
                return
            if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
                return self.send(415, {"error": "send application/json"})
            n = int(self.headers.get("Content-Length") or 0)
            if n > 262144:
                return self.send(413, {"error": "too large"})
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return self.send(400, {"error": "not JSON"})
            path = urllib.parse.urlparse(self.path).path
            try:
                if path == "/api/preview":
                    return self.send(200, preview(self.scenario(body.get("name")), body.get("answers")))
                if path == "/api/save":
                    nm = self.scenario(body.get("name"))
                    clean, errors = clean_answers(body.get("answers"))
                    if errors:
                        return self.send(400, {"error": "not saved - " + "; ".join(errors.values()), "errors": errors})
                    note = str(body.get("note") or "").replace("\n", " ").replace("\r", " ").strip()
                    changed = apply_answers(nm, clean, note, by)
                    written = rebuild(nm)
                    sys.stderr.write("  saved %s: %s\n" % (nm, ", ".join(sorted(changed)) or "no changes"))
                    return self.send(200, {"changed": sorted(changed), "written": written})
                if path == "/api/new":
                    nm = create_scenario(str(body.get("name") or "").strip(), str(body.get("title") or "").strip())
                    rebuild(nm)
                    sys.stderr.write("  created %s\n" % nm)
                    return self.send(200, {"name": nm})
                return self.send(404, {"error": "not found"})
            except LookupError as e:
                return self.send(404, {"error": str(e)})
            except ValueError as e:
                return self.send(400, {"error": str(e)})

    try:
        srv = http.server.HTTPServer(("127.0.0.1", port), Handler)
    except OSError as e:
        sys.exit("serve: cannot listen on 127.0.0.1:%d (%s) - try --port <another>" % (port, e))
    print("facility-design web form for %s - Ctrl-C stops it." % os.path.relpath(DIR, REPO))
    print("  open:   http://127.0.0.1:%d/?t=%s" % (port, token))
    print("  listening on 127.0.0.1 only. From Windows: VS Code forwards the port by itself (PORTS tab) -")
    print("  ctrl-click the link above; or a SecureCRT tunnel: local %d -> 127.0.0.1:%d on the stage-01 session." % (port, port))
    print("  saving as: %s   (change with --by NAME)\n" % by, flush=True)   # flushed: a redirected stdout would hold the key back
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped.")


PAGE = r'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Facility design</title>
<style>
:root{--bg:#f6f7f9;--panel:#fff;--ink:#1d232b;--muted:#5d6875;--line:#d9dee5;--accent:#2f5d8a;--accent-ink:#fff;
--conflict:#b42318;--conflict-bg:#fdecea;--cost:#b54708;--cost-bg:#fef3e2;--depends:#1d5fa8;--depends-bg:#e8f1fb;
--dirty:#fff7d6;--dirty-line:#d4a017}
@media (prefers-color-scheme:dark){:root{--bg:#14181d;--panel:#1c2229;--ink:#e6e9ed;--muted:#9aa4b0;--line:#2e3742;
--accent:#6ea3d6;--accent-ink:#0d1117;--conflict:#ff8a80;--conflict-bg:#3a1d1b;--cost:#ffb366;--cost-bg:#3a2a16;
--depends:#8cc0f5;--depends-bg:#16283b;--dirty:#3a3216;--dirty-line:#d4a017}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
header{position:sticky;top:0;z-index:5;background:var(--panel);border-bottom:1px solid var(--line);padding:10px 16px;
display:flex;flex-wrap:wrap;gap:8px 10px;align-items:center}
header h1{font-size:17px;margin:0 6px 0 0}
select,input,button{font:inherit;color:inherit}
select,input[type=text],input[type=number]{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:5px 8px}
button{border:1px solid var(--line);background:var(--panel);border-radius:6px;padding:6px 12px;cursor:pointer}
button.primary{background:var(--accent);color:var(--accent-ink);border-color:var(--accent);font-weight:600}
button:disabled{opacity:.45;cursor:default}
.chips{display:flex;gap:6px;flex-wrap:wrap}
.chip{border-radius:999px;padding:2px 10px;font-size:13px;font-weight:600}
.c-conflict{background:var(--conflict-bg);color:var(--conflict)}.c-cost{background:var(--cost-bg);color:var(--cost)}
.c-depends{background:var(--depends-bg);color:var(--depends)}.c-open{color:var(--muted);border:1px solid var(--line)}
.spacer{flex:1}.small{font-size:12.5px;color:var(--muted)}
main{display:grid;grid-template-columns:minmax(0,1fr) 430px;gap:16px;padding:16px;max-width:1500px;margin:0 auto}
@media (max-width:1000px){main{grid-template-columns:1fr}}
.side{position:sticky;top:70px;align-self:start;max-height:calc(100vh - 86px);overflow:auto}
@media (max-width:1000px){.side{position:static;max-height:none}}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:22px 0 8px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px 14px;margin-bottom:10px}
.card.dirty{background:var(--dirty);border-color:var(--dirty-line)}
.card.na{display:none}
.qhead{display:flex;gap:8px;align-items:baseline}
.qid{font-weight:700;color:var(--accent);min-width:46px}
.qtext{font-weight:600}
.badge{font-size:12px;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:0 5px;margin-left:auto;white-space:nowrap}
.meta{font-size:13px;color:var(--muted);margin:2px 0 8px 54px}
.opts{margin-left:54px;display:grid;gap:3px}
.opt{display:grid;grid-template-columns:20px 1fr;gap:6px;padding:5px 6px;border-radius:6px;cursor:pointer;border:1px solid transparent}
.opt:hover{background:var(--bg)}
.opt.sel{border-color:var(--accent)}
.opt input{margin-top:4px}
.says{font-size:13px;color:var(--muted)}
.field{margin:6px 0 0 54px}.field input{width:100%}
.prov{margin:6px 0 0 54px;font-size:12px;color:var(--muted)}
.err{color:var(--conflict);font-size:13px;margin:4px 0 0 54px}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px 14px;margin-bottom:12px}
.panel h3{margin:0 0 8px;font-size:14px}
.check{padding:6px 8px;border-radius:6px;margin-bottom:6px;font-size:13.5px}
.k-CONFLICT{background:var(--conflict-bg)}.k-COST{background:var(--cost-bg)}.k-DEPENDS{background:var(--depends-bg)}
ul{margin:0;padding-left:18px}li{margin:3px 0;font-size:13.5px}
table{border-collapse:collapse;width:100%;font-size:13px}td{border-top:1px solid var(--line);padding:4px;vertical-align:top}
summary{cursor:pointer;font-weight:600}
code{font-size:12.5px;background:var(--bg);padding:0 3px;border-radius:3px}
#toast{position:fixed;bottom:16px;left:50%;transform:translateX(-50%);background:var(--ink);color:var(--bg);padding:10px 16px;
border-radius:8px;display:none;max-width:90vw;z-index:9}
#toast.bad{background:var(--conflict);color:#fff}
</style></head>
<body>
<header>
  <h1>Facility design</h1>
  <select id="scn" title="Scenario"></select>
  <input type="text" id="facility" size="18" title="The facility's name - its characteristics, never its identity (origin is public)">
  <button id="newbtn" type="button">New facility...</button>
  <div class="chips" id="chips"></div>
  <span class="spacer"></span>
  <span id="dirty" class="small"></span>
  <input type="text" id="note" size="26" placeholder="Why (kept in the .env comment)">
  <button id="discard" type="button" disabled>Discard</button>
  <button id="save" class="primary" type="button" disabled>Save &amp; rebuild</button>
</header>
<main>
  <section id="questions"></section>
  <aside class="side">
    <div class="panel"><h3>Checks</h3>
      <div class="small" style="margin-bottom:8px">&#x1F534; conflict - two answers cannot both hold &middot; &#x1F7E0; cost - accept it knowingly &middot; &#x1F535; depends on work not done yet &middot; &#x2B1C; open</div>
      <div id="checks"></div></div>
    <div class="panel"><h3>Still open</h3><ul id="open"></ul></div>
    <div class="panel"><h3>Numbers</h3><table id="numbers"></table></div>
    <div class="panel"><details><summary>The design, as it will be written</summary><div id="design"></div></details></div>
    <div class="panel small" id="files"></div>
  </aside>
</main>
<div id="toast"></div>
<script>
"use strict";
const params = new URLSearchParams(location.search);
const TOKEN = params.get("t") || "";
const ICON = {CONFLICT: "\u{1F534}", COST: "\u{1F7E0}", DEPENDS: "\u{1F535}"};
const ORDER = {CONFLICT: 0, COST: 1, DEPENDS: 2};
let S = null, A = {}, SAVED = {}, timer = null, seq = 0;
const $ = (id) => document.getElementById(id);

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"}[c]));
}
function md(s) {
  return esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*([^*]+)\*/g, "<i>$1</i>");
}
async function api(path, body) {
  const r = await fetch(path, {method: body ? "POST" : "GET", headers: {"X-Token": TOKEN, "Content-Type": "application/json"},
                               body: body ? JSON.stringify(body) : undefined});
  let j;
  try { j = await r.json(); } catch (e) { j = {error: "HTTP " + r.status}; }
  if (!r.ok) { const err = new Error(j.error || "HTTP " + r.status); err.data = j; throw err; }
  return j;
}
function toast(msg, bad) {
  const t = $("toast");
  t.textContent = msg; t.className = bad ? "bad" : ""; t.style.display = "block";
  clearTimeout(toast.h); toast.h = setTimeout(() => { t.style.display = "none"; }, bad ? 10000 : 5000);
}
function dirtyKeys() {
  return Object.keys(A).filter((k) => (A[k] || "") !== (SAVED[k] || ""));
}
function updateDirty() {
  const d = dirtyKeys();
  $("save").disabled = d.length === 0;
  $("discard").disabled = d.length === 0;
  $("dirty").textContent = d.length ? d.length + " unsaved change" + (d.length === 1 ? "" : "s") : "";
  document.querySelectorAll(".card[data-key]").forEach((c) => c.classList.toggle("dirty", d.includes(c.dataset.key)));
}
function setAnswer(key, value) {
  A[key] = value; updateDirty(); schedule();
}
function card(q) {
  const c = document.createElement("div");
  c.className = "card"; c.dataset.key = q.key; c.id = "q-" + q.key;
  let h = '<div class="qhead"><span class="qid">' + esc(q.id) + '</span><span class="qtext">' + esc(q.text) +
          '</span><span class="badge" hidden>open</span></div><div class="meta">' + esc(q.who) + " &mdash; " + esc(q.why) + "</div>";
  if (q.kind === "choice") {
    h += '<div class="opts">' + q.options.map((o) =>
      '<label class="opt"><input type="radio" name="' + esc(q.key) + '" value="' + esc(o.value) + '"><span><b>' + esc(o.label) +
      "</b> <code>" + esc(o.value) + '</code><br><span class="says">' + esc(o.says) + "</span></span></label>").join("") + "</div>";
    if (q.free) h += '<div class="field"><input type="text" data-free="1" placeholder="or an exact value, e.g. 6 or 5-8"></div>';
  } else if (q.kind === "number") {
    h += '<div class="field"><input type="number" min="0" step="1" placeholder="days"></div>';
  } else {
    h += '<div class="field"><input type="text" placeholder="the answer, one line - blank leaves it open"></div>';
  }
  h += '<div class="err" hidden></div><div class="prov"></div>';
  c.innerHTML = h;
  c.querySelectorAll("input[type=radio]").forEach((r) => r.addEventListener("change", () => { setAnswer(q.key, r.value); syncCard(q); }));
  const free = c.querySelector("input[data-free]");
  if (free) free.addEventListener("input", () => { setAnswer(q.key, free.value.trim()); syncCard(q, true); });
  const fld = c.querySelector(".field input:not([data-free])");
  if (fld) fld.addEventListener("input", () => setAnswer(q.key, fld.value.replace(/[\r\n]+/g, " ").trim()));
  return c;
}
function syncCard(q, fromFree) {
  const c = $("q-" + q.key), v = A[q.key] || "";
  c.querySelectorAll("input[type=radio]").forEach((r) => {
    r.checked = r.value === v; r.closest(".opt").classList.toggle("sel", r.checked);
  });
  const free = c.querySelector("input[data-free]");
  if (free && !fromFree) free.value = q.options.some((o) => o.value === v) ? "" : v;
  const fld = c.querySelector(".field input:not([data-free])");
  if (fld && document.activeElement !== fld) fld.value = v;
  c.querySelector(".prov").textContent = S.prov[q.key] ? "set by " + S.prov[q.key] : "";
}
function assumptionCard(x) {
  const c = document.createElement("div");
  c.className = "card"; c.dataset.key = x.key; c.id = "q-" + x.key;
  c.innerHTML = '<div class="qhead"><span class="qid"></span><span class="qtext">' + esc(x.key) + '</span></div><div class="meta">default ' +
    esc(x.default || "none") + " &mdash; " + esc(x.source) + '</div><div class="field"><input type="text" inputmode="decimal" placeholder="' +
    esc(x.default) + '"></div><div class="err" hidden></div><div class="prov"></div>';
  const f = c.querySelector("input");
  f.value = A[x.key] || "";
  f.addEventListener("input", () => setAnswer(x.key, f.value.trim()));
  c.querySelector(".prov").textContent = S.prov[x.key] ? "set by " + S.prov[x.key] : "";
  return c;
}
function build() {
  const box = $("questions");
  box.innerHTML = "";
  let grp = null;
  S.questions.forEach((q) => {
    if (q.group !== grp) {
      grp = q.group;
      const h = document.createElement("h2"); h.textContent = grp; box.appendChild(h);
    }
    box.appendChild(card(q)); syncCard(q);
  });
  const h = document.createElement("h2");
  h.textContent = "8 - Assumptions: blank uses the default shown";
  box.appendChild(h);
  S.assumptions.forEach((x) => box.appendChild(assumptionCard(x)));
}
function applyView(v) {
  v.questions.forEach((q) => {
    const c = $("q-" + q.key);
    if (!c) return;
    c.classList.toggle("na", !q.applies);
    c.querySelector(".badge").hidden = !q.open;
  });
  document.querySelectorAll(".card .err").forEach((e) => { e.hidden = true; });
  Object.keys(v.errors || {}).forEach((k) => {
    const c = $("q-" + k);
    if (c) { const e = c.querySelector(".err"); e.textContent = v.errors[k]; e.hidden = false; }
  });
  const n = v.counts;
  $("chips").innerHTML = '<span class="chip c-conflict">' + ICON.CONFLICT + " " + n.conflict + " conflict" + (n.conflict === 1 ? "" : "s") +
    '</span><span class="chip c-cost">' + ICON.COST + " " + n.cost + ' cost</span><span class="chip c-depends">' + ICON.DEPENDS + " " +
    n.depends + ' depends</span><span class="chip c-open">⬜ ' + n.open + " open</span>";
  $("checks").innerHTML = v.checks.length ? v.checks.slice().sort((x, y) => ORDER[x[0]] - ORDER[y[0]]).map((c) =>
    '<div class="check k-' + c[0] + '">' + ICON[c[0]] + " " + md(c[1]) + "</div>").join("") : '<div class="small">none</div>';
  $("open").innerHTML = v.open.length ? v.open.map((o) => "<li>" + md(o) + "</li>").join("") : "<li>nothing</li>";
  $("numbers").innerHTML = v.numbers.map((r) => "<tr><td>" + esc(r[0]) + "</td><td><b>" + esc(r[1]) + '</b></td><td class="small">' +
    esc(r[2]) + "</td></tr>").join("");
  $("design").innerHTML = v.sections.map((s) => '<h3 style="margin:12px 0 4px">' + esc(s[0]) + "</h3><ul>" +
    s[1].map((i) => "<li>" + md(i) + "</li>").join("") + "</ul>").join("");
  $("files").innerHTML = "Save writes <code>" + esc(v.name) + ".env</code> and rebuilds <code>" + esc(v.name) +
    ".md</code> (below its marker) and <code>" + esc(v.name) + ".drawio</code>. Saving as <b>" + esc(v.by) + "</b>.";
}
function schedule() {
  clearTimeout(timer);
  timer = setTimeout(async () => {
    const mine = ++seq;
    try {
      const v = await api("/api/preview", {name: S.name, answers: A});
      if (mine !== seq) return;
      applyView(v);
    } catch (e) { toast(e.message, true); }
  }, 200);
}
async function load(name) {
  S = await api("/api/state?name=" + encodeURIComponent(name || ""));
  A = Object.assign({}, S.answers);
  SAVED = Object.assign({}, S.answers);
  $("scn").innerHTML = S.scenarios.map((s) => "<option" + (s === S.name ? " selected" : "") + ">" + esc(s) + "</option>").join("");
  $("facility").value = A.FACILITY || "";
  document.title = (A.FACILITY || S.name) + " - facility design";
  build(); applyView(S); updateDirty();
  history.replaceState(null, "", "?t=" + encodeURIComponent(TOKEN) + "&s=" + encodeURIComponent(S.name));
}
function leaveOk() {
  return dirtyKeys().length === 0 || confirm("Discard the unsaved changes?");
}
$("facility").addEventListener("input", (e) => setAnswer("FACILITY", e.target.value.replace(/[\r\n]+/g, " ").trim()));
$("scn").addEventListener("change", async (e) => {
  if (!leaveOk()) { e.target.value = S.name; return; }
  try { await load(e.target.value); } catch (err) { toast(err.message, true); }
});
$("discard").addEventListener("click", () => { if (leaveOk()) load(S.name).catch((e) => toast(e.message, true)); });
$("save").addEventListener("click", async () => {
  $("save").disabled = true;
  try {
    const r = await api("/api/save", {name: S.name, answers: A, note: $("note").value});
    $("note").value = "";
    await load(S.name);
    toast("Saved " + r.changed.length + " answer" + (r.changed.length === 1 ? "" : "s") + " - " +
          r.written.map((w) => w[1] + " " + w[0].split("/").pop()).join(", "));
  } catch (e) { toast(e.message, true); updateDirty(); }
});
$("newbtn").addEventListener("click", async () => {
  if (!leaveOk()) return;
  const name = prompt("File name for the new facility - two digits, a dash, lowercase words, e.g. 02-facility-b");
  if (!name) return;
  const title = prompt("Its title - characteristics, never identity (origin is public):", "Facility " + name.trim().slice(3));
  if (title === null) return;
  try {
    const r = await api("/api/new", {name: name.trim(), title: title.trim()});
    await load(r.name);
    toast("Created " + r.name + " - every question open");
  } catch (e) { toast(e.message, true); }
});
window.addEventListener("beforeunload", (e) => { if (dirtyKeys().length) { e.preventDefault(); e.returnValue = ""; } });
if (!TOKEN) {
  toast("Open the URL that serve printed - it carries the key", true);
} else {
  load(params.get("s") || "").catch((e) => toast(e.message, true));
}
</script>
</body></html>
'''


def main(argv):
    by, note, only_open, port, rest = by_default(), "", False, 8765, []
    i = 0
    while i < len(argv):
        if argv[i] == "--by":
            by, i = argv[i + 1], i + 2
        elif argv[i] == "--note":
            note, i = argv[i + 1], i + 2
        elif argv[i] == "--open":
            only_open, i = True, i + 1
        elif argv[i] == "--port":
            port, i = int(argv[i + 1]), i + 2
        else:
            rest.append(argv[i])
            i += 1
    if not rest or rest[0] in ("-h", "--help", "help"):
        print(__doc__)
        return
    cmd, args = rest[0], rest[1:]
    if cmd == "--check":
        return cmd_check()
    if cmd == "keys":
        return cmd_keys()
    if cmd == "serve":
        return serve(port, by)
    if not args:
        sys.exit("%s: name a scenario, e.g. 01-facility-a" % cmd)
    name, extra = args[0], args[1:]
    pairs = dict(x.split("=", 1) for x in extra if "=" in x)
    if cmd != "new" and not os.path.exists(paths(name)[1]):
        sys.exit("%s: no %s - start one with: facility-design.py new %s \"Title\"" % (cmd, os.path.relpath(paths(name)[1], REPO), name))
    if cmd == "build":
        cmd_build(name)
    elif cmd == "show":
        cmd_show(name, pairs)
    elif cmd == "set":
        if not pairs:
            sys.exit("set: give KEY=value - run: facility-design.py keys")
        cmd_set(name, pairs, note, by)
    elif cmd == "ask":
        cmd_ask(name, [x for x in extra if "=" not in x], only_open, by)
    elif cmd == "new":
        cmd_new(name, extra[0] if extra else name)
    else:
        sys.exit("unknown command %s - see --help" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
