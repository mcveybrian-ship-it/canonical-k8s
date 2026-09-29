# Step 06a — PostgreSQL HA on pg-01..03, as built

> **BUILT 2026-09-27/28 — slices 1–5 of 6 passed.** Three guests, one per physical host, each
> running PostgreSQL 16 under Patroni with the database's own three-member etcd. pg-01 bootstrapped
> the cluster; the other two cloned from it and stream from it; one is synchronous. The nodes
> authenticate to each other **by certificate only** — there is no shared password anywhere.
> **Slice 4 passed 2026-09-28** (§9): monitored end to end, the data disks re-reserved without an
> outage, a timed planned switchover, a real power-cut failover with the dead leader rejoining by
> `pg_rewind`, and the "no synchronous standby" alert fired and cleared on purpose.
> **Slice 5 passed 2026-09-28** (§10): every WAL file goes to **two** backup stores (host-4 and
> host-3) as it is written, each takes its own nightly backups, and a **point-in-time restore was
> proven from each store independently**. **Not built:** the PostgreSQL STIG scan (6 — needs the
> CAC download).
>
> **The procedure is `scripts/install/06a-postgres-ha.sh`.** This document explains what it and
> the steps before it did, in order, with the evidence. Every fact below was read from the script,
> the commands actually run, or the live nodes on 2026-09-28 — not remembered. The *design* and its
> reasoning are runbook §9a (why three nodes, why its own etcd, the storage split) and §9a.2a
> (the STIG traps); the decisions are `HANDOFF.md` §3 (2026-09-27/28); the live status is
> `docs/backlog.md` row **B-06a**.
>
> Times are UTC. Until 2026-09-28 14:17 the enclave clock ran ~11 s ahead of UTC (backlog 3.39);
> timestamps before that carry the offset.

---

## 1. The picture

### 1.1 Three nodes, one cluster

```
                  ┌───────────────┐       ┌───────────────┐       ┌───────────────┐
  physical host   │    host-1     │       │    host-2     │       │    host-3     │
                  │   .155        │       │   .156        │       │   .157        │
                  │ ┌───────────┐ │       │ ┌───────────┐ │       │ ┌───────────┐ │
  guest VM        │ │  pg-01    │ │       │ │  pg-02    │ │       │ │  pg-03    │ │
                  │ │  .165     │ │       │ │  .166     │ │       │ │  .167     │ │
                  │ │ Patroni   │ │       │ │ Patroni   │ │       │ │ Patroni   │ │
                  │ │ PG 16.15  │ │       │ │ PG 16.15  │ │       │ │ PG 16.15  │ │
                  │ │ etcd 3.4  │ │       │ │ etcd 3.4  │ │       │ │ etcd 3.4  │ │
                  │ └───────────┘ │       │ └───────────┘ │       │ └───────────┘ │
                  └───────────────┘       └───────────────┘       └───────────────┘
  role 17:00 UTC      SYNC STANDBY            replica              LEADER  (timeline 3)
                        ▲                        ▲                       │
                        └── WAL stream, 5432/tcp, TLS, certificate auth ─┘

  etcd:   one member on each node, 2380/tcp between them (raft), 2379/tcp for Patroni
  quorum: 2 of 3 — lose any ONE host and etcd still has a quorum and PostgreSQL still has a
          leader and a synchronous standby. Lose two and it stops accepting writes, by design.
  backup: every WAL file to host-4 AND host-3 as it is written; each store backs up nightly (§10)
```

The roles move. Patroni chooses the leader and which replica is synchronous; after a failover, or
simply over time, they will not be what this picture shows — on 2026-09-28 the synchronous standby
changed from pg-02 to pg-03 without a failover, and in slice 4 the lead went pg-01 → pg-02
(planned) → pg-03 (a power cut). **Ask the cluster, never assume** (§14).

The addresses come from `scripts/enclave/enclave-addresses.env` (`PG_01..03`); the placement, one
per host with anti-affinity, from `scripts/enclave/vm-specs.env` (`PLACE_PG_0N`, `ANTI_AFFINITY`).
host-4 deliberately holds none of them (runbook §9a).

### 1.2 Inside one node

```
 pg-0N  —  Ubuntu 24.04, FIPS kernel 6.8.0-138-fips (fips_enabled=1), hardened by 05 (step 06)
           lab profile: 2 vCPU, 4 GiB RAM, 40 GB OS disk, 150 GB data disk
 ┌──────────────────────────────────────────────────────────────────────────────────────────┐
 │ systemd                                                                                  │
 │  ├─ etcd.service         user etcd       listens <own IP>:2379 (client)  :2380 (peer)    │
 │  │     config /etc/default/etcd          data /var/lib/etcd/enclave-pg                   │
 │  │                                                                                       │
 │  ├─ patroni.service      user postgres   listens <own IP>:8008 (REST API)                │
 │  │     config /etc/patroni/config.yml                                                    │
 │  │     └─ postgres       STARTED BY PATRONI, not by systemd   <own IP>:5432              │
 │  │           data /var/lib/postgresql/16/enclave-pg                                      │
 │  │                                                                                       │
 │  ├─ prometheus-postgres-exporter  user prometheus  <own IP>:9187  (login pgmonitor, peer)│
 │  ├─ prometheus-node-exporter      user prometheus  <own IP>:9100                        │
 │  └─ postgresql.service   disabled — Debian's wrapper; there is no Debian cluster         │
 │                                                                                          │
 │  vda  40 GB   the OS                                                                     │
 │  vdb 150 GB   ext4, LABEL=pgdata, mounted at /var/lib/postgresql  nodev,nosuid,noexec    │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
 Nothing else listens on the network except sshd (22). Both exporters (slice 4) are scraped
 only by svc-obs-01; ufw admits nobody else to 9100 or 9187.
```

### 1.3 Where the disks really are

```
 host-N                                                     pg-0N sees
 ─────────────────────────────────────────────────────────  ──────────────────────────────
 NVMe ─ partition ─ LUKS (crypt) ─ LVM vg-data
          ├─ LV libvirt       → /var/lib/libvirt/images       pg-0N.qcow2     → vda  40 GB
          └─ LV libvirt-data  → /var/lib/libvirt/images-data  pg-0N-data.qcow2 → vdb 150 GB
```

**At-rest encryption is the host's**: both pools sit on LVM over LUKS — `lsblk -s` on host-1,
host-2 and host-3 shows `lvm → crypt → part → disk` under both mounts (read 2026-09-28). That is the
evidence B-06a owed for V-261901/930/931. The guest does not encrypt again.

The data disk is a **separate volume** from the OS disk on purpose (runbook §9a.2), and it is
**reserved** — every block allocated on the host — so that a full volume can fail a backup copy
but never a database write. It was undone once by guest TRIM and **restored in slice 4 (§9.2):
each data disk is 153,623 of 153,623 MiB allocated.** Because the volume is now full by design, it
is watched by what is *on* it rather than by free space (§9.5).

---

## 2. How it was built — the whole sequence

```
 STEP MACHINE          ACTION                                                 RESULT
 ──── ──────────────── ─────────────────────────────────────────────────────  ─────────────────────
  A   stage-01 (lab)   make-credentials.sh --any-dir --machines pg-01,pg-02,   a credentials file and
      build-01 (prod)    pg-03                                                 an audit key per guest
      stage-01         scp each guest's two files → its host; trust file →
                         svc-obs-01
      svc-obs-01       audit-offload.sh collector-trust <file>                 pg keys accepted by IP
  B   host-1/2/3       03-compose-vm.sh pg-0N --harden --cred-dir /root/cred-  VM created and started
                         pg-0N          (all three in parallel)
      pg-0N itself     cloud-init → 05 first-boot → reboot → 05 runs every     DONE pass=211 fail=4
                         step, rebooting itself 3 times — nobody logs in       credentials deleted
  C   host-1/2/3       03-compose-vm.sh pg-0N --finish                         seed + provisioning
                                                                               disks shredded, cold
                                                                               restart, register line
  D   pg-0N            ca.sh request pg-0N                                     key (stays) + CSR
      stage-01         scp -3 the CSR → svc-mgmt-01          (relay only)
      svc-mgmt-01      ca.sh sign-server --peer ~/pg-0N.csr                    certificate, 1 year
      stage-01         scp -3 the certificate → pg-0N        (relay only)
  E   pg-01, 02, 03    06a-postgres-ha.sh etcd ~/pg-0N.fullchain.crt           3-member etcd, mTLS
      pg-01, 02, 03    06a-postgres-ha.sh etcd-check                           healthy from each
  F   pg-01 FIRST      06a-postgres-ha.sh patroni                              bootstraps → Leader
      pg-02, pg-03     06a-postgres-ha.sh patroni                              clone → streaming
  G   pg-01, 02, 03    06a-postgres-ha.sh patroni-check                        traps + a sync commit
  H   pg-01..03        monitoring.sh exporter + facts-timer                    node-exporter :9100
      pg-01 (primary)  06a-postgres-ha.sh monitor, then pg-02, pg-03           postgres-exporter :9187
      svc-obs-01       monitoring.sh scrape, then rules                        24 targets, 53 rules
  I   per node         06a leave (node) → 03-compose-vm.sh --reserve-data      one node at a time,
                         (host) ; 06a switchover before the leader's turn        no outage
  J   host-4           03-host-services.sh cryptdisk                           spare NVMe: LUKS, ext4
  K   host-4, host-3   ca.sh request → sign-server --peer → carry (as D)       store certificates
      pg-01..03,host-3 stig-tailor.sh ufw --apply                              8432 open
  L   pg-01..03        06a backup-node                                         pgBackRest server
      host-4, host-3   06a backup-store <fullchain>                            stores + stanza
      the primary      06a backup-enable                                       archiving → both
      host-4, host-3   06a backup-run full                                     first fulls + timers
  M   the primary      06a backup-restore-test                                 PITR from each store
```

Steps A–C are step 06's mechanism (`docs/06-guest-vms.md`) applied to the three database guests —
**slice 1**. D–E are **slice 2**, F–G **slice 3**, H–I and the failure tests **slice 4** (§9),
J–M **slice 5** (§10). Each is described below with the command as it
was run, what it does, what it writes, what it refuses, and how it was verified.

