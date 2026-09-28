# Step 06a — PostgreSQL HA on pg-01..03, as built

> **BUILT 2026-09-27/28 — slices 1–3 of 6 passed.** Three guests, one per physical host, each
> running PostgreSQL 16 under Patroni with the database's own three-member etcd. pg-01 bootstrapped
> the cluster; the other two cloned from it and stream from it; one is synchronous. The nodes
> authenticate to each other **by certificate only** — there is no shared password anywhere.
> **Slices 4–6 are not built:** failover rehearsal and monitoring (4), WAL archive and
> point-in-time restore (5), the PostgreSQL STIG scan (6). **There is no backup of the database
> today** (§14).
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
  role 2026-09-28     LEADER                  replica              SYNC STANDBY
                        │                        ▲                       ▲
                        └── WAL stream, 5432/tcp, TLS, certificate auth ─┘

  etcd:   one member on each node, 2380/tcp between them (raft), 2379/tcp for Patroni
  quorum: 2 of 3 — lose any ONE host and etcd still has a quorum and PostgreSQL still has a
          leader and a synchronous standby. Lose two and it stops accepting writes, by design.
```

The roles move. Patroni chooses the leader and which replica is synchronous; after a failover, or
simply over time, they will not be what this picture shows — on 2026-09-28 the synchronous standby
changed from pg-02 to pg-03 without a failover (§13). **Ask the cluster, never assume** (§12).

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
 │  └─ postgresql.service   disabled — Debian's wrapper; there is no Debian cluster         │
 │                                                                                          │
 │  vda  40 GB   the OS                                                                     │
 │  vdb 150 GB   ext4, LABEL=pgdata, mounted at /var/lib/postgresql  nodev,nosuid,noexec    │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
 Nothing else listens on the network except sshd (22). node-exporter (9100) and
 postgres-exporter (9187) have firewall rows but are NOT installed yet — slice 4.
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
meant to be **reserved** — every block allocated when it is created, so that a full volume can
fail a backup copy but never a database write. **Today it is not** — see §13, item 6.

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
```

Steps A–C are step 06's mechanism (`docs/06-guest-vms.md`) applied to the three database guests —
**slice 1**. D–E are **slice 2**, F–G **slice 3**. Each is described below with the command as it
was run, what it does, what it writes, what it refuses, and how it was verified.

**Before any of it** (all done and verified before 2026-09-27; runbook §6.5, backlog 3.42/3.43):
host-1..3 hardened and VM-ready (libvirt, `br0`, `images` and `images-data` pools on separate
mounted volumes, the base image in place, `/etc/enclave-profile` saying `VM_PROFILE=lab`); the
PPSM register carrying 2379, 2380, 8008 and 9187 (§10); the enclave issuing CA on svc-mgmt-01; the
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
   `images-data/pg-0N-data.qcow2`, 150 GB, `preallocation=falloc` (reserved — §13 item 6).
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

One key and one certificate per node carry every TLS role the node has (§9). The key is made **on
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
| subject CN | `pg-01.enclave.internal` — **this exact string is what `pg_ident` maps to the database roles** (§9.3) |
| SAN | `DNS:pg-01.enclave.internal, DNS:pg-01, IP:10.2.20.165` — `ca.sh request` adds the name, the FQDN and the node's own IP |
| key | RSA 3072, made on the node |
| purpose | `serverAuth` **and** `clientAuth` — `--peer`. Every etcd member is a server to its peers and a client to them at once; a plain server certificate fails the peer handshake with an error naming the *cipher*, not the purpose |
| chain | leaf + issuing CA; verifies to the enclave root |
| valid until | **2027-09-28** — and nothing watches it yet (§15) |

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
   and names the stale-`initialize` trap if that is what it sees (§13 item 2).

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
| `authentication.replication` / `.rewind` | `replicator` / `rewinder`, `sslmode verify-full`, `sslcert/sslkey/sslrootcert` = the node certificate | **no password** — the node's certificate is the credential (§9.3) |

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
that did not exist yet, exited non-zero, and Patroni cancelled the bootstrap (§13 item 1). So it
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

## 9. Who talks to whom, and how each proves who it is

### 9.1 The flows

```
  FROM               TO             PORT       WHAT                        AUTHENTICATION
  ─────────────────  ─────────────  ─────────  ──────────────────────────  ─────────────────────────
  etcd member        etcd member    2380/tcp   raft (peer)                 mutual TLS, node certs
  Patroni            etcd (any)     2379/tcp   leader lock, config (DCS)   mutual TLS, node cert
  Patroni            Patroni        8008/tcp   REST, in a leader race      TLS; client cert to change
  replica            leader         5432/tcp   WAL stream, basebackup      hostssl + CERT → replicator
  old leader         new leader     5432/tcp   pg_rewind after failover    hostssl + CERT → rewinder
  Patroni            local postgres  socket    management                  peer (OS user postgres)
  svc-obs-01         Patroni        8008/tcp   /metrics            slice 4  reads open, TLS
  svc-obs-01         exporters      9100,9187  metrics             slice 4  NOT INSTALLED YET
  k8s-wk-01..04      leader         5432/tcp   applications         B-07    hostssl + scram-sha-256
```

