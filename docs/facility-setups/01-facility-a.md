# Facility A — a main facility with external sites that must run through a lockdown

**Status: designed on paper 2026-10-30 — all fifteen questions answered by Brian (A1–A15, plus
A10c). Still open: the review role, vendor questions 2–6, DoD CRL lifetime, a survey of each site.
Nothing built.**
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

**Answer them in this order.** A4 and A3 first: together they decide whether the merge is
**bought** (the vendor's feature) or **built** (an export, staging and review queue that somebody
owns). A2 and A1 next: they decide the accreditation shape and the hardware at each site. The rest
refine a design that those four have already shaped.

| # | Question | Who answers | Why it decides the design | Answer |
|---|---|---|---|---|
| **A1** | How many external sites, and what runs at each — the full application or part of it, for how many users? | facility | Sizes each site: one host or three | 🔄 **4–10 external sites** (Brian, 2026-10-30). So a site is a **repeatable, parameterised build** — one procedure, a parameter file per site, never hand-built 4–10 times — and a reconnect after a lockdown is up to ten separate merges. ✅ **The whole application at every site** (Brian, 2026-10-30) — so the merge covers every record type the product has. ✅ **Under 10 concurrent users per site** (Brian, 2026-10-30) — small hardware. **One host or more is decided by A9**, not by load |
| **A2** | What carries the link in normal operation — dedicated fibre, a leased circuit, an encrypted tunnel — and are the external sites inside the same accreditation boundary? | facility (link) · AO (boundary) | One system across sites, or separate systems with an interconnection agreement. A link through space the facility does not control needs FIPS-validated encryption on it | ✅ **Answered 2026-10-30 (Brian):** *"these are closed systems but get more closed on lock down"* — no egress in either state; the lockdown cuts the inter-site link. ✅ **The link is the facility's own fibre, on ground it controls** (Brian, 2026-10-30) — so no bulk link encryption is required for crossing uncontrolled space; the services' own TLS still protects the traffic. Reading, to confirm with A15: the external sites are outside the **lockdown** perimeter but on ground the facility controls. ✅ **One system, one authorization** (Brian as acting AO, 2026-10-30): one SSP covers every site, each external site a segment of the same enclave — so **every site meets the full control set**, physical protection included (A15) |
| **A3** | During a lockdown, does an external site only create new records, or also change records that existed before? Does the main side change those same records meanwhile? And when both sides changed one record, who decides which stands — a rule, or a named role? | mission owner | Cases 1–3 above | 🔄 **All three — answered 2026-10-30 (Brian):** *"case 1, 2, 3 must all be accounted for"*. The built merge handles new records, changes to records the main side did not touch, **and real conflicts**. ✅ **Conflicts: merge by field, a person for real clashes** (Brian, 2026-10-30): where the two sides changed **different** fields of a record, both changes apply automatically; only where they changed the **same** field does a named role decide, from a review queue. Nothing is discarded silently — both versions stay in the record's history. ⚠️ **What that requires:** a field can only be called "changed" against the record **as it stood at the cut**, so every site keeps that starting state, and its change journal records each field's before and after. Still open: which role reviews the queue |
| **A4** | Does the COTS application support a disconnected remote site that syncs back? Detail below | vendor | Vendor-supported sync, or a built export/import | ✅ **No — answered 2026-10-30 (Brian).** The product runs only as one central system. **The merge is BUILT**: export, staging, checks and a review queue, through the product's own interfaces, owned by whoever builds it. The vendor questions below narrow to what that build needs |
| **A5** | How long can a lockdown last — hours, days, weeks? | facility | Storage, backups, time source and CRL freshness at each site | ✅ **Design for 30–45 days untended — the design figure is 45** (Brian, 2026-10-30). So: a receive-only GPS time source at every site; CAC revocation lists valid 45+ days after the cut, or an AO decision on what happens when they expire; application passwords that outlive 45 days, or CAC; an alert on any site certificate within 45 days + margin of expiry. Comparison in the A5 section below |
| **A6** | Who declares a lockdown, how is the link cut (physically or by policy), and who authorises the reconnect? | facility | The reconcile procedure and its checks | 🔄 **The cut is both** (Brian, 2026-10-30): configuration first for speed, then a physical disconnect to make it certain. **Design rule that follows:** a site behaves the same however the link is lost, and **the reconnect is the controlled step** — sync resumes only when authorised, never because the link came back; plugging the fibre back in starts nothing. ✅ **Reconnect in two steps, by two roles** (Brian, 2026-10-30): security lifts the lockdown and restores the link; then the system owner (or ISSO) **releases each site's merge** after its staging checks pass — *is it safe* and *is the data good* are separate decisions with separate names. Reading: security also declares the lockdown |
| **A7** | Does data also flow out — do external sites receive the main side's records, and does reference data (people, locations) need to stay current while connected? | mission owner | One-way or two-way, and what goes stale during the split | ✅ **Two-way, and every site holds a full copy of everything** (Brian, 2026-10-30; answers A13 too). Any lookup works during a lockdown. **What it costs:** 4–10 complete copies of records retrieved by personal identifier, outside the lockdown perimeter — each encrypted at rest, each sized for the whole database, and each in the records-destruction scope (3.27). **Destruction is a change the merge must carry too:** a record destroyed on one side during a lockdown and edited on the other is a conflict of its own |
| **A8** | Who can fix an external site during a lockdown? Nobody at the main facility can reach it while the link is cut | facility | A trained person and local admin accounts at each site, or a stated acceptance that a broken site stays broken until the reconnect | ✅ **Nobody — a broken site waits for the reconnect** (Brian, 2026-10-30); a stated, accepted risk, with no admin access held at the sites. **What follows:** (1) a site must run the whole lockdown **untended** — disks, logs and backups sized for the longest lockdown (A5) with margin, nothing scheduled that needs a person; (2) staff at a broken site fall back to **paper**, and those records are entered at the reconnect — a fourth input to the merge |
| **A9** | If an external site's hardware fails during a lockdown, how much of its data may be lost, and how soon must it be working again? | mission owner · AO accepts | One host or three per site (A1), and how often the site backs itself up | ✅ **M2 — two hosts + a witness per site** (Brian, 2026-10-30): keeps running through a host loss with nobody's help. Options and trade-offs in the A9 section below |
| **A10** | Are the external sites linked to each other, or only to the main facility? In a lockdown, are they cut from each other too? | facility | Hub or mesh: whether sites see each other's data, and how many merges a reconnect has | ✅ **Mesh — and the external sites keep syncing each other during a lockdown** (Brian, 2026-10-30). **The most expensive answer so far, stated plainly:** (1) during a lockdown the external sites are **4–10 writers merging continuously**, not islands waiting for one merge each — the merge stops being a batch job at the reconnect and becomes a **continuously running sync engine** between independent instances of a product whose vendor does not support it (A4), which somebody builds, tests and owns; (2) a same-field clash between two sites **cannot be reviewed during the lockdown** if nobody at the sites holds the review role — the record has to carry both values, visibly flagged, until the main's reviewer decides; (3) **the staging checks are bypassed between sites**: a bad change at one site reaches the others before anything checks it, and the main's checks see it only at the reconnect; (4) the mesh can **split unevenly** — A reaches B but not C — so the engine must handle any partition, not just "main cut off"; (5) the order of changes comes from per-record version tracking, not clocks (GPS helps people read times, it cannot order edits). See A10c for how the sites sync |
| **A10c** | During a lockdown, how do the external sites sync with each other — through a lead site, or peer to peer? | Brian | How much is built: one merge component, or a general multi-writer engine | ✅ **Through a lead site** (Brian, 2026-10-30). One external site is pre-named the **lockdown lead**, with a pre-named backup; during a lockdown the others sync with it exactly as they sync with the main normally. **The same hub merge component runs at the main and at the lead** — built and tested once. A site that cannot reach the lead runs alone. At the reconnect, the lead's merged state and any lone site merge into the main, each change still carrying the site that made it |
| **A11** | Is an unplanned link failure — a cut fibre, a dead switch — handled exactly like a lockdown? Can one site be cut while the others stay connected? | mission owner | **Recommended: yes to both** — one mechanism, reconciled per site. Otherwise the everyday failure takes a path the drill never tests | ✅ **Yes — one mechanism for every loss of contact** (Brian, 2026-10-30): lockdown, cut fibre or dead switch, one site or all. A site first tries to reach the main **through the mesh**; failing that, it works with the lead or alone. Every link failure therefore exercises the lockdown path. Proposed detail: after an unplanned loss, with no lockdown declared, only the second reconnect step applies — the system owner's release |
| **A12** | If a person's access is withdrawn at the main facility during a lockdown, how soon must the external sites honour it? They cannot hear about it until the reconnect | AO | A local revocation procedure at each site, or a stated, accepted risk | ✅ **By phone and a site supervisor** (Brian as acting AO, 2026-10-30): security tells the sites out of band — phone or radio — and a **supervisor role in the application** at each site (not an OS admin, so A8 stands) disables the user; the change syncs through the lead to every reachable site. Depends on the product allowing that role — vendor question 6 |
| **A13** | After the reconcile, does an external site keep every record, or only what it needs to work? | mission owner · privacy office | Every copy of records retrieved by personal identifier is in the retention and destruction scope (backlog 3.27), and each copy sits outside the facility perimeter | ✅ **Every record, at every site** — answered with A7 (Brian, 2026-10-30). ⚠️ The privacy office should see this: it multiplies the copies the records notice has to cover |
| **A14** | Will lockdowns be drilled, how often, and does the drill include the reconcile? | facility | A reconcile that has never run fails the first time it is real. Sets how the procedure is tested | ✅ **Quarterly, merge included** (Brian, 2026-10-30): the cut, the lead taking over, the two-role reconnect and the merge with its review queue, four times a year, on the real system. ⚠️ A drill cannot run for 45 days: the **untended** claim (A5) is proven by sizing and measurement, not by the drill |
| **A15** | What does an external site have: a locked room or a rack, power and UPS runtime, cooling, physical access control? | facility | The hardware's form factor, and the physical-protection (PE) controls at each site | 🔄 **Space varies by site** (Brian, 2026-10-30): some have rooms, some only a locking cabinet in a shared room. So **one site build that fits the smallest** — compact hardware that fits a locking cabinet — and the physical controls written **per site** (who holds the key, the access log). A site survey per site also places the **GPS antenna**, which needs a view of the sky. ✅ **Power also varies by site** (Brian, 2026-10-30) — so design for the weakest, **UPS only**: a site must survive a total power loss mid-lockdown and **restart unattended** — firmware set to power on after AC loss, disks unlocked by TPM (clevis, already working on all four main hosts — never a passphrase prompt), the UPS signalling a clean shutdown on low battery, and the database and cluster **cold-starting in the right order by themselves**, which the main build does not do yet (backlog 3.57) |