**Before any of it** (all done and verified before 2026-09-27; runbook §6.5, backlog 3.42/3.43):
host-1..3 hardened and VM-ready (libvirt, `br0`, `images` and `images-data` pools on separate
mounted volumes, the base image in place, `/etc/enclave-profile` saying `VM_PROFILE=lab`); the
PPSM register carrying 2379, 2380, 8008 and 9187 (§12); the enclave issuing CA on svc-mgmt-01; the
mirror on svc-repo-01 carrying every package in §8.3. **`03-compose-vm.sh plan` on each host is
the check** — it refuses a data pool that is not a mounted volume or is too small.

---

## 3. Step A — credentials and audit keys (slice 1)

Every hardened machine needs two things it must not share with any other: a **credentials file**
(the admin and emergency password hashes, and nothing reversible) and an **audit-offload key**
(the SSH key that ships its audit records weekly to svc-obs-01). They are made off the enclave.

**In the lab** they were throwaway credentials made on stage-01 with `--any-dir` (decided
2026-09-27; the 2.6 rebuild uses the real stick):

```bash
### MACHINE: stage-01 ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && . scripts/enclave/enclave-addresses.env
  mkdir -p ~/credtest && ./scripts/transfer/make-credentials.sh -o ~/credtest --any-dir --machines pg-01,pg-02,pg-03 \
    && for m in pg-01:HOST_1 pg-02:HOST_2 pg-03:HOST_3; do v=${m%%:*}; h=${m##*:}
         scp -q -p -i ~/.ssh/build01 ~/credtest/credentials.$v.env ~/credtest/audit-offload.$v.key encadmin@${!h}: \
           && echo "copied $v's two files to $h"; done \
    && scp -q -p -i ~/.ssh/build01 ~/credtest/audit-collector.authorized_keys encadmin@$SVC_OBS_01: \
    && echo "trust file to svc-obs-01"
fi
```

**In production** the same script runs on **build-01** and writes onto the registered credentials
stick only; custody, placement and destruction are `docs/airgap-media.md` §9.

`make-credentials.sh` asks for each password twice without echo, enforces the password policy,
and writes a hash — the password is never stored. It also writes **one RSA 4096 audit key per
machine** (not ed25519: FIPS refuses it) and `audit-collector.authorized_keys`, one line per
machine, each pinned to that machine's address and forced into a write-only drop:

```
from="10.2.20.165",restrict,command="/usr/bin/rrsync -wo /srv/audit-offload" ssh-rsa AAAA... pg-01
```

The collector takes that file and merges it **by address** — a line for an address it already
has is replaced, not duplicated — and accepts only lines of exactly that form:

```bash
### MACHINE: svc-obs-01 (10.2.20.164) ###
if [ "$(hostname -s)" != svc-obs-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/enclave/audit-offload.sh collector-trust ~/audit-collector.authorized_keys \
    && rm -f ~/audit-collector.authorized_keys
fi
```

Result 2026-09-27: `2 added, 1 replaced` — pg-02 and pg-03 new, pg-01's key from the morning's
test run swapped for the new one by its address.

---

## 4. Step B — compose each guest, and it hardens itself (slice 1)

On each host, the guest's two files are moved root-only, the guest is composed with `--harden`,
and the host's copies are shredded once the provisioning disk holds them:

```bash
### MACHINE: host-1 (10.2.20.155) ###   — same on host-2 with pg-02, host-3 with pg-03
if [ "$(hostname -s)" != host-1 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  vm=pg-01
  for f in credentials.$vm.env audit-offload.$vm.key; do
    if [ -e ~/"$f" ]; then sudo install -D -o root -g root -m 600 ~/"$f" /root/cred-$vm/"$f" && shred -u ~/"$f" && echo "placed root-only: $f"; fi
  done
  cd ~/canonical-k8s/scripts/install \
    && sudo ./03-compose-vm.sh $vm --harden --cred-dir /root/cred-$vm \
    && sudo shred -u /root/cred-$vm/credentials.$vm.env /root/cred-$vm/audit-offload.$vm.key && echo "placed copies shredded"
fi
```

**What `03-compose-vm.sh pg-0N --harden` does**, in order:

1. Checks the host: this is the host `PLACE_PG_0N` names; both pools are reachable by qemu; the
   data pool is a **mounted volume**, not a directory on the OS drive; it fits.
2. Asks the guest admin password **before** creating anything (3 tries; backlog 3.38).
3. Creates the OS disk from the base image (`images` pool) and the **data disk**
   `images-data/pg-0N-data.qcow2`, 150 GB, `preallocation=falloc` (reserved — §15 item 6).
4. Writes the cloud-init seed: hostname, admin account (hash and keys), the mirror as the only apt
   source, `/etc/hosts`, the enclave resolver, the enclave CA as trusted.
5. Builds the **provisioning disk** `ENCLAVE-PROV` — a read-only ISO (`genisoimage -R`) staged on
   `/run` (tmpfs, shredded on any exit) carrying: the repository (exactly the files in
   `.pushed-files`), the guest's credentials file, the host's Pro token, the Evaluate-STIG answer
   file, its audit key, and the operator's name.
6. Defines and starts the VM: the OS disk, the data disk (`cache=none,io=native`, now
   `discard=ignore`), the seed and provisioning disks read-only, the serial console logged to
   `<pool>/console/pg-0N-console.log`, the enclave bridge.

**What the guest then does, by itself** (`docs/06-guest-vms.md` §4):

```
 first boot   cloud-init → 05-harden-host.sh first-boot: copies the build to /opt/enclave-build
              (root-owned), installs the credentials, Pro token, answer file and audit key,
              enables enclave-harden.service → cloud-init reboots ONCE
 then         enclave-harden.service runs 05 through every step, resuming itself after each
              reboot, printing one progress line per step to the serial console:

   preflight · hostprep · pro · fips (REBOOT) · patch · usg · baseline · prechecks ·
   usgfix (REBOOT) · tailor · radio · grub · accounts · v1r6 (REBOOT) · verify ·
   auditvolume · auditoffload · final_audit · evalstig · DONE

 DONE         shreds the credentials file and the Pro token, disables the unit
 on failure   halts, disables the unit, says why on the console (decision D7)
```

Each line ends with ` @<UTC time>`, so a run can be told from an earlier one in the same log. The
log is watched from the host (read as root — `virtlogd` rotates it at 2 MB into a 0600 file):

```bash
### MACHINE: host-1 (10.2.20.155) ###
sudo sh -c 'cat $(ls -1r /var/lib/libvirt/images/console/pg-01-console.log*)' | grep 'ENCLAVE-HARDEN' | tail -5
```

**Result 2026-09-27**, all three composed in parallel: `DONE pass=211 fail=4` at 21:04, 21:05 and
21:09; Evaluate-STIG **NF 172 / Open 4 / NR 9 / NA 9** on each; `auditoffload OK` on each (the first
audit bundles reached svc-obs-01 20:57–21:01). The counts are identical on all three and to
pg-01's earlier slice runs; the Open items include the three CAC controls (backlog Q25). Nothing in
them is specific to the database — the PostgreSQL STIG is a separate scan (slice 6).

---

## 5. Step C — finish (slice 1)

```bash
### MACHINE: host-1 (10.2.20.155) ###   — same on host-2 / host-3
if [ "$(hostname -s)" != host-1 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s/scripts/install && sudo ./03-compose-vm.sh pg-01 --finish
fi
```

`--finish` refuses unless the guest's console shows `DONE` for **this** run. Then it checks the
guest **from outside**: SSH answers with a host key (any type — FIPS offers ECDSA and RSA, never
ed25519), a port that should be closed is dropped, and DNS resolves the name. It knocks at most
once per 12 s, because a hardened guest's SSH rule is `ufw limit` (6 per 30 s, and every attempt
renews the ban). Then it **shreds the seed and the provisioning disk** (the seed carried the admin
hash and keys), **cold-restarts** the guest to prove it boots without them — the data disk moves
`vdc → vdb` when the seed goes, which is why everything mounts it by label — and writes the
custody record `/var/lib/enclave/finish/pg-0N.register`.

Verified on the hosts 2026-09-27: seeds and provisioning disks gone, each guest on its OS disk and
its data disk only, SSH answering.

---

## 6. Step D — each node's certificate (slice 2)

One key and one certificate per node carry every TLS role the node has (§11). The key is made **on
the node** and never leaves it; only the CSR (public) and the certificate (public) travel.

```
 pg-0N                                stage-01 (relay only)       svc-mgmt-01 (issuing CA)
 ─────────────────────────────────    ─────────────────────       ─────────────────────────────
 ca.sh request pg-0N
   /etc/ssl/enclave/pg-0N.key   0640 root   ← NEVER LEAVES
   /etc/ssl/enclave/pg-0N.csr   0444 ────── scp -3 ──────────────► ~/pg-0N.csr
                                                                    ca.sh sign-server --peer
                                                                    → /etc/enclave-ca/certs/
                                                                        pg-0N.fullchain.crt
   ~/pg-0N.fullchain.crt ◄──────────────── scp -3 ────────────────── ~/pg-0N.fullchain.crt
```

```bash
### MACHINE: pg-01 (10.2.20.165) ###   — same on pg-02 / pg-03 with their own name
if [ "$(hostname -s)" != pg-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/enclave/ca.sh request pg-01
fi
```

```bash
### MACHINE: stage-01 ###   — carries the three CSRs; scp -3 writes nothing on stage-01
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && . scripts/enclave/enclave-addresses.env
  for k in PG_01 PG_02 PG_03; do n="$(echo "$k" | tr 'A-Z_' 'a-z-')"
    scp -q -3 -i ~/.ssh/build01 "encadmin@${!k}:/etc/ssl/enclave/$n.csr" "encadmin@$SVC_MGMT_01:$n.csr" && echo "$n.csr -> svc-mgmt-01"
  done
fi
```

```bash
### MACHINE: svc-mgmt-01 (10.2.20.161) ###
if [ "$(hostname -s)" != svc-mgmt-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  for n in pg-01 pg-02 pg-03; do
    sudo ~/canonical-k8s/scripts/enclave/ca.sh sign-server --peer ~/$n.csr
    sudo install -m 0644 -o encadmin -g encadmin /etc/enclave-ca/certs/$n.fullchain.crt ~/$n.fullchain.crt && rm -f ~/$n.csr
  done
fi
```

