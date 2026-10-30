# Facility A — a main facility with external sites that must run through a lockdown

**Status: scenario captured 2026-10-30. A2 partly answered; the rest open. Nothing designed or built.**
Backlog 3.74. Diagram: [`01-facility-a.drawio`](01-facility-a.drawio) — three pages: normal
operation, lockdown, reconnect and reconcile.

## The scenario as given (Brian, 2026-10-30)

- The main facility runs the internal system.
- External sites sit outside the facility and are connected to it.
- When the facility goes on lockdown, the internal system is cut off from the external sites.
- During the lockdown **both sides keep running**: the internal system, and each external site on
  its own.
- When the connection comes back, the external sites' data is **reconciled back into the
  internal system**.

## What it changes in the current design

| The design today | Facility A | Source |
|---|---|---|
| Network: **fully disconnected, no egress — locked** | **Still holds.** Every site is a closed system (A2). What changes is that the closed network spans sites, joined by a link in normal operation; a lockdown cuts that link and leaves each site closed on its own | `HANDOFF.md` §1 |
| One site, one room | Several sites, and a link between them that is part of the boundary | `HANDOFF.md` §1, §4 |
| One site, no standby — accepted as a risk | Two or more sites, each able to run alone | `HANDOFF.md` §4, `poam.md` AO-19 |
| One database, one writer: Patroni, synchronous replication | A writer at every site for the length of the lockdown | backlog B-06a, `06a-postgres-ha.md` |
| The mission application is COTS | The merge happens inside data the vendor's product owns | backlog 6a.21 |
| One clock for the enclave | Each site keeps its own time during the split, and a merge orders events by it | `scripts/enclave/time-sync.sh` |

## Where the hard part is

**Copying data back is easy. Deciding what wins is not.** Three cases, in order of difficulty:

1. **External sites only create new records during the lockdown.** The reconcile is an append.
   The one trap: if both sides number records from their own counter, both issue the same next
   number. Per-site number ranges or prefixes have to be decided **before** the first lockdown —
   afterwards there are already two record 1042s.
2. **External sites also change records that existed before the split, and the main side does
   not touch them.** Still mergeable: the external change applies on top.
3. **Both sides change the same record during the split.** A real conflict. Either a rule
   decides — *last writer wins* silently discards one side's change, which for records of this
   kind has to be a stated, accepted loss — or a person decides, from a review queue after the
   reconnect.

**Database replication does not solve this.** Streaming replication, which Patroni runs, has one
writer. Promote a cut-off replica and there are two histories; rejoining the old side
(`pg_rewind`) discards its writes. Logical replication copies row changes but does not decide who
wins — a conflicting row stops it. Merging is application logic.

**And the application is COTS (6a.21).** So the first question is the vendor's: does the product
support a remote site that runs disconnected and syncs back? If it does, the platform's job is to
give each site what that feature needs. If it does not, writing into the vendor's database behind
its back is unsupported; the alternative is an export and import through the product's own
interfaces, which somebody has to build and own, with a review queue for case 3.

**Proposal: an external site always works on its local copy.** If a site normally uses the main
system and switches to a local copy only when the link is cut, the switch-over happens during an
incident — the least-tested moment there is. If it always works locally and the link only carries
sync, a lockdown pauses sync and changes nothing about how the site runs. Depends on A4.

**A lockdown is a security event.** For its duration the external site ran outside the main
facility's control. What comes back should land in a staging area and be checked before it is
merged, not replicate straight in — and a named person authorises the reconnect.

## What an external site needs to run alone

An external site is a smaller copy of this enclave, and most of it already exists here:

- compute and a database of its own — how big depends on A1;
- its own backups (`vm-backup.sh`) — the lockdown length (A5) sets how much;
- its own time source, if a lockdown can outlast the clock's drift tolerance;
- identity that works disconnected — CAC needs revocation lists cached at the site (6a.23, D3);
- its own monitoring, because `svc-obs-01` is on the other side of the cut;
- patches and images carried from the main site while connected (mirror, Harbor).

**One host per site means a host failure during a lockdown stops that site.** Whether that is
acceptable is part of A1.

## Questions

| # | Question | Why it decides the design | Answer |
|---|---|---|---|
| **A1** | How many external sites, and what runs at each — the full application or part of it, for how many users? | Sizes each site: one host or three | ⬜ open |
| **A2** | What carries the link in normal operation — dedicated fibre, a leased circuit, an encrypted tunnel — and are the external sites inside the same accreditation boundary? | One system across sites, or separate systems with an interconnection agreement. A link through space the facility does not control needs FIPS-validated encryption on it | 🔄 **partly answered 2026-10-30 (Brian):** *"these are closed systems but get more closed on lock down"* — no egress in either state; the lockdown cuts the inter-site link. **Still open:** what carries the link, and whether it crosses uncontrolled space |
| **A3** | During a lockdown, does an external site only create new records, or also change records that existed before? Does the main side change those same records meanwhile? | Cases 1–3 above | ⬜ open |
| **A4** | Does the COTS application support a disconnected remote site that syncs back? | Vendor-supported sync, or a built export/import | ⬜ open — vendor |
| **A5** | How long can a lockdown last — hours, days, weeks? | Storage, backups, time source and CRL freshness at each site | ⬜ open |
| **A6** | Who declares a lockdown, how is the link cut (physically or by policy), and who authorises the reconnect? | The reconcile procedure and its checks | ⬜ open |
| **A7** | Does data also flow out — do external sites receive the main side's records, and does reference data (people, locations) need to stay current while connected? | One-way or two-way, and what goes stale during the split | ⬜ open |

## What changes

Not yet known — written once A1–A4 are answered.
