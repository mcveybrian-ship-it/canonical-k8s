# Facility A — a main facility that can disconnect from its external sites at will

Backlog 3.74. **The answers live in [`01-facility-a.env`](01-facility-a.env)**, one line each with
who set it and when. **Everything below the BEGIN marker, and the whole of
[`01-facility-a.drawio`](01-facility-a.drawio), is generated from them** by
[`facility-design.py`](facility-design.py) — change an answer and rebuild; never edit the
generated parts. A what-if prints the variant's design and checks and writes nothing:

```bash
### MACHINE: stage-01 (10.0.20.160) - prints only, writes nothing ###
python3 docs/facility-setups/facility-design.py show 01-facility-a SITE_HA=S1 DISCONNECT_DAYS=120
```

Changing an answer writes the `.env`, the block below and the `.drawio`:

```bash
### MACHINE: stage-01 (10.0.20.160) ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && python3 docs/facility-setups/facility-design.py set 01-facility-a SITE_HA=M1 --note "why"
fi
```

`ask 01-facility-a --open` walks only the unanswered questions, one at a time; `keys` lists every
key and the values it takes.

## The scenario (Brian, 2026-10-30)

- The main facility runs the internal system.
- External sites sit outside the facility and are connected to it.
- **The main facility can disconnect from the external sites at will** — whenever it chooses, for
  any reason. The design does not depend on why.
- While disconnected **both sides keep running**: the internal system, and each external site on
  its own.
- When the connection comes back, the external sites' data is **reconciled back into the
  internal system**.
- Every site is a closed system, connected or not: *"these are closed systems but get more closed
  on lock down"*.

*Restated 2026-10-30.* The scenario was first given as a lockdown: when the facility goes on
lockdown, the internal system is cut off from the external sites. Brian widened it the same day to
a main site that can be disconnected at will from the external sites. Every answer below carries over
unchanged, and the questions now say *disconnect*. The widening raised one new question: who may
order a disconnect (A6c).

## Where the hard part is

**Copying data back is easy. Deciding what wins is not.** Three cases, in order of difficulty:

1. **External sites only create new records during the disconnect.** The reconcile is an append.
   The one trap: if both sides number records from their own counter, both issue the same next
   number. Per-site number ranges or prefixes have to be decided **before** the first disconnect —
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
sync, a disconnect pauses sync and changes nothing about how the site runs. Depends on A4.
With disconnects at will this matters more: one can come at any time, and it must never be an
incident for the site.

**Treat every reconnect as a security event, whatever the reason for the disconnect.** For its
duration the external site ran outside the main facility's control. What comes back should land
in a staging area and be checked before it is merged, not replicate straight in — and a named
person authorises the reconnect.

## How the harder answers were reached (2026-10-30)

Two answers came after Brian asked to see the options. The comparisons are kept as he saw them —
**a record of the decision, not the current state**: the current answers are in the generated
block, and a later change there does not rewrite this history. The one edit since: he saw them
as *lockdown*, now *disconnect* (restated above). The substance is unchanged.

### A9 — the options for a site whose host fails during a disconnect

Asked 2026-10-30; Brian asked to see the options for *must keep running* and *short outage*.
The constraint that shapes all four: **during a disconnect nobody from the main facility can help**,
so whatever recovery an option needs happens with what is already at the site.

| | Option | Machines per site | A host fails during a disconnect | Needs a person on site (A8) |
|---|---|---|---|---|
| **M1** | **Three small hosts** — the main enclave in miniature: Kubernetes and a Patroni member on each | 3 | **Keeps running, automatically.** Patroni failover was proven by a power cut on 2026-09-28; a lost Kubernetes worker costs ~50 s of partial failures (3.63). Then runs with no spare — degraded until the host is replaced, after the reconnect | No |
| **M2** | **Two hosts + a witness** — a small box holding only quorum votes, no data. The witness design already exists as option 2.8 | 2 + witness | **Keeps running, automatically** — either host can be lost | No |
| **S1** | **One host + a warm standby** — a second machine holding a synchronous copy of the database, application stopped | 2 | **No data lost. Down for minutes** while a person promotes the standby and starts the application on it. Two machines cannot fail over by themselves — that needs a third vote, which is M2 | Yes |
| **S2** | **One host + an on-site backup device + a cold spare** | 1 + backup device + spare | **Loses the changes since the last archive** — up to `archive_timeout`, 300 s in the main build, a parameter. **Down for hours** while a person restores onto the spare | Yes, the restore |