**A4 in detail — the questions for the vendor:**

1. ~~Does the product have a supported mode for a site that runs disconnected and syncs back?~~
   **No** (Brian, 2026-10-30). So the questions are now about building the merge around it:
2. Can an **independent instance** run at each external site, and what does each cost in licences?
3. How does it number records, and can numbering be split by site (a range or a prefix per site)?
4. What interfaces does it offer to **read and write records** — an API, an import, an export — and
   does writing through them keep the product's own rules: validation, its audit trail? Writing to
   its database directly is the path the vendor will not support.
5. Is an instance supported on this platform: Canonical Kubernetes, PostgreSQL 16?
6. Can a **supervisor role** — not an administrator — disable a user in one instance, and are
   user accounts data that can be read and written through the interfaces in 4, so a disable
   at one site can sync to the others (A12)?

## A9 — the options for a site whose host fails during a lockdown

Asked 2026-10-30; Brian asked to see the options for *must keep running* and *short outage*.
The constraint that shapes all four: **during a lockdown nobody from the main facility can help**,
so whatever recovery an option needs happens with what is already at the site.

| | Option | Machines per site | A host fails during a lockdown | Needs a person on site (A8) |
|---|---|---|---|---|
| **M1** | **Three small hosts** — the main enclave in miniature: Kubernetes and a Patroni member on each | 3 | **Keeps running, automatically.** Patroni failover was proven by a power cut on 2026-09-28; a lost Kubernetes worker costs ~50 s of partial failures (3.63). Then runs with no spare — degraded until the host is replaced, after the reconnect | No |
| **M2** | **Two hosts + a witness** — a small box holding only quorum votes, no data. The witness design already exists as option 2.8 | 2 + witness | **Keeps running, automatically** — either host can be lost | No |
| **S1** | **One host + a warm standby** — a second machine holding a synchronous copy of the database, application stopped | 2 | **No data lost. Down for minutes** while a person promotes the standby and starts the application on it. Two machines cannot fail over by themselves — that needs a third vote, which is M2 | Yes |
| **S2** | **One host + an on-site backup device + a cold spare** | 1 + backup device + spare | **Loses the changes since the last archive** — up to `archive_timeout`, 300 s in the main build, a parameter. **Down for hours** while a person restores onto the spare | Yes, the restore |