### 9.2 One key, used five ways

```
 /etc/ssl/enclave/pg-0N.key   (0640 root:root — made here by ca.sh request, never copied off)
   │
   ├─ copy → /etc/etcd/pki/member.key      0640 root:etcd       etcd server 2379, peer 2380, etcdctl
   │
   └─ copy → /etc/patroni/pki/node.key     0640 root:postgres   Patroni REST API 8008
                                                                Patroni as etcd client
                                                                PostgreSQL server TLS 5432
                                                                replication + rewind client (cert)
 with the same certificate beside each copy (member.crt / node.crt) and the enclave root (ca.crt)
```

Two copies on the same machine, each readable by exactly one service account. When the
certificate is renewed (before 2027-09-28), **both** copies and **both** certificates must be
replaced and both services restarted — there is no procedure for that yet (§15).

### 9.3 `pg_hba` and `pg_ident` — the whole access list

Generated by Patroni from `config.yml`; the full list, in order. **Anything that matches no line
is rejected.**

| type | database | user | address | method | who uses it |
|---|---|---|---|---|---|
| `local` | all | `postgres` | — | `peer` | Patroni and an administrator, as the OS user `postgres` on the node |
| `hostssl` | replication | `replicator` | each pg node /32 | `cert map=pgnodes` | replicas streaming and cloning |
| `hostssl` | all | `rewinder` | each pg node /32 | `cert map=pgnodes` | `pg_rewind` after a failover |
| `hostssl` | all | all | each K8S worker /32 | `scram-sha-256` | applications — **no application database or user exists yet** |

```
 pg_ident  map pgnodes:   pg-01.enclave.internal → replicator     pg-01.enclave.internal → rewinder
                          pg-02.enclave.internal → replicator     pg-02.enclave.internal → rewinder
                          pg-03.enclave.internal → replicator     pg-03.enclave.internal → rewinder
```

`cert` means PostgreSQL checks the client's certificate chains to the enclave root **and** that
its CN is mapped to the role being asked for. A node proves it is a pg node by holding a key only
it has; there is no shared replication password to make, carry on a stick, keep or rotate
(decided 2026-09-28, HANDOFF §3). `patroni-check` proves no `md5`, `password` or `trust` line and no
non-TLS network line exists.

---

## 10. Ports and firewall

Each pg node has 20 ufw rules from `stig-tailor.sh ufw` (its table in `stig-tailor.sh`, sources
from the address file). Every port is in the PPSM register `scripts/enclave/ppsm-services.tsv`, and
`stig-tailor.sh ufw` refuses a port that is not (D5). The table was active from the guest's first
hardening pass, default deny.

| port | rule | from | rules | what |
|---|---|---|---|---|
| 22/tcp | limit | any | 1 | SSH — `limit` is 6 new connections per 30 s per source |
| 9100/tcp | limit | svc-obs-01 | 1 | node-exporter — **not installed yet** |
| 5432/tcp | **allow** | k8s-wk-01..04, pg-01..03 | 7 | PostgreSQL. `allow`, not `limit`: a connection pool reconnecting after a failover must not be banned |
| 2379/tcp | allow | pg-01..03 | 3 | etcd client API |
| 2380/tcp | allow | pg-01..03 | 3 | etcd peer |
| 8008/tcp | allow | pg-01..03, svc-obs-01 | 4 | Patroni REST API |
| 9187/tcp | limit | svc-obs-01 | 1 | postgres-exporter — **not installed yet** |

2379, 2380, 8008 and 9187 are in the register with CAL `-`: no PPSM Category Assurance List entry
could be verified from inside the gap.

---

## 11. Files on a pg node

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
| `/etc/patroni/config.yml.in`, `dcs.yml` | 0644 root:root | the Ubuntu `patroni` package | Ubuntu's templates — **not used** |

The two 0600 files are written under the hardened umask (077); only root and systemd read them,
which is all they need.

---

## 12. Operating it

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

**Do not:**

- edit `postgresql.conf` or `pg_hba.conf` by hand — Patroni rewrites both on its next start. A
  setting changes in `config.yml` (and the DCS), through the script;
- `systemctl start postgresql` or `pg_ctl` — Patroni starts and stops PostgreSQL; a second
  postmaster is the failure this design exists to avoid;
- stop etcd on two nodes at once — that is the quorum;
- delete keys under `/enclave/enclave-pg/` while any Patroni is running (§13 item 2 is the only
  time to);
