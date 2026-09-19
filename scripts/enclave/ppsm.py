#!/usr/bin/env python3
"""
ppsm.py - generate the PPSM Components Local Services Assessment (CLSA) from measurements.

    MACHINE: svc-obs-01 (it reads Prometheus on 127.0.0.1:9090). Runs entirely inside the gap.

    ./ppsm.py --cal /path/to/CAL_Excel_format_YYYYMMDD.xlsx
    ./ppsm.py --cal CAL.xlsx --nmap scan.xml --out ppsm-clsa.md
    ./ppsm.py --cal CAL.xlsx --prometheus http://127.0.0.1:19090     # through a tunnel

WHAT IT IS FOR - backlog 6a.22, STIG V-270719, ASD APSC-DV-001510 / 002990:

  V-270719 fails any port, protocol or service the firewall allows that is not in the site's
  PPSM CLSA, and anything the PPSM CAL prohibits. DoDI 8551.01 requires every PPS to be
  declared, internal to the enclave or not.

WHERE EACH INPUT COMES FROM, and why none of it is typed into the document:

  listeners     enclave_listen_socket - `monitoring.sh facts`, as root, every 15 minutes on
                every machine. TCP and UDP, bind scope, owning process.
  firewall      enclave_ufw_active / enclave_ufw_rule - same timer. The LIVE table.
  intent        ufw_rules() in stig-tailor.sh - the table as designed, with a reason per port.
  identity      ppsm-services.tsv - what each listener is, and its exact CAL service name.
                The one hand-written input.
  CAL           the DISA workbook, carried in with the transfer bundle. NOT redistributable
                beyond PPSM CCB/TAG membership - so the output quotes only the rows that
                match our own ports, never the list.
  reachability  optional nmap XML from svc-obs-01. Listening is not the same as reachable -
                a systemd IPAddressDeny filter, for one, is invisible to ss.

WHAT IT WILL NOT DO: approve anything. A service the CAL does not list is marked for AO
approval, not waved through. The report drafts ONE proposed local CLSA entry per such service,
in the CAL workbook's CLSA-sheet columns, with a decision line the AO signs - the paperwork is
generated from the same measurements as the findings, so it cannot drift from them.

The output is THIS SITE'S PORT INVENTORY. It does not go in the git repository - origin is
public. Write it to /srv/stig-evidence/PPSM/ - NOT under an Evaluate-STIG host directory,
whose rotation deletes it (refused below).
"""
import argparse, collections, datetime, json, os, re, sys, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
import zipfile

HERE = os.path.dirname(os.path.realpath(__file__))

# ------------------------------------------------------------------------------ inputs
def prom(base, query):
    url = base.rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=20) as r:
        d = json.load(r)
    if d.get("status") != "success":
        sys.exit("prometheus refused %r: %s" % (query, d))
    return d["data"]["result"]