**Across 4–10 sites the counts multiply** — M1 is 12–30 machines, M2 8–20 plus a witness each.
Subscriptions are counted per machine, and the COTS licence per instance is vendor question 2.

**The coupling to A8:** S1 and S2 work only if a trained person is at the site during a disconnect.
If A8's answer is *nobody*, only M1 and M2 remain.

**Brian chose M2 on 2026-10-30.** Two consequences it carries:

- **The witness sits at the site, not at the main facility.** In a disconnect the site is alone; a
  witness on the far side of the cut is a vote it cannot reach.
- **Storage on two hosts needs its own answer.** The application's records are in PostgreSQL,
  which Patroni replicates; anything the main build keeps on Ceph (the map store, per the data
  protection diagram) cannot use the three-host Ceph layout at a two-host site.

### A5 — designing for a week, or for weeks

Asked 2026-10-30; Brian asked to see the *week* and *weeks or more* options. A site runs the whole
disconnect untended (A8), so everything below has to last it with nobody touching it. Measured or
configured values are this repo's; nothing here is estimated except where it says so.

| | Up to a week | Weeks or more (say 30–45 days) | Source |
|---|---|---|---|
| **Clock** | ~4 s of drift at the measured rate — acceptable. At the reconnect the site's clock **steps** back by that much, and its audit trail shows the step | ~17 s a month and growing. **A receive-only GPS time source at every site** — the main facility's own AO-13 design, 4–10 times over | `HANDOFF.md` AO-13: +0.583 s/day measured on lab hardware; STIG `makestep 1 -1` makes any correction over 1 s a step |
| **CAC revocation lists (DoD CRLs)** | Must still be valid a week after the cut | Must still be valid 30+ days after the cut. **If they are not, then when they expire either CAC logins fail at the site, or revocation checking is relaxed** — an AO decision either way | 6a.23 D3. ⚠️ **How long DoD CRLs stay valid is not measured here** — read `nextUpdate` from the real files when CAC is built |
| **Enclave certificates** | No effect: CRL 90 days, leaf certificates 365 days | No effect at these lifetimes — but a disconnect comes when the main chooses, not when a site is ready, so a site certificate must never sit within *(longest disconnect + margin)* of its expiry: an alert, not a habit | `ca.sh` defaults `CA_CRL_DAYS` 90, `CA_LEAF_DAYS` 365 |
| **OS accounts** | No effect — nobody logs into a site's OS during a disconnect (A8) | Same. The hard ceiling is ~95 days (password max 60 + inactive 35), well past either | `stig-tailor.sh` |
| **Application users' passwords** | The product's own policy | **A password that expires mid-disconnect locks that user out until the reconnect** — nobody can reset it (A8). Expiry longer than the longest disconnect, or CAC | vendor — the product's settings |
| **Disk for logs** | ~175 MB per machine | ~750 MB per machine per month — still small | audit rate measured 25 MB/day/machine (`open-questions.md`, audit offload) |
| **The merge** | A week of changes from under 10 users per site | A month of changes, a bigger review queue, and more paper records from any broken site (A8) | — |
| **Withdrawn access (A12)** | Stays valid at the sites for up to a week | Stays valid for weeks | — |

**Brian chose weeks on 2026-10-30, with 45 days as the design figure.**