- read the journals as `encadmin` and trust the answer — `journalctl` is permission-denied without
  sudo on a hardened guest, and a count taken that way is zero because nothing was read.

---

## 13. What went wrong on the way, and what the build now does about it

| # | what happened | fixed by |
|---|---|---|
| 1 | **Run 1 on pg-01, 2026-09-28:** `post_bootstrap` ALTERed `replicator`/`rewinder` before Patroni had created them, exited 3; Patroni cancelled the bootstrap and systemd restarted it **34 times**, each leaving a `*.failed` data directory. The wait printed a **false `[ok]`** — it accepted "running" in passing | `post_bootstrap` **creates** the roles; `StartLimitBurst=5` in 10 min; the wait needs the right role held for 15 s |
| 2 | **Run 2:** Patroni had been stopped mid-bootstrap, so its claim `/enclave/enclave-pg/initialize` stayed in etcd; every start sat on "waiting for leader to bootstrap" with no leader anywhere. Patroni removes the key when a bootstrap *fails*, not when it is *killed* | diagnosed from the key list; stopped Patroni, confirmed no leader key, deleted the cluster's keys and the never-initialised data directory, re-ran. `06a patroni` now **names this** when it sees it — and never clears it automatically, since another node may really be bootstrapping |
| 3 | etcd's package starts its own single-node etcd on install | installed under `policy-rc.d`; own data directory |
| 4 | Ubuntu's `postgresql-16` creates `16/main` | `create_main_cluster = false` before install; refuse if any cluster exists |
| 5 | The draft named `python3-etcd3` | `python3-etcd` — what Patroni 3.2.2 depends on |
| 6 | **The data disks are no longer reserved (found 2026-09-28).** The host attached them `discard=unmap`; `mkfs.ext4` TRIMs the whole device by default, and the TRIM punched holes straight through the falloc reservation — 161 GB released on each host within the hour slice 3 formatted it. The files are now **0.1–0.2 % allocated** | new disks: `discard=ignore` and `mkfs -E nodiscard`; `03-compose-vm.sh plan` checks the files; alert `DataDiskNotReserved` (firing for all three, correctly). **The three existing disks are re-reserved inside slice 4** (decided) — until then the only protection is that nothing else now writes to their volume (backlog 3.42) |
| 7 | **The clock correction of 2026-09-28** stepped every machine back 10.9 s (backlog 3.39) | the cluster stayed on timeline 1, no failover, no restarts, lag 0. The synchronous standby is now pg-03 (was pg-02); when and why is not known without reading the journal with sudo |

---

## 14. There is no backup of the database today

**pg-01..03 are not covered by any backup.** `vm-backup.sh` runs on host-4 only and protects its
four service VMs (`enclave_backup_domains_protected` = 4, all svc-*; read 2026-09-28). There is
no WAL archive (slice 5). **Replication is not a backup** — a bad write, a dropped table or a
corrupted page replicates to every standby in milliseconds.

It costs nothing today because the cluster is empty — no application database exists. It becomes
real the day an application writes. Backlog **3.46**.

---

## 15. Not done yet

| | what | where |
|---|---|---|
| ⬜ | **Slice 4:** switchover, a timed hard failover, loss of an etcd member, postgres-exporter and Patroni `/metrics` scraped by svc-obs-01, the **synchronous-degradation alert** that makes `synchronous_mode_strict` off defensible — **and re-reserving the three data disks** one node at a time | B-06a, 3.42 |
| ⬜ | **Slice 5:** WAL archive (pgbackrest) and a point-in-time restore | B-06a, 1.2 |
| ⬜ | **Slice 6:** the PostgreSQL 16 STIG scan (the XCCDF needs a CAC download), the org baseline, the Crunchy-vs-Ubuntu tailoring statement | B-06a, 6a.1, 6a.10, 6a.11 |
| ⬜ | **Any backup at all** | 3.46 |
| ⬜ | **Certificate renewal** — the node certificates expire **2027-09-28**, in two places per node, and the cert-expiry facts do not look in `/etc/etcd/pki` or `/etc/patroni/pki` | B-06a |
| ⬜ | **Unattended certificates** — step D is three hand-carried round trips; the unattended rebuild cannot make them | 2.6 |
| ⬜ | node-exporter on the pg nodes, and their scrape targets — they report nothing to Prometheus yet | 3.39 |
| ⬜ | A FIPS-built etcd from Canonical | Q-CORE (h), not sent; ENG-68 |
| ⬜ | Application database, users and the connection string (`target_session_attrs=read-write` across the three nodes, runbook §9a.3) | B-07 |
| 🗳️ | Production sizing — the lab runs 2 vCPU / 4 GiB / 40 GB / 150 GB; `vm-specs.env`'s default of 8 GiB / 60 GB / 400 GB is explicitly not a production sizing | 2.8 |

**Key:** ⬜ open · 🗳️ a decision owed.
