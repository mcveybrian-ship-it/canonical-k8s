# Lab network — as built 2026-09-22

**What this is.** The physical and logical layout of the lab that builds the air-gapped IL5
enclave: what is plugged into what, which address lives where, how traffic leaves, and where the
air gap actually is. It replaces the topology that ran from 2026-09-02 to 2026-09-22.

**Who it is for.** Anyone who has to work on this lab, at the rack or over SSH, without having
watched it get built. It assumes no prior knowledge of the kit.

> **Redactions.** This repository's `origin` is **public**. Two WAN public IP addresses and the
> two IPsec peer names are held back here; they are in the FortiGate configuration and in
> `docs/runbook.md` §3.1b, which is gitignored. Private (RFC1918) addressing is not redacted —
> it is throughout this repository already and is meaningless without physical access.

---

## 1. The whole picture

```
        ISP #1                                Starlink dish
     (terrestrial)                          (BYPASS mode - no NAT,
           |                                 no Starlink LAN, no WiFi)
           |                                        |
        [wan1]                                   [wan2]
   default route prio 1                   default route prio 10
   PREFERRED for everything              present, chosen only by policy route
           |                                        |
           +--------------------+-------------------+
                                |
                    +-----------------------+
                    |   FortiGate FG-60F    |
                    |   10 x 1 GbE ports    |
                    +-----------------------+
                      |                  |
      OFFICE SIDE     |                  |     LAB SIDE
   (unchanged by any  |                  |  (everything below is new)
    of this work)     |                  |
                      |                  |
     [internal]  hard switch        [lab]  software switch
     192.168.1.99/24                10.2.10.1/24
     members: a, b,                 members: dmz, internal3,
              internal1,                     internal4, internal5
              internal2                  |
         |                               |
         |  internal2                    |  internal3 --- R7515 (Hyper-V host)
         +--- office dumb switch         |                  +-- stage-01 VM
         |                               |
     VLAN 10  10.0.10.1/24               |  internal4 --- build-01
     VLAN 20  10.0.20.1/24 "Office"      |
     VLAN 30  10.0.30.1/24               |  internal5 --- spare
     VLAN 40  10.0.40.1/24               |
              192.168.0.1/24 (secondary) |  dmz ========= THE CABLE THAT MATTERS
                                                          |
     ssl.root   SSL VPN, pool 10.212.134.200/29           |
     fortilink  10.255.1.1/24                             |
     2 route-based IPsec tunnels, VLAN 20 local           |
                                                          v
                                    +---------------------------------------+
                                    |  TP-Link TL-SG108S-M2                 |
                                    |  8 x 2.5 GbE, UNMANAGED               |
                                    |  no VLANs, no management IP, no web UI|
                                    +---------------------------------------+
                                       |      |      |      |
                                    host-1 host-2 host-3 host-4
                                          10.2.20.0/24, NO GATEWAY
                                    host-4 also runs the 4 service VMs
```

**Retired 2026-09-22:** a TP-Link WR3602BE travel router and a NETGEAR GS105E smart switch. Both
are off the bench. Everything they did is now done by the FortiGate.

---

## 2. FortiGate interfaces

| Interface | Address | Type | What is on it |
|---|---|---|---|
| `wan1` | *(public, redacted)* | physical | Terrestrial ISP. **Holds the preferred default route** |
| `wan2` | `100.108.1.181` | physical | Starlink in bypass mode. CGNAT `100.64.0.0/10`, gateway `100.64.0.1` |
| `internal` | `192.168.1.99/24` | **hard switch** | Members `a`, `b`, `internal1`, `internal2`. Office dumb switch on `internal2` |
| `VLAN 10` | `10.0.10.1/24` | VLAN on `internal` | Office |
| `VLAN 20` | `10.0.20.1/24` | VLAN on `internal` | Office, alias **"Office"**. `stage-01` and the admin workstation live here |
| `VLAN 30` | `10.0.30.1/24` | VLAN on `internal` | Office |
| `VLAN 40` | `10.0.40.1/24` + `192.168.0.1/24` | VLAN on `internal` | Office |
| **`lab`** | **`10.2.10.1/24`** | **software switch** | **Members `dmz`, `internal3`, `internal4`, `internal5`. Alias "Lab Staging"** |
| `ssl.root` | pool `10.212.134.200/29` | SSL VPN | Remote access, group `VPN_USERS` |
| `fortilink` | `10.255.1.1/24` | FortiLink | Unused here |