**Verdict:** weeks costs **a GPS receiver per site** and an answer on **CAC revocation lists**.
Everything else holds at either length. A disconnect lasts as long as the main chooses, and a
design for a week fails *during* a long one — the clock wanders and the revocation lists expire with nobody there
to fix either.

<!-- BEGIN facility-design.py: generated from the .env - change answers with set or ask, never edit inside this block -->
**Status:** 21 of 30 questions answered · **0 conflicts** · 9 open. Answers: [`01-facility-a.env`](01-facility-a.env) · diagram: [`01-facility-a.drawio`](01-facility-a.drawio) · generated by [`facility-design.py`](facility-design.py).

## Checks

🔴 conflict - two answers cannot both hold · 🟠 cost - a consequence to accept knowingly · 🔵 depends on work not done yet · ⬜ open

- 🟠 **A4 no + A10b lead: the merge is a sync engine running through the disconnect**, not a batch job at the reconnect - a software product of its own around a COTS product that does not support it.
- 🟠 **Checks are bypassed between sites** (A10b): a bad change at one site reaches the others before anything checks it; the main's staging sees it only at the reconnect.
- 🟠 A7: **up to 10 complete copies of records retrieved by personal identifier** outside the main facility - tell the privacy office; the records notice has to cover them.
- 🔵 A15b: a site must restart unattended after a total power loss - an **ordered cold start of the database and the cluster**, which the main build does not do yet (backlog 3.57).
- 🔵 A9 M2: the witness design (backlog 2.8) becomes required, and anything the main keeps on Ceph needs a two-host answer at a site.
- 🔵 A4 no: the built merge depends on **V4** - which interfaces the product offers to read and write records.
- 🔵 A12 depends on **V6** - a supervisor role that can disable a user in one instance.

## What it changes in the current design

| The design today | This facility | Source |
|---|---|---|
| Network: **fully disconnected, no egress** - locked | **Still holds.** Every site is a closed system; a disconnect makes it more closed | `HANDOFF.md` §1 |
| One site, one room | 4-10 external sites plus the main, linked to each other | `HANDOFF.md` §1, §4 |
| One database, one writer | A writer at every site through a disconnect; the lead also merges the others | B-06a |
| The mission application is COTS | The merge is built around it, through its interfaces | 6a.21 |
| One clock, the main's time master | A GPS time source at every site | AO-13 |
| One authorization | Still one - every site inside it | A2b |

## Answers