```bash
### MACHINE: stage-01 ###   — carries the three certificates back
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && . scripts/enclave/enclave-addresses.env
  for k in PG_01 PG_02 PG_03; do n="$(echo "$k" | tr 'A-Z_' 'a-z-')"
    scp -q -3 -i ~/.ssh/build01 "encadmin@$SVC_MGMT_01:$n.fullchain.crt" "encadmin@${!k}:$n.fullchain.crt" && echo "$n.fullchain.crt -> $n"
  done
fi
```

**What the certificate is** (read from pg-01 2026-09-28):

| field | value |
|---|---|
| subject CN | `pg-01.enclave.internal` — **this exact string is what `pg_ident` maps to the database roles** (§11.3) |
| SAN | `DNS:pg-01.enclave.internal, DNS:pg-01, IP:10.2.20.165` — `ca.sh request` adds the name, the FQDN and the node's own IP |
| key | RSA 3072, made on the node |
| purpose | `serverAuth` **and** `clientAuth` — `--peer`. Every etcd member is a server to its peers and a client to them at once; a plain server certificate fails the peer handshake with an error naming the *cipher*, not the purpose |
| chain | leaf + issuing CA; verifies to the enclave root |
| valid until | **2027-09-28** — and nothing watches it yet (§16) |

`--peer` is a flag, not the default, deliberately: giving every certificate in the enclave
`clientAuth` would let any service's key authenticate *as a client* to any other.

Verified 2026-09-28 before any node used its certificate: each CSR's signature valid and naming
its own node and IP; each CSR identical on the node and on svc-mgmt-01 (sha256); each certificate a
2-cert chain verifying to the root, `serverAuth`+`clientAuth`, naming its own node, and **its
public key identical to the CSR made on that node**.

---

## 7. Step E — the database's own etcd (slice 2)

Patroni needs a consistent store to hold the leader lock and the cluster's configuration. This
cluster gets **its own** three-member etcd — deliberately not the Kubernetes cluster's; coupling the
database's failover to the Kubernetes control plane is what runbook §9a exists to remove.

```bash
### MACHINE: pg-01 (10.2.20.165) ###   — then pg-02 and pg-03 straight after, each with its own file
if [ "$(hostname -s)" != pg-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh etcd ~/pg-01.fullchain.crt
fi
```

**What `06a etcd` does**, in order:

1. **Works out which node it is from its IP** — a `PG_*` address in the address file — never from
   a typed name. On any other machine it refuses.
2. **Checks the certificate before installing anything** (`check_member_cert`) and refuses one that:
   does not verify to the enclave root through its issuing CA · lacks `serverAuth` or `clientAuth`
   · does not name this node's IP · **was not made from this node's key** (catches a CSR from the
   wrong node).
3. **Installs `etcd-server` and `etcd-client` with the package's self-start blocked.** The package's
   postinst enables and starts a *single-node* etcd named after the host with data in
   `/var/lib/etcd/default`; a three-member static bootstrap on top of it fails on a cluster-ID
   mismatch. A temporary `/usr/sbin/policy-rc.d` (exit 101) blocks the start and is removed straight
   after; any default data directory is deleted.
4. **Places the PKI** in `/etc/etcd/pki` (0750 root:etcd): the enclave root as `ca.crt`, the
   certificate as `member.crt`, **a copy** of the node key as `member.key` (0640 root:etcd — etcd
   runs as user `etcd` and must read it).
5. **Renders `/etc/default/etcd`** (0640 root:etcd) from the address file — member name, its own
   data directory `/var/lib/etcd/enclave-pg`, listen and advertise URLs on **this node's IP only**,
   the three-member initial cluster, token `enclave-pg-etcd`, TLS on both ports with **client
   certificates required on both** (`CLIENT_CERT_AUTH`, `PEER_CLIENT_CERT_AUTH`), and:

   ```
   ETCD_CIPHER_SUITES="TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384"
   GODEBUG="tlsrsakex=0,tls10server=0"
   ```
6. **Starts etcd without waiting on systemd** (`--no-block`): the unit is `Type=notify`, and the
   first member only reports ready once a quorum exists — a blocking start on pg-01 would time out
   waiting for pg-02 and pg-03. Then it waits up to 300 s for **quorum** (`etcdctl endpoint health`
   as this member) and prints the member list.

```bash
### MACHINE: pg-01 (10.2.20.165) ###   — then pg-02, pg-03
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh etcd-check
```

`etcd-check` asks **all three** endpoints for health from this node, prints the member list,
proves a client **without** a certificate is refused, and proves the running etcd process carries
the `GODEBUG` setting (read from `/proc/<pid>/environ`, not from the file).

**Result 2026-09-28 02:45:** all three endpoints healthy from every node; the identical
three-member list on each (one cluster, not three); a certificate-less client refused; `GODEBUG`
in the running process; etcd listening only on each node's own address.

### 7.1 FIPS — what is true and what is not

Ubuntu's etcd 3.4.30 is Go 1.22.2 **built without BoringCrypto**. Its TLS is Go's own code, **not
the host's FIPS-validated OpenSSL module**. What the build does is restrict it to FIPS-**approved
algorithms** — proven offline against the real binary on 2026-09-27 with a client offering
everything:

| offered | result |
|---|---|
| TLS 1.2, ECDHE-RSA, AES-GCM | accepted |
| RSA key exchange · CBC · ChaCha20 (TLS 1.2) · TLS 1.0 · TLS 1.1 | **refused**, on 2379 and 2380 |
| a client with no certificate | **refused** |
| TLS 1.3 ChaCha20-Poly1305 | **still negotiable** — Go does not allow TLS 1.3 suites to be restricted, and 3.4 has no `--tls-max-version` |

Approved algorithms in a non-validated module is an SC-13 finding, not a pass: **POA&M ENG-68**,
with the TLS 1.3 residual stated. Only enclave-CA-certified clients can connect at all, and the pg
nodes' own clients choose AES-GCM. Canonical has been asked for a FIPS-built etcd — **backlog
Q-CORE (h), not yet sent**. Patroni's side of every etcd connection, and all of PostgreSQL's TLS,
is the FIPS OpenSSL.

---

## 8. Step F — Patroni and PostgreSQL 16 (slice 3)

```bash
### MACHINE: pg-01 (10.2.20.165) ###   — pg-01 FIRST, alone; it bootstraps the cluster
if [ "$(hostname -s)" != pg-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh patroni
fi
```

```bash
### MACHINE: pg-02 (10.2.20.166) ###   — then pg-03 the same way; they clone from the leader
if [ "$(hostname -s)" != pg-02 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh patroni
fi
```

**Not all three at once:** a simultaneous three-way bootstrap is a race whose loser can initialise
a second, empty cluster (runbook §9a.3).

### 8.1 What `06a patroni` does, in order

1. **Refuses unless this node's etcd is healthy** and slice 2's certificate and key are present.
2. **The data disk, never the OS disk.** If a filesystem labelled `pgdata` exists, use it.
   Otherwise there must be **exactly one** whole disk with no partitions, no filesystem and no mount
   — anything else and it refuses rather than guess which disk to format. Formats it
   `mkfs.ext4 -E nodiscard -L pgdata`, adds to `/etc/fstab` (backup `/etc/fstab.bak-06a-<time>`
   first):

   ```
   LABEL=pgdata  /var/lib/postgresql  ext4  defaults,nodev,nosuid,noexec  0 2
   ```

   **By label**, because the disk's device name moved `vdc → vdb` when `finish` removed the seed.
   **No `nofail`**: a missing data disk must stop the boot's mount, not let the database start
   somewhere else.
3. **Switches off Ubuntu's default cluster before the package exists.** `postgresql-16`'s install
   normally creates and starts a cluster `16/main` on 5432 — a second postmaster Patroni would not
   manage, and the classic way a failover promotes an empty database. So first:

   ```
   /etc/postgresql-common/createcluster.d/00-no-main-cluster.conf:   create_main_cluster = false
   ```

   then installs `postgresql-16 postgresql-16-pgaudit patroni python3-etcd`, **refuses** if
   `pg_lsclusters` shows any cluster at all, and disables Debian's `postgresql.service`.
4. **The node's identity for Patroni and PostgreSQL** — `/etc/patroni/pki` (0750 root:postgres):
   the root as `ca.crt`, slice 2's certificate as `node.crt`, **a second copy** of the node key as
   `node.key` (0640 root:postgres — Patroni and PostgreSQL run as `postgres`).
5. **Writes `/etc/patroni/config.yml`** (0640 root:postgres) — §8.2 — and
   `/etc/patroni/post-bootstrap.sh` (0750 root:postgres) — §8.4 — and runs
   `patroni --validate-config` on it.
6. **A systemd drop-in** `/etc/systemd/system/patroni.service.d/06a.conf`:

   ```
   [Unit]
   RequiresMountsFor=/var/lib/postgresql   ← no data disk, no Patroni: never initdb on the OS disk
   After=etcd.service
   Wants=etcd.service
   StartLimitIntervalSec=600               ← a bootstrap that keeps failing STOPS after 5 tries
   StartLimitBurst=5                          in 10 min (it looped 34 times on 2026-09-28)
   [Service]
   RestartSec=15
   ```
7. **Starts Patroni and waits for the right role, held.** Up to 300 s, polling `patronictl list`:
   this node must be **Leader and running**, or **Replica / Sync Standby and streaming** — for three
   polls in a row (15 s), so a moment in passing does not count. On failure it prints the journal
   and names the stale-`initialize` trap if that is what it sees (§15 item 2).

### 8.2 `config.yml` — every setting, and why

Patroni **owns** `postgresql.conf` and `pg_hba.conf` and rewrites them on every start. Every
setting lives here (or in the DCS), never in a file edited by hand — about sixty STIG fix texts say
"edit postgresql.conf", and on this cluster that edit is silently undone (runbook §9a.2a).

