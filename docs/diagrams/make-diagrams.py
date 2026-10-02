#!/usr/bin/env python3
"""
make-diagrams.py - draw the enclave as draw.io files, from the files that define it.

    python3 docs/diagrams/make-diagrams.py          # writes docs/diagrams/*.drawio
    python3 docs/diagrams/make-diagrams.py --check  # exit 1, naming the files, if any is stale

KEEPING THEM CURRENT (2026-10-02). Two kinds of drift, two answers:
  - the source files change (an address, a placement, a size): re-run this. The pre-push hook
    (.githooks/pre-push) runs --check against the commit being pushed and refuses a push whose
    diagrams do not match that commit's enclave-addresses.env and vm-specs.env.
  - something gets BUILT: the source files cannot say so. Edit the STATUS block below in the same
    commit as the milestone, and re-run. Solid instead of dashed, "built" instead of "planned",
    follow from it.

Addresses come from scripts/enclave/enclave-addresses.env and placement and sizes from
scripts/enclave/vm-specs.env - the same files every script reads - so a renumbered machine or a
moved VM is redrawn by re-running this, not by editing seven diagrams by hand. What those files
cannot say (what is built, what is planned, the decisions behind it) is written here, dated, and
each fact names the backlog row or document it comes from.

Open the .drawio files with diagrams.net (desktop or web) or VS Code's Draw.io Integration.

NOTATION, on every page: solid = built and running · dashed = planned, not built · dotted red =
lab only, not part of the product · grey dashed = an option, not decided.
"""
import os
import re
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ADDR = os.path.join(REPO, "scripts/enclave/enclave-addresses.env")
SPECS = os.path.join(REPO, "scripts/enclave/vm-specs.env")


# ---------------------------------------------------------------------------------- the source files
def read_env(path):
    """KEY='value' assignments, several per line allowed; comments ignored. Never executes the file."""
    out = {}
    for line in open(path):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        for k, v in re.findall(r"([A-Z0-9_]+)='([^']*)'", s.split(" #")[0]):
            out[k] = v
    return out


def read_specs(path):
    """Production values (before the VM_PROFILE case) and the lab overrides (inside `lab)`)."""
    prod, lab, mode = {}, {}, "prod"
    for line in open(path):
        s = line.strip()
        if s.startswith('case "$VM_PROFILE"'):
            mode = "case"
            continue
        if mode == "case" and s == "lab)":
            mode = "lab"
            continue
        if mode == "lab" and s == ";;":
            mode = "after"
            continue
        if not s or s.startswith("#"):
            continue
        target = prod if mode == "prod" else lab if mode == "lab" else None
        if target is None:
            continue
        for k, v in re.findall(r"([A-Z0-9_]+)='([^']*)'", s.split(" #")[0]):
            target[k] = v
    return prod, lab


A = read_env(ADDR)
PROD, LABO = read_specs(SPECS)
LAB = dict(PROD, **LABO)

# ------------------------------------------------------------------------ STATUS - what is BUILT
# The ONLY place the drawing learns what exists. Date a line when the thing is built, in the same
# commit as the milestone; empty means planned. Everything that is not here comes from the env files.
STATUS = {
    "kubernetes": "",                               # B-07: date the cluster was bootstrapped
    "ceph": "",                                     # B-08: date Ceph served its first volume
    "witness": "",                                  # 2.8: an OPTION until decided
    "storage_address": {"host-4": "2026-10-01"},    # 3.16: `03-host-services.sh storage`, per host
}


def built(key):
    return bool(STATUS.get(key))


def state(key, row):
    return ("built %s" % STATUS[key]) if built(key) else ("planned, %s" % row)


def addr(key):
    return A.get(key, "?")