**Across 4–10 sites the counts multiply** — M1 is 12–30 machines, M2 8–20 plus a witness each.
Subscriptions are counted per machine, and the COTS licence per instance is vendor question 2.

**The coupling to A8:** S1 and S2 work only if a trained person is at the site during a lockdown.
If A8's answer is *nobody*, only M1 and M2 remain.

✅ **Chosen: M2** (Brian, 2026-10-30). Two consequences to design for:

- **The witness sits at the site, not at the main facility.** In a lockdown the site is alone; a
  witness on the far side of the cut is a vote it cannot reach.
- **Storage on two hosts needs its own answer.** The application's records are in PostgreSQL,
  which Patroni replicates; anything the main build keeps on Ceph (the map store, per the data
  protection diagram) cannot use the three-host Ceph layout at a two-host site.

## A5 — designing for a week, or for weeks

Asked 2026-10-30; Brian asked to see the *week* and *weeks or more* options. A site runs the whole
lockdown untended (A8), so everything below has to last it with nobody touching it. Measured or
configured values are this repo's; nothing here is estimated except where it says so.

| | Up to a week | Weeks or more (say 30–45 days) | Source |
|---|---|---|---|
| **Clock** | ~4 s of drift at the measured rate — acceptable. At the reconnect the site's clock **steps** back by that much, and its audit trail shows the step | ~17 s a month and growing. **A receive-only GPS time source at every site** — the main facility's own AO-13 design, 4–10 times over | `HANDOFF.md` AO-13: +0.583 s/day measured on lab hardware; STIG `makestep 1 -1` makes any correction over 1 s a step |
| **CAC revocation lists (DoD CRLs)** | Must still be valid a week after the cut | Must still be valid 30+ days after the cut. **If they are not, then when they expire either CAC logins fail at the site, or revocation checking is relaxed** — an AO decision either way | 6a.23 D3. ⚠️ **How long DoD CRLs stay valid is not measured here** — read `nextUpdate` from the real files when CAC is built |
| **Enclave certificates** | No effect: CRL 90 days, leaf certificates 365 days | No effect at these lifetimes — but lockdowns are unannounced, so a site certificate must never sit within *(longest lockdown + margin)* of its expiry: an alert, not a habit | `ca.sh` defaults `CA_CRL_DAYS` 90, `CA_LEAF_DAYS` 365 |
| **OS accounts** | No effect — nobody logs into a site's OS during a lockdown (A8) | Same. The hard ceiling is ~95 days (password max 60 + inactive 35), well past either | `stig-tailor.sh` |
| **Application users' passwords** | The product's own policy | **A password that expires mid-lockdown locks that user out until the reconnect** — nobody can reset it (A8). Expiry longer than the longest lockdown, or CAC | vendor — the product's settings |
| **Disk for logs** | ~175 MB per machine | ~750 MB per machine per month — still small | audit rate measured 25 MB/day/machine (`open-questions.md`, audit offload) |
| **The merge** | A week of changes from under 10 users per site | A month of changes, a bigger review queue, and more paper records from any broken site (A8) | — |
| **Withdrawn access (A12)** | Stays valid at the sites for up to a week | Stays valid for weeks | — |