def read_env(path):
    out = {}
    for line in open(path):
        m = re.match(r"^([A-Z0-9_]+)=['\"]?([^'\"#]*)['\"]?", line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def read_services(path):
    rows = []
    for line in open(path):
        if not line.strip() or line.startswith("#") or line.startswith("proto\t"):
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 5:
            sys.exit("%s: malformed row (want 5 TAB-separated fields): %r" % (path, line))
        f += [""] * (7 - len(f))
        rows.append({"proto": f[0], "port": f[1], "process": f[2], "cal": f[3], "purpose": f[4],
                     "clsa": f[5], "risk": f[6]})
    return rows


def lookup_service(services, proto, port, process):
    for s in services:
        if s["proto"] == proto and s["process"] == process and s["port"] in (port, "*"):
            return s
    return None


def read_design_table(tailor, env):
    """ufw_rules() in stig-tailor.sh: machine TAB port/proto TAB action TAB source TAB why."""
    src = open(tailor).read()
    m = re.search(r"^ufw_rules\(\) \{\ncat <<'EOF'\n(.*?)\nEOF\n", src, re.S | re.M)
    if not m:
        sys.exit("cannot find the ufw_rules() table in %s" % tailor)
    obs = env.get("SVC_OBS_01", "")
    cidr = env.get("ENCLAVE_CIDR") or (obs.rsplit(".", 1)[0] + ".0/24" if obs else "")
    rows = []
    for line in m.group(1).splitlines():
        f = line.replace("__SVC_OBS_01__", obs).replace("__ENCLAVE_CIDR__", cidr).split("\t")
        if len(f) >= 5:
            port, proto = f[1].split("/")
            rows.append({"machine": f[0], "port": port, "proto": proto, "action": f[2],
                         "source": f[3], "why": f[4]})
    return rows


def parse_live_rule(rule):
    """'limit 22/tcp' | 'allow from 10.2.20.164 to any port 9100 proto tcp' -> dict."""
    m = re.match(r"^(allow|deny|reject|limit)\s+(\d+)/(tcp|udp)$", rule)
    if m:
        return {"action": m.group(1), "port": m.group(2), "proto": m.group(3), "source": "any"}
    m = re.match(r"^(allow|deny|reject|limit)\s+(?:in\s+)?from\s+(\S+)\s+to\s+\S+\s+port\s+(\d+)"
                 r"(?:\s+proto\s+(tcp|udp))?", rule)
    if m:
        return {"action": m.group(1), "port": m.group(3), "proto": m.group(4) or "any",
                "source": m.group(2)}
    return {"action": "?", "port": "?", "proto": "?", "source": "?", "raw": rule}


# ---------------------------------------------------------------------------- the CAL
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
RNS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"


def xlsx_sheet(path, want):
    """One worksheet as a list of {column letter: text}. Stdlib only - the enclave has no
    spreadsheet library and should not need one for this."""
    z = zipfile.ZipFile(path)
    shared = []
    if "xl/sharedStrings.xml" in z.namelist():
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).iter(NS + "si"):
            shared.append("".join(t.text or "" for t in si.iter(NS + "t")))
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    rels = {r.get("Id"): r.get("Target") for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))}
    for s in wb.iter(NS + "sheet"):
        if s.get("name") != want:
            continue
        tgt = rels[s.get(RNS + "id")].lstrip("/")
        tgt = tgt if tgt.startswith("xl/") else "xl/" + tgt
        rows = []
        for row in ET.fromstring(z.read(tgt)).iter(NS + "row"):
            r = {}
            for c in row.iter(NS + "c"):
                col = re.match(r"[A-Z]+", c.get("r")).group(0)
                v = c.find(NS + "v")
                if c.get("t") == "s" and v is not None:
                    r[col] = shared[int(v.text)]
                elif c.get("t") == "inlineStr":
                    r[col] = "".join(x.text or "" for x in c.iter(NS + "t"))
                else:
                    r[col] = v.text if v is not None else ""
            rows.append(r)
        return rows
    sys.exit("%s has no sheet named %r - has DISA changed the workbook layout?" % (path, want))


