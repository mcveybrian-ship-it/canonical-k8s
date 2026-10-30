# Facility setups — scenarios for taking the enclave to a facility

This enclave is **a template for other facilities, not a one-off** (`docs/compliance/baseline/README.md`).
This folder works that through one facility at a time: a scenario with its constraints, the
questions it raises, and what the build has to change to fit it.

**Three files per scenario, and only one of them holds decisions:**

| File | What it is | Edited by |
|---|---|---|
| `NN-<short-name>.env` | **The answers** — one `KEY='value'` per question, with who set it and when | you, through `facility-design.py set` or `ask` (or by hand) |
| `NN-<short-name>.md` | The scenario as given and the reasoning, by hand; **below the BEGIN marker, generated** — checks, the design, numbers, what it adds to the repo, what is still open, every question's options | the top by hand; the block by the engine only |
| `NN-<short-name>.drawio` | Three pages — normal operation, disconnected, reconnect and reconcile | the engine only |

**[`facility-design.py`](facility-design.py) is the engine.** It holds the questions and their
options, derives the design from the answers, and **checks the answers against each other and
against the repo** — a recovery that needs a person at a site nobody staffs, a disconnect longer
than the enclave CRL lasts (read from `ca.sh`, not copied). A what-if prints a variant and writes
nothing:

```bash
### MACHINE: stage-01 (10.0.20.160) - prints only, writes nothing ###
python3 docs/facility-setups/facility-design.py show 01-facility-a SITE_HA=S1 DISCONNECT_DAYS=120
python3 docs/facility-setups/facility-design.py keys      # every key, its question, its values
```

Changing an answer writes the `.env` and rebuilds the generated parts:

```bash
### MACHINE: stage-01 (10.0.20.160) ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && python3 docs/facility-setups/facility-design.py set 01-facility-a SITE_HA=M1 --note "why"
  # or one question at a time:  ... ask 01-facility-a --open      a new scenario:  ... new 02-facility-b "Facility B"
fi
```

**Or use the web form** — the same engine, every question as choices, the checks redrawn on every
click (a what-if until you press Save), and Save writes the `.env` and rebuilds exactly as `set`
does. It listens on `stage-01`'s `127.0.0.1` only, and prints a URL carrying a one-time key; every
change must present that key, so no other web page in the browser can post answers to it:

```bash
### MACHINE: stage-01 (10.0.20.160) - Ctrl-C stops it ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && python3 docs/facility-setups/facility-design.py serve
fi
```

From Windows: in the VS Code terminal, ctrl-click the printed link — VS Code forwards the port by
itself (PORTS tab). From SecureCRT: add a tunnel on the `stage-01` session, local 8765 →
`127.0.0.1:8765`, then open the printed link. `--port` picks another port if 8765 is taken.

**The generated parts are checked on push.** `.githooks/pre-push` runs `facility-design.py --check`
against the commit being pushed and refuses one whose `.md` block or `.drawio` does not match its
`.env` — the same guard as `docs/diagrams/`. Python 3, standard library only; it runs wherever the
repo is, and `stage-01` owns the repo.

**What changes** when a design is built — parameters (`host-params.env`, `vm-specs.env`,
`enclave-addresses.env`, `facility-profile.env`), documents, hardware — is in each design's *What it
adds to this repo* table. A change that cannot be a parameter is a finding.

**`origin` is public.** No real facility name, address, building, room, POC or sponsor goes in
this folder — not in the `.env` either. Those are layer 3 and live only in
[`facility-profile.env`](../compliance/baseline/facility-profile.env), or `HANDOFF.md` §3 for
the client. Describe a facility by its characteristics, never its identity.