| # | Question | Who answers | Answer | Set by |
|---|---|---|---|---|
| **A4** | Does the mission application (COTS) support an external site that runs disconnected and syncs its data back? | vendor | **No, it does not** - the merge is BUILT - through the product's own interfaces, owned by whoever builds it | Brian 2026-10-30 |
| **A3** | During a disconnect, what does an external site do to records? | mission owner | **Both sides may edit the same record** - cases 1-3: real conflicts, decided by a rule or a person (A3b) | Brian 2026-10-30: "case1 ,2,3 must all be account for" |
| **A3b** | When both sides changed one record, how is it decided? | mission owner | **Field merge + a person for clashes** - different fields: both apply; same field: the record carries both values, flagged, until a named role decides - nothing is lost silently | Brian 2026-10-30 |
| **A3c** | Which role works the review queue? | mission owner | ⬜ open |  |
| **A2a** | What physically carries the link between the main and the external sites? | facility | **The facility's own fibre, on its ground** - no bulk link encryption needed for crossing uncontrolled space; the services' own TLS still protects the traffic | Brian 2026-10-30: "these are closed systems but get more closed on lock down" |
| **A2b** | One system in one accreditation boundary, or separate systems with interconnection agreements? | AO | **One system, one authorization** - one SSP covers every site - so every site meets the full control set, physical protection included | Brian as acting AO 2026-10-30 |
| **A1a** | How many external sites? | facility | **4-10 sites** - enough that a site must be one repeatable build with a parameter file per site | Brian 2026-10-30 |
| **A1b** | What runs at each site during a disconnect? | mission owner | **The whole application** - every function at every site; the merge covers every record type | Brian 2026-10-30 |
| **A1c** | How many people use one site at the same time? | facility | **Under 10** - small hardware - a site is sized by its recovery model (A9), not by load | Brian 2026-10-30 |
| **A9** | A site's host fails during a disconnect, and nobody from the main can help. What is acceptable? | mission owner, AO accepts | **Two hosts + a witness - keeps running** - keeps running automatically through either host's loss; the witness is a small box holding only quorum votes, at the site (the 2.8 witness design) | Brian 2026-10-30, after seeing M1/M2/S1/S2 |
| **A8** | During a disconnect, who can fix a site when something other than a host failure breaks it? | facility | **Nobody - wait for the reconnect** - a site runs the whole disconnect untended; staff at a broken site use paper, entered at the reconnect | Brian 2026-10-30 |
| **A5** | What is the longest disconnect a site must survive untended, in days? | facility | **45** days | Brian 2026-10-30: weeks, 30-45 days, after seeing a week against weeks (asked as LOCKDOWN_DAYS) |
| **A6c** | The main can disconnect at will - who may order a disconnect? | facility | ⬜ open | A6c, added 2026-10-30 when the cut became "the main can disconnect at will" |
| **A6a** | How is the link cut when the main disconnects? | facility | **Both** - configuration first for speed, then a physical disconnect to make it certain | Brian 2026-10-30 |
| **A6b** | Who authorises the reconnect? | facility | **Two steps, two roles** - security ends the disconnect and restores the link; the system owner or ISSO then releases each site's merge after its checks | Brian 2026-10-30 |
| **A7** | What does each external site hold? | mission owner, privacy office | **A full copy of everything** - any lookup works during a disconnect; one complete copy of the records per site, each encrypted at rest and in the destruction scope | Brian 2026-10-30 (answers A13 too) |
| **A10** | Are the external sites linked to each other, or only to the main? | facility | **Also to each other** - site-to-site links too - what they do in a disconnect is A10b | Brian 2026-10-30 |
| **A10b** | During a disconnect, do the external sites sync each other, and how? | facility | **Yes, through a lead site** - a pre-named lead (and backup) runs the same hub as the main; the others sync with it | Brian 2026-10-30: the sites keep syncing each other, through a lead site |
| **A11** | Is an unplanned link failure (cut fibre, dead switch) handled exactly like an ordered disconnect? | mission owner | **Yes - one mechanism** - every loss of contact takes the disconnect path, so every link failure exercises it | Brian 2026-10-30 |
| **A12** | Someone's access is withdrawn at the main during a disconnect. How do the sites stop that person? | AO | **Phone + a site supervisor** - security phones the sites; a supervisor role in the application disables the user - vendor question V6 | Brian as acting AO 2026-10-30 |
| **A14** | How often is a full disconnect drilled, merge included? | facility | **Quarterly** - four full drills a year; the review queue becomes routine | Brian 2026-10-30 |
| **A15a** | What space does a site have for its equipment? | facility | **Varies by site** - one site build that fits the smallest; physical controls written per site | Brian 2026-10-30 |
| **A15b** | What power does a site have? | facility | **Varies by site** - design for the weakest: UPS only | Brian 2026-10-30 |
| **V2** | Can an independent instance run at each site, and what does each cost in licences? | vendor | ⬜ open |  |
| **V3** | How does the product number records - can numbering be split by site? | vendor | ⬜ open |  |
| **V4** | What interfaces read and write records (API, import, export), and does writing through them keep the product's validation and audit trail? | vendor | ⬜ open |  |
| **V5** | Is an instance supported on Canonical Kubernetes and PostgreSQL 16? | vendor | ⬜ open |  |
| **V6** | Can a supervisor role - not an administrator - disable a user in one instance, and are user accounts data the sync can carry? | vendor | ⬜ open |  |
| **CRL** | How many days are DoD revocation lists valid from issue (their nextUpdate)? | measured when CAC is built (6a.23) | ⬜ open | read nextUpdate from the real DoD CRLs when CAC is built (6a.23) |
| **SURVEY** | Has each site been surveyed - space, power, GPS antenna, key holders? | facility | ⬜ open |  |

