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
| **esm.ubuntu.com/fips-updates** | **noble-updates** (component `main`) | Pro token | **FIPS crypto packages. Added 2026-08-30 — it was missing, and without it the enclave cannot enable FIPS at all.** |
| **esm.ubuntu.com/usg** | **noble** (component `main`) | Pro token | **USG — the DISA-STIG / CIS tooling. Added 2026-08-31.** Its own archive, `Origin: UbuntuCIS`, key `ubuntu-pro-cis.gpg`. Not part of ESM |

> **`usg` is an alias of the `cis` entitlement, and that is why it is easy to miss.** In the
> Pro client it is `CISEntitlement` — `name = "cis"`, `origin = "UbuntuCIS"`,
> `repo_key_file = "ubuntu-pro-cis.gpg"` — surfaced under the name `usg`. It is **not** in
> `archive.ubuntu.com noble/main` and **not** in either ESM pocket, so mirroring ESM does not
> get it. Verified 2026-08-31: `https://esm.ubuntu.com/usg/ubuntu/dists/noble/Release` → 200,
> `Origin: UbuntuCIS`, `Components: main`, suite plain **`noble`** (no `-updates` pocket).
> `esm.ubuntu.com/cis/ubuntu` serves byte-identical metadata — same archive under the old name.
> Without this stanza there is no `usg fix stig-v1r1` inside the boundary, and no `apt install`
> to recover with.

> **The FIPS archive is a separate host path, not a pocket of esm-infra.** It was absent from
> this table and from §6's `mirror.list` until 2026-08-30. Verified that day against the live
> archive:
>
> ```
> https://esm.ubuntu.com/fips-updates/ubuntu/dists/noble-updates/Release  -> 200
>   Origin: UbuntuFIPSUpdates   Suite: noble-updates   Components: main
>   Architectures: amd64 arm64 s390x   Date: Thu, 27 Aug 2026 14:22:06 UTC
>
> https://esm.ubuntu.com/fips/ubuntu/dists/noble/Release                  -> 404
> https://esm.ubuntu.com/fips/ubuntu/dists/noble-updates/Release          -> 404
> ```
>
> The 404s on the plain `fips` archive independently corroborate the pathfinder finding that
> on 24.04 only the `fips-updates` stream exists — `fips` and `fips-preview` report `n/a`.
> **Note the suite is `noble-updates`, not `noble-fips-updates`** — it does not follow the
> naming pattern the infra and apps pockets use.
>
> **RESOLVED 2026-08-31.** The `usg` archive holds exactly three packages, and the package is
> named **`usg`** — *not* `ubuntu-security-guide`, which is the 20.04-era name. That is why
> `apt-cache madison ubuntu-security-guide` kept returning nothing and the search looked like
> a missing repository:
>
> ```
> usg_24.04.8_all.deb              45,286 bytes
> usg-benchmarks_24.04.8_all.deb    2,516,800 bytes
> usg-benchmarks-1_24.04.5_all.deb    816,842 bytes
> ```

Sizing: budget ~200–250 GB for amd64-only noble with main + universe, binaries
only. Trim by dropping multiverse, source packages, and i386.

**Measured on the real first run, 2026-08-31 — the estimates above were close, the ESM one
was not:**

| Half | Estimated | **Actual** | Files | Wall clock |
|---|---|---|---|---|
| archive.ubuntu.com | 200–250 GB | **247 GB** | 85,779 | 2 h 53 m @ ~24 MB/s |
| ESM + FIPS + USG | "single-digit GB" | **69.9 GiB** | 4,902 | ~1 h |
| **Total** | | **~317 GB** | **90,681** | |

**The "single-digit GB" figure was wrong by an order of magnitude.** It described `esm-infra`
alone on a young LTS. The full set — `esm-apps` covering ~36k Universe packages, plus
`fips-updates` and the `usg`/`cis` archive — is 69.9 GiB. Anyone sizing removable media or a
`svc-01` volume off the old number would come up ~60 GB short. **Size the transfer media for
~320 GB, not 250 GB.**

## 5. Build STAGE-01 (online, one-time)

**Executed end to end 2026-08-30/31. Everything below was run, not drafted.** Wall clock was
about four hours, nearly all of it the archive download.