| key | value | why |
|---|---|---|
| `scope` / `namespace` | `enclave-pg` / `/enclave/` | the cluster's name; its keys in etcd live under `/enclave/enclave-pg/` |
| `restapi.listen` | `<own IP>:8008` | the REST API — members query each other during a leader race |
| `restapi.certfile/keyfile/cafile` | the node certificate | the API is TLS |
| `restapi.verify_client` | `optional` | **a client certificate is required for anything that changes state** (switchover, restart, reload, config); reads (`/health`, `/cluster`, `/metrics`) stay open to what ufw lets in — the three pg nodes and svc-obs-01 |
| `restapi.allowlist` | the three pg IPs | |
| `etcd3.protocol/hosts` | `https`, the three nodes `:2379` | the DCS. Patroni 3.2.2's `etcd3` module talks to etcd's JSON gateway with `urllib3` — hence `python3-etcd`, not `python3-etcd3` (the draft was wrong) |
| `etcd3.cacert/cert/key` | the node certificate | Patroni is an mTLS client of etcd |
| `bootstrap.dcs.ttl / loop_wait / retry_timeout` | `30 / 10 / 10` | conservative: a promotion needs ~30 s of real leader loss, not a network blip |
| `maximum_lag_on_failover` | `1048576` (1 MB) | a replica further behind than this is never promoted |
| `synchronous_mode` / `synchronous_node_count` | `true` / `1` | one standby must confirm every commit. **Here, not in `synchronous_standby_names`** — Patroni overwrites a hand-set value (runbook §9a.1 correction 2) |
| `synchronous_mode_strict` | absent (off) — **decided** | with no standby left, the primary degrades to asynchronous instead of blocking writes. Defensible only with an alert on that degradation — **owed, slice 4** |
| `use_pg_rewind` / `use_slots` | `true` / `true` | a failed old leader rejoins by rewind; replicas hold slots so WAL they need is kept |
| `synchronous_commit` | `on` | |
| `max_connections` | `100` (`PG_MAX_CONN`) | |
| `password_encryption` | `scram-sha-256` | |
| `ssl`, `ssl_min_protocol_version` | `on`, `TLSv1.2` | server TLS with the node certificate |
| `wal_level`, `wal_log_hints`, `hot_standby`, `max_wal_senders`, `max_replication_slots` | `replica`, `on`, `on`, `10`, `10` | replication and rewind |
| `log_destination` + `logging_collector` + `log_file_mode` | `stderr,syslog` + `on` + `0600` | V-261967 wants syslog, 25 other rules want the collector's files — both, decided once (6a.7 trap 2) |
| `log_line_prefix` | `"%m %a %u %d %r %p %s %c %h "` | the union of what the STIG's rules ask for (runbook §9a.2a section 6) |
| `log_connections` / `log_disconnections` | `on` / `on` | |
| `shared_preload_libraries` / `pgaudit.log` / `pgaudit.log_catalog` | `pgaudit` / `ddl,role,read,write` / `on` | audit of statements |
| `initdb` | `UTF8`, `data-checksums`, `auth-local peer`, `auth-host scram-sha-256` | |
| `postgresql.listen` | `<own IP>:5432` | not `0.0.0.0` |
| `data_dir` / `bin_dir` | `/var/lib/postgresql/16/enclave-pg` / `/usr/lib/postgresql/16/bin` | Patroni's own directory, never Debian's `16/main` |
| `authentication.superuser` | `postgres` | local only, by peer |
| `authentication.replication` / `.rewind` | `replicator` / `rewinder`, `sslmode verify-full`, `sslcert/sslkey/sslrootcert` = the node certificate | **no password** — the node's certificate is the credential (§11.3) |

### 8.3 What was installed (read from all three nodes, 2026-09-28)

| package | version | from |
|---|---|---|
| `postgresql-16` | 16.15-0ubuntu0.24.04.1 | Ubuntu noble-updates, via svc-repo-01 |
| `postgresql-16-pgaudit` | 16.0-1 | Ubuntu noble/universe |
| `postgresql-common` | 257build1.1 | Ubuntu |
| `patroni` | 3.2.2-2 | Ubuntu noble/universe |
| `python3-etcd` | 0.4.5-4 | Ubuntu noble/universe |
| `etcd-server`, `etcd-client` | 3.4.30-1ubuntu0.24.04.3 | Ubuntu |

This is **Ubuntu's build of PostgreSQL, not Crunchy Data's.** The only DISA STIG for PostgreSQL 16
is written for Crunchy; applying it here is a tailoring decision that must be written down —
backlog **6a.11**, open.

### 8.4 What happens inside, first node and the others

```
 pg-01 — started first                            pg-02, pg-03 — started after
 ───────────────────────────────────────────      ────────────────────────────────────────────
 Patroni finds no cluster in etcd                 Patroni finds the cluster and its leader
  └─ takes /enclave/enclave-pg/initialize         └─ pg_basebackup FROM pg-01 over 5432:
 initdb  (UTF8, data checksums)                        user replicator, sslmode verify-full,
 post_bootstrap: post-bootstrap.sh                     its OWN node certificate (hba: cert)
  └─ CREATE ROLE replicator LOGIN REPLICATION     starts PostgreSQL as a standby
       CONNECTION LIMIT 10                         └─ streams WAL from pg-01
  └─ CREATE ROLE rewinder LOGIN                   Patroni on pg-01 creates a replication slot
       CONNECTION LIMIT 10                          for it, and names ONE standby synchronous
 Patroni: ALTER ROLE ... (keeps the limits),
   grants rewinder its pg_rewind functions
 writes /leader → LEADER
```

**`post_bootstrap` runs BEFORE Patroni creates its own roles.** The first version ALTERed roles
that did not exist yet, exited non-zero, and Patroni cancelled the bootstrap (§15 item 1). So it
**creates** them, with their connection limits (V-261857); Patroni's own create-or-alter then leaves
the limit alone.

### 8.5 Step G — `patroni-check`

```bash
### MACHINE: pg-01 (10.2.20.165) ###   — then pg-02, pg-03
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh patroni-check
```

| checks | fails if |
|---|---|
| `patronictl list` | the cluster cannot be read |
| `shared_preload_libraries` **and `pending_restart`** | pgaudit is not loaded, or is set but **not applied** — a node can SHOW the right value and not run it (the false-pass detector) |
| the methods in `pg_hba_file_rules` | any `md5`, `password` or `trust` (V-261892) |
| the line types in `pg_hba_file_rules` | any `host` or `hostnossl` — only `hostssl` over the network |
| `replicator` and `rewinder` connection limits | either is missing or unlimited (V-261857) |
| ssl, TLS minimum, password encryption, logging, synchronous_commit | printed for the record |
| **on the primary: a real synchronous write** | `pg_logical_emit_message` (a WAL record, no table left behind), then **a synchronous standby must have replayed past it** |

**Result 2026-09-28 03:20:** pg-01 Leader, pg-02 Sync Standby, pg-03 Replica, lag 0, cluster
system identifier `7690418360759139912`; every check passed on all three; connection limits
`replicator=10 rewinder=10`; a commit made on pg-01 replayed on the synchronous standby.

---

## 9. Slice 4 — watched, maintained, and broken on purpose (2026-09-28)

### 9.1 Monitoring

**The OS agent, as on every enclave machine** — node-exporter bound to the node's own IP and the
15-minute compliance-facts timer:

```bash
### MACHINE: pg-01 (10.2.20.165) ###   — then pg-02, pg-03
if [ "$(hostname -s)" != pg-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && sudo ./scripts/enclave/monitoring.sh exporter && sudo ./scripts/enclave/monitoring.sh facts-timer
fi
```

**The database exporter — `06a monitor`, on the PRIMARY first** (it creates the role; the
replicas receive it by replication and only check it is there):

```bash
### MACHINE: pg-0N — the primary first, then the two replicas ###
if ! hostname -s | grep -qx 'pg-0[123]'; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh monitor
fi
```

It does three things, and changes nothing else:

1. **The login path, through Patroni** — `config.yml` is backed up (`config.yml.bak-06a-<time>`)
   and re-rendered with one `pg_hba` line, `local postgres pgmonitor peer map=pgmonitor`, and one
   `pg_ident` map, `pgmonitor prometheus pgmonitor`. Patroni is **reloaded, not restarted**; the
   script waits until the line is live in `pg_hba_file_rules`. **No PostgreSQL restarted** —
   the postmaster start times were unchanged on all three.
2. **The role, on the primary only** — `pgmonitor`: `LOGIN`, `CONNECTION LIMIT 3`, member of
   `pg_monitor` (statistics only — it cannot read table data), **no password, not superuser**.
3. **postgres-exporter 0.15.0** — installed with its self-start **blocked** (its postinst starts it
   with an empty connection string on every interface), then `/etc/default/prometheus-postgres-exporter`
   (0640 root:prometheus): `DATA_SOURCE_NAME='host=/var/run/postgresql user=pgmonitor dbname=postgres'`,
   listening on the node's own IP only. The run passes only on `pg_up 1`.

**pgaudit and the monitor — a decided tailoring (2026-09-28, for the org baseline 6a.10).**
Measured on pg-01: one exporter scrape wrote **20 audit lines** (~945 bytes each) of `pgmonitor`
reading statistics views — **~4.5 MB/hour per node** at a 15 s scrape, about **6×** the node's
entire syslog, doubled by PostgreSQL's own log files, kept a year under backlog 3.37. Decided:
`ALTER ROLE pgmonitor SET pgaudit.log = 'none'` (superuser-only; the role cannot undo it).
**Proven live on all three: a scrape now writes 0 audit lines, and its login is still logged**
(`connection authorized: user=pgmonitor`). `patroni-check` fails if the global classes change from
`ddl,role,read,write` or if **any other** role gains a pgaudit setting.

**The collector** scrapes three new jobs, generated from the address file:

```bash
### MACHINE: svc-obs-01 (10.2.20.164) ###
if [ "$(hostname -s)" != svc-obs-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s && sudo ./scripts/enclave/monitoring.sh scrape && sudo ./scripts/enclave/monitoring.sh rules
fi
```

| job | target | what |
|---|---|---|
| `node` | pg-0N:9100 | the OS — CPU, memory, **`/var/lib/postgresql` free space** |
| `patroni` | pg-0N:8008, **https, certificate verified** against the system trust store (no `insecure_skip_verify`) | leader, sync standby, timeline, WAL positions, paused, pending restart |
| `postgres` | pg-0N:9187 | connections, locks, replication, per-database statistics |