def size(specs, vm):
    v = specs.get("VM_" + vm.upper().replace("-", "_"), "")
    p = v.split(":")
    if len(p) < 3:
        return ""
    s = "%s vCPU · %d GB · %s GB" % (p[0], int(p[1]) // 1024, p[2])
    if len(p) > 3:
        s += " + %s GB data" % p[3]
    return s


def placed(specs, host):
    return sorted(k[6:].lower().replace("_", "-") for k, v in specs.items()
                  if k.startswith("PLACE_") and k != "PLACE_BACKUP_SECOND" and v == host)


# ---------------------------------------------------------------------------------------- styles
BASE = "rounded=1;whiteSpace=wrap;html=1;arcSize=8;"
ST = {
    "outside": BASE + "fillColor=#f5f5f5;strokeColor=#666666;fontColor=#333333;",
    "host": BASE + "fillColor=#ffffff;strokeColor=#333333;strokeWidth=2;verticalAlign=top;align=left;spacingLeft=8;spacingTop=4;",
    "svc": BASE + "fillColor=#fff2cc;strokeColor=#d6b656;",
    "pg": BASE + "fillColor=#d5e8d4;strokeColor=#82b366;",
    "k8s": BASE + "fillColor=#e1d5e7;strokeColor=#9673a6;" + ("" if built("kubernetes") else "dashed=1;"),
    "k8s_item": BASE + "fillColor=#ffffff;strokeColor=#9673a6;" + ("" if built("kubernetes") else "dashed=1;"),
    "ceph": BASE + "fillColor=#ffe6cc;strokeColor=#d79b00;" + ("" if built("ceph") else "dashed=1;"),
    "mgmt": BASE + "fillColor=#dae8fc;strokeColor=#6c8ebf;",
    "stor": BASE + "fillColor=#ffe6cc;strokeColor=#d79b00;",
    "lab": BASE + "fillColor=#f8cecc;strokeColor=#b85450;dashed=1;dashPattern=1 3;strokeWidth=2;",
    "option": BASE + "fillColor=#f5f5f5;strokeColor=#999999;dashed=1;dashPattern=8 4;fontColor=#666666;",
    "planned": BASE + "fillColor=#ffffff;strokeColor=#9673a6;dashed=1;",
    "zone": "rounded=0;whiteSpace=wrap;html=1;fillColor=#fafafa;strokeColor=#bbbbbb;verticalAlign=top;align=left;spacingLeft=8;spacingTop=4;fontColor=#555555;",
    "zone_out": "rounded=0;whiteSpace=wrap;html=1;fillColor=#fdf3f3;strokeColor=#cc9999;dashed=1;verticalAlign=top;align=left;spacingLeft=8;spacingTop=4;fontColor=#884444;",
    "note": "shape=note;whiteSpace=wrap;html=1;size=14;fillColor=#ffffe0;strokeColor=#b3b300;align=left;verticalAlign=top;spacingLeft=6;spacingTop=4;fontSize=11;",
    "title": "text;html=1;align=left;verticalAlign=top;fontSize=20;fontStyle=1;",
    "text": "text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontSize=11;",
    "gap": "shape=mxgraph.basic.x;fillColor=#ff6666;strokeColor=#cc0000;",
}
EDGE = "endArrow=none;html=1;rounded=0;strokeColor=#6c8ebf;strokeWidth=2;"
EDGE_ST = "endArrow=none;html=1;rounded=0;strokeColor=#d79b00;strokeWidth=2;"
FLOW = "endArrow=block;endFill=1;html=1;rounded=1;edgeStyle=orthogonalEdgeStyle;strokeColor=#555555;fontSize=10;"
FLOW_DASH = FLOW + "dashed=1;"
FLOW_LAB = "endArrow=block;endFill=1;html=1;rounded=1;edgeStyle=orthogonalEdgeStyle;strokeColor=#b85450;dashed=1;dashPattern=1 3;strokeWidth=2;fontSize=10;"


class Page:
    def __init__(self, name, w=1990, h=1100):
        self.name, self.w, self.h = name, w, h
        self.cells, self.n = [], 1

    def _id(self):
        self.n += 1
        return "c%d" % self.n

    def box(self, x, y, w, h, label, style, size_=12):
        i = self._id()
        st = ST.get(style, style)
        if "fontSize" not in st:
            st += "fontSize=%d;" % size_
        self.cells.append('<mxCell id="%s" value=%s style=%s vertex="1" parent="1">'
                          '<mxGeometry x="%d" y="%d" width="%d" height="%d" as="geometry"/></mxCell>'
                          % (i, quoteattr(label), quoteattr(st), x, y, w, h))
        return i

    def edge(self, a, b, label="", style=EDGE):
        i = self._id()
        self.cells.append('<mxCell id="%s" value=%s style=%s edge="1" parent="1" source="%s" target="%s">'
                          '<mxGeometry relative="1" as="geometry"/></mxCell>'
                          % (i, quoteattr(label), quoteattr(style), a, b))
        return i

    def title(self, text, sub):
        self.box(30, 12, 1640, 36, text, "title")
        self.box(30, 50, 1640, 34, sub, "text")

    def legend(self, x=1700, y=100):
        self.box(x, y, 270, 160, "<b>Notation</b>", "zone")
        self.box(x + 10, y + 26, 120, 22, "built", BASE + "fillColor=#ffffff;strokeColor=#333333;", 10)
        self.box(x + 140, y + 26, 120, 22, "planned", "planned", 10)
        self.box(x + 10, y + 54, 120, 22, "lab only", "lab", 10)
        self.box(x + 140, y + 54, 120, 22, "option", "option", 10)
        self.box(x + 10, y + 82, 250, 72, "Generated by docs/diagrams/make-diagrams.py from "
                 "enclave-addresses.env and vm-specs.env - re-run it, do not hand-edit.", "text", 9)

    def xml(self):
        return ('<diagram id=%s name=%s><mxGraphModel dx="1600" dy="1000" grid="1" gridSize="10" '
                'guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
                'pageWidth="%d" pageHeight="%d" math="0" shadow="0"><root><mxCell id="0"/>'
                '<mxCell id="1" parent="0"/>%s</root></mxGraphModel></diagram>'
                % (quoteattr(re.sub(r"\W+", "-", self.name.lower())), quoteattr(self.name),
                   self.w, self.h, "".join(self.cells)))


def render(pages):
    return ('<mxfile host="make-diagrams.py" agent="make-diagrams.py" version="24.0.0">%s</mxfile>\n'
            % "".join(p.xml() for p in pages))


def write(fname, pages):
    path = os.path.join(HERE, fname)
    with open(path, "w") as f:
        f.write(render(pages))
    return path


HOSTS = ["host-1", "host-2", "host-3", "host-4"]


def vm_style(vm):
    if vm.startswith("pg-"):
        return "pg"
    if vm.startswith("k8s-"):
        return "k8s"
    return "svc"


VM_ROLE = {
    "svc-mgmt-01": "enclave DNS · issuing CA · Pro contracts · NTP",
    "svc-repo-01": "apt mirror · snaps · images in",
    "svc-harbor-01": "Harbor registry · Trivy",
    "svc-obs-01": "Prometheus · Grafana · audit offload",
}


def vm_label(vm, specs, with_size=True):
    key = vm.upper().replace("-", "_")
    lab = "<b>%s</b><br>%s" % (vm, addr(key))
    if vm.startswith("pg-"):
        lab += "<br>PostgreSQL 16 · Patroni · etcd"
    elif vm.startswith("k8s-cp"):
        lab += "<br>control plane · etcd member"
    elif vm.startswith("k8s-wk"):
        lab += "<br>worker · Ceph OSD"
    elif vm in VM_ROLE:
        lab += "<br>" + VM_ROLE[vm]
    if with_size:
        lab += "<br><font style='font-size:9px'>%s</font>" % size(specs, vm)
    return lab


# ======================================================================== 1. hosts and VMs
def page_hosts():
    p = Page("1 - Hosts and VMs", 1990, 1290)
    p.title("Hosts and VMs - where every guest runs",
            "Production placement (agreed 2026-09-20, backlog 2.9) above; the lab as built below. "
            "Anti-affinity: %s." % PROD.get("ANTI_AFFINITY", "?").replace("|", "  and  "))
    p.legend()
    for row, (specs, label, y0) in enumerate([(PROD, "PRODUCTION (target)", 150), (LAB, "LAB (as built / as it will be composed)", 620)]):
        p.box(30, y0 - 30, 600, 26, "<b>%s</b>" % label, "text", 14)
        for i, h in enumerate(HOSTS):
            x = 30 + i * 410
            n = h.split("-")[1]
            vms = placed(specs, h)
            hb = p.box(x, y0, 390, 60 + 92 * max(len(vms), 1),
                       "<b>%s</b>  %s<br><font style='font-size:10px'>storage %s · br0 bridges its guests</font>"
                       % (h, addr("HOST_" + n), addr("STORAGE_HOST_" + n)), "host", 13)
            for j, vm in enumerate(vms):
                st = vm_style(vm)
                if specs is LAB and vm == "k8s-wk-04":
                    st = "option"
                p.box(x + 15, y0 + 50 + 92 * j, 360, 82, vm_label(vm, specs), st, 11)
        if specs is LAB:
            p.box(30, 1160, 1620, 90,
                  "<b>Lab differences (vm-specs.env, profile lab):</b> the four service VMs stay on host-4 - the only "
                  "machine with the memory (125 GiB against 30 on host-1..3) - and k8s-wk-04 is <b>not composed</b> "
                  "in the lab, so the lab's Ceph would have three OSD nodes, the no-self-heal case the fourth exists to fix "
                  "(open: K4 / backlog 3.48)." + ("" if built("kubernetes") else " Kubernetes guests are planned only - none is composed yet (B-07)."),
                  "note")
    return p


# ======================================================================== 2. networks
def page_networks():
    p = Page("2 - Networks", 1990, 1150)
    p.title("Networks - management, storage, and the gap",
            "No gateway and no router on either enclave network. IPv6: link-local only today; dual-stack "
            "is required for the cluster (B-07) and router advertisements are ignored everywhere (3.55).")
    p.legend()
    # outside
    p.box(30, 90, 1320, 210, "<b>OUTSIDE THE GAP</b> - online side, not in the ATO boundary", "zone_out", 12)
    fg = p.box(50, 130, 220, 70, "<b>FortiGate FG-60F</b><br>internet edge · staging 10.2.10.0/24", "outside")
    st1 = p.box(300, 130, 220, 70, "<b>stage-01</b><br>%s (+ 10.2.20.160 in State A)<br>mirror · repo · builds" % addr("STAGE_01"), "outside")
    b1 = p.box(550, 130, 220, 70, "<b>build-01</b><br>%s<br>transfer SSD · private backups" % addr("BUILD_01"), "outside")
    dell = p.box(800, 120, 520, 160, "<b>Dell R7515</b> - Hyper-V host (lab)<br>runs stage-01; RAID 10 on D:", "outside")
    vault = p.box(1010, 190, 290, 70, "<b>lab-vault</b> 10.2.30.170<br>LUKS2 /srv/cold · third copy (lab only)", "lab", 11)
    # gap cables
    g1 = p.box(140, 320, 140, 36, "<b>gap cable #1</b><br>FortiGate dmz", "lab", 10)
    g2 = p.box(1030, 320, 160, 36, "<b>gap cable #2</b><br>Dell 10 Gb (lab only)", "lab", 10)
    p.edge(fg, g1, "", EDGE)
    p.edge(dell, g2, "", EDGE_ST)
    # switches
    mg = p.box(30, 390, 900, 60, "<b>MANAGEMENT</b> - TL-SG108S-M2, unmanaged · <b>10.2.20.0/24</b> · no gateway, no DHCP in use, no IPv6 router", "mgmt", 12)
    sg = p.box(960, 390, 690, 60, "<b>STORAGE</b> - GigaPlus 2.5 G + SFP+, unmanaged · <b>%s</b> · no uplink, no gateway" % addr("STORAGE_SUBNET"), "stor", 12)
    p.edge(g1, mg, "State A: cable in · State B: unplugged", EDGE)
    p.edge(g2, sg, "", EDGE_ST)
    # hosts
    for i, h in enumerate(HOSTS):
        n = h.split("-")[1]
        x = 60 + i * 400
        hb = p.box(x, 500, 360, 120,
                   "<b>%s</b><br>br0 = %s (onboard NIC)<br>storage NIC = %s%s"
                   % (h, addr("HOST_" + n), addr("STORAGE_HOST_" + n),
                      ("  <b>(configured %s)</b>" % STATUS["storage_address"][h]) if h in STATUS["storage_address"]
                      else "  (planned)"), "host", 12)
        p.edge(hb, mg, "br0", EDGE)
        p.edge(hb, sg, "2.5 G USB adapter", EDGE_ST)
    # address plan
    plan = ("<b>Management address plan</b> (enclave-addresses.env)<br>"
            "hosts %s - %s<br>"
            "svc-mgmt-01 %s · svc-repo-01 %s · svc-harbor-01 %s · svc-obs-01 %s<br>"
            "pg-01..03 %s - %s<br>"
            "<b>Kubernetes API VIP %s</b> (keepalived) · control planes %s - %s · workers %s - %s<br>"
            "<b>LoadBalancer pool %s - %s</b> (built-in, layer-2) - the Gateway VIP and *.apps come from here<br>"
            "pods 10.1.0.0/16 · services 10.152.183.0/24 (Canonical defaults, set at bootstrap)<br>"
            "DNS: enclave.internal on svc-mgmt-01 · *.apps.enclave.internal → the Gateway VIP (today a placeholder on the API VIP)"
            % (addr("HOST_1"), addr("HOST_4"), addr("SVC_MGMT_01"), addr("SVC_REPO_01"), addr("SVC_HARBOR_01"),
               addr("SVC_OBS_01"), addr("PG_01"), addr("PG_03"), addr("K8S_API_VIP"), addr("K8S_CP_01"),
               addr("K8S_CP_03"), addr("K8S_WK_01"), addr("K8S_WK_04"), addr("K8S_LB_POOL_START"),
               addr("K8S_LB_POOL_END")))
    p.box(30, 680, 1000, 170, plan, "note")
    stor = ("<b>Storage network</b> (backlog 3.16)<br>"
            "hosts %s - %s (STORAGE_HOST_n) · lab: vault 10.2.30.170, NAS 10.2.30.171<br>"
            "<b>planned:</b> br-storage on each host so worker VMs get a second NIC - Ceph's cluster (replication) "
            "network here, its public network on management<br>"
            "measured 2026-10-01: raw TCP host-4 → vault 274 MB/s (the 2.5 G link ~93%% used)"
            % (addr("STORAGE_HOST_1"), addr("STORAGE_HOST_4")))
    p.box(1060, 680, 590, 170, stor, "note")
    p.box(30, 880, 1620, 110,
          "<b>Dual-stack (required, B-07 - not designed):</b> one private IPv6 ULA prefix (RFC 4193) generated once; "
          "a /64 for the node network with static addresses (no router, no DHCPv6 - 3.54); IPv6 pod, service and "
          "LoadBalancer ranges; node IPs explicit for both families. Must be in the bootstrap config - the ranges "
          "cannot change afterwards.<br><b>Geo-diverse sites (option):</b> both VIPs are layer-2 announcements, so "
          "they need one layer-2 network across locations, or a different mechanism.", "planned", 11)
    return p


# ======================================================================== 3. the Kubernetes cluster
def page_k8s():
    p = Page("3 - Kubernetes cluster", 1990, 1200)
    p.title("Kubernetes cluster - Canonical Kubernetes 1.36.4 (%s)" % state("kubernetes", "B-07"),
            "Embedded etcd on three control planes · Cilium · Gateway API via the built-in ck-gateway · "
            "images only from Harbor · database outside the cluster on Patroni.")
    p.legend()
    users = p.box(40, 100, 200, 60, "<b>Users and clients</b><br>enclave network", "outside")
    vip = p.box(330, 100, 300, 60, "<b>Gateway VIP</b> - LoadBalancer address from %s-%s<br>layer-2 announced, moves on node failure"
                % (addr("K8S_LB_POOL_START"), addr("K8S_LB_POOL_END").split(".")[-1]), "k8s", 11)
    gw = p.box(720, 100, 360, 60, "<b>ck-gateway</b> (Gateway API, Cilium)<br>HTTPRoutes for the app · *.apps.enclave.internal", "k8s", 11)
    p.edge(users, vip, "https", FLOW)
    p.edge(vip, gw, "", FLOW)
    p.box(1110, 95, 270, 70, "<b>FIPS condition (Q-CORE (i))</b><br>if the gateway's TLS is not FIPS-validated: "
          "two HAProxy VMs on Ubuntu Pro FIPS + keepalived VIP terminate TLS in front", "option", 10)
    # control plane
    p.box(30, 200, 640, 330, "<b>CONTROL PLANE</b> - 3 VMs, one per host-1..3 (anti-affinity) · tainted: no app pods (H3)", "zone", 12)
    api = p.box(60, 240, 580, 50, "<b>Kubernetes API VIP %s</b> - keepalived VRRP across the three (not kube-vip)" % addr("K8S_API_VIP"), "k8s", 11)
    cps = []
    for i in range(3):
        n = "%02d" % (i + 1)
        c = p.box(60 + i * 195, 310, 180, 200,
                  "<b>k8s-cp-%s</b><br>%s<br>on host-%d<br><br>kube-apiserver<br>scheduler · controller-manager<br><b>etcd member</b><br>keepalived"
                  % (n, addr("K8S_CP_" + n), i + 1), "k8s", 11)
        cps.append(c)
        p.edge(api, c, "", FLOW_DASH)
    p.box(60, 520, 580, 0, "", "text")
    # workers
    p.box(700, 200, 960, 560, "<b>WORKERS</b> - 4 VMs, one per host · app pods spread across them", "zone", 12)
    wks = []
    for i in range(4):
        n = "%02d" % (i + 1)
        x = 720 + i * 235
        w = p.box(x, 240, 220, 500, "", "k8s", 10)
        wks.append(w)
        p.box(x + 10, 248, 200, 40, "<b>k8s-wk-%s</b> %s · host-%d" % (n, addr("K8S_WK_" + n), i + 1), "text", 11)
        pods = ["app services (replica)", "GeoServer (replica)" if i < 2 else None,
                "Redis %s" % ("master" if i == 0 else "replica"), "pgAdmin (admin ns)" if i == 3 else None,
                "Gateway data path (Cilium)", "ceph-csi node plugin", "Ceph OSD (raw device, dmcrypt)",
                "Ceph mon + mgr" if i < 3 else "Ceph MDS standby" if i == 3 else None,
                "Ceph MDS active" if i == 0 else None]
        y = 292
        for pod in [q for q in pods if q]:
            st = "ceph" if pod.startswith("Ceph") or pod.startswith("ceph") else "k8s_item"
            p.box(x + 10, y, 200, 44, pod, st, 10)
            y += 50
    p.edge(gw, wks[1], "routes to app pods", FLOW_DASH)
    # storage classes
    p.box(30, 560, 640, 200,
          "<b>Volumes (ceph-csi)</b><br>• <b>CephFS - ReadWriteMany</b>: every app PVC; the map store (default 10 GB, "
          "adjustable) shared by the app's file server and GeoServer<br>• RBD - ReadWriteOnce: available if a "
          "workload wants block storage<br>• replica 3 across four OSD nodes (one per worker), encrypted OSDs<br>"
          "• a single-writer pod on a DEAD worker needs the node marked <b>out-of-service</b>: automatic through "
          "the BMC in production, a manual step in the lab (H2)", "ceph", 11)
    # outside the cluster
    harbor = p.box(30, 800, 380, 90, "<b>svc-harbor-01</b> %s<br>Harbor: every image (≈1 GB for the app stack), "
                   "containerd points here before bootstrap" % addr("SVC_HARBOR_01"), "svc", 11)
    pg = p.box(440, 800, 420, 90, "<b>pg-01..03</b> %s-%s · Patroni, synchronous<br>the app's database - NOT in the cluster; "
               "libpq multi-host, 5432 allowed from the four workers only" % (addr("PG_01"), addr("PG_03").split(".")[-1]), "pg", 11)
    obs = p.box(890, 800, 360, 90, "<b>svc-obs-01</b> %s<br>scrapes the nodes and Ceph from outside the cluster (planned)"
                % addr("SVC_OBS_01"), "svc", 11)
    dns = p.box(1280, 800, 370, 90, "<b>svc-mgmt-01</b> %s<br>enclave DNS: *.apps → Gateway VIP · issuing CA"
                % addr("SVC_MGMT_01"), "svc", 11)
    p.edge(harbor, wks[0], "image pulls", FLOW_DASH)
    p.edge(wks[2], pg, "SQL (5432)", FLOW_DASH)
    p.edge(obs, wks[3], "scrape", FLOW_DASH)
    p.box(30, 920, 1620, 120,
          "<b>Decided 2026-10-02 (B-07):</b> HA target = any one host failure (H1) · BMC fencing in production, manual in the lab (H2) · "
          "control planes run no app pods (H3) · ingress = Gateway API on ck-gateway, the vendor's NGINX Ingress manifests converted "
          "with ingress2gateway 1.0 and shared with Azure · all PVCs RWX (CephFS) · Redis master + 3 replicas, one per worker · "
          "GeoServer in the cluster (it mounts the map store).<br><b>Open before bootstrap:</b> revision (K1, 3.26) · dual-stack ranges · "
          "the STIG's set-once items (anonymous kubelet auth off, audit policy, secrets encryption, Pod Security) · k8s ufw/PPSM tables "
          "(compose --harden refuses without them) · keepalived config.", "note")
    return p


# ======================================================================== 4. storage
def page_storage():
    p = Page("4 - Storage (Ceph)", 1990, 1150)
    p.title("Storage - Ceph from Ubuntu debs on the workers (%s)" % state("ceph", "B-08"),
            "Not MicroCeph (runbook 2.5). Ceph 19.2.3 from the enclave mirror; ceph-mds is there too (checked 2026-10-02).")
    p.legend()
    p.box(30, 100, 1620, 330, "<b>CEPH CLUSTER</b> - one OSD per worker · replica 3 · OSDs encrypted (--dmcrypt, decided 2026-09-23)", "zone", 12)
    for i in range(4):
        n = "%02d" % (i + 1)
        x = 50 + i * 400
        p.box(x, 140, 380, 270, "", "k8s", 10)
        p.box(x + 10, 146, 360, 24, "<b>k8s-wk-%s</b> on host-%d" % (n, i + 1), "text", 11)
        p.box(x + 10, 176, 360, 60, "<b>OSD</b> - the host's raw M.2 partition p2 (~500 GB), passed through whole; "
              "every OSD the same declared size", "ceph", 10)
        if i < 3:
            p.box(x + 10, 244, 175, 40, "<b>mon</b> (quorum)", "ceph", 10)
            p.box(x + 195, 244, 175, 40, "<b>mgr</b>" if i < 2 else "-", "ceph" if i < 2 else "text", 10)
        mds = "MDS active" if i == 0 else "MDS standby" if i == 3 else None
        if mds:
            p.box(x + 10, 292, 360, 40, "<b>%s</b> (CephFS)" % mds, "ceph", 10)
        p.box(x + 10, 340, 360, 60, "ceph-csi node plugin<br>RBD + CephFS", "planned", 10)
    p.box(30, 450, 790, 180,
          "<b>Pools and classes</b><br>• CephFS data + metadata (replica 3) → StorageClass <b>ReadWriteMany</b> - every app PVC<br>"
          "• RBD pool 'kubernetes' (128 PGs, replica 3) → StorageClass ReadWriteOnce<br>"
          "• the database is NOT on Ceph (pg-01..03 on encrypted local LVs)<br>"
          "• 60% fill rule: ~400 GB working at replica 3 from four ~500 GB OSDs", "ceph", 11)
    p.box(850, 450, 800, 180,
          "<b>Networks</b><br>• public network (clients, mons): management 10.2.20.0/24<br>"
          "• cluster network (replication): storage %s - needs br-storage on the hosts (planned, 3.16)<br>"
          "• lab: the OSDs share the host NVMe with the database volume (a documented waiver); remainders "
          "are evened at the smallest" % addr("STORAGE_SUBNET"), "stor", 11)
    # stretch option
    p.box(30, 660, 1620, 420, "<b>OPTION - Ceph stretch mode, if the hosts are spread across the complex</b> (Ceph Squid docs)", "option", 12)
    sa = p.box(60, 710, 480, 220, "<b>Site A</b><br>2 hosts · 2 OSD nodes<br><b>2 monitors</b><br>2 copies of every object", "option", 12)
    sb = p.box(580, 710, 480, 220, "<b>Site B</b><br>2 hosts · 2 OSD nodes<br><b>2 monitors</b><br>2 copies of every object", "option", 12)
    sc = p.box(1100, 710, 520, 220, "<b>Site C - witness</b> (a fifth, small machine)<br><b>tie-breaker monitor</b> only, no data<br>"
               "+ one Kubernetes etcd member and one Patroni etcd member", "option", 12)
    p.edge(sa, sb, "synchronous replication", FLOW_DASH)
    p.box(60, 950, 1560, 110,
          "Five monitors (two per data site + the tie-breaker) · pools of <b>size 4, two copies per site</b> - usable space falls from a third "
          "to a quarter of raw · when one site fails the survivor goes active alone · replicated pools only (no erasure coding) · OSDs "
          "at exactly two sites · SSD OSDs recommended. Latency between sites to be measured.", "text", 11)
    return p


# ======================================================================== 5. HA and failure domains
def page_ha():
    p = Page("5 - HA and failure domains", 1990, 1150)
    p.title("HA - what survives what (decided H1: any one host failure)",
            "Three quorum systems, each with one member on host-1..3. Losing any one host costs one vote in each - all keep quorum.")
    p.legend()
    cols = ["host-1", "host-2", "host-3", "host-4", "witness (option)"]
    rows = [("Kubernetes etcd (control planes)", ["member", "member", "member", "-", "member*"]),
            ("Patroni etcd (database DCS)", ["member", "member", "member", "-", "member*"]),
            ("Ceph monitors", ["mon", "mon", "mon", "-", "tie-breaker*"]),
            ("PostgreSQL (Patroni)", ["pg-01", "pg-02", "pg-03", "backup store", "-"]),
            ("Kubernetes workers / Ceph OSDs", ["wk-01 · OSD", "wk-02 · OSD", "wk-03 · OSD", "wk-04 · OSD", "-"])]
    x0, y0, cw, rh = 30, 100, 260, 56
    p.box(x0, y0, 330, rh, "<b>quorum / role</b>", "zone", 12)
    for j, c in enumerate(cols):
        p.box(x0 + 340 + j * cw, y0, cw - 10, rh, "<b>%s</b>" % c, "option" if "witness" in c else "host", 12)
    for i, (r, vals) in enumerate(rows):
        y = y0 + (i + 1) * (rh + 8)
        p.box(x0, y, 330, rh, r, "zone", 11)
        for j, v in enumerate(vals):
            st = "option" if j == 4 and v != "-" else ("pg" if "pg-" in v else "k8s" if v not in ("-", "backup store") else "text")
            p.box(x0 + 340 + j * cw, y, cw - 10, rh, v, st, 11)
    p.box(x0, 482, 1640, 30, "* the witness exists only in the geo-diverse option - a fifth, small physical machine in a third location.", "text", 11)
    p.box(30, 520, 800, 230,
          "<b>Four hosts (the plan)</b><br>• any <b>one</b> host lost → every quorum holds, workloads reschedule, Ceph heals onto the "
          "remaining OSDs, Patroni fails over automatically (proven by a power cut, 2026-09-28)<br>"
          "• <b>two</b> hosts lost → quorum lost → the cluster stops writing; data is safe and it resumes when a host returns<br>"
          "• a watcher VM on these four hosts adds nothing: a 4th member still survives only one loss, and 5 members on 4 hosts "
          "put two on one host<br>• during maintenance of one host there is no spare - a second failure then is an outage", "note")
    p.box(860, 520, 810, 230,
          "<b>Geo-diverse option (2.8)</b><br>hosts split 2 + 2 across two locations → losing a location = losing two hosts. Without a "
          "witness, one location holds two of the three members and its loss stops everything.<br>With a <b>witness in a third "
          "location</b> (one member of each quorum, no data) and <b>Ceph stretch mode</b> (size 4, two copies per site), either data "
          "location can be lost. Build site-aware now (site per host, zone labels, Ceph datacenter buckets) so adding it later is "
          "configuration.", "option", 11)
    # fencing
    p.box(30, 780, 1640, 330, "<b>FENCING A DEAD WORKER (H2)</b> - a single-writer pod on a dead node stays 'terminating' forever until the node "
          "is marked out-of-service; Kubernetes requires the node be verified powered off first (kubernetes.io, node shutdown)", "zone", 11)
    a = p.box(60, 840, 240, 70, "worker's host stops responding", "k8s", 11)
    b = p.box(360, 840, 260, 70, "<b>production:</b> ask that host's <b>BMC</b> (Redfish/IPMI) - powered off?", "planned", 11)
    c = p.box(700, 820, 300, 50, "<b>off</b> → taint node.kubernetes.io/out-of-service", "planned", 11)
    d = p.box(700, 890, 300, 60, "<b>on but unreachable</b> → power it OFF through the BMC (fence), then taint", "planned", 11)
    e = p.box(1080, 840, 300, 70, "pods force-deleted, volumes detached immediately → pods restart on surviving workers", "k8s", 11)
    f = p.box(360, 960, 640, 70, "<b>lab (no BMC):</b> the same tool prints the checks and the command; a person confirms the host is "
              "really off before the taint", "lab", 11)
    p.edge(a, b, "", FLOW_DASH)
    p.edge(b, c, "", FLOW_DASH)
    p.edge(b, d, "", FLOW_DASH)
    p.edge(c, e, "", FLOW_DASH)
    p.edge(d, e, "", FLOW_DASH)
    p.edge(a, f, "", FLOW_LAB)
    p.box(1080, 960, 560, 110, "Production needs: an isolated out-of-band BMC network, BMC credential custody, PPSM rows. "
          "Remove the taint by hand once the node is back (the docs require it).", "note")
    return p


# ======================================================================== 6. data protection
def page_backup():
    p = Page("6 - Data protection", 1990, 1100)
    p.title("Data protection - backups, copies and the audit trail",
            "What exists today (solid), what is planned (dashed), and the lab's extra copy (dotted red).")
    p.legend()
    vms = p.box(40, 110, 330, 90, "<b>host-4's guests</b><br>svc-mgmt-01 · svc-repo-01 · svc-harbor-01 · svc-obs-01", "svc", 11)
    vb = p.box(470, 110, 380, 90, "<b>vm-backup.sh</b> nightly 02:00 Central<br>incr · verify (new sets) · prune · weekly verify --all", "svc", 11)
    drv = p.box(950, 110, 330, 90, "<b>/mnt/vmbackup</b> on host-4<br>USB SSD, LUKS · 2 chains kept", "svc", 11)
    c2 = p.box(950, 240, 330, 80, "<b>second copy → host-1</b><br>write-only rrsync · svc-repo-01 skipped", "svc", 11)
    c3 = p.box(1320, 240, 330, 80, "<b>third copy → lab-vault</b><br>10.2.30.170, storage network", "lab", 11)
    p.edge(vms, vb, "", FLOW)
    p.edge(vb, drv, "", FLOW)
    p.edge(drv, c2, "nightly · new files verified", FLOW)
    p.edge(drv, c3, "nightly · lab only", FLOW_LAB)
    p.box(40, 240, 860, 80, "Copies verify only files not verified before (a ledger on host-4); the weekly verify re-reads both "
          "copies in full (--verify-all). Measured 2026-10-01: 182.4 GB first third copy in 38.6 min.", "note")
    pgs = p.box(40, 380, 330, 90, "<b>pg-01..03</b><br>Patroni · the app's real records", "pg", 11)
    pb4 = p.box(470, 360, 380, 60, "<b>pgBackRest store 1</b> - host-4 /srv/pgbackrest/repo", "pg", 11)
    pb3 = p.box(470, 430, 380, 60, "<b>pgBackRest store 2</b> - host-3", "pg", 11)
    p.edge(pgs, pb4, "WAL + backups", FLOW)
    p.edge(pgs, pb3, "", FLOW)
    p.box(950, 360, 700, 130, "<b>3.50:</b> pgBackRest's repositories are NOT copied to the lab stores until repository "
          "encryption is on - they hold real records. Point-in-time restore proven from both stores (2026-09-28).", "note")
    k = p.box(40, 540, 330, 80, "<b>Kubernetes etcd</b><br>(planned)", "k8s", 11)
    ks = p.box(470, 540, 380, 80, "nightly etcd snapshot → the backup volume (rides the copies) + a cluster restore drill", "planned", 11)
    p.edge(k, ks, "", FLOW_DASH)
    cf = p.box(950, 540, 700, 80, "<b>CephFS / RBD volumes</b> (planned): backup approach not yet designed - the app's state "
               "is in PostgreSQL; the map store is on CephFS", "planned", 11)
    all_ = p.box(40, 680, 330, 80, "<b>all 11 enclave machines</b><br>audit logs", "svc", 11)
    ao = p.box(470, 680, 380, 80, "<b>audit offload → svc-obs-01</b><br>weekly · kept 1 year", "svc", 11)
    p.edge(all_, ao, "", FLOW)
    p.box(950, 680, 700, 80, "Planned: continuous delivery (audisp-remote, N-2 step 2); syslog kept one year (3.37).", "planned", 11)
    p.box(40, 800, 1610, 120,
          "<b>Records destruction (3.27, go-live gate):</b> backups must age out within ~60 days - an age-based full every 30 days, two "
          "chains kept, a legal-hold switch, a disposal log - and every copy follows the source (--delete). Measured 2026-09-24: "
          "retention is currently UNBOUNDED (nightly runs are incremental, so no chain ever retires). Build owed.", "note")
    return p


# ======================================================================== 0. overview
def page_overview():
    p = Page("0 - Enclave overview", 1990, 1150)
    p.title("The enclave - overview",
            "Four hosts, two enclave networks, the gap, the service VMs, the database cluster and the planned Kubernetes cluster. "
            "Production placement shown; lab differences on page 1.")
    p.legend()
    p.box(30, 90, 1320, 150, "<b>OUTSIDE THE GAP</b> (online side)", "zone_out", 12)
    fg = p.box(50, 125, 200, 60, "<b>FortiGate</b> · internet edge", "outside", 11)
    s1 = p.box(270, 125, 200, 60, "<b>stage-01</b> · mirror, repo", "outside", 11)
    b1 = p.box(490, 125, 200, 60, "<b>build-01</b> · transfer SSD", "outside", 11)
    dl = p.box(710, 120, 620, 105, "<b>Dell R7515</b> (Hyper-V, lab)", "outside", 11)
    p.box(980, 150, 330, 60, "<b>lab-vault</b> · cold copy (lab only)", "lab", 11)
    mg = p.box(30, 280, 1000, 46, "<b>MANAGEMENT 10.2.20.0/24</b> · no gateway", "mgmt", 12)
    sg = p.box(1060, 280, 590, 46, "<b>STORAGE %s</b> · no uplink" % addr("STORAGE_SUBNET"), "stor", 12)
    p.edge(fg, mg, "gap cable #1", EDGE)
    p.edge(dl, sg, "gap cable #2 (lab)", EDGE_ST)
    for i, h in enumerate(HOSTS):
        n = h.split("-")[1]
        x = 30 + i * 410
        vms = placed(PROD, h)
        hb = p.box(x, 370, 390, 50 + 70 * len(vms), "<b>%s</b>  %s" % (h, addr("HOST_" + n)), "host", 13)
        p.edge(hb, mg, "", EDGE)
        p.edge(hb, sg, "", EDGE_ST)
        for j, vm in enumerate(vms):
            p.box(x + 15, 405 + 70 * j, 360, 62, vm_label(vm, PROD, with_size=False), vm_style(vm), 10)
    p.box(30, 720, 520, 130, "<b>Kubernetes (" + state("kubernetes", "B-07") + ")</b><br>3 control planes (etcd, API VIP %s) · 4 workers<br>"
          "Gateway API (ck-gateway) on a LoadBalancer VIP · *.apps<br>Ceph on the workers: CephFS RWX + RBD"
          % addr("K8S_API_VIP"), "k8s", 11)
    p.box(570, 720, 520, 130, "<b>PostgreSQL HA (built)</b><br>pg-01..03, Patroni + its own etcd, synchronous<br>"
          "backed up by pgBackRest to host-4 and host-3<br>Postgres 16 STIG: all 111 rules judged (2026-10-01)", "pg", 11)
    p.box(1110, 720, 540, 130, "<b>Service VMs (built)</b><br>DNS · CA · mirror · Harbor · monitoring<br>"
          "every machine hardened (USG STIG + Evaluate-STIG)<br>lab: all four on host-4", "svc", 11)
    p.box(30, 880, 1620, 110, "<b>Pages:</b> 1 hosts and VMs · 2 networks · 3 Kubernetes cluster · 4 storage · 5 HA and failure domains · "
          "6 data protection.<br><b>HA target:</b> any one host failure (H1). Option: a fifth witness in a third location if the hosts are "
          "spread across the complex (page 5).", "note")
    p.box(30, 1010, 1620, 60, "Witness option: one Kubernetes etcd member, one Patroni etcd member and a Ceph tie-breaker monitor on a small "
          "machine in a third location - not decided (2.8).", "option", 11)
    return p


PAGES = [
    ("00-enclave-overview.drawio", page_overview),
    ("01-hosts-and-vms.drawio", page_hosts),
    ("02-networks.drawio", page_networks),
    ("03-kubernetes-cluster.drawio", page_k8s),
    ("04-storage-ceph.drawio", page_storage),
    ("05-ha-and-failure-domains.drawio", page_ha),
    ("06-data-protection.drawio", page_backup),
]

if __name__ == "__main__":
    import sys
    pages = [(f, fn()) for f, fn in PAGES]
    wanted = [(f, render([pg])) for f, pg in pages] + [("enclave-all-pages.drawio", render([pg for _, pg in pages]))]
    if "--check" in sys.argv[1:]:
        stale = []
        for f, content in wanted:
            path = os.path.join(HERE, f)
            if not os.path.exists(path) or open(path).read() != content:
                stale.append(f)
        if stale:
            print("diagrams STALE - they do not match enclave-addresses.env / vm-specs.env / the STATUS block:")
            for f in stale:
                print("   docs/diagrams/" + f)
            print("fix:  python3 docs/diagrams/make-diagrams.py   then commit docs/diagrams/")
            sys.exit(1)
        print("diagrams current: %d files match the generator" % len(wanted))
        sys.exit(0)
    for f, content in wanted:
        with open(os.path.join(HERE, f), "w") as fh:
            fh.write(content)
        print("wrote", "docs/diagrams/" + f)