```bash
# 1. Attach the PAID Pro subscription. Infra tier or above - self-support ($500) has no
#    Knowledge Base, and the air-gapped procedure exists only as a KB article.
sudo pro attach <PAID_PRO_TOKEN>

# 2. Air-gap tooling. All three packages are Maintainer "Canonical Ltd. <support@canonical.com>"
#    at 1.8.1, verified against the PPA's own Packages index.
sudo add-apt-repository -y ppa:yellow/ua-airgapped
sudo apt update
sudo apt install -y contracts-airgapped get-resource-tokens pro-airgapped apt-mirror

# 3. Per-service resource tokens.  ***THE OUTPUT IS SECRET.***
get-resource-tokens <PAID_PRO_TOKEN>
```

### 5.1 Reading the `get-resource-tokens` output — three naming traps

It prints one block per **contract resource type**, and those names are not the names you
expect. On this contract it lists twelve: `cc-eal`, `esm-apps`, `esm-infra`, `fips`,
`fips-preview`, `fips-updates`, `landscape`, `livepatch`, `realtime-kernel`, `ros`,
`ros-updates`, `usg`.

| You want the token for | Take the block printed under | Trap |
|---|---|---|
| `esm.ubuntu.com/infra` | **`esm-infra`** | There is no block called "infra" |
| `esm.ubuntu.com/apps` | **`esm-apps`** | |
| `esm.ubuntu.com/fips-updates` | **`fips-updates`** | **Not `fips`, not `fips-preview`** — both exist on the contract and neither is available on 24.04 |
| `esm.ubuntu.com/usg` | **`cis`** | `usg` is an alias of the `cis` entitlement. The token may not appear under `usg` at all |

### 5.2 Do NOT enable `fips-updates` or `usg` on STAGE-01

Both are entitled; both stay disabled here. STAGE-01 is the staging box, not an enclave host.
Enabling `fips-updates` moves it onto the FIPS kernel (`7.0.0-30-generic` HWE →
`6.8.0-138-fips` on the pathfinder) and imposes FIPS-mode SSH restrictions — including the
Ed25519 ban — on the machine holding the git deploy key.

**The packages still reach the enclave.** They are *mirrored*, not installed. Mirroring needs
only the bearer token in `mirror.list`; it never requires enabling the service locally.

## 6. Mirror the repos

**This step splits in two, and the halves are not gated the same way.** Section 5 above reads
as a prerequisite for all of section 6; it is not. Only the ESM half needs the paid token.

| Half | Needs Q9 / the paid token? | Size | Time |
|---|---|---|---|
| **archive.ubuntu.com** — noble, -updates, -security | **No.** Anonymous, free | **247 GB measured** | **2 h 53 m @ ~24 MB/s** |
| **esm.ubuntu.com** — infra + apps + fips-updates + usg | Yes — bearer auth with resource tokens from §5 | **69.9 GiB measured** | **~1 h** |

So run the archive half now and let it grind; ESM is a short delta appended later. Re-running
`apt-mirror` after adding the ESM lines does **not** re-fetch the archive content already on
disk.

**Check what is actually in `/etc/apt/mirror.list` before running.** The `apt-mirror` package
ships a default (`0.5.4-2`, unchanged since 2022) pointing at suite **`kinetic` (22.10)** with
`deb-src`, `restricted` and `multiverse` all enabled. Running that unedited mirrors the wrong
release at several times the size. On STAGE-01 that stock file sat in place until 2026-08-30 —
it is preserved at `/etc/apt/mirror.list.stock-2022`.

`/etc/apt/mirror.list` (amd64 only, binaries only):

```
set base_path    /srv/apt-mirror
set nthreads     20
set _tilde 0

# Standard archive — free, no auth. Runs without the Pro token.
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble main universe
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble-updates main universe
deb [arch=amd64] http://archive.ubuntu.com/ubuntu noble-security main universe

# ESM — bearer auth with resource tokens from step 5.
deb [arch=amd64] https://bearer:<INFRA_TOKEN>@esm.ubuntu.com/infra/ubuntu noble-infra-security main
deb [arch=amd64] https://bearer:<INFRA_TOKEN>@esm.ubuntu.com/infra/ubuntu noble-infra-updates main
deb [arch=amd64] https://bearer:<APPS_TOKEN>@esm.ubuntu.com/apps/ubuntu noble-apps-security main
deb [arch=amd64] https://bearer:<APPS_TOKEN>@esm.ubuntu.com/apps/ubuntu noble-apps-updates main

# FIPS — separate archive path, suite is noble-updates (NOT noble-fips-updates).
# Without this the enclave cannot enable FIPS. See the box in section 4.
deb [arch=amd64] https://bearer:<FIPS_TOKEN>@esm.ubuntu.com/fips-updates/ubuntu noble-updates main

# USG (DISA-STIG / CIS tooling) — its own archive, suite is plain "noble".
# Not part of ESM. Without this there is no `usg fix stig-v1r1` inside the gap.
deb [arch=amd64] https://bearer:<USG_TOKEN>@esm.ubuntu.com/usg/ubuntu noble main

clean http://archive.ubuntu.com/ubuntu
```