Two **route-based** IPsec tunnels terminate on this unit, each with `10.0.20.0/24` as a local
selector. Peer names redacted; their remote subnets appear in the routing table as blackhole
routes at distance 254, which is normal VPN-wizard output.

### Why `lab` is a software switch and not a single port

The lab segment needs three simultaneous connections — the R7515, `build-01`, and the uplink to
the enclave switch. `dmz` is one physical port. Rather than keep a separate fan-out switch,
`internal3/4/5` were removed from the `internal` hard switch and joined with `dmz` into a
software switch. `intra-switch-policy` is `implicit`, so members reach each other without a
firewall policy — the lab is one L2 segment, which is what the build requires.

**`internal2` was never touched.** It is still a member of the `internal` hard switch, and the
office LAN did not move.

---

## 3. Two WANs, and how traffic picks one

There is **no static default route** on this unit. Both defaults are learned by DHCP, and they
are separated by **priority**, not by distance:

```
prio=1    gateway <wan1 ISP>       dev wan1     <- chosen for everything, by default
prio=10   gateway 100.64.0.1       dev wan2     <- present in the table, not chosen
```

Lower priority wins. That single `set priority 10` on `wan2` is what guarantees the office, both
IPsec tunnels and the SSL VPN keep the exact path they had before Starlink was added. Without it
the FortiGate installs two equal-cost defaults and load-balances across them, which would put
tunnel traffic on an unpredictable circuit.

Traffic is moved to Starlink **only** by policy route, and policy routes are evaluated **before**
the routing table.

### The policy routes, and why the first three exist

```
1  deny    src 10.2.10.0/24, 10.0.20.160/32   dst 10.0.0.0/8
2  deny    src 10.2.10.0/24, 10.0.20.160/32   dst 172.16.0.0/12
3  deny    src 10.2.10.0/24, 10.0.20.160/32   dst 192.168.0.0/16
4  permit  src 10.2.10.0/24, 10.0.20.160/32   dst 0.0.0.0/0   -> wan2
```

On a FortiOS policy route, `action deny` does **not** drop the packet — it stops policy-route
processing so the packet is forwarded by the normal routing table. The deny entries must sit at
the top.

**Why this matters more than it looks.** `10.0.20.0/24` is a local selector on both IPsec
tunnels. A bare "source `10.0.20.160`, destination any, out `wan2`" rule would be evaluated
before the routing table and would silently push tunnel traffic out Starlink, breaking VPN
reachability from `stage-01` with no error anywhere. Rules 1–3 keep **everything private** on the
routing table: both tunnels, all four office VLANs, the `internal` LAN, and the SSL-VPN pool —
which an enumeration of tunnel selectors would have missed.

Rule 4 therefore moves **internet-bound traffic only**.

### Which machines leave by which circuit

| Source | Circuit | Why |
|---|---|---|
| Office VLANs 10/20/30/40, except `stage-01` | **wan1** | Policy 3 `Office to WAN`, untouched |
| Both IPsec tunnels, SSL VPN | **wan1** | Protected by policy-route denies 1–3 |
| `lab` segment (`build-01`, DHCP clients) | **Starlink** | Policy route 4 + firewall policy 19 |
| `stage-01` (`10.0.20.160`) | **Starlink** | Policy route 4 + a narrow `VLAN 20 -> wan2` policy |
| The enclave (`10.2.20.0/24`) | **none, ever** | No gateway, in any state |

---

## 4. Firewall policies that matter here

| ID | Name | From | To | Notes |
|---|---|---|---|---|
| 3 | Office to WAN | `VLAN 20` | `wan1` | all/all, NAT. **Unchanged** — every other VLAN 20 machine stays on wan1 |
| 19 | Lab to WAN | `lab` | `wan2` | all/all, NAT |
| **21** | **DENY enclave to WAN** | `lab` | `wan1` + `wan2` | source `10.2.20.0/24`, **action deny**, `logtraffic all`. Sequenced **above** policy 19 |
| *(new)* | stage-01 to Starlink | `VLAN 20` | `wan2` | source `stage-01` (`10.0.20.160/32`) only, NAT |