Result: **24 targets, 24 up; 53 rules.** (New targets read ~75–90 % "busy" for their first five
minutes — `rate()` over 5 minutes of a 2-minute-old series. The raw counters said 95.5 % idle;
`HighCPU`'s 10-minute `for` absorbs it.)

**The database alerts** (`monitoring.sh`, group `enclave-database`):

| alert | fires when | for | severity |
|---|---|---|---|
| **`PostgresSyncStandbyLost`** | a primary with no synchronous standby — commits no longer protected. **The alert that makes strict mode OFF defensible** | 5 m | critical |
| `PostgresNoPrimary` | no leader — longer than a normal failover | 1 m | critical |
| `PostgresMultiplePrimaries` | more than one leader — split brain | 1 m | critical |
| `PostgresReplicaNotStreaming` | a replica not streaming | 5 m | warning |
| `PostgresNotRunning` | Patroni up, PostgreSQL down | 5 m | warning |
| `PostgresFailoverHappened` | the timeline changed — any promotion, planned or not | — | warning |
| `PatroniPendingRestart` | a setting shown but not applied | 1 h | warning |
| `PatroniPaused` | automatic failover switched off | 30 m | warning |
| `PostgresExporterCannotConnect` | `pg_up 0` | 5 m | warning |
| `DataDiskNotReserved` | a data disk under 98 % allocated (§9.2) | 1 h | warning |
| `DataVolumeForeignData` | > 5 GB on the database volume that is not a data disk (§9.5) | 15 m | warning |

All promtool-tested both ways with a control that must fail, then proven live below.

### 9.2 Maintenance without an outage — the data disks re-reserved

The disks had lost their reservation (§15 item 6). The repair needs the guest **off**, so each
node was taken out and brought back **one at a time**. Two guards make it safe, and both live in
the scripts, not in the runbook:

- **`06a leave`** (on the node) refuses if the node is the **leader**, if either other member is not
  running/streaming at **lag 0**, or if any etcd member is unhealthy — so it can never take down a
  second node. Tested against eight cluster shapes, including "pg-03 already stopped → `leave` on
  pg-02 refused". Then: Patroni stopped (PostgreSQL shuts down with it), etcd stopped, power off.
- **`03-compose-vm.sh <vm> --reserve-data`** (on the host) refuses a guest that is not shut off;
  sets the data disk's `discard=ignore` with virt-xml, **selecting the disk by path**, and reads it
  back from the XML before touching the file; `fallocate`s the file; `qemu-img check`; ≥98 % or it
  will not start the guest. Proven offline first on the hosts' qemu-img 8.2.2 (TRIM reproduced to
  12 %, fallocate → 100 %, data intact, a later 256 MB write stayed inside the file).
- **`06a switchover`** hands the lead to the synchronous standby (no commit can be lost), through
  Patroni's REST API with the node's client certificate, and times it.

```bash
### MACHINE: pg-0N (the node) ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh leave            # the leader first runs: ... switchover
```

```bash
### MACHINE: host-N (its host) ###
if ! hostname -s | grep -qx 'host-[123]'; then echo "WRONG MACHINE: $(hostname -s)"; else
  vm=pg-0N   # this host's pg node
  for i in $(seq 1 36); do [ "$(sudo virsh domstate $vm)" = "shut off" ] && break; sleep 5; done
  cd ~/canonical-k8s/scripts/install && sudo ./03-compose-vm.sh $vm --reserve-data
fi
```

| order | node | what happened |
|---|---|---|
| 1 | pg-02 (async replica) | back 16:30:59, lag 0 — 100 % reserved |
| 2 | pg-03 (sync standby) | **Patroni moved sync to pg-02 by itself**; back 16:33:52 as a replica — 100 % |
| 3 | `switchover` pg-01 → pg-02 | **timeline 1 → 2 at 16:35:29** (Patroni history); pg-02 promoted **in place, no restart**; `PostgresFailoverHappened` fired on all three |
| 4 | pg-01 (now a replica) | back 16:36:55, lag 0 — 100 % |

`DataDiskNotReserved` cleared at the next facts refresh. (The switchover's own two timings print
from the script; that output was not captured on 2026-09-28.)

### 9.3 A real crash — the leader's power cut