✅ **Chosen: weeks, 30–45 days; the design figure is 45** (Brian, 2026-10-30).

**Verdict:** weeks costs **a GPS receiver per site** and an answer on **CAC revocation lists**.
Everything else holds at either length. Lockdowns are not scheduled, and a design for a week
fails *during* a long one — the clock wanders and the revocation lists expire with nobody there
to fix either.

## The design, as decided 2026-10-30

Put together from the answers above; each point names the question it comes from. Designed on
paper, nothing built.

**Shape.** The main facility is today's enclave, unchanged in shape, plus a **sync hub**. Around it
are **4–10 identical external sites** (A1), each built from one procedure and a parameter file per
site: two hosts and a witness (A9, M2), a receive-only GPS time source (A5), and a UPS, sized to
fit a locking cabinet (A15). The links are facility-owned fibre on controlled ground (A2), and the
sites are also linked to each other (A10). **It is one system with one authorization (A2).**

**Data.** Every site holds a **full copy of every record**, encrypted at rest and in the
destruction scope (A7, A13). Each site numbers new records from **its own range** (A3, vendor
question 3). **A site always works on its local copy**, and the link carries sync, so a cut pauses
sync instead of switching anything over.

**The sync and merge component — built, not bought (A4).**

- It reads and writes **through the product's own interfaces** (vendor question 4), never its
  database directly.