### What else has to cross that `apt-mirror` will never fetch

A repo mirror is not the whole bundle. These are carried as files, and each one has bitten
somebody:

| Item | Why the mirror misses it |
|---|---|
| **`contracts-airgapped` and `pro-airgapped` `.deb`s** | They must be **installed on MIRROR-01, inside the gap**, but they live in `ppa:yellow/ua-airgapped` — which is not in `mirror.list` and cannot be, since MIRROR-01 has no route to Launchpad. **Pull them with `apt download` on STAGE-01 and carry them.** Bootstrap trap: the contracts server cannot be installed from the mirror it exists to authenticate |
| **Four signing keys** | `ubuntu-pro-esm-infra.gpg`, `ubuntu-pro-esm-apps.gpg`, `ubuntu-pro-fips.gpg`, **`ubuntu-pro-cis.gpg`** (for `usg`). `fips-updates` uses the plain `ubuntu-pro-fips.gpg` — there is no `-updates` key |
| Snaps + base snaps, container images, Harbor installer, MAAS boot images | Not apt at all — Stage B. Tracked separately under Q6/Q8 |

**Components and pockets, decided deliberately:** `main` + `universe` only, no `restricted`,
no `multiverse`, no `noble-backports`, amd64 only. Note the mirrored `Release` file still
advertises all four components and seven architectures because it is Canonical's file copied
verbatim — pointing a client at `restricted` will resolve the index and then 404 on the
packages. Set the client `sources` to match what is actually held.

> **`mirror.list` holds bearer tokens in cleartext once these lines are filled in.** It is a
> credential file from that point on: `sudo chmod 600 /etc/apt/mirror.list`, keep it out of the
> repo, and never paste it into a document, a ticket or a chat. The repo's copy of this block
> keeps the `<PLACEHOLDER>` form for that reason.

`[arch=amd64]` is honoured by `apt-mirror` 0.5.4-2 — verified in `/usr/bin/apt-mirror` line 300,
which parses the `options` field. Without it the mirror falls back to `defaultarch`.

`base_path` is `/srv/apt-mirror`, **not** the package default `/var/spool/apt-mirror`. Create it
owned by the `apt-mirror` user or the run fails on write:

```bash
sudo install -d -o apt-mirror -g apt-mirror -m 0755 /srv/apt-mirror /srv/apt-mirror/keys
```

### 6.1 File permissions — this silently kills the run

Once tokens are in it, `mirror.list` is a credential file. But **`apt-mirror` runs as the
`apt-mirror` user**, so a root-only file is unreadable to it and the run dies instantly:

```
apt-mirror: can't open config file (/etc/apt/mirror.list) at /usr/bin/apt-mirror line 318.
```

`nohup ... &` swallows that into the log, so it looks like the job started. **Use `640
root:apt-mirror`** — private from every other user, readable by the service:

```bash
sudo chown root:apt-mirror /etc/apt/mirror.list
sudo chmod 640 /etc/apt/mirror.list
```

`chmod 600` is wrong here, and cost a cycle on 2026-08-31.

### 6.2 Substituting the tokens without leaking them

Keeps the values off the terminal and out of `~/.bash_history`. Write the file with
`INFRA_TOKEN_HERE` / `APPS_TOKEN_HERE` / `FIPS_TOKEN_HERE` / `USG_TOKEN_HERE` placeholders
first, then:

```bash
read -rsp 'esm-infra token   : ' T_INFRA; echo
read -rsp 'esm-apps token    : ' T_APPS;  echo
read -rsp 'fips-updates token: ' T_FIPS;  echo
read -rsp 'cis (=usg) token  : ' T_USG;   echo
sudo sed -i "s|INFRA_TOKEN_HERE|$T_INFRA|g; s|APPS_TOKEN_HERE|$T_APPS|g; \
             s|FIPS_TOKEN_HERE|$T_FIPS|g;   s|USG_TOKEN_HERE|$T_USG|g" /etc/apt/mirror.list
unset T_INFRA T_APPS T_FIPS T_USG
sudo grep -c 'TOKEN_HERE' /etc/apt/mirror.list      # MUST print 0
```

### 6.3 Verify the tokens against `pool/`, never against `Release`

**A wrong token returns 200 on `dists/<suite>/Release` and 401 on every package.** Release
metadata is served more permissively than content, so a Release-based check passes while the
archive downloads nothing. This happened on 2026-08-31: `esm-infra` verified green and
mirrored zero packages.