class CAL:
    """'CAL by Port': header row names the columns, the next row numbers the 16 boundaries.
    Located by header text rather than fixed letters, so a column added by DISA is survivable
    and a renamed one fails loudly."""

    NEED = ["Network", "Low Port", "High Port", "TCP/UDP", "Service name"]

    @staticmethod
    def locate(rows, sheet):
        """(header index, {column name: letter}, {boundary number: letter}) for one sheet."""
        # Header cells carry line breaks ("Low\nPort") - normalise before comparing, or the
        # lookup fails on a layout that has not actually changed.
        norm = lambda r: {k: " ".join((v or "").split()) for k, v in r.items()}
        hdr = next((i for i, r in enumerate(rows) if "Low Port" in norm(r).values()), None)
        if hdr is None:
            sys.exit("CAL %r: no 'Low Port' header row - workbook layout changed" % sheet)
        names = {v: k for k, v in norm(rows[hdr]).items() if v}
        nums = {v: k for k, v in norm(rows[hdr + 1]).items() if v}
        for n in CAL.NEED:
            if n not in names:
                sys.exit("CAL %r: column %r not found - workbook layout changed" % (sheet, n))
        return hdr, {n: names[n] for n in CAL.NEED}, nums

    def __init__(self, path):
        rows = xlsx_sheet(path, "CAL by Port")
        hdr, self.c, nums = self.locate(rows, "CAL by Port")
        self.b = {k: nums[k] for k in ("07", "08", "11", "12") if k in nums}
        if len(self.b) < 4:
            sys.exit("CAL: boundary numbering row not where expected")
        self.expires = ""
        for r in rows[:hdr]:
            for v in r.values():
                m = re.search(r"expires on:\s*(\S+)", v or "")
                if m:
                    self.expires = m.group(1)
        self.rows = [r for r in rows[hdr + 2:] if r.get(self.c["TCP/UDP"])]
        # OTHER ORGANISATIONS' LOCAL ENTRIES. Not an approval of ours - evidence that the
        # AO-approval path for this kind of service is an established one.
        crows = xlsx_sheet(path, "CLSA")
        chdr, cc, _ = self.locate(crows, "CLSA")
        self.clsa = [r for r in crows[chdr + 2:] if r.get(cc["TCP/UDP"])]
        self.cc = cc

    GENERIC = {"HTTP", "HTTPS", "TCP", "UDP", "API", "WEB", "DATA", "SERVER", "SERVICE"}

    def precedent(self, proto, port, name):
        """Unclassified CLSA entry names at this protocol and port that share a word with our
        proposed name. BOTH, because a port alone is the false-hit trap: 9100/tcp carries
        rendering services and web apps that have nothing to do with an exporter. Wide ranges
        are skipped - a 1000-port entry "matches" everything and proves nothing."""
        words = {w for w in re.split(r"[-_ ]+", name.upper()) if len(w) > 2} - self.GENERIC
        out = []
        for r in self.clsa:
            if r.get(self.cc["Network"]) != "U" or not r.get(self.cc["TCP/UDP"], "").upper().startswith(proto.upper()):
                continue
            try:
                lo = int(r.get(self.cc["Low Port"]))
                hi = int(r.get(self.cc["High Port"]) or lo)
            except ValueError:
                continue
            if hi - lo <= 10 and lo <= int(port) <= hi:
                n = r.get(self.cc["Service name"], "")
                if n and n not in out and words & set(re.split(r"[-_ ]+", n.upper())):
                    out.append(n)
        return out

    def find(self, name, proto, port):
        """The CAL row for this exact service name, protocol and port - unclassified network."""
        if name in ("", "-"):
            return None
        for r in self.rows:
            if r.get(self.c["Network"]) != "U" or r.get(self.c["Service name"]) != name:
                continue
            if not r.get(self.c["TCP/UDP"], "").upper().startswith(proto.upper()):
                continue
            try:
                lo = int(r.get(self.c["Low Port"]))
                hi = int(r.get(self.c["High Port"]) or lo)
            except ValueError:
                continue
            if port != "*" and lo <= int(port) <= hi:
                return {b: r.get(col, "") for b, col in self.b.items()}
        return None


# ---------------------------------------------------------------------------- nmap
def read_nmap(path):
    """{address: {(proto, port): state}} from nmap -oX."""
    out = collections.defaultdict(dict)
    for h in ET.parse(path).getroot().iter("host"):
        addr = next((a.get("addr") for a in h.iter("address") if a.get("addrtype") == "ipv4"), None)
        if not addr:
            continue
        for p in h.iter("port"):
            st = p.find("state")
            out[addr][(p.get("protocol"), p.get("portid"))] = st.get("state") if st is not None else "?"
    return out


# Ports probed over UDP IN ADDITION to every UDP port any machine reports listening on.
# UDP scanning is slow and, through a DROP firewall, every closed port reads "open|filtered" -
# so it is aimed, not exhaustive. 623 is IPMI: a BMC answering on the enclave network would be
# a management plane nobody has accounted for.
UDP_ALWAYS = [53, 67, 68, 69, 123, 137, 138, 161, 162, 500, 514, 520, 623, 1900, 4500, 5353]