- Every change carries **site, record, field, before, after, and version**. "Changed" is judged
  against the record **as it stood at the cut**.
- **Merge by field (A3).** Changes to different fields both apply. A clash on the same field
  leaves the record carrying **both values, flagged**, until the review queue at the main decides.
  A record destroyed on one side and edited on the other is a clash too.
- It is **one component in two places**: the main normally, and the **pre-named lead site** during
  a lockdown, with a pre-named backup lead (A10c).

**Lockdown.**

- **Cutting the link:** by configuration first, then physically (A6).
- **Running untended:** sites run up to **45 days** with nobody to fix them (A5, A8). They keep
  syncing each other through the lead; a site that cannot reach the lead runs alone. Any loss of
  contact uses this same mechanism, and a site tries the main through the mesh first (A11).
- **Withdrawing access:** security phones or radios the sites, and an application supervisor
  disables the user there (A12).
- **A site that breaks:** its staff use paper, entered at the reconnect (A8).

**Reconnect: two steps, two roles (A6).**

1. **Security** lifts the lockdown and restores the link. Nothing syncs.
2. **The system owner or ISSO** releases the merge, site by site. The lead's merged state (every
   change tagged with its site), any lone site's changes and any paper records go to **staging**
   for checks, then the merge, with clashes sent to the review queue. Then the main's state flows
   back out to every site.

After an unplanned loss with no lockdown declared, step 2 alone (proposed, A11).

**Running untended for 45 days.**

- Disks, logs (~750 MB per machine per month) and backups are sized for it, and nothing scheduled
  needs a person.
- **A total power loss restarts by itself:** power-on after AC loss, TPM disk unlock, a clean
  shutdown signalled by the UPS, and an **ordered cold start of the database and the cluster**
  (backlog 3.57, not yet solved on the main build).
- CAC revocation lists stay valid 45+ days, or the AO decides what happens when they expire.
  Application passwords outlive 45 days, or logins use CAC. An alert fires on any site certificate
  within 45 days plus a margin of its expiry.

**Tested quarterly**, merge included (A14). The 45-day claim is proven by sizing and measurement.

### What it adds to this repo, when built

| | Item | Builds on |
|---|---|---|
| **New** | **The sync and merge component**, with staging, checks and the review queue. **The largest item, and with no vendor support** | — |
| **New** | **A site build**: the unattended build parameterised for two hosts and a witness, with one parameter file per site | backlog 2.6, the witness design in 2.8 |
| **Required** | **An unattended cold start** of Postgres and Kubernetes after total power loss | backlog 3.57 |
| **Changed** | **Time**: GPS at every site, not just the main | AO-13 |
| **Changed** | **The SSP**: several sites, mesh links, physical controls per site, and PPSM rows for the sync traffic | baseline documents |
| **Changed** | **Records destruction** at every site, and the privacy office told about the copies | backlog 3.27 |

### The honest cost

The sites are buildable from what this repository already does. **The sync engine is a software
product of its own**: a continuously running, multi-site, field-level merge around a COTS product
whose vendor does not support it. It needs an owner, a test suite and a lifecycle. Two things
follow that are easy to miss:

- **Every product upgrade has to be re-tested against the sync engine before it reaches any site.**
  The interfaces it relies on can change.
- **The main and all 4–10 sites must run the same product version.** An upgrade becomes one
  coordinated event across every site, and it cannot happen during a lockdown.

### Still open

- **Which role works the review queue** (A3).
- **Vendor questions 2–6.**
- **How long DoD revocation lists stay valid**, measured when CAC is built (6a.23).
- **A survey of each site**: space, power, GPS antenna placement, key holders.