This check pulls the first `Filename:` from each archive's own `Packages` index and fetches
the real file. Every line must print **200**:

```bash
sudo bash -c '
while read -r _ _ url suite _; do
  case "$url" in *bearer:*) tok="${url#*bearer:}"; tok="${tok%%@*}"; host="${url#*@}";; *) continue;; esac
  pkgs=$(find /srv/apt-mirror/mirror/${host%%/*}/${host#*/} -path "*${suite}*" -name Packages 2>/dev/null | head -1)
  fn=$(grep -m1 "^Filename:" "$pkgs" 2>/dev/null | awk "{print \$2}")
  [ -z "$fn" ] && { printf "  ----  %-38s %s  (index empty)\n" "$host" "$suite"; continue; }
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 -u "bearer:$tok" "https://$host/$fn")
  printf "  %s   %-38s %s\n" "$code" "$host" "$suite"
done < <(grep "^deb .*bearer" /etc/apt/mirror.list)'
```

**And when reading wget logs, grep `Authentication Failed`, not `401`.** Success and failure
open identically — wget probes unauthenticated, is challenged, then retries:

```
apps :  401 -> Authentication selected: Basic realm="APT mirror" -> 200 OK            OK
infra:  401 -> Authentication selected: Basic realm="APT mirror" -> 401 Unauthorized
        Username/Password Authentication Failed.                                      FAILED
```

```bash
grep -l 'Authentication Failed' /srv/apt-mirror/var/archive-log.*   # must be empty
```

### 6.4 What a completed mirror looks like — measured 2026-08-31

Compare against this before carrying anything across. A count that is short by an archive is
the failure mode this table exists to catch.

| Archive | Size | Packages |
|---|---|---|
| `archive.ubuntu.com` | 247 G | 85,779 |
| `esm/fips-updates` | 68 G | 3,836 (incl. **353 FIPS kernel images**) |
| `esm/apps` | 2.4 G | 1,059 |
| `esm/usg` | 3.3 M | 3 |
| `esm/infra` | 408 K | **4** — see below |
| **TOTAL** | **317 G** | **90,681** |

**`esm-infra` holding only 4 packages is correct, not a failure.** On a young LTS, standard
security support is still active, so ESM Infra has barely started. Today it carries `hello`,
`iperf3`, `libiperf-dev` and `libiperf0`. It is the 10-year coverage that justifies the
architecture — it just has nothing to carry yet. **Do not treat a near-empty `infra` tree as a
broken token**; distinguish the two with §6.3.

**FIPS packaging on 24.04 — there is no FIPS `openssl` or `libssl3` package, and that is
correct.** 24.04 uses the OpenSSL 3 provider-module model, so the FIPS crypto ships as
`openssl-fips-module-3`. The dependency chain:

```
ubuntu-fips -> gawk, update-notifier-common, grub2-common,
               linux-fips (>= 6.8.0-38.38+fips4), fips-initramfs,
               ubuntu-fips-userspace
ubuntu-fips-userspace -> openssl-fips-module-3 (= 3.0.13-0ubuntu3.15+Fips1),
                         libgcrypt20 (= 1.12.0-2ubuntu0.1~Fips1~rc11),
                         libgnutls30 (= 3.8.3-1.1ubuntu3.6+Fips1.2),
                         libnettle8, libhogweed6, libgmp10
```

Searching the mirror for `openssl_*+Fips*.deb` finds nothing and looks alarming. Search for
`openssl-fips-module-3` instead.

```bash
sudo -u apt-mirror apt-mirror        # first run: the big one (hours)

# Grab the ESM signing keys to carry across
cp /usr/share/keyrings/ubuntu-pro-esm-infra.gpg  /srv/apt-mirror/keys/
cp /usr/share/keyrings/ubuntu-pro-esm-apps.gpg   /srv/apt-mirror/keys/

# Generate the airgapped contracts-server config (maps token -> entitlements),
# then edit its aptURL entries to point at MIRROR-01
pro-airgapped < tokens.yaml > airgapped-contracts.yaml
```

### 6.5 Serve it and prove it — done on STAGE-01 2026-08-31

**Prove the mirror before media crosses.** Until a client resolves a package through nginx,
all that is known is that files are on disk — not that the tree is served in a layout `apt`
can consume. A layout error found inside the gap costs a media round trip.