**Policy 21 is the layer-3 guarantee.** If an enclave host ever gained a route out - someone typing
`ip route add` on `host-4` - its packets arrive on `lab` with a `10.2.20.x` source and are dropped
and logged by a device the enclave does not administer. Stated honestly, it is not what stops that
traffic *today*: there is no `lab -> wan1` permit policy, so it already hit the implicit deny. Its
value is that the deny is **explicit, logged and auditable**, and that it **survives someone later
adding a broad `lab -> wan` policy** - which would otherwise re-open the path with no sign. The
retired travel router could not express this rule at all.

There is **no policy between `lab` and any office interface**, and FortiOS denies by default. So
the lab cannot reach the office network and the office network cannot reach the lab. That
isolation is now a rule you can point at, rather than a consequence of which router a cable was
plugged into.

**DHCP:** one server on `lab` — range `10.2.10.200–250`, gateway `10.2.10.1`. Everything that
matters in the lab is static and outside that range.

---

## 5. The lab segment in detail

```
   FortiGate lab  10.2.10.1/24  (gateway + DHCP for the staging subnet)
        |
        +-- internal3 --- R7515 (Hyper-V host, DHCP)
        |                   |
        |                   +-- stage-01 VM
        |                         eth0  10.0.20.160   <- Office VLAN 20
        |                         eth1  10.2.10.160   <- staging
        |                               10.2.20.160   <- enclave foot, State A only
        |
        +-- internal4 --- build-01     10.2.10.124 static
        |
        +-- internal5 --- spare
        |
        +-- dmz ========= TL-SG108S-M2 ========= THE AIR GAP
```

### `stage-01` is deliberately dual-homed

`eth0` sits on the office network and keeps the machine reachable from the admin workstation;
`eth1` sits on the staging subnet and, in State A only, carries a second address inside the
enclave subnet so the enclave machines can reach the mirror.

**Multi-homed is fine. Routing is not.** `ip_forward` is `0`, and `gap-state.sh` refuses to enter
State A while forwarding is on. That is the control — not which interface exists.

`stage-01`'s internet leaves by `eth0` -> VLAN 20 -> FortiGate -> Starlink. Its default route is
the office gateway; it does **not** use the lab gateway.

### The enclave switch

`TL-SG108S-M2`, 8 × 2.5 GbE, **unmanaged**. No VLANs, no management address, no web interface,
no firmware update path reachable from the enclave. That is the point — see §6.

| Machine | Address | Link speed |
|---|---|---|
| `host-1` | `10.2.20.155` | 1000 Mb |
| `host-2` | `10.2.20.156` | 1000 Mb |
| `host-3` | `10.2.20.157` | 1000 Mb |
| `host-4` | `10.2.20.158` | **2500 Mb** |
| `svc-mgmt-01` | `10.2.20.161` | on `host-4` |
| `svc-repo-01` | `10.2.20.162` | on `host-4` |
| `svc-harbor-01` | `10.2.20.163` | on `host-4` |
| `svc-obs-01` | `10.2.20.164` | on `host-4` |

`host-4`'s onboard RTL8125 negotiates 2.5 GbE. Hosts 1–3 are switch-limited no longer but
NIC-limited — they need USB 2.5 GbE adapters, which is backlog 3.16.

---

## 6. Where the air gap is

**The boundary is one cable: `dmz` on the FortiGate to the uplink port on the TL-SG108S-M2.**

### State A — BUILD (cable in)

```
   FortiGate lab ---- dmz ==== TL-SG108S-M2 ---- host-1..4
                                     ^
   stage-01 eth1 holds 10.2.10.160 AND 10.2.20.160
   so the enclave can reach the mirror
```

One L2 segment carrying two IP subnets. The enclave is isolated from the office network and from
the internet, but it is **not air-gapped** — isolation rests on absent routes and on
`ip_forward=0`. **Nothing built in State A is accredited.**

### State B — GAPPED (cable out)

```
   FortiGate lab ---- dmz     X     TL-SG108S-M2 ---- host-1..4
                                          ^
   stage-01 has no enclave address        no gateway, no router,
                                          nothing holding a 10.2.10.x address
```

Order matters: drop `stage-01`'s enclave foot **first**, then pull the cable.

```bash
### MACHINE: stage-01 ###
sudo ./scripts/enclave/gap-state.sh close     # removes the 10.2.20.160 foot
                                              # then UNPLUG the dmz cable
```

Administration afterwards requires a machine physically plugged into the TL-SG108S-M2 — which is
then *inside* the boundary and must not also touch the office network.

