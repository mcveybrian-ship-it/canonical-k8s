# Air-Gap Update Lab — Ubuntu Pro Mirror Runbook

McVey Consulting lab runbook. Four-machine lab proving the production design: one
online staging box builds an Ubuntu Pro update mirror, the mirror crosses the air
gap on removable media, and fully disconnected Ubuntu 24.04 servers patch from
it — including ESM content served through a local contracts server.

Lab spec: Ubuntu 24.04 LTS ("noble") · fully disconnected air gap · apt-mirror + nginx · Aug 2026.

---

## 1. Licensing model for this lab

**Confirmed approach:** ONE paid full Ubuntu Pro (Server) subscription + free
personal-tier tokens for the rest.

- The **paid full Pro** sub (on the staging box) unlocks: the air-gapped tooling
  entitlement, Canonical Support-Portal Knowledge Base access (where the official
  step-by-step guide lives), and the `esm-apps` + `esm-infra` repo content.
- The other lab machines ride on the **free personal tier** (up to 5 machines,
  register at https://ubuntu.com/pro/dashboard).
- Refinement: inside the gap, clients never contact Canonical. They attach against
  the **local contracts server** on the mirror box, which serves entitlements
  derived from the paid token. The free tokens are good-faith coverage for the
  extra lab machines, not something the air-gapped machinery consumes.

> **PRODUCTION IS DIFFERENT.** Canonical's Ubuntu Pro service description licenses
> per machine and requires covering every Ubuntu system in the environment
> (see §7, https://canonical.com/legal/ubuntu-pro-description). One paid sub
> feeding unlicensed production servers through a mirror violates those terms.
> This layout is for lab/evaluation only. Quote paid Pro per server for
> production; ask Canonical sales about lab/dev pricing.

## 2. Machines

| Machine   | Where                  | Role                                            | Subscription     |
|-----------|------------------------|-------------------------------------------------|------------------|
| STAGE-01  | Online, outside gap    | Builds & syncs the mirror; holds the Pro token  | PAID full Pro    |
| MIRROR-01 | Inside the gap         | nginx repo mirror (:80) + contracts server (:8484) | Free tier     |
| CLIENT-01 | Inside the gap         | Test server, patches from MIRROR-01             | Free tier        |
| CLIENT-02 | Inside the gap         | Test server, patches from MIRROR-01             | Free tier        |

STAGE-01 can be any laptop/VM: internet access, ~250 GB disk, Ubuntu 24.04.

## 3. Architecture

```
  ONLINE STAGING ZONE          ║ AIR GAP ║        AIR-GAPPED LAB NETWORK
                               ║         ║
  Canonical                    ║         ║        ┌────────────────────┐
  archive.ubuntu.com           ║         ║   ┌───▶│ CLIENT-01          │
  esm.ubuntu.com               ║         ║   │    │ pro attach → :8484 │
      │ https sync             ║         ║   │    └────────────────────┘
      ▼                        ║         ║   │
  ┌──────────────────┐  USB /  ║         ║  ┌┴───────────────────────┐
  │ STAGE-01         │  rsync  ║         ║  │ MIRROR-01              │
  │ apt-mirror       │═════════╬═════════╬═▶│ nginx :80 (repo)       │
  │ paid Pro token   │         ║         ║  │ contracts-airgapped    │
  └──────────────────┘         ║         ║  │ :8484                  │
                               ║         ║  └┬───────────────────────┘
                               ║         ║   │    ┌────────────────────┐
                               ║         ║   └───▶│ CLIENT-02          │
                               ║         ║        │ apt → mirror :80   │
                               ║         ║        └────────────────────┘
```

## 4. What the mirror carries

Fully disconnected clients need ALL their apt sources served locally — not just
the Pro pockets.

| Repository            | Suites (24.04)                              | Auth        | Why |
|-----------------------|---------------------------------------------|-------------|-----|
| archive.ubuntu.com    | noble, noble-updates, noble-security        | none (free) | Day-to-day OS updates. On a young LTS this is where nearly all patches come from today. |
| esm.ubuntu.com/infra  | noble-infra-security, noble-infra-updates   | Pro token   | 10-year coverage for Main packages. Thin for noble now; the reason the design exists. |
| esm.ubuntu.com/apps   | noble-apps-security, noble-apps-updates     | Pro token   | Security fixes for ~36k Universe packages — the "full Pro" content. |

Sizing: budget ~200–250 GB for amd64-only noble with main + universe, binaries
only. ESM pockets add single-digit GB today. Trim by dropping multiverse,
source packages, and i386.

## 5. Build STAGE-01 (online, one-time)

```bash
# Attach the PAID full Pro token
sudo pro attach <PAID_PRO_TOKEN>

# Air-gap tooling lives in Canonical's ua-airgapped PPA
sudo add-apt-repository ppa:yellow/ua-airgapped
sudo apt update
sudo apt install contracts-airgapped get-resource-tokens apt-mirror

# Pull per-service resource tokens for the paid contract
get-resource-tokens <PAID_PRO_TOKEN>   # note the esm-infra / esm-apps tokens
```

## 6. Mirror the repos

`/etc/apt/mirror.list` (amd64 only, binaries only):

```
set base_path    /srv/apt-mirror
set nthreads     20
set _tilde 0

# Standard archive — free, no auth
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble main universe
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble-updates main universe
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble-security main universe

# ESM — bearer auth with resource tokens from step 5
deb [arch=amd64] https://bearer:<INFRA_TOKEN>@esm.ubuntu.com/infra/ubuntu noble-infra-security main
deb [arch=amd64] https://bearer:<INFRA_TOKEN>@esm.ubuntu.com/infra/ubuntu noble-infra-updates main
deb [arch=amd64] https://bearer:<APPS_TOKEN>@esm.ubuntu.com/apps/ubuntu noble-apps-security main
deb [arch=amd64] https://bearer:<APPS_TOKEN>@esm.ubuntu.com/apps/ubuntu noble-apps-updates main

clean http://archive.ubuntu.com/ubuntu
```

```bash
sudo -u apt-mirror apt-mirror        # first run: the big one (hours)

# Grab the ESM signing keys to carry across
cp /usr/share/keyrings/ubuntu-pro-esm-infra.gpg  /srv/apt-mirror/keys/
cp /usr/share/keyrings/ubuntu-pro-esm-apps.gpg   /srv/apt-mirror/keys/

# Generate the airgapped contracts-server config (maps token -> entitlements),
# then edit its aptURL entries to point at MIRROR-01
pro-airgapped < tokens.yaml > airgapped-contracts.yaml
```

## 7. Carry it across

1. `rsync -a /srv/apt-mirror/ /media/usb/apt-mirror/` — first trip needs a disk
   sized to the mirror (500 GB USB SSD is comfortable); later trips carry only
   the delta because rsync compares against what's already on the drive.
2. Carry on the same drive: `airgapped-contracts.yaml`, both ESM keyrings, and
   the ua-airgapped PPA .debs (download once with `apt download contracts-airgapped`).
3. On MIRROR-01: `rsync -a /media/usb/apt-mirror/ /srv/repo/`

## 8. Serve inside the gap (MIRROR-01)

```bash
# nginx serving the mirror tree on :80
sudo apt install nginx     # from the carried mirror, or the 24.04 install ISO
# root /srv/repo/mirror/archive.ubuntu.com;  autoindex on;  (plus esm paths)

# Local contracts server on :8484
sudo dpkg -i contracts-airgapped_*.deb
contracts-airgapped --config airgapped-contracts.yaml   # aptURLs -> http://MIRROR-01
```

## 9. Attach the clients

```bash
# /etc/apt/sources.list.d/ubuntu.sources -> point at http://MIRROR-01/ubuntu

# /etc/ubuntu-advantage/uaclient.conf
#   contract_url: http://<MIRROR-01_IP>:8484

sudo pro refresh
sudo pro attach <PAID_PRO_TOKEN>     # validated by YOUR server, not Canonical
pro status                           # esm-infra / esm-apps: enabled
sudo apt update && sudo apt upgrade  # everything resolves to MIRROR-01
```

## 10. Recurring update cycle

1. **Sync** — on STAGE-01, run `apt-mirror` (cron weekly, or to patch cadence).
2. **Export** — rsync the delta to the USB drive (minutes after first trip).
3. **Import** — rsync from the drive into `/srv/repo` on MIRROR-01.
4. **Patch** — clients pick up changes on next `apt update` / unattended-upgrades.
   No client config ever changes again.

## 11. Verification checklist

- [ ] `pro status` on both clients shows esm-infra AND esm-apps enabled with
      zero internet routes on the machine.
- [ ] `apt-get update -o Debug::Acquire::http=true 2>&1 | grep -v <MIRROR-01_IP>`
      shows no requests leaving the lab network.
- [ ] Install a package from an ESM pocket; `apt-cache policy` shows it sourced
      from MIRROR-01.
- [ ] Pull the USB drive and run a full patch cycle anyway — clients still update
      from the last import (the gap is real).
- [ ] Time one full sync→carry→patch cycle end-to-end; that number is the
      production maintenance-window estimate.

## 12. Watch-outs

- **Tokens in plain text:** bearer tokens sit in `mirror.list` — encrypt
  STAGE-01's disk, chmod 600 the file.
- **Contract expiry:** entitlements in `airgapped-contracts.yaml` carry the
  contract's validity; regenerate after renewal and carry across with next sync.
- **Exact flags may drift:** the ua-airgapped tooling is actively developed.
  Authoritative steps: Support-Portal KB article "Get Started With Ubuntu Pro in
  an Airgapped Environment" (unlocked by the paid sub). Verify syntax before
  build day.
- **Snaps and Livepatch are separate tracks:** deb mirroring covers apt only.
  Offline snaps = Snap Store Proxy (offline mode); kernel patching = Livepatch
  on-prem. Bolt on later; don't block the lab on them.
- **Production:** paid Pro per machine; consider self-hosted Landscape (included
  with Pro) if the fleet outgrows hand-run rsync cycles. Landscape caveat for
  fully disconnected: no diff generation — each transfer is the full repository.

## Sources

- Pro Client airgapped docs: https://documentation.ubuntu.com/pro-client/en/v30/explanations/using_pro_offline/
- Ubuntu Pro airgapped setup: https://ubuntu.com/pro/docs/airgapped-setup/
- pro-airgapped-server charm how-to: https://discourse.charmhub.io/t/pro-airgapped-server-how-to/15278
- Landscape air-gapped repo management: https://discourse.ubuntu.com/t/how-to-manage-repositories-in-an-air-gapped-or-offline-environment/57320
- Ubuntu Pro service description: https://canonical.com/legal/ubuntu-pro-description
- Ubuntu Pro pricing: https://ubuntu.com/pricing/pro