## The design

**Shape.**

- The main facility is today's enclave, unchanged in shape, plus a **sync hub**.
- **4-10 external sites** (A1a), identical - one build procedure and a parameter file per site: two hosts + a witness (A9 M2); a receive-only GPS time source (A5); a UPS, and nothing more assumed (A15b); sized to fit a locking cabinet (A15a).
- Links: no bulk link encryption needed for crossing uncontrolled space; the services' own TLS still protects the traffic (A2a). Sites linked to each other as well as to the main (A10).
- **One SSP covers every site - so every site meets the full control set, physical protection included** (A2b).

**Data.**

- Each site holds a full copy of everything: any lookup works during a disconnect; one complete copy of the records per site, each encrypted at rest and in the destruction scope (A7).
- Each site numbers new records from **its own range** (A3, V3) - decided before the first disconnect.
- **A site always works on its local copy**; the links carry sync, so a cut pauses sync instead of switching anything over.
- The scope is every function at every site; the merge covers every record type (A1b).

**Sync and merge.**

- **Built, not bought (A4):** reads and writes **through the product's own interfaces** (V4), never its database.
- Every change carries **site, record, field, before, after and version**; *changed* is judged against the record **as it stood at the cut**.
- **Cases 1-3** (A3). Different fields: both apply; same field: the record carries both values, flagged, until a named role decides - nothing is lost silently (A3b).
- A record **destroyed on one side and edited on the other** is a clash too.
- **Who works the review queue is open** (A3c).
- **One component in two places:** the main normally, and the **pre-named lead site** during a disconnect, with a pre-named backup lead (A10b).

**Disconnected.**

- **The main disconnects from the external sites at will** - for any reason, whenever it chooses.
- **Who may order a disconnect is open** (A6c).
- **Cut:** configuration first for speed, then a physical disconnect to make it certain (A6a).
- **Untended for up to 45 days** (A5): a site runs the whole disconnect untended; staff at a broken site use paper, entered at the reconnect (A8).
- The sites keep syncing each other **through the lead**; a site that cannot reach the lead runs alone.
- **Any loss of contact uses this same mechanism** (A11); a site tries the main **through the mesh** first.
- **Withdrawn access:** security phones the sites; a supervisor role in the application disables the user - vendor question V6 (A12).

**Reconnect.**

- Plugging the link back in **starts nothing** (A6b).
- **Step 1 - security** ends the disconnect and restores the link. Nothing syncs.
- **Step 2 - the system owner or ISSO** releases the merge, site by site, after its checks.
- In: the lead's merged state (every change tagged with its site), any lone site's changes, paper records from a site that broke -> **staging** at the main -> checks -> the merge -> clashes to the review queue -> the system of record -> back out to every site.
- After an unplanned loss, with no disconnect ordered: step 2 alone (proposed, A11).

**Running untended for 45 days.**

- Disks, logs and backups sized for it - nothing scheduled needs a person.
- **Clock:** 26.2 s of drift without GPS, over the 5 s tolerance - **a receive-only GPS at every site**.
- **Revocation lists** must outlast 59 days: the enclave CRL is 90 days; DoD lists are not measured yet (CRL).
- **Application passwords** must outlive 45 days, or logins use CAC.
- **An alert** on any site certificate within 59 days of expiry.
- **A total power loss restarts by itself:** power-on after AC loss, TPM disk unlock, a clean shutdown on the UPS signal, and an ordered cold start of the database and the cluster (3.57).

**Testing.**

- Quarterly (A14) - merge included; the untended length is proven by sizing and measurement, not by the drill.

## Numbers