The vhost roots the mirror tree itself, so served paths mirror the upstream hostnames and the
client `sources` written for MIRROR-01 are near-identical to the real ones. Keys and the
carried `.deb`s sit outside that tree and get explicit aliases. Full config lives in
`/etc/nginx/sites-available/apt-mirror`; the shape is:

```nginx
server {
    listen 80 default_server;
    root /srv/apt-mirror/mirror;
    autoindex on;

    # ^~ IS REQUIRED ON BOTH. See the trap below.
    location ^~ /keys/ { alias /srv/apt-mirror/keys/; autoindex on; }
    location ^~ /debs/ { alias /srv/apt-mirror/debs/; autoindex on;
                         default_type application/vnd.debian.binary-package; }

    location ~* \.(deb|udeb|ddeb|tar\.(gz|xz|zst))$ {
        default_type application/vnd.debian.binary-package;
    }
    location / { try_files $uri $uri/ =404; }
}
```

Remove `sites-enabled/default` — it is also `default_server` on :80 and nginx will not start
with two.

> **nginx trap: regex locations are matched BEFORE prefix locations.** Written as
> `location /debs/`, the `\.deb$` regex block captures `/debs/*.deb` and resolves it against
> the *server root* instead of the alias. The symptom is precise and misleading: `/debs/`
> returns **200** (the directory index matches the prefix location) while every `.deb` inside
> it returns **404**. `^~` tells nginx not to consider regex locations for that prefix.
> This silently hid exactly the three packages MIRROR-01 cannot obtain any other way.

**No auth on this vhost, and that is correct.** Inside the gap, entitlement is enforced by the
contracts server on `:8484`, not by the repo. The bearer tokens never leave STAGE-01's
`mirror.list`.

#### The proof — run it, do not assume it

Metadata resolving is not proof; that is the same trap as §6.3. Verify at three levels:

1. **`Release` for all nine suites** → 200.
2. **A real `pool/` file from each of the five archives**, taken from that archive's own
   `Packages` index → 200 with a non-zero size.
3. **A genuine `apt` resolution with GPG verification on.** Point apt at `localhost` using
   overridden `Dir::` paths so STAGE-01's own configuration is never touched:

```bash
T=/tmp/aptproof; rm -rf $T
mkdir -p $T/{lists/partial,cache/archives/partial,etc/preferences.d,etc/apt.conf.d}
# one "deb [arch=amd64 signed-by=<keyring>] http://localhost/<archive> <suite> <components>"
# line per source; keyrings are /usr/share/keyrings/ubuntu-archive-keyring.gpg for the
# archive and /srv/apt-mirror/keys/*.gpg for infra / apps / fips / cis.
O="-o Dir::Etc::sourcelist=$T/etc/sources.list -o Dir::Etc::sourceparts=/dev/null \
   -o Dir::State::lists=$T/lists -o Dir::Cache=$T/cache \
   -o Dir::Etc::preferencesparts=$T/etc/preferences.d -o Dir::Etc::parts=$T/etc/apt.conf.d \
   -o Acquire::Languages=none"
apt-get $O update
apt-cache $O policy usg openssl-fips-module-3        # confirm the source URL per package
cd $T && apt-get $O download accountsservice iperf3 7zip openssl-fips-module-3 usg
dpkg-deb -I $T/usg_*.deb                             # a real, intact package
```

**Result 2026-08-31 — all nine sources fetched, GPG verified, exit 0.** One marker package
pulled from every archive, each resolving to the expected source:

| Package | Version | Resolved from |
|---|---|---|
| `accountsservice` | 23.13.9-2ubuntu6.1 | `archive.ubuntu.com/ubuntu` |
| `iperf3` | 3.16-1ubuntu0.1~esm1 | `esm.ubuntu.com/infra/ubuntu` |
| `7zip` | 23.01+dfsg-11ubuntu0.1~esm1 | `esm.ubuntu.com/apps/ubuntu` |
| `openssl-fips-module-3` | 3.0.13-0ubuntu3.15+Fips1 | `esm.ubuntu.com/fips-updates/ubuntu` |
| `usg` | 24.04.8 | `esm.ubuntu.com/usg/ubuntu` |

That the ESM/FIPS/USG `Release` signatures verify against the four carried keyrings is the
other half of the proof — it confirms `/srv/apt-mirror/keys/` holds the right keys before
they cross.

**One thing the proof does not cover:** the mirrored `Release` files advertise
`main restricted universe multiverse` and seven architectures, because they are Canonical's
files copied verbatim, while only amd64 `main`+`universe` is held. A client asking for
`restricted` resolves the index and then 404s on packages. **Client `sources` must match what
is actually held**, not what `Release` claims.

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