`virsh destroy` on the leader's host — an instant power-off: PostgreSQL, Patroni and etcd die
mid-flight, the way a host failure looks. A watcher on svc-obs-01 logged every state change
(read-only; one SSH session; it polls each node's `/patroni` every ~0.5 s):

```bash
### MACHINE: host-2 (the leader's host at the time) ###
if [ "$(hostname -s)" != host-2 ]; then echo "WRONG MACHINE: $(hostname -s)"
elif [ "$(sudo virsh domstate pg-02)" != running ]; then echo "pg-02 is not running"
else echo "PLUG PULLED at $(date -u +%T.%N | cut -c1-11) UTC"; sudo virsh destroy pg-02; fi
```

| UTC | what the watcher saw |
|---|---|
| 16:40:46.3 | pg-02 (leader, timeline 2) stops answering. pg-01 and pg-03 wait out its leader lock |
| **16:41:19.1** | Patroni history: timeline 2 ends at WAL `0/50029E0`; **pg-03 promoted** (the sync standby — in synchronous mode the only one allowed) |
| 16:41:20.4 | pg-03 answering as leader, **timeline 3 — ~34 s after the loss** (30 s TTL + one loop) |
| 16:41:33.0 | pg-01 follows onto timeline 3 and **becomes pg-03's sync standby**, lag 0 — **healed on two nodes ~47 s after the power cut**, nobody touching it |
| 16:44:06–12 | pg-02 powered on: Patroni finds itself demoted, **runs `pg_rewind`**, rejoins as a replica on timeline 3, lag 0 |

**etcd lost a member and kept its quorum** — without that, no promotion could have happened.

**`pg_rewind`, from pg-02's own journal:** `running pg_rewind from dbname=postgres user=rewinder
host=10.2.20.167 ... sslmode=verify-full sslcert=/etc/patroni/pki/node.crt` → `servers diverged at
WAL location 0/50029E0 on timeline 2` (exactly where Patroni's history says timeline 2 ended) →
`exit code=0` → `started streaming WAL from primary ... on timeline 3`. **The certificate-only
rewind login, used for real.** The WAL pg-02 held beyond the divergence had never been confirmed by
a standby, so under synchronous commit it cannot have held a committed transaction.

**Alerts:** `PostgresFailoverHappened` fired; `InstanceDown` fired for pg-02's three targets at
2 minutes and reached Alertmanager; `PostgresNoPrimary` did **not** fire (34 s < its 1 m);
`PostgresSyncStandbyLost` and `PostgresReplicaNotStreaming` went pending for the 13 s before pg-01
became sync and **cleared by themselves**.

**The honest limit:** nothing was writing during the crash. This proves promotion, rejoin and
alerting — **not zero data loss under load**. That rests on synchronous mode and on `patroni-check`
having proven the sync standby replays a commit made just before. A crash under a write load needs
a write generator (§16).

### 9.4 The "no synchronous standby" alert, proven

Patroni **stopped on both replicas** (the VMs and etcd left up — powering two VMs off would cost
etcd its quorum and test something else). pg-03 kept its leader lock, lost its synchronous
standby, and — strict mode being off — went on accepting writes **asynchronously**:

| UTC | |
|---|---|
| 16:46:36 / 16:48:52 | Patroni stopped on pg-02, then pg-01 |
| 16:49:21 | `PostgresSyncStandbyLost` **pending** — pg-03 reporting no replication at all |
| **16:54:13** | **firing — in Alertmanager as critical**: *"the primary has NO synchronous standby - commits are no longer protected"* |
| 16:58:22 / 16:58:45 | Patroni started on pg-01, then pg-02; pg-01 sync again, both lag 0 |
| 16:59:04 | **cleared** |

That completes the argument for strict mode off: the degradation it permits can no longer be silent.

### 9.5 The database volume, once it is full by design

Reserved disks leave each host's database volume ~18 % free **for good**, and the general %-free
alert fired on host-1..3 with no way to clear — the same alert that went unheeded for 12 hours on
2026-09-27. Decided 2026-09-28: the two %-free rules **skip** the database volume (from
`VM_POOL_DATA`, the composer's own setting), and **`DataVolumeForeignData`** alerts on anything on it
that is **not** a reserved data disk (above 5 GB — measured baseline 28 KB, the filesystem's
`lost+found`). That is exactly 2026-09-27's failure. The database cannot be starved by that volume
any more — its disk is reserved — and **the filesystem whose filling does stop PostgreSQL,
`/var/lib/postgresql` inside each pg node, keeps every %-free and predictive alert.**

---

## 10. Slice 5 — backup and point-in-time restore (2026-09-28)

Decided 2026-09-28 (HANDOFF §3): pgBackRest 2.50 over **TLS with enclave-CA certificates in both
directions**; **two live stores** — host-4's spare 2 TB NVMe (repo1) and host-3's images pool
(repo2, 100 GB counted by the planner) — each receiving every WAL file and taking its own backups;
**encryption by the LUKS volumes underneath**, no pgBackRest passphrase; **2 weekly fulls + daily
differentials** (≈ 7–14 days of point-in-time restore). This also closed backlog **3.46**.

### 10.1 The shape

```
  the PRIMARY (whichever pg node leads)
    archive_command = pgbackrest --stanza=enclave-pg archive-push %p     (archive_timeout 300 s)
       │  every finished WAL file, to BOTH stores, as it is produced
       ├─── TLS :8432 ──► host-4  repo1  /srv/pgbackrest/repo                 spare NVMe, LUKS
       └─── TLS :8432 ──► host-3  repo2  /var/lib/libvirt/images/pgbackrest   images pool, LUKS

  host-4 / host-3 ─── TLS :8432 ──► reach INTO the primary for the backups:
       full on Sunday, differential the other days — host-4 at 01:30 UTC, host-3 at 02:30
```

**Why traffic runs both ways:** pgBackRest *requires* the backup command to run on the repository
host (its binary says so: "command must be run on the repository host"). So every machine in the
picture runs pgBackRest's TLS server on 8432 — the stores admit the three pg nodes' certificates,
the pg nodes admit the two stores' — and `tls-server-auth` names each certificate CN allowed to use
stanza `enclave-pg`; nothing else gets in. Names, not addresses, on the client side: the
certificates carry DNS names, and every machine resolves the others from `/etc/hosts`.

### 10.2 host-4's spare NVMe — `03-host-services.sh cryptdisk`

Encrypted the way the installer built `crypt-data`: LUKS opened at boot by a 4 KiB random **key
file** in `/etc/luks` (which lives on the TPM-unlocked OS disk), the **site passphrase kept as a
second slot** so it can always be opened by hand, and `nofail` so a key problem degrades to "not
mounted" rather than a failed boot. The disk is named by its **stable ID** in `services-params.env`:

```bash
### MACHINE: host-4 (10.2.20.158) ###
if [ "$(hostname -s)" != host-4 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  P=~/canonical-k8s/scripts/install/03-host-services/services-params.env
  grep -q '^CRYPT_DISKS=' "$P" || echo "CRYPT_DISKS='crypt-pgbackrest:/dev/disk/by-id/nvme-XF-2TB_2280_9C60401530473:/srv/pgbackrest'" >> "$P"
  cd ~/canonical-k8s/scripts/install && sudo ./03-host-services.sh cryptdisk     # asks for the site passphrase twice
fi
```

It **refuses any disk that is not completely blank** (partitions, signatures, open or mounted).
Result: LUKS2 **aes-xts-plain64/512, PBKDF2-SHA256** (FIPS-approved, stated rather than left to
cryptsetup's argon2id default), two keyslots, ext4 at `/srv/pgbackrest` (1.9 TB) with
`nodev,nosuid,noexec`. **The boot path was proven without a reboot:** the disk was closed and
reopened by `systemd-cryptsetup@crypt\x2dpgbackrest.service` and mounted from fstab — the unit and
lines a boot uses.

### 10.3 The stores' certificates, and port 8432

The same round trip as step D (§6): `ca.sh request host-4` / `host-3` on each store (the key never
leaves it), the requests carried by `scp -3` to svc-mgmt-01, `ca.sh sign-server --peer` (both
purposes — each store is a server to WAL pushes and a client when it reaches in), carried back.
Verified: chain to the enclave root, serverAuth + clientAuth, each naming its own host and IP,
**each certificate's key identical to the request made on that host**, valid to **2027-09-28**.

8432 is in the PPSM register (CAL `-`). `stig-tailor.sh ufw --apply` rebuilt pg-01..03's tables
(22 rules, 8432 from host-4 and host-3) and host-3's (8432 from the three pg nodes) — each block
refused to run unless ufw was already active and the plan showed nothing listening left uncovered.
**host-4's row is on record only: its firewall is deferred by decision (backlog 3.1).**
The rules are `allow`, like 5432/2379/2380/8008 — a backup opens several connections at once — so
STIG `ufw_rate_limit` now fails on pg-01..03 and host-3 as it already does elsewhere: part of the
known residual awaiting the AO's acceptance (backlog Q25).

### 10.4 pgBackRest on the nodes and the stores

```bash
### MACHINE: pg-01, pg-02, pg-03 — each ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh backup-node
```

```bash
### MACHINE: host-4 (then host-3 with its own file) ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh backup-store ~/host-4.fullchain.crt
```

**`backup-node`** installs pgbackrest (its server's self-start blocked — the unit is
`Restart=always` with no start limit), places the node's existing certificate and key under
`/etc/pgbackrest/pki`, writes `/etc/pgbackrest/pgbackrest.conf` (repo1 = host-4, repo2 = host-3,
admit only `host-4.enclave.internal` and `host-3.enclave.internal`) and starts the server on the
node's own IP only. **`backup-store`** checks the certificate as `06a etcd` does, **refuses unless
the repository's parent is its own mount**, installs pgbackrest (which pulls `postgresql-common`;
the Debian `postgresql.service` it enables is disabled again — no server runs on a store), creates
the repository (`postgres`, 0750), writes its config (its repo, 2 fulls, zstd, admit only the three
pg nodes, `pg1..3-host` = the pg nodes) and runs **`stanza-create`** — reaching every node over TLS,
finding the primary, recording the cluster's identity: the first live proof of store → node.

### 10.5 Archiving on — `backup-enable`, on the primary

```bash
### MACHINE: the primary (pg-03 on 2026-09-28) ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh backup-enable
```

The settings go into the **DCS** (`patronictl edit-config`) — where a running cluster's parameters
live; `config.yml`'s bootstrap section only applies when a cluster is first created, and carries
the same three values so a rebuild archives from its first boot: `archive_mode = on`,
`archive_command = pgbackrest --stanza=enclave-pg archive-push %p`, `archive_timeout = 300`.
`archive_mode` needs a restart: **pg-01, then pg-02, each back and streaming before the next, then
pg-03 restarted in place** — timeline 3 throughout, no failover, "Pending restart" clearing node by
node. Then **`pgbackrest check`** forced a WAL switch and saw that file land **in both stores** —
node → store proven.

### 10.6 The first full backups, and the timers — `backup-run`

```bash
### MACHINE: host-4, then host-3 ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh backup-run full
```

| | host-4 (repo1) | host-3 (repo2) |
|---|---|---|
| backup | `20260928-184508F`, 5 s | `20260928-184528F`, 7 s |
| database → stored | 34.2 MB → **2.9 MB** (zstd) | 34.3 MB → **2.9 MB** |
| status | ok | ok |
| timers | full Sun 01:30, diff other days 01:30 UTC | full Sun 02:30, diff 02:30 UTC |

A backup reaches into the primary with `start-fast` (an immediate checkpoint) and does not block
writes. Units `pgbackrest-full` / `pgbackrest-diff` run as `postgres`; the timers are `Persistent`.

### 10.7 The proof — `backup-restore-test`, on the primary

```bash
### MACHINE: the primary ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh backup-restore-test
```

A throwaway database `pitr_probe` gets a row `before-target`; the time **T** is taken; a row
`after-target` follows; that WAL is forced out and archived. Then, **from each store in turn**, the
backup + WAL are restored **to T** into a scratch directory on the data disk (the script refuses if
it could overlap the live one, or if a previous run left anything), started as a throwaway instance
on a private socket with **archiving off** (a promoted copy must never push its new timeline into
the real stores), and read. Everything it made is removed afterwards.

**Result 2026-09-28:** T = `18:49:47.404041` UTC, marker WAL `…000B` archived; **repo1 (host-4):
`before-target` present, `after-target` absent — PROVEN; repo2 (host-3): the same — PROVEN.** Each
store stood alone: the generated `restore_command` read WAL with `--repo=1` for the first and
`--repo=2` for the second. **Losing either host leaves a complete, restorable history on the
other.** Re-run it after any change to the backup path — a restore nobody has tried is a hope.

### 10.8 Watching the backups

On each store, the 15-minute facts read `pgbackrest info` as `postgres` (read-only):
`enclave_pgbackrest_status{repo}` (0 ok; 99 if info cannot be read — never a missing number) and
`enclave_pgbackrest_last_backup_seconds{repo,type}`. On the primary, postgres-exporter already
publishes the archiver counters.

| alert | fires when | for | severity |
|---|---|---|---|
| `DatabaseBackupMissed` | no backup finished on a store in 26 h | 15 m | warning |
| `DatabaseFullBackupStale` | no full in 8 days | 1 h | warning |
| `DatabaseBackupStoreError` | pgBackRest's own verdict on a store is not ok | 30 m | critical |
| `DatabaseArchivingFailing` | archive failures rising **and** nothing archived for 15 min | 5 m | critical |

promtool-tested both ways with controls. **Live 2026-09-28: status 0 on repo1 and repo2, each with
today's full.** The first version of the status fact emitted **nothing** on the real stores — it
read the verdict from a JSON layout the 2.50 output does not use, so `DatabaseBackupStoreError` could
never have fired; caught by checking the live metrics, fixed to read both layouts and fall back to
the stanza's verdict.

---

## 10a. Slice 6 prep — the application's database, loaded without its content leaving the gap (2026-09-29)

### 10a.1 What and why

The application's own database — a full plain-SQL `pg_dump --create` of its Azure PostgreSQL 14
database, **real records** — loaded at full size into the cluster. It is the real test of slice 5
(backup time, WAL volume) and what the slice-6 STIG scan must see: the real roles, grants and
ownership. **Every `app-restore` subcommand prints numbers only**, so its output is safe to paste
anywhere. The dump goes from the operator's workstation straight to the leader's home directory, in a
binary transfer, and never passes through stage-01. The database's name is in HANDOFF §3 only.

### 10a.2 The commands

```bash
### MACHINE: the leader (pg-03 on 2026-09-29) ###
sudo ./scripts/install/06a-postgres-ha.sh app-restore rehearse            # the whole path, a made-up dump
sudo ./scripts/install/06a-postgres-ha.sh app-restore census ~/<dump>.sql # what it is and needs - reads only
```

```bash
### MACHINE: pg-01, pg-02, pg-03 — each ###
sudo ./scripts/install/06a-postgres-ha.sh extensions   # PG_EXTENSION_PACKAGES (vm-specs.env): PostGIS here
```

```bash
### MACHINE: the leader ###
sudo ./scripts/install/06a-postgres-ha.sh app-restore load ~/<dump>.sql <database>
sudo ./scripts/install/06a-postgres-ha.sh app-restore summary              # reprint it from the log
sudo ./scripts/install/06a-postgres-ha.sh app-restore drop <database>      # for a reload - only one it loaded
sudo ./scripts/install/06a-postgres-ha.sh app-restore shred <file>...      # the dump and the logs, when done
```

`load` refuses a standby, an existing database, a cluster dump (`pg_dumpall`) and data rows with Windows
line endings. A `--create` dump loads under the name given: its `CREATE DATABASE` and `\connect` are
skipped and its `ALTER DATABASE` / `GRANT … ON DATABASE` lines pointed at the new database. The roles
it refers to are created `NOLOGIN`, counted, never named.

### 10a.3 Where the rows can go, and where they cannot

| place | what reaches it |
|---|---|
| the screen | numbers only — sizes, times, counts, errors counted by SQLSTATE |
| the load log, `/var/log/enclave-app-restore/<db>-<time>.log` | everything psql printed — root `0600`, because a failed COPY's `CONTEXT` line quotes the row |
| the PostgreSQL log and syslog | not the session's errors (which quote the bad value): the load runs with `log_min_messages=log` and `log_min_error_statement=panic` |
| the audit trail | `pgaudit.log=ddl,role` for the load session: structure and role changes audited, rows not |
| the original database name | never printed; passed to the stream filter by environment, not on the command line |

### 10a.4 Proven live by `rehearse` on pg-03

A made-up `--create` dump — 1,000 rows, one bad row carrying a unique marker, three roles, an extension
that does not exist — through the real path, then twelve checks: the load ran to the end; 1,000 rows;
2 errors counted; the bad row as 1 × 22P02; the dump's own `CREATE DATABASE` skipped; its `OWNER TO`
landed on the new database; the rows in it and nothing in `postgres`; the marker **in** the load log
(control) and **not** on the screen, and **not** in the PostgreSQL log or syslog; an ordinary session's
error **is** in the server log and this run's DDL **is** in the audit (the two controls that prove the
no-leak checks can fail). Then everything it made is dropped and shredded.

### 10a.5 The result

| | |
|---|---|
| rows | **1,167,589** — the census's count, by all 305 COPY statements |
| errors | **0** |
| time | **49 s** |
| database | 344 MB — 335 tables (the application's 298 and PostGIS's), 599 indexes |
| WAL | 292 MB, archived to both stores, 0 failures; both standbys at lag 0 |
| full backups | **8 s** to repo1, **12 s** to repo2 — **75.5 MB** each (389.5 MB of database) |

### 10a.6 Findings for slice 6

- **PostGIS refuses to install under pgaudit** (P0001) — the first load's 14 errors were all this one
  refusal and its knock-ons. The load sets `pgaudit.log` to `none` for `CREATE EXTENSION postgis*`
  statements only and restores it straight after, recorded in the load log. Any build that installs
  PostGIS needs the same exception: a tailoring entry for the baseline (backlog 3.49).
- **PostGIS is 69 packages on every node, and the application has 1 table with a PostGIS column,
  holding 0 rows** — ask its owners whether it is needed (3.49).
- **The stores now hold real records, and pgBackRest does not encrypt them** (`cipher: none` — LUKS
  underneath). No copy to the lab recovery store until repository encryption is on (3.50).

---

## 11. Who talks to whom, and how each proves who it is

### 11.1 The flows

```
  FROM               TO             PORT       WHAT                        AUTHENTICATION
  ─────────────────  ─────────────  ─────────  ──────────────────────────  ─────────────────────────
  etcd member        etcd member    2380/tcp   raft (peer)                 mutual TLS, node certs
  Patroni            etcd (any)     2379/tcp   leader lock, config (DCS)   mutual TLS, node cert
  Patroni            Patroni        8008/tcp   REST, in a leader race      TLS; client cert to change
  replica            leader         5432/tcp   WAL stream, basebackup      hostssl + CERT → replicator
  old leader         new leader     5432/tcp   pg_rewind after failover    hostssl + CERT → rewinder
  Patroni            local postgres  socket    management                  peer (OS user postgres)
  svc-obs-01         Patroni        8008/tcp   /metrics                    TLS, verified; reads need no cert
  svc-obs-01         exporters      9100,9187  node + database metrics     ufw: svc-obs-01 only
  postgres-exporter  local postgres  socket    statistics (pg_monitor)     peer, prometheus → pgmonitor
  primary            host-4, host-3 8432/tcp   WAL archive-push            mutual TLS, node cert → tls-server-auth
  host-4, host-3     pg nodes       8432/tcp   backups, stanza, check      mutual TLS, store cert → tls-server-auth
  k8s-wk-01..04      leader         5432/tcp   applications         B-07    hostssl + scram-sha-256
```

### 11.2 One key, used six ways

```
 /etc/ssl/enclave/pg-0N.key   (0640 root:root — made here by ca.sh request, never copied off)
   │
   ├─ copy → /etc/etcd/pki/member.key      0640 root:etcd       etcd server 2379, peer 2380, etcdctl
   │
   ├─ copy → /etc/pgbackrest/pki/node.key  0640 root:postgres   pgBackRest server 8432 + client (slice 5)
   └─ copy → /etc/patroni/pki/node.key     0640 root:postgres   Patroni REST API 8008
                                                                Patroni as etcd client
                                                                PostgreSQL server TLS 5432
                                                                replication + rewind client (cert)
 with the same certificate beside each copy (member.crt / node.crt) and the enclave root (ca.crt)
```

Three copies on the same machine, each readable by exactly the service account that needs it. When
the certificate is renewed (before 2027-09-28), **all three** copies and certificates must be
replaced and etcd, Patroni and pgBackRest restarted — there is no procedure for that yet (§16).

### 11.3 `pg_hba` and `pg_ident` — the whole access list

Generated by Patroni from `config.yml`; the full list, in order. **Anything that matches no line
is rejected.**

| type | database | user | address | method | who uses it |
|---|---|---|---|---|---|
| `local` | all | `postgres` | — | `peer` | Patroni and an administrator, as the OS user `postgres` on the node |
| `local` | postgres | `pgmonitor` | — | `peer map=pgmonitor` | postgres-exporter, as the OS user `prometheus` (slice 4) |
| `hostssl` | replication | `replicator` | each pg node /32 | `cert map=pgnodes` | replicas streaming and cloning |
| `hostssl` | all | `rewinder` | each pg node /32 | `cert map=pgnodes` | `pg_rewind` after a failover |
| `hostssl` | all | all | each K8S worker /32 | `scram-sha-256` | applications — **no application database or user exists yet** |

```
 pg_ident  map pgmonitor: prometheus (OS user) → pgmonitor
           map pgnodes:   pg-01.enclave.internal → replicator     pg-01.enclave.internal → rewinder
                          pg-02.enclave.internal → replicator     pg-02.enclave.internal → rewinder
                          pg-03.enclave.internal → replicator     pg-03.enclave.internal → rewinder
```

`cert` means PostgreSQL checks the client's certificate chains to the enclave root **and** that
its CN is mapped to the role being asked for. A node proves it is a pg node by holding a key only
it has; there is no shared replication password to make, carry on a stick, keep or rotate
(decided 2026-09-28, HANDOFF §3). `patroni-check` proves no `md5`, `password` or `trust` line and no
non-TLS network line exists.

---

## 12. Ports and firewall

Each pg node has 22 ufw rules from `stig-tailor.sh ufw` (its table in `stig-tailor.sh`, sources
from the address file). Every port is in the PPSM register `scripts/enclave/ppsm-services.tsv`, and
`stig-tailor.sh ufw` refuses a port that is not (D5). The table was active from the guest's first
hardening pass, default deny.

| port | rule | from | rules | what |
|---|---|---|---|---|
| 22/tcp | limit | any | 1 | SSH — `limit` is 6 new connections per 30 s per source |
| 9100/tcp | limit | svc-obs-01 | 1 | node-exporter (slice 4) |
| 5432/tcp | **allow** | k8s-wk-01..04, pg-01..03 | 7 | PostgreSQL. `allow`, not `limit`: a connection pool reconnecting after a failover must not be banned |
| 2379/tcp | allow | pg-01..03 | 3 | etcd client API |
| 2380/tcp | allow | pg-01..03 | 3 | etcd peer |
| 8008/tcp | allow | pg-01..03, svc-obs-01 | 4 | Patroni REST API |
| 9187/tcp | limit | svc-obs-01 | 1 | postgres-exporter (slice 4) |
| 8432/tcp | allow | host-4, host-3 | 2 | pgBackRest TLS server — the stores reach in for backups (slice 5) |

2379, 2380, 8008 and 9187 are in the register with CAL `-`: no PPSM Category Assurance List entry
could be verified from inside the gap.

---

## 13. Files on a pg node

Read from pg-01..03 on 2026-09-28 (identical on all three), except where marked.

| path | mode, owner | written by | what |
|---|---|---|---|
| `/etc/ssl/enclave/pg-0N.key` | 0640 root:root | `ca.sh request` | the node's private key |
| `/etc/ssl/enclave/pg-0N.csr` | 0444 root:root | `ca.sh request` | its CSR (public) |
| `/etc/etcd/pki/` | 0750 root:etcd | `06a etcd` | `ca.crt` 0644, `member.crt` 0644, `member.key` 0640 root:etcd *(from the script; the directory is not readable to verify without sudo)* |
| `/etc/default/etcd` | 0640 root:etcd | `06a etcd` | etcd's configuration, rendered |
| `/var/lib/etcd/enclave-pg` | 0700 etcd:etcd *(from the script)* | `06a etcd` | etcd's data |
| `/etc/postgresql-common/createcluster.d/00-no-main-cluster.conf` | 0600 root:root | `06a patroni` | `create_main_cluster = false` |
| `/etc/fstab` (one line) | — | `06a patroni` | the data disk by label; the previous file kept as `/etc/fstab.bak-06a-<time>` |
| `/var/lib/postgresql` | 0755 postgres:postgres | mount point | the data disk's root |
| `/var/lib/postgresql/16/enclave-pg` | 0700 postgres | Patroni (initdb / basebackup) | **PGDATA** |
| `/etc/patroni/pki/` | 0750 root:postgres | `06a patroni` | `ca.crt` 0644, `node.crt` 0644, `node.key` 0640 root:postgres |
| `/etc/patroni/config.yml` | 0640 root:postgres | `06a patroni` | Patroni's configuration (§8.2) |
| `/etc/patroni/post-bootstrap.sh` | 0750 root:postgres | `06a patroni` | creates the two roles (§8.4) |
| `/etc/systemd/system/patroni.service.d/06a.conf` | 0600 root:root | `06a patroni` | mount requirement, start limit (§8.1) |
| `/etc/patroni/config.yml.bak-06a-<time>` | 0640 root:postgres | `06a monitor` | the previous config, kept before each re-render |
| `/etc/default/prometheus-postgres-exporter` | 0640 root:prometheus | `06a monitor` | the exporter's login (no secret — peer) and listen address |
| `/etc/pgbackrest/pgbackrest.conf` | 0640 root:postgres | `06a backup-node` | the two stores, and who may reach in (slice 5) |
| `/etc/pgbackrest/pki/` | 0750 root:postgres | `06a backup-node` | `ca.crt`, `node.crt`, `node.key` (0640) — the third copy of the node key |
| `/var/log/pgbackrest/` | 0750 postgres | `06a backup-node` | pgBackRest's own logs |
| `/etc/patroni/config.yml.in`, `dcs.yml` | 0644 root:root | the Ubuntu `patroni` package | Ubuntu's templates — **not used** |
| `/var/log/enclave-app-restore/` | 0700 root | `06a app-restore` | the load logs, 0600 — they **can quote rows** (§10a.3) |
| the application's dump, in the leader's home directory | 0600 | the operator, then `app-restore census` | kept until slice 6's scans, then shredded (`app-restore shred`) |

The two 0600 files are written under the hardened umask (077); only root and systemd read them,
which is all they need.

---

## 14. Operating it

**Who is the leader right now** — never assume, the roles move:

```bash
### MACHINE: any pg node ###
sudo patronictl -c /etc/patroni/config.yml list
```

**Without logging in to a pg node** — the REST API's read endpoints, from svc-obs-01 (ufw lets it
reach 8008):

```bash
### MACHINE: svc-obs-01 (10.2.20.164) ###
curl -sk https://10.2.20.165:8008/cluster
```

**etcd's health, and the TLS it enforces:**

```bash
### MACHINE: any pg node ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh etcd-check
```

**Take a node down for maintenance** (§9.2) — `leave` refuses the leader and refuses unless the
other two are healthy; hand the lead over first with `switchover`:

```bash
### MACHINE: the pg node ###
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh switchover   # only if it is the leader
sudo ~/canonical-k8s/scripts/install/06a-postgres-ha.sh leave        # powers the VM off
```

**Backups** (slice 5) — read-only, on either store or the primary:

```bash
### MACHINE: host-4 or host-3, or a pg node ###
sudo -u postgres pgbackrest --stanza=enclave-pg info      # backups held, WAL range, status
sudo -u postgres pgbackrest --stanza=enclave-pg check     # on the PRIMARY: a WAL file reaches every store
```

A backup now: `06a backup-run full|diff` on a store. A restore drill: `06a backup-restore-test` on
the primary. A real restore is a different operation — it replaces a cluster — and is not yet
written as a procedure (§16).

**Do not:**

- edit `postgresql.conf` or `pg_hba.conf` by hand — Patroni rewrites both on its next start. A
  setting changes in `config.yml` (and the DCS), through the script;
- `systemctl start postgresql` or `pg_ctl` — Patroni starts and stops PostgreSQL; a second
  postmaster is the failure this design exists to avoid;
- stop etcd on two nodes at once — that is the quorum;
- delete keys under `/enclave/enclave-pg/` while any Patroni is running (§15 item 2 is the only
  time to);
- read the journals as `encadmin` and trust the answer — `journalctl` is permission-denied without
  sudo on a hardened guest, and a count taken that way is zero because nothing was read.

---

## 15. What went wrong on the way, and what the build now does about it

| # | what happened | fixed by |
|---|---|---|
| 1 | **Run 1 on pg-01, 2026-09-28:** `post_bootstrap` ALTERed `replicator`/`rewinder` before Patroni had created them, exited 3; Patroni cancelled the bootstrap and systemd restarted it **34 times**, each leaving a `*.failed` data directory. The wait printed a **false `[ok]`** — it accepted "running" in passing | `post_bootstrap` **creates** the roles; `StartLimitBurst=5` in 10 min; the wait needs the right role held for 15 s |
| 2 | **Run 2:** Patroni had been stopped mid-bootstrap, so its claim `/enclave/enclave-pg/initialize` stayed in etcd; every start sat on "waiting for leader to bootstrap" with no leader anywhere. Patroni removes the key when a bootstrap *fails*, not when it is *killed* | diagnosed from the key list; stopped Patroni, confirmed no leader key, deleted the cluster's keys and the never-initialised data directory, re-ran. `06a patroni` now **names this** when it sees it — and never clears it automatically, since another node may really be bootstrapping |
| 3 | etcd's package starts its own single-node etcd on install | installed under `policy-rc.d`; own data directory |
| 4 | Ubuntu's `postgresql-16` creates `16/main` | `create_main_cluster = false` before install; refuse if any cluster exists |
| 5 | The draft named `python3-etcd3` | `python3-etcd` — what Patroni 3.2.2 depends on |
| 6 | **The data disks are no longer reserved (found 2026-09-28).** The host attached them `discard=unmap`; `mkfs.ext4` TRIMs the whole device by default, and the TRIM punched holes straight through the falloc reservation — 161 GB released on each host within the hour slice 3 formatted it. The files are now **0.1–0.2 % allocated** | new disks: `discard=ignore` and `mkfs -E nodiscard`; `03-compose-vm.sh plan` checks the files; alert `DataDiskNotReserved`. **The three existing disks re-reserved in slice 4 without an outage (§9.2) — 100 % each** |
| 7 | **The clock correction of 2026-09-28** stepped every machine back 10.9 s (backlog 3.39) | the cluster stayed on timeline 1, no failover, no restarts, lag 0. The synchronous standby is now pg-03 (was pg-02); when and why is not known without reading the journal with sudo |
| 8 | **`06a monitor`'s first run on pg-01 ended silently** after doing its work: the first exporter poll came before the exporter listened, and under `set -e` + `pipefail` the failed `curl` ended the script with no `[ok]` and no `[x]` | a failed poll now means "not yet"; the state was verified from outside before anything was re-run |
| 9 | **The reserved volume tripped the %-free alert for good** | §9.5 — watched by what is on it instead |
| 10 | `stanza-create` given `--repo` — it takes none (it always acts on every repository in the config); and the failure message **guessed** a cause ("are the servers up?") while the real reason was printed above it | `--repo` dropped; failure messages now say "the lines above say why" — the output is the diagnosis |
| 11 | **The backup-store status fact emitted nothing** on the real stores (it read a JSON layout 2.50 does not use), so `DatabaseBackupStoreError` could never fire | caught by reading the live metrics after rollout; reads both layouts and falls back to the stanza's verdict (§10.8) |
| 12 | `FilesystemWillFillSoon` fired on host-1..3's database volumes after the re-reserve: `predict_linear` over 6 h drew a line through the 150 GB step of `fallocate` | an artefact of any reservation — it clears once the step leaves the 6-hour window, and recurs only when a data disk is created. Left as is: it is the fast-fill safety net for that volume |
| 13 | apt on the hosts prints **"Pending kernel upgrade … expected 6.8.0-138-generic"** | a false alarm: `needrestart` ranks the installed generic kernel above the running FIPS one; GRUB boots `GRUB_FLAVOUR_ORDER="fips"` — **do not "fix" it by removing or reordering kernels** |
| 14 | **The first rehearsal's summary said "0 errors, a clean load"** with errors in the log: psql prefixes `psql:<stdin>:N:` only with `-f`, and the dump was piped | `-f -`, the prefix optional, an unreadable ERROR line counted as `?????`; the rehearsal asserts the count. A test fixture typed from memory had carried the same assumption |
| 15 | **The real dump was refused twice by the script's own checks** — as "creates its own database" (it was an ordinary `pg_dump --create`), then for Windows line endings on 21 lines of the application's own function source | `--create` loads under the given name; line endings are refused only on data rows, where they would corrupt values |
| 16 | **`06a extensions`: apt stopped (state `T`) after installing**, then reported a failure that never happened — `timeout` runs it in a background process group and apt resets the terminal when dpkg ends | apt gets no terminal: `< /dev/null`, `Dpkg::Use-Pty=0` |
| 17 | **The first real load: 14 errors**, every one PostGIS refusing to install under pgaudit, and its knock-ons | the `CREATE EXTENSION postgis*` audit exception (§10a.6); reloaded with 0 errors |
| 18 | The load's terminal timed out before its summary was read | `app-restore summary` reprints it from the log; loads now record their duration there |

---

## 16. Not done yet

| | what | where |
|---|---|---|
| ⬜ | **A crash under a write load** — slice 4 proved promotion and rejoin with no writes running; zero loss under load needs a write generator | B-06a |
| ⬜ | **Slice 6:** the PostgreSQL 16 STIG scan (the XCCDF needs a CAC download), the org baseline, the Crunchy-vs-Ubuntu tailoring statement. The application's database is loaded (§10a); the empty-cluster scan needs it dropped and reloaded from the dump, which stays on the leader until then | B-06a, 6a.1, 6a.10, 6a.11 |
| ⬜ | **A written restore procedure** — replacing the cluster from a store after a disaster (slice 5 proved the backups restore; recovering the live cluster from them is a different operation), and a **scheduled** restore drill rather than a manual one | B-06a |
| ⬜ | **host-3's store sizing** — 100 GB reserved on its images pool. Measured 2026-09-29: 344 MB of the application's database is 75.5 MB per full; size it alongside 2.8 | B-06a, 2.8 |
| ⬜ | **Certificate renewal** — the pg nodes' and the stores' certificates expire **2027-09-28**, in three places per pg node. Watched since 2026-09-29 (`CertificateExpiringSoon`, 30 days ahead, backlog 3.45); renewal itself is still manual | B-06a |
| ⬜ | **Unattended certificates** — step D is three hand-carried round trips; the unattended rebuild cannot make them | 2.6 |
| ⬜ | A FIPS-built etcd from Canonical | Q-CORE (h), not sent; ENG-68 |
| ⬜ | Application users with logins and the connection string (`target_session_attrs=read-write` across the three nodes, runbook §9a.3) — the database itself is loaded (§10a) | B-07 |
| ❓ | **PostGIS** — the audit exception as a tailoring entry, and whether the application needs it at all | 3.49 |
| 🔴 | **pgBackRest repository encryption** before any copy to the lab recovery store | 3.50 |
| 🗳️ | Production sizing — the lab runs 2 vCPU / 4 GiB / 40 GB / 150 GB; `vm-specs.env`'s default of 8 GiB / 60 GB / 400 GB is explicitly not a production sizing | 2.8 |

**Key:** ⬜ open · 🗳️ a decision owed · ❓ a question for someone else · 🔴 blocks something.