| | Value | From |
|---|---|---|
| External sites (A1a) | **4-10** | the answer |
| Hosts at the sites (A9 M2) | **8-20** | 2 per site |
| Witness boxes | **4-10** | one per site, at the site |
| Clock drift over 45 days, no GPS | **26.2 s** | 0.583 s/day, measured on lab hardware 2026-09-27/28 (poam.md AO-13); tolerance 5 s, ASSUMED - how far a site clock may drift before it needs its own GPS |
| Audit logs per machine over 45 days | **1.1 GB** | 25 MB/day, measured audit-log rate per machine (stig-tailor.sh; backlog N-2) |
| Everything that expires must outlast | **59 days** | the longest disconnect + 14 days margin (ASSUMED - margin before any certificate or list expires) |
| Enclave CRL lifetime | **90 days** | scripts/enclave/ca.sh default |
| Enclave certificate lifetime | **365 days** | scripts/enclave/ca.sh default |

## What it adds to this repo, when built

| | Item | Builds on |
|---|---|---|
| **New** | **The sync and merge component**, with staging, checks and the review queue - the largest item, with no vendor support | - |
| **New** | **A site build**: the unattended build parameterised for 2 hosts + witness, a parameter file per site | 2.6, the 2.8 witness design |
| **Required** | **An unattended cold start** of Postgres and Kubernetes after a total power loss | 3.57 |
| **Changed** | **Time**: a GPS at every site, not just the main | AO-13 |
| **Changed** | **The SSP**: several sites, the links, physical controls per site, PPSM rows for the sync traffic | baseline documents |
| **Changed** | **Records destruction at every site**, and the privacy office told about the copies | 3.27 |

## The honest cost

The sites are buildable from what this repository already does. **The merge is a software product of its own**: a continuously running, multi-site, field-level sync, around a COTS product whose vendor does not support it. It needs an owner, a test suite and a lifecycle.

- **Every product upgrade is re-tested against it** before it reaches any site - the interfaces it relies on can change.
- **The main and every site run the same product version**, so an upgrade is one coordinated event - never during a disconnect.

## Still open

- ⬜ **A3c** Which role works the review queue? - *mission owner*
- ⬜ **A6c** The main can disconnect at will - who may order a disconnect? - *facility*
- ⬜ **V2** Can an independent instance run at each site, and what does each cost in licences? - *vendor*
- ⬜ **V3** How does the product number records - can numbering be split by site? - *vendor*
- ⬜ **V4** What interfaces read and write records (API, import, export), and does writing through them keep the product's validation and audit trail? - *vendor*
- ⬜ **V5** Is an instance supported on Canonical Kubernetes and PostgreSQL 16? - *vendor*
- ⬜ **V6** Can a supervisor role - not an administrator - disable a user in one instance, and are user accounts data the sync can carry? - *vendor*
- ⬜ **CRL** How many days are DoD revocation lists valid from issue (their nextUpdate)? - *measured when CAC is built (6a.23)*
- ⬜ **SURVEY** Has each site been surveyed - space, power, GPS antenna, key holders? - *facility*

## Every question's options

So a change is a choice between known alternatives. ✅ marks the answer.

**A4** Does the mission application (COTS) support an external site that runs disconnected and syncs its data back?

| | Option | What it means |
|---|---|---|
|  | `yes` Yes, it has that mode | the merge is BOUGHT - the vendor's feature; the platform gives each site what it needs |
| ✅ | `no` No, it does not | the merge is BUILT - through the product's own interfaces, owned by whoever builds it |

**A3** During a disconnect, what does an external site do to records?

| | Option | What it means |
|---|---|---|
|  | `create` Only creates new records | case 1: the merge is an append - safe only with a number range per site |
|  | `update` Also changes old records | cases 1-2: sites also change records that existed before the cut; the main never touches those same records meanwhile |
| ✅ | `both-edit` Both sides may edit the same record | cases 1-3: real conflicts, decided by a rule or a person (A3b) |

**A3b** When both sides changed one record, how is it decided?