def run_scan(targets, udp_ports, xml_out):
    """nmap from THIS machine: every TCP port, and the chosen UDP ports, on every enclave
    address. Needs root (SYN and UDP scans). Returns the XML path."""
    import shutil, subprocess
    if os.geteuid() != 0:
        sys.exit("--scan needs root: sudo %s ..." % sys.argv[0])
    nmap = shutil.which("nmap")
    if not nmap:
        sys.exit("nmap is not installed on this machine - it is in the enclave mirror: sudo apt-get install nmap")
    ports = "T:1-65535,U:" + ",".join(str(p) for p in sorted(set(udp_ports)))
    cmd = [nmap, "-Pn", "-n", "-sS", "-sU", "-p", ports, "--max-retries", "2",
           "--min-rate", "500", "-T4", "--reason", "-oX", xml_out] + sorted(targets)
    print("running: " + " ".join(cmd), file=sys.stderr)
    print("(every TCP port on %d machines plus %d UDP ports - several minutes)" % (len(targets), len(set(udp_ports))),
          file=sys.stderr)
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0 or not os.path.exists(xml_out):
        sys.exit("nmap failed (exit %d):\n%s" % (r.returncode, r.stderr))
    # Hand the evidence back to the operator - written under sudo it is root's, and the
    # next unprivileged regeneration could not read it.
    uid, gid = os.environ.get("SUDO_UID"), os.environ.get("SUDO_GID")
    if uid and gid:
        os.chown(xml_out, int(uid), int(gid))
    os.chmod(xml_out, 0o640)
    return xml_out


# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prometheus", default=os.environ.get("PPSM_PROMETHEUS", "http://127.0.0.1:9090"))
    ap.add_argument("--cal", required=True, help="the DISA CAL workbook (CAL_Excel_format_*.xlsx)")
    ap.add_argument("--services", default=os.path.join(HERE, "ppsm-services.tsv"))
    ap.add_argument("--tailor", default=os.path.join(HERE, "stig-tailor.sh"))
    ap.add_argument("--addresses", default=os.path.join(HERE, "enclave-addresses.env"))
    ap.add_argument("--nmap", default=None, help="an existing nmap -oX result to use (optional)")
    ap.add_argument("--scanner", default=os.uname()[1].split(".")[0],
                    help="the machine the nmap scan ran FROM (default: this one). Its own row is a loopback view")
    ap.add_argument("--scan", action="store_true",
                    help="run the reachability scan now (needs root and nmap); XML is written beside --out")
    ap.add_argument("--out", default=None, help="write the CLSA here (default: stdout)")
    a = ap.parse_args()
    # NEVER INSIDE AN EVALUATE-STIG HOST DIRECTORY. Its next run rotates everything there into
    # Previous/ and keeps PreviousToKeep (default 1) - so the scan after that DELETES the CLSA,
    # the nmap evidence and the CAL copy. It did the first half on svc-obs-01 on 2026-09-19.
    if a.out:
        d = os.path.dirname(os.path.abspath(a.out))
        while d != os.path.dirname(d):
            if os.path.exists(os.path.join(d, "Evaluate-STIG.log")):
                sys.exit("--out is inside Evaluate-STIG's output tree (%s) - its next scan rotates and then deletes"
                         " it. Use a sibling, e.g. /srv/stig-evidence/PPSM/" % d)
            d = os.path.dirname(d)

    env = read_env(a.addresses)
    addr_of = {k.lower().replace("_", "-"): v for k, v in env.items()
               if re.match(r"^(HOST_\d|SVC_[A-Z]+_\d+)$", k)}
    services = read_services(a.services)
    design = read_design_table(a.tailor, env)
    cal = CAL(a.cal)
    scan = read_nmap(a.nmap) if a.nmap else None

    socks = prom(a.prometheus, "enclave_listen_socket")
    live_rules = prom(a.prometheus, "enclave_ufw_rule")
    active = {r["metric"]["machine"]: r["value"][1] == "1" for r in prom(a.prometheus, "enclave_ufw_active")}
    src_ok = {(r["metric"]["machine"], r["metric"]["source"]): r["value"][1]
              for r in prom(a.prometheus, 'enclave_facts_source_ok{source=~"listeners|ufw"}')}
    fresh = {r["metric"]["machine"]: float(r["value"][1])
             for r in prom(a.prometheus, "time() - enclave_facts_generated_seconds")}

    machines = sorted(addr_of)
    if a.scan:
        if not a.out:
            sys.exit("--scan needs --out, so the scan XML has somewhere to live beside the report")
        udp = UDP_ALWAYS + [int(r["metric"]["port"]) for r in socks if r["metric"]["proto"] == "udp"]
        xml_out = re.sub(r"\.md$", "", a.out) + "-nmap.xml"
        scan = read_nmap(run_scan(set(addr_of.values()), udp, xml_out))
        scan_file = xml_out
    else:
        scan_file = a.nmap
    rules_by = collections.defaultdict(list)
    for r in live_rules:
        rules_by[r["metric"]["machine"]].append(parse_live_rule(r["metric"]["rule"]))
    socks_by = collections.defaultdict(list)
    for r in socks:
        socks_by[r["metric"]["machine"]].append(r["metric"])

    findings = []
    def finding(kind, machine, text):
        findings.append((kind, machine, text))

    # MISSING DATA IS A FINDING, NEVER A CLEAN RESULT. A machine that did not report its
    # listeners has not been assessed - it must not render as "no ports".
    for m in machines:
        if src_ok.get((m, "listeners")) != "1":
            finding("NOT ASSESSED", m, "no listener facts in Prometheus - run `monitoring.sh facts-timer` there")
        elif fresh.get(m, 1e9) > 3600:
            finding("STALE", m, "listener facts are %.0f minutes old" % (fresh[m] / 60))

    rows = []
    ao = collections.defaultdict(lambda: {"svc": None, "where": []})
    for m in machines:
        for s in sorted(socks_by.get(m, []), key=lambda s: (s["bind"] == "loopback", s["proto"], int(s["port"]))):
            proto, port, proc, bind = s["proto"], s["port"], s["process"], s["bind"]
            svc = lookup_service(services, proto, port, proc)
            dz = next((d for d in design if d["machine"] == m and d["port"] == port and d["proto"] == proto), None)
            lv = [r for r in rules_by.get(m, []) if r["port"] == port and r["proto"] in (proto, "any")]
            reach = None
            if scan is not None and m in addr_of:
                reach = scan.get(addr_of[m], {}).get((proto, port), "not scanned" if addr_of[m] not in scan else "closed/filtered")
                # TWO THINGS THE SCAN CANNOT SEE, measured 2026-09-19:
                # 1. A machine scanning ITSELF goes over loopback, and ufw does not filter lo -
                #    so its own row is not the view anyone else on the enclave gets.
                # 2. ufw LIMIT counts NEW connections per source across every limit rule. The
                #    scan's own probes and retries exhaust the 6-per-30s allowance, and ports
                #    probed later read "filtered" while Prometheus scrapes them every 15 s
                #    without a miss (it holds its connections open). Not evidence of anything.
                if m == a.scanner:
                    reach = "%s (self-scan: ufw not in path)" % reach
                elif reach in ("filtered", "closed/filtered") and any(r["action"] == "limit" for r in lv):
                    reach = "filtered - ufw LIMIT tripped by the scan itself; not a reachability result"
            calrow = cal.find(svc["cal"], proto, port) if svc else None

            if bind == "loopback":
                fw = "n/a - loopback"
            elif proc == "docker-proxy":
                fw = "BYPASSED - Docker publishes this port; ufw does not filter it"
            elif not active.get(m):
                fw = "ufw NOT enforcing" + (" (designed in stig-tailor.sh, not applied)" if lv or dz else " (no rule)")
            elif lv:
                fw = "; ".join("%s from %s" % (r["action"], r["source"]) for r in lv)
            else:
                fw = "NO RULE - ufw drops it (listening for nothing)"

            if svc is None:
                finding("UNIDENTIFIED", m, "%s/%s (%s, bind %s) matches no row in ppsm-services.tsv" % (port, proto, proc, bind))
            if bind != "loopback":
                # WHEN A SCAN EXISTS IT WINS OVER THE ASSUMPTION. ss says what is bound; only the
                # scan says what answers. A systemd IPAddressDeny filter, for one, is invisible to
                # ss - calling that port "reachable" would be a false finding.
                blocked = reach is not None and (reach == "filtered" or reach == "closed/filtered" or reach == "closed")
                if proc != "docker-proxy" and not active.get(m) and blocked:
                    finding("BOUND BUT NOT REACHABLE", m, "%s/%s (%s) binds %s but the scan got '%s' - filtered by something other than ufw; record what" % (port, proto, proc, bind, reach))
                elif proc != "docker-proxy" and not active.get(m):
                    finding("UNFILTERED", m, "%s/%s (%s) is %s from the enclave and ufw is not enforcing" % (port, proto, proc, "reachable" if reach in ("open", "open|filtered") else "assumed reachable (no scan)"))
                elif proc != "docker-proxy" and active.get(m) and not lv:
                    finding("DEAD LISTENER", m, "%s/%s (%s) listens but ufw has no rule - remove the service or add the rule" % (port, proto, proc))
                if dz is None and proc != "docker-proxy":
                    finding("NO DESIGN RECORD", m, "%s/%s (%s) is not in stig-tailor.sh ufw_rules() - no recorded reason for it to be open" % (port, proto, proc))
                if svc and svc["cal"] == "-":
                    finding("AO APPROVAL", m, "%s/%s %s - not on the CAL; needs a local CLSA entry approved by the AO" % (port, proto, proc))
                    ao[(proto, port, proc)]["svc"] = svc
                    ao[(proto, port, proc)]["where"].append({
                        "machine": m, "bind": bind, "fw": fw, "reach": reach,
                        "enforcing": bool(active.get(m)),
                        "design": ("%s from %s" % (dz["action"], dz["source"])) if dz else "NOT IN THE DESIGN TABLE"})
                elif svc and calrow is None:
                    finding("CAL MISMATCH", m, "%s/%s: ppsm-services.tsv names CAL service %r but the CAL has no such entry at this port" % (port, proto, svc["cal"]))
                elif calrow and "RED" in (calrow.get("11", ""), calrow.get("12", "")):
                    finding("PROHIBITED", m, "%s/%s %s is RED on the CAL at the enclave boundary" % (port, proto, svc["cal"]))

            rows.append({"machine": m, "proto": proto, "port": port, "process": proc, "bind": bind,
                         "service": svc["purpose"] if svc else "UNIDENTIFIED",
                         "cal": (svc["cal"] if svc and svc["cal"] != "-" else "not listed"),
                         "cat": ("%s / %s" % (calrow.get("11") or "-", calrow.get("12") or "-")) if calrow else ("local CLSA - AO" if bind != "loopback" else "-"),
                         "fw": fw, "reach": reach,
                         "why": dz["why"] if dz else ""})

    # THE OTHER DIRECTION: a reason on file for a port nothing is listening on.
    listening = {(r["machine"], r["port"], r["proto"]) for r in rows}
    for d in design:
        if d["machine"] in machines and (d["machine"], d["port"], d["proto"]) not in listening:
            finding("NOT LISTENING", d["machine"], "%s/%s is in the ufw design table but nothing listens on it" % (d["port"], d["proto"]))
    # REACHABLE BUT NOT IN THE FACTS: something answers on the network that no machine
    # reported listening. Docker-published ports, a BMC, a forgotten service - or a machine
    # whose facts are stale. Either way it is surface nobody has accounted for.
    if scan is not None:
        for m in machines:
            for (proto, port), state in sorted(scan.get(addr_of.get(m, ""), {}).items()):
                if state == "open" and (m, port, proto) not in listening:
                    finding("OPEN, NOT IN FACTS", m, "%s/%s answers from svc-obs-01 but no listener was reported for it" % (port, proto))
    for m in machines:
        for r in rules_by.get(m, []):
            if r["action"] == "?":
                finding("UNPARSED RULE", m, "could not read ufw rule %r" % r.get("raw"))
            elif (m, r["port"], r["proto"]) not in listening and not (r["proto"] == "any" and any((m, r["port"], p) in listening for p in ("tcp", "udp"))):
                finding("RULE WITHOUT SERVICE", m, "live ufw rule %s %s/%s from %s - nothing listens on it" % (r["action"], r["port"], r["proto"], r["source"]))

    # ---------------------------------------------------------------------------- output
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    L = []
    L.append("# Components Local Services Assessment (CLSA) — ports, protocols and services")
    L.append("")
    L.append("**Generated %s by `ppsm.py` — do not edit; regenerate.** Listeners and firewall state are measured"
             " (Prometheus facts, refreshed every 15 minutes); service identity from `ppsm-services.tsv`;"
             " design intent from `stig-tailor.sh`; CAL category from the DISA CAL (expires **%s**)."
             % (now, cal.expires or "unknown"))
    L.append("")
    L.append("**This is the site's port inventory. Handle it as sensitive and keep it out of public repositories.**"
             " CAL content is quoted only for the rows that match this system's own ports.")
    L.append("")
    L.append("Boundary columns are CAL boundaries 11 / 12 (Enclave GW ↔ Enclave). `AO` there means the authorising"
             " official approves the use; the DISN colours at boundaries 07/08 do not apply to an enclave with no DISN connection.")
    if scan is None:
        L.append("")
        L.append("⚠️ **No reachability scan supplied** — the *Reachable* column is empty. Listening is not the same as reachable.")
    else:
        L.append("")
        L.append("Reachability: nmap from svc-obs-01, every TCP port plus aimed UDP ports — `%s`. UDP `open|filtered` is"
                 " ambiguous by nature; the listener facts are what make a UDP row trustworthy." % os.path.basename(scan_file or ""))
    L.append("")
    kinds = collections.Counter(k for k, _, _ in findings)
    L.append("## Summary")
    L.append("")
    L.append("| | |")
    L.append("|---|---|")
    L.append("| Machines | %d — facts present for %d |" % (len(machines), sum(1 for m in machines if src_ok.get((m, "listeners")) == "1")))
    L.append("| Listeners | %d external, %d loopback-only |" % (sum(r["bind"] != "loopback" for r in rows), sum(r["bind"] == "loopback" for r in rows)))
    L.append("| ufw enforcing | %s |" % ", ".join(sorted(m for m in machines if active.get(m))) )
    L.append("| ufw **not** enforcing | %s |" % (", ".join(sorted(m for m in machines if not active.get(m))) or "none"))
    for k in sorted(kinds):
        L.append("| %s | %d |" % (k, kinds[k]))
    L.append("")
    L.append("## Findings")
    L.append("")
    if findings:
        L.append("| Kind | Machine | Detail |")
        L.append("|---|---|---|")
        order = ["NOT ASSESSED", "STALE", "PROHIBITED", "UNIDENTIFIED", "UNFILTERED", "DEAD LISTENER",
                 "NO DESIGN RECORD", "OPEN, NOT IN FACTS", "BOUND BUT NOT REACHABLE", "CAL MISMATCH", "RULE WITHOUT SERVICE", "NOT LISTENING", "UNPARSED RULE", "AO APPROVAL"]
        for k, m, t in sorted(findings, key=lambda f: (order.index(f[0]) if f[0] in order else 99, f[1])):
            L.append("| %s | %s | %s |" % (k, m, t.replace("|", "/")))
    else:
        L.append("None.")
    L.append("")
    L.append("## AO decision — proposed local CLSA entries")
    L.append("")
    if not ao:
        L.append("None - every external service is on the CAL.")
    else:
        L.append("The %d AO APPROVAL findings above are **%d services**. Each needs one local CLSA entry, written in the"
                 " columns of the CAL workbook's CLSA sheet, and a decision from the AO. **Nothing here is approved until"
                 " the decision line is signed.** `«…»` values come from `facility-profile.env` — the ORG prefix is the"
                 " DoD component that owns the system, as the CLSA sheet uses it."
                 % (kinds["AO APPROVAL"], len(ao)))
        L.append("")
        for n, ((proto, port, proc), g) in enumerate(sorted(ao.items(), key=lambda kv: -len(kv[1]["where"])), 1):
            svc = g["svc"]
            name = "«PPSM_ORG»-" + (svc["clsa"] or "«NAME»")
            L.append("### %d. `%s` — %s/%s on %d machine%s" % (n, name, port, proto, len(g["where"]), "" if len(g["where"]) == 1 else "s"))
            L.append("")
            L.append("| CLSA field | Proposed |")
            L.append("|---|---|")
            L.append("| Network | U |")
            L.append("| Service name | %s |" % name)
            L.append("| TCP/UDP | %s |" % ("TCP (6)" if proto == "tcp" else "UDP (17)"))
            L.append("| Low / High port | %s / %s |" % (port, port))
            L.append("| ORG | «PPSM_ORG» |")
            L.append("| 11 Enclave GW to Enclave · 12 Enclave to Enclave GW | AO · AO |")
            L.append("| 01–10, 13–16 | - (no DISN, ISP, DMZ or VPN connection exists) |")
            L.append("")
            L.append("**What it is.** %s" % svc["purpose"])
            L.append("")
            L.append("**Risk and mitigation.** %s" % (svc["risk"] or "⚠️ NOT WRITTEN - add the risk column in ppsm-services.tsv"))
            L.append("")
            L.append("| Machine | Bind | Allowed from (design) | Firewall now | Reachable from svc-obs-01 |")
            L.append("|---|---|---|---|---|")
            for w in g["where"]:
                L.append("| %s | %s | %s | %s | %s |" % (w["machine"], w["bind"], w["design"], w["fw"], w["reach"] or "no scan"))
            L.append("")
            gaps = [w["machine"] for w in g["where"] if not w["enforcing"] and w["reach"] not in ("filtered", "closed/filtered", "closed")]
            if gaps:
                L.append("⚠️ **Not yet as designed on %s** — ufw is not enforcing there, so the source restriction above is"
                         " not in force. An approval now is an approval of the design; make it conditional on the firewall." % ", ".join(gaps))
                L.append("")
            prec = cal.precedent(proto, port, svc["clsa"])
            if prec:
                L.append("**Precedent.** %d other unclassified CLSA entr%s for the same kind of service at %s/%s in this CAL: %s."
                         " Not an approval of this entry — evidence the AO-approval path for it is an established one."
                         % (len(prec), "y" if len(prec) == 1 else "ies", port, proto, ", ".join("`%s`" % x for x in prec[:6])))
            else:
                L.append("**Precedent.** No other unclassified CLSA entry for this kind of service at %s/%s in this CAL -"
                         " this entry stands on its own justification." % (port, proto))
            L.append("")
            L.append("**Decision:** ☐ Approve  ☐ Approve with conditions: ______________________  ☐ Disapprove")
            L.append("")
            L.append("«AO_NAME», Authorizing Official — signature ____________________  date __________")
            L.append("")
    L.append("## Inventory — external listeners")
    L.append("")
    cols = ["Machine", "Port", "Process", "Bind", "Service", "CAL service", "CAL 11 / 12", "Firewall", "Reachable", "Design reason"]
    L.append("| " + " | ".join(cols) + " |")
    L.append("|" + "---|" * len(cols))
    for r in rows:
        if r["bind"] == "loopback":
            continue
        L.append("| %s | %s/%s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["machine"], r["port"], r["proto"], r["process"], r["bind"], r["service"], r["cal"], r["cat"],
            r["fw"], r["reach"] or "", r["why"].replace("|", "/")))
    L.append("")
    L.append("## Inventory — loopback only (not reachable off the machine; listed for completeness)")
    L.append("")
    L.append("| Machine | Port | Process | Service |")
    L.append("|---|---|---|---|")
    for r in rows:
        if r["bind"] == "loopback":
            L.append("| %s | %s/%s | %s | %s |" % (r["machine"], r["port"], r["proto"], r["process"], r["service"]))
    L.append("")
    text = "\n".join(L) + "\n"
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(text)
        os.chmod(a.out, 0o640)
        uid, gid = os.environ.get("SUDO_UID"), os.environ.get("SUDO_GID")
        if uid and gid and os.geteuid() == 0:
            os.chown(a.out, int(uid), int(gid))
        print("wrote %s - %d listeners, %d findings" % (a.out, len(rows), len(findings)), file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
