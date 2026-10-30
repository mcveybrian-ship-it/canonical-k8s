# Facility setups — scenarios for taking the enclave to a facility

This enclave is **a template for other facilities, not a one-off** (`docs/compliance/baseline/README.md`).
This folder works that through one facility at a time: a scenario with its constraints, the
questions it raises, and what the build has to change to fit it.

**One file per scenario, `NN-<short-name>.md`.** Each holds:

- **The scenario as given** — space, power, cooling, network, physical security, staff, what is
  already on site.
- **The questions**, and for each one the answer with **where it comes from in this repo**, or
  plainly *not answered: measure it* or *not answered: the facility decides*.
- **What changes**: parameters (`host-params.env`, `vm-specs.env`, `enclave-addresses.env`,
  `facility-profile.env`), documents, hardware. A change that cannot be a parameter is a finding.

**A diagram, where one helps, is `NN-<short-name>.drawio` beside the scenario.** It uses the
enclave diagrams' styles but, unlike `docs/diagrams/`, **nothing generates it** — a scenario has
no source file to draw from, so edit it in draw.io and keep it agreeing with its `.md`.

**`origin` is public.** No real facility name, address, building, room, POC or sponsor goes in
this folder. Those are layer 3 and live only in
[`facility-profile.env`](../compliance/baseline/facility-profile.env), or `HANDOFF.md` §3 for
the client. Describe a facility by its characteristics, never its identity.