| | Option | What it means |
|---|---|---|
| ✅ | `field-merge` Field merge + a person for clashes | different fields: both apply; same field: the record carries both values, flagged, until a named role decides - nothing is lost silently |
|  | `person-all` A person decides every one | any record changed on both sides waits for review - the simplest rule, and the most manual work after a long disconnect |
|  | `main-wins` The main facility always wins | the main's version stands; the site's change is kept for review but not applied |
|  | `newest-wins` Newest change wins | the later timestamp stands - silently drops the other side's change, and needs trusted clocks at every site |

**A2a** What physically carries the link between the main and the external sites?

| | Option | What it means |
|---|---|---|
| ✅ | `own-fibre` The facility's own fibre, on its ground | no bulk link encryption needed for crossing uncontrolled space; the services' own TLS still protects the traffic |
|  | `leased` A leased circuit through uncontrolled space | the link needs FIPS-validated encryption and is part of the security boundary |
|  | `tunnel` An encrypted tunnel over another network | FIPS-validated tunnel endpoints at the main and every site; the carrying network stays outside the boundary |

**A2b** One system in one accreditation boundary, or separate systems with interconnection agreements?

| | Option | What it means |
|---|---|---|
| ✅ | `one` One system, one authorization | one SSP covers every site - so every site meets the full control set, physical protection included |
|  | `separate` Separate systems + agreements | each site authorized on its own, an interconnection agreement for every linked pair, and the merge moves records between systems |

**A1a** How many external sites?

| | Option | What it means |
|---|---|---|
|  | `1` 1 site | a single external site |
|  | `2-3` 2-3 sites | a handful of sites |
| ✅ | `4-10` 4-10 sites | enough that a site must be one repeatable build with a parameter file per site |

**A1b** What runs at each site during a disconnect?

| | Option | What it means |
|---|---|---|
| ✅ | `whole` The whole application | every function at every site; the merge covers every record type |
|  | `part` Only part of it | a subset of functions and fewer record types to merge - name the part in the scenario |

**A1c** How many people use one site at the same time?

| | Option | What it means |
|---|---|---|
| ✅ | `under-10` Under 10 | small hardware - a site is sized by its recovery model (A9), not by load |
|  | `10-50` 10-50 | a working office |
|  | `50-plus` 50+ | close to the main facility's own size |

**A9** A site's host fails during a disconnect, and nobody from the main can help. What is acceptable?

| | Option | What it means |
|---|---|---|
|  | `M1` Three hosts - keeps running | the main enclave in miniature: keeps running automatically through one host loss, then degraded until the host is replaced |
| ✅ | `M2` Two hosts + a witness - keeps running | keeps running automatically through either host's loss; the witness is a small box holding only quorum votes, at the site (the 2.8 witness design) |
|  | `S1` One host + a warm standby | no data lost; down for minutes while a PERSON promotes the standby |
|  | `S2` One host + backup device + spare | loses up to archive_timeout of changes; down for hours while a PERSON restores onto the spare |

**A8** During a disconnect, who can fix a site when something other than a host failure breaks it?

| | Option | What it means |
|---|---|---|
|  | `local-admin` A trained admin at each site | local admin accounts and break-glass envelopes at every site, each in the audit scope |
| ✅ | `nobody` Nobody - wait for the reconnect | a site runs the whole disconnect untended; staff at a broken site use paper, entered at the reconnect |
|  | `travel` Main staff travel to it | the disconnect cuts the network, not people: an admin goes to the site's console |

**A6c** The main can disconnect at will - who may order a disconnect?

| | Option | What it means |
|---|---|---|
|  | `security` The security officer | the same role that restores the link at the reconnect (A6b) |
|  | `owner` The system owner or ISSO | a disconnect is an operational decision as well as a security one |
|  | `either` Either of them | both roles hold the procedure; whoever is on duty orders it |

**A6a** How is the link cut when the main disconnects?