### Why this is better than what it replaced

The previous boundary was a VLAN assignment on a NETGEAR GS105E: port 4 in VLAN 10 during a
build, VLAN 20 when gapped. It worked, but the gap was partly a **configuration claim** on a
device with a web UI, a default password and a firmware update path — and NETGEAR documents that
management on those switches is not VLAN-bound, so that UI stayed reachable from the enclave VLAN
with no setting that changes it.

Now there is nothing to configure in the path. The FortiGate serves `10.2.10.0/24` and knows
nothing of `10.2.20.0/24`. The enclave sits on an unmanaged switch with no gateway and no
management plane. **The gap is one cable between two devices, and neither of them can be
misconfigured into bridging it** — which is a materially stronger statement to put in front of an
assessor.

> ### This lab wiring is NOT the customer design
>
> Here the break is a cable out of a firewall port, because that is the kit on hand and because
> the FortiGate never carries enclave traffic. **The customer design specifies a physical break
> with no routed path to the enclave at all.** *Air-gapped* and *firewall-isolated* are different
> claims, and only one of them survives an assessor asking what happens if a policy is edited.
> Do not read this topology as the reference architecture.

---

## 7. Measured, not assumed

Everything below was measured on 2026-09-22 rather than inferred from configuration.

**Which circuit traffic actually leaves by** — verified at the far end, not on the firewall:

```bash
### MACHINE: build-01 (10.2.10.124) ###
curl -s https://ifconfig.me; echo
```

The answer resolved to `customer.<id>.isp.starlink.com`, registered to SpaceX Services, Inc.
`stage-01` gave the same result after its policy route went in, having previously returned the
wan1 address.

**Throughput**, same 38.5 MB file from `archive.ubuntu.com`:

| Path | Samples | Range | Mean |
|---|---|---|---|
| wan1 | 3 | 7.60 – 8.80 MB/s | **8.2 MB/s** |
| Starlink | 9 | 3.80 – 15.10 MB/s | **8.5 MB/s** |

**Starlink is not faster.** An early sample suggested it was 47% quicker; nine samples put the two
circuits within 4% of each other, with Starlink varying by a factor of four and wan1 holding a
1.2 MB/s band. The lab was left on Starlink anyway — for **circuit separation**, so that hundreds
of gigabytes of archive pulls stop competing with office work and two IPsec tunnels, which is a
benefit that does not depend on a number that moves.

---

## 8. Verifying this document is still true

```
### MACHINE: FortiGate FG-60F (console or SSH) ###
show system virtual-switch           # a, b, internal1, internal2 only
show system switch-interface         # lab: dmz, internal3, internal4, internal5
show router policy                   # 3 denies, then the permit out wan2
diagnose ip route list               # wan1 prio 1, wan2 prio 10
execute dhcp lease-list lab
```

FortiOS `grep` supports only `-invfcABC`. **There is no `-E`.** `grep -f <pattern>` is the useful
one — it prints each match with its configuration context, which is how the stray `dmz address`
object was found before it could fail a change.

```bash
### MACHINE: stage-01 ###
./scripts/enclave/gap-state.sh status   # which state, and is ip_forward still 0
curl -s https://ifconfig.me; echo       # must be the Starlink egress
ping -c2 -W3 10.0.30.1                  # must STILL answer - proves deny rule 1 holds
```

That last ping is the canary. Neither IPsec remote answers ICMP, so the tunnels cannot be tested
directly from `stage-01`; `10.0.30.1` takes the same path through the `10.0.0.0/8` deny, so if it
answers, the deny is working.

---

## 9. Known gaps in this layout

| | |
|---|---|
| **3.16** | Hosts 1–3 are NIC-limited at 1 GbE on a 2.5 GbE switch, pending USB adapters, and the management/storage NIC split is unbuilt |

---

## 10. Related documents

- `docs/runbook.md` §3.1 — the build procedure, as executed, with the commands
- `docs/runbook.md` §3.1a — what a second WAN does and does not buy
- `docs/runbook.md` §3.1b — lab egress as built, including the revert
- `docs/backlog.md` 3.16 / 3.17 / 3.18
- `scripts/enclave/gap-state.sh` — moves the enclave between the two states
- `airgapped-setup-machine/README.md` §0 — the machine roster

*(`docs/runbook.md` is gitignored and moves only via `scripts/private-sync.sh`.)*