| | Option | What it means |
|---|---|---|
|  | `physical` Physically | a person disconnects or powers off the link at the main |
|  | `config` By configuration | the network shuts the inter-site ports - fast, and only as good as the configuration |
| ✅ | `both` Both | configuration first for speed, then a physical disconnect to make it certain |

**A6b** Who authorises the reconnect?

| | Option | What it means |
|---|---|---|
| ✅ | `two-step` Two steps, two roles | security ends the disconnect and restores the link; the system owner or ISSO then releases each site's merge after its checks |
|  | `security` The security officer alone | ending the disconnect releases every site's merge |
|  | `owner` The system owner or ISSO alone | one person decides both the reconnect and the merge |

**A7** What does each external site hold?

| | Option | What it means |
|---|---|---|
| ✅ | `full` A full copy of everything | any lookup works during a disconnect; one complete copy of the records per site, each encrypted at rest and in the destruction scope |
|  | `subset` Only what the site needs | its own area, open records and recent history; a lookup for anything else fails during a disconnect |

**A10** Are the external sites linked to each other, or only to the main?

| | Option | What it means |
|---|---|---|
|  | `hub` Only to the main | every site talks only to the main; a disconnect cuts every site from every other |
| ✅ | `mesh` Also to each other | site-to-site links too - what they do in a disconnect is A10b |

**A10b** During a disconnect, do the external sites sync each other, and how?

| | Option | What it means |
|---|---|---|
|  | `none` No - each site alone | site-to-site links carry no data in a disconnect; one merge per site at the reconnect |
| ✅ | `lead` Yes, through a lead site | a pre-named lead (and backup) runs the same hub as the main; the others sync with it |
|  | `p2p` Yes, peer to peer | every site merges with every site it reaches - a general multi-writer engine, the hardest thing to build and prove |

**A11** Is an unplanned link failure (cut fibre, dead switch) handled exactly like an ordered disconnect?

| | Option | What it means |
|---|---|---|
| ✅ | `same` Yes - one mechanism | every loss of contact takes the disconnect path, so every link failure exercises it |
|  | `different` No - an ordered disconnect is special | two paths to build; the everyday one is not the one an ordered disconnect uses |

**A12** Someone's access is withdrawn at the main during a disconnect. How do the sites stop that person?

| | Option | What it means |
|---|---|---|
| ✅ | `phone-supervisor` Phone + a site supervisor | security phones the sites; a supervisor role in the application disables the user - vendor question V6 |
|  | `accept` Accepted risk until the reconnect | the person stays valid at the sites for the whole disconnect |

**A14** How often is a full disconnect drilled, merge included?

| | Option | What it means |
|---|---|---|
| ✅ | `quarterly` Quarterly | four full drills a year; the review queue becomes routine |
|  | `twice` Twice a year | two full drills a year |
|  | `yearly` Yearly | one full drill a year - the contingency-plan test cadence |
|  | `none` Not drilled | the reconcile first runs when it is real |

**A15a** What space does a site have for its equipment?

| | Option | What it means |
|---|---|---|
|  | `room` A locked room | a dedicated, access-controlled room with its own rack |
|  | `cabinet` A locking cabinet in a shared room | the cabinet key and an access log become the controls |
| ✅ | `varies` Varies by site | one site build that fits the smallest; physical controls written per site |

**A15b** What power does a site have?

| | Option | What it means |
|---|---|---|
|  | `generator` Generator + UPS | outages rare and short - the unattended restart is still needed, rarely |
|  | `ups` UPS only | a long cut takes the site down; it must restart unattended |
| ✅ | `varies` Varies by site | design for the weakest: UPS only |

**SURVEY** Has each site been surveyed - space, power, GPS antenna, key holders?

| | Option | What it means |
|---|---|---|
| ✅ | `not-started` Not started | no site surveyed |
|  | `in-progress` In progress | some sites surveyed |
|  | `done` Done | every site surveyed |
<!-- END facility-design.py -->
