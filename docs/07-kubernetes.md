# 07 — Kubernetes (backlog B-07)

**Status: 🔄 IN PROGRESS. The cluster has been running since 2026-10-14 (03:15–04:00 UTC):** seven nodes
`Ready`, `high availability: yes` (three etcd voters), every pod Running, load balancer enabled.
**Verified 2026-10-14 15:10 UTC — `07-kubernetes.sh verify`, all 28 checks passed** (§4); **the API VIP live the
same day** (§3.10). **Still owed:** the survivability tests (K-B was reversed — ssh stays on the workers, §2). The live list is `docs/backlog.md` row B-07; this document is
the procedure and the record of how it was built.

The script is [`scripts/install/07-kubernetes.sh`](../scripts/install/07-kubernetes.sh). Every
command below names its machine and refuses to run on any other.

---

## 1. The picture

| node | host | IPv4 | IPv6 | role | lab size |
|---|---|---|---|---|---|
| k8s-cp-01 | host-1 | 10.2.20.171 | fd6e:32f0:f4b3:20::171 | control plane, etcd | 2 vCPU · 6 GiB · 60 GB |
| k8s-cp-02 | host-2 | 10.2.20.172 | fd6e:32f0:f4b3:20::172 | control plane, etcd | 2 · 6 · 60 |
| k8s-cp-03 | host-3 | 10.2.20.173 | fd6e:32f0:f4b3:20::173 | control plane, etcd | 2 · 6 · 60 |
| k8s-wk-01 | host-1 | 10.2.20.181 | fd6e:32f0:f4b3:20::181 | worker | 4 · 12 · 60 |
| k8s-wk-02 | host-2 | 10.2.20.182 | fd6e:32f0:f4b3:20::182 | worker | 4 · 12 · 60 |
| k8s-wk-03 | host-3 | 10.2.20.183 | fd6e:32f0:f4b3:20::183 | worker | 4 · 12 · 60 |
| k8s-wk-04 | host-4 | 10.2.20.184 | fd6e:32f0:f4b3:20::184 | worker | 4 · 12 · 60 |

Addresses, ranges and placement have one home each: `scripts/enclave/enclave-addresses.env` and
`scripts/enclave/vm-specs.env`. A node's IPv6 address is **derived, not stored**: the node /64 plus
the digits of its IPv4 last octet (the address file says why there is no per-node key).

| range | IPv4 | IPv6 | note |
|---|---|---|---|
| node network | 10.2.20.0/24 | fd6e:32f0:f4b3:20::/64 | ULA `fd6e:32f0:f4b3::/48`, RFC 4193, generated once |
| pods | 10.1.0.0/16 | fd6e:32f0:f4b3:1::/108 | set at bootstrap, never changeable |
| services | 10.152.183.0/24 | fd6e:32f0:f4b3:152::/108 | /108 is Canonical's maximum |
| LoadBalancer pool | .200 – .250 | :20::200 – :20::250 | layer-2 announcement, on the node network |
| API VIP | 10.2.20.170 | — | keepalived on cp-01..03, VRRP unicast — **live 2026-10-14** |

**What runs:** Canonical Kubernetes **v1.36.4, snap rev 5526** (Q23), on base **`core22`
20260125+fips, rev 2383**, installed by **`snapd` 2.78+fips, rev 28333** — all three side-loaded
from the in-gap mirror, verified by snapd against Canonical's signed assertions, refresh held.
etcd on the three control planes; Cilium (kube-proxy replacement); CoreDNS; metrics-server;
MetalLB in L2 mode; the built-in gateway (Gateway API, decided 2026-10-02). **Only the seven
nodes have IPv6**; every other machine, the API VIP and the storage network stay IPv4.

## 2. Decisions

| | decision | date / by | why |
|---|---|---|---|
| A1 | The cluster's images come from **Harbor only**, carried as OCI layouts in the mirror's `oci/` tree | 2026-10-14, Brian | one route for lab and production; `images.lock` is the chain of custody |
| — | **amd64 only**; Harbor project **`canonical`, public read** | 2026-10-14 | Canonical's own amd64 digest, half the transfer; containerd's `hosts.toml` has no place for a credential, and the images are public upstream |
| A2 | The dual-stack address plan above | 2026-10-14, Brian | ranges can never change after bootstrap |
| — | **Four workers in the lab too, wk-04 on host-4** | 2026-10-14, Brian | Ceph at replica-3 on three OSD nodes cannot self-heal — but see backlog 3.48 |
| A3 | A ufw table for every node, sources narrowed; **routed rules for the pod ranges only** once measured (§5, trap 7) | 2026-10-14, Brian | Canonical's narrower option, never `DEFAULT_FORWARD_POLICY=ACCEPT` |
| K-A | **API audit policy: a narrow, documented deviation from V-242403** — Secrets, `serviceaccounts/token` and `tokenreviews` at `Metadata`; everything else `RequestResponse` | 2026-10-14, Brian | the STIG's exact policy writes every Secret's value into a log that is offloaded to svc-obs-01 and copied to the vault and the NAS |
| K-B | ~~sshd off on the workers~~ → **REVERSED the same day: sshd stays ON on the workers** | 2026-10-14, Brian | the only other way in is `virsh console` from each host — and everything run on a worker (the repo push, `verify --fips-only`, patching, the rebuild tooling) goes over ssh. The STIGs conflict anyway: the Ubuntu 24.04 STIG's **UBTU-24-100810 requires sshd enabled**, the Kubernetes STIG's **V-242393/242394 require it off** on workers — so V-242393/394 stay **open, accepted** (POA&M AO-21). ssh on a worker is key-only, FIPS ciphers, `ufw limit`, the DoD banner — as on every machine |
| 3.64 | **Secrets encrypted at rest with `aesgcm`**, the keys derived on each control plane from one sealed passphrase (`K8S_SECRETS_PASS`), rotated by raising `K8S_SECRETS_GEN` | 2026-10-15, Brian | Kubernetes STIG **V-274882 (CAT I)** was open — every Secret plain in etcd. `aesgcm` over `aescbc`: Kubernetes calls CBC weak, and a rotation procedure is owed under either (§3.12) |
| K-C | **Pod Security `baseline`** (Canonical's default, V-254800) | 2026-10-14, Brian | the vendor's images are unmeasured; revisit `restricted` once they run |
| — | **snapd: the FIPS build** from `fips-updates/candidate` | 2026-10-14, Brian | `fips-updates/stable` was empty; snapd verifies every snap's signature. Q-CORE asks when stable carries it |
| — | local-storage **off**; CoreDNS forwards to the **enclave DNS**; `--address` always explicit | 2026-10-14 | node-local volumes do not survive their node; the node resolver 127.0.0.53 means nothing in a pod; there is no default route to find |

The STIG arguments are **Canonical's own**, read from the pinned snap
(`/snap/k8s/current/k8s/resources/configurations/disa-stig/{bootstrap,control-plane,worker}.yaml`).
`render_config` takes them as written and replaces only `--audit-policy-file` (K-A) and
`--admission-control-config-file` (K-C, the same baseline file named explicitly), and adds
`--node-ip <v4>,<v6>` and, on control planes, `--encryption-provider-config` (3.64 — the file's name
only; the keys never enter the bootstrap or join config, which is printed). Canonical's audit-policy file says *Metadata* in its comment while its one
rule is `RequestResponse` — the rule is what applies, and is what V-242403 demands.

## 3. The sequence — as run 2026-10-14

### 3.1 Images into Harbor (step A1)

```bash
### MACHINE: stage-01 (10.2.10.160) ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  cd ~/canonical-k8s
  sudo ./scripts/install/07-kubernetes.sh images-export      # refuses off STAGE_01; ~15 min at ghcr's ~0.7 MB/s
  ./scripts/install/07-kubernetes.sh images-load && ./scripts/install/07-kubernetes.sh images-check
fi
```

`images-export` reads the list from the pinned snap's own `images.txt` (12 images for rev 5526),
writes `mirror/oci/k8s-5526/` and `images.lock`. `images-load` refuses a layout whose digest is not
the lock's, then pushes; `images-check` reads every image back **with no credentials**, the way
containerd will. In production the load runs on svc-harbor-01 — **see §7: the in-gap fetch from
`/oci/` does not work as the runbook describes it.**

### 3.2 Credentials and audit keys (lab route — production uses the stick, `airgap-media.md` §9)

```bash
### MACHINE: stage-01 (10.2.10.160) ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  mkdir -p ~/credk8s && ~/canonical-k8s/scripts/transfer/make-credentials.sh -o ~/credk8s --any-dir --machines k8s-cp-01,k8s-cp-02,k8s-cp-03,k8s-wk-01,k8s-wk-02,k8s-wk-03,k8s-wk-04
  scp -p -i ~/.ssh/build01 ~/credk8s/audit-collector.authorized_keys encadmin@10.2.20.164:~/
fi
```

```bash
### MACHINE: svc-obs-01 (10.2.20.164) ###
if [ "$(hostname -s)" != svc-obs-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/enclave/audit-offload.sh collector-trust ~/audit-collector.authorized_keys && rm ~/audit-collector.authorized_keys
fi
```

The collector must trust a node's key **before** that node's `auditoffload` step runs.

### 3.3 Compose, harden, finish (B1 — the 06 mechanism, unchanged)

From stage-01, push the repo to the host and copy that guest's two files to it
(`scp -p -i ~/.ssh/build01 ~/credk8s/credentials.<vm>.env ~/credk8s/audit-offload.<vm>.key
encadmin@<host>:~/`). Then on the host — **round 1**, the control planes and wk-04 (one control
plane first, the rest once it is past `tailor`):

```bash
### MACHINE: host-1, host-2, host-3 or host-4 — the same block on each ###
case "$(hostname -s)" in host-1) V=k8s-cp-01 ;; host-2) V=k8s-cp-02 ;; host-3) V=k8s-cp-03 ;; host-4) V=k8s-wk-04 ;; *) V="" ;; esac
if [ -z "$V" ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo install -D -o root -g root -m 600 ~/credentials.$V.env /root/cred-$V/credentials.$V.env \
    && sudo install -o root -g root -m 600 ~/audit-offload.$V.key /root/cred-$V/audit-offload.$V.key \
    && shred -u ~/credentials.$V.env ~/audit-offload.$V.key && echo "placed root-only"
  cd ~/canonical-k8s/scripts/install \
    && sudo ./03-compose-vm.sh $V --harden --cred-dir /root/cred-$V \
    && sudo shred -u /root/cred-$V/credentials.$V.env /root/cred-$V/audit-offload.$V.key && echo "host copies shredded"
fi
```

**Round 2**, the workers on host-1..3 — the same block with
`case "$(hostname -s)" in host-1) V=k8s-wk-01 ;; host-2) V=k8s-wk-02 ;; host-3) V=k8s-wk-03 ;; *) V="" ;; esac`.

Each guest hardens itself unattended (~16–20 min; all seven `DONE pass=211 fail=4`), then
`sudo ./03-compose-vm.sh $V --finish` on its host. The composer gives a k8s node its IPv6 address
in the network config, and refuses if `K8S_NODE_V6_NET` is missing. One control plane first, then
the rest in parallel; a worker sharing a 4-thread host with a hardening control plane slows both.

### 3.4 Trust each node's host key — against its console, not on first use

Each guest prints its host-key fingerprints to its serial console at first boot; the host logs it.
`push-repo-to-host.sh` refuses an unknown key, correctly. This trusts a node only when every key
it offers on the network matches its console record (`host:vm:last-octet` per entry):

```bash
### MACHINE: stage-01 (10.2.10.160) ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  for p in 155:k8s-cp-01:171 155:k8s-wk-01:181 156:k8s-cp-02:172 156:k8s-wk-02:182 157:k8s-cp-03:173 157:k8s-wk-03:183 158:k8s-wk-04:184; do
    IFS=: read -r h v a <<< "$p"
    con="$(ssh -i ~/.ssh/build01 -o BatchMode=yes encadmin@10.2.20.$h "cat /var/lib/libvirt/images/console/$v-console.log*" 2>/dev/null | tr -d '\r' | grep -oE 'SHA256:[A-Za-z0-9+/]+' | sort -u)"
    keys="$(ssh-keyscan -T 5 -t ecdsa,rsa 10.2.20.$a 2>/dev/null)"
    fps="$(printf '%s\n' "$keys" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
    n=0; bad=0
    for fp in $fps; do n=$((n+1)); printf '%s\n' "$con" | grep -qxF "$fp" || bad=1; done
    if [ "$n" -gt 0 ] && [ "$bad" -eq 0 ]; then printf '%s\n' "$keys" >> ~/.ssh/known_hosts && echo "$v: $n key(s) match its console - trusted"
    else echo "$v: NOT trusted - $n key(s) offered, a mismatch or no console record"; fi
  done
fi
```

Then `./scripts/install/push-repo-to-host.sh <address>` to each node. The hardened guests offer
RSA and ECDSA only (FIPS); the console also lists ed25519.

### 3.5 Prepare every node (B2)

```bash
### MACHINE: each k8s node — the same block on all seven ###
case "$(hostname -s)" in k8s-cp-0[1-3]|k8s-wk-0[1-4]) sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh node-prep ;; *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

In order: FIPS kernel and both addresses present → kubelet's six kernel settings written **and
read back** (`/etc/sysctl.d/99-kubelet.conf`) → snapd, core22, k8s side-loaded (each refused if not
the pinned revision; snapd and core22 refused if not `+fips`) → refresh held → containerd's
`ghcr.io` pointed at Harbor with the enclave root (`/etc/containerd/hosts.d/ghcr.io/`) → on control
planes, the K-A audit policy and — on a control plane **not yet in a cluster** — the Secrets
encryption config (§3.12; it asks for `K8S_SECRETS_PASS` unless the credentials file holds it). Safe to
repeat: on a running control plane it never touches that config.

### 3.6 Bootstrap the first control plane

```bash
### MACHINE: k8s-cp-01 (10.2.20.171) ###
if [ "$(hostname -s)" != k8s-cp-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh bootstrap
fi
```

Prints the generated config, runs `k8s bootstrap --file … --address 10.2.20.171`, **checks
containerd's real `config_path` before the ready-wait**, then waits for ready.
`sudo …/07-kubernetes.sh render` prints the config any node would use, changing nothing.

### 3.7 Join the other six — tokens travel as files

```bash
### MACHINE: k8s-cp-01 (10.2.20.171) ###
if [ "$(hostname -s)" != k8s-cp-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh join-tokens     # one 0600 file per node, never printed
fi
```

```bash
### MACHINE: stage-01 (10.2.10.160) ###
if [ "$(hostname -s)" != stage-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  O="-i $HOME/.ssh/build01 -o BatchMode=yes -o ControlMaster=auto -o ControlPath=$HOME/.ssh/cm-%C -o ControlPersist=60"
  for p in k8s-cp-02:172 k8s-cp-03:173 k8s-wk-01:181 k8s-wk-02:182 k8s-wk-03:183 k8s-wk-04:184; do
    n=${p%%:*}; a=10.2.20.${p#*:}
    scp -3 -p $O encadmin@10.2.20.171:k8s-join-tokens/$n.token encadmin@$a:k8s-join.token && echo "$n: token copied"
  done
  ssh $O encadmin@10.2.20.171 'shred -u ~/k8s-join-tokens/*.token && rmdir ~/k8s-join-tokens'
fi
```

One shared ssh connection to cp-01: six separate copies would trip its `ufw limit` (6 per 30 s).

```bash
### MACHINE: the joining node — cp-02, wait; cp-03, wait; then the four workers ###
case "$(hostname -s)" in k8s-cp-0[23]|k8s-wk-0[1-4]) sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh join ;; *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

`join` reads `~/k8s-join.token`, shape-checks it, joins as control plane or worker by its address,
checks containerd's path, and shreds the spent token. Control planes **one at a time** — each adds
an etcd member.

### 3.8 After the last worker joins — the load balancer

```bash
### MACHINE: k8s-cp-01 (10.2.20.171) ###
if [ "$(hostname -s)" != k8s-cp-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo k8s enable load-balancer && sudo k8s status
fi
```

**Expected on every fresh build, not a fault:** MetalLB fails at bootstrap because its controller
may not run on a control plane (the H3 taint) and no worker exists yet. Re-apply once workers are
in. Not yet scripted (backlog 3.60).

### 3.9 Verify — repeatable, read-mostly

```bash
### MACHINE: k8s-cp-01 (any control plane) ###
if [ "$(hostname -s)" != k8s-cp-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh verify
fi
```

Five sections, each line `[ok]` or `[x]`, failing if any `[x]`: the cluster; FIPS in this node's
processes; DNS; a dual-stack LoadBalancer Service; the K-A audit policy (a probe Secret whose value
must not appear in the log, plain or base64, while its create is logged at `Metadata`). It leaves a
test workload running — namespace `enclave-verify`, the cluster's own CoreDNS image answering
`whoami` on four replicas, one per worker — as the target for the survivability tests;
`verify --cleanup` removes it. `verify --fips-only` checks one node's processes, on any node.

### 3.10 The API VIP

```bash
### MACHINE: k8s-cp-01, k8s-cp-02, k8s-cp-03 — the same block on each ###
case "$(hostname -s)" in k8s-cp-0[1-3]) sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh vip ;; *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

keepalived from the mirror (`--no-install-recommends`; its net-snmp dependency still brings Perl —
1–2 min), VRRP unicast to the other two, id = the VIP's last octet, priority 130/120/110 by node
number with `nopreempt` (one move per failure). The health check carries **no credentials**:
anonymous access is off, so a healthy API server answers `/livez` with 401 — that or 200 is "up".
It does not notice an API server that runs but has lost etcd, a cluster-wide event a VIP move would
not fix. The VIP serves clients outside the cluster (svc-mgmt-01, svc-obs-01); inside, each worker's
`k8s-apiserver-proxy` spreads over all three API servers already.

### 3.11 The etcd drill — and the real restore

```bash
### MACHINE: k8s-cp-01 (any control plane) ###
if [ "$(hostname -s)" != k8s-cp-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh etcd-drill
fi
```

`etcdctl` and `etcdutl` are **not in the k8s snap**, and Ubuntu's `etcd-client` is 3.4 with no `etcdutl`;
the cluster runs **etcd v3.6.13** (the snap's `bom.json`). So the tools are etcd's own v3.6.13 release,
verified against etcd's published `SHA256SUMS` on stage-01 and staged on the mirror as
`/bin/etcdctl-v3.6.13` and `/bin/etcdutl-v3.6.13` (like `regctl`). They are standard Go builds, **not
FIPS** — drill and recovery tools, never a running service. The drill refuses tools that do not match
the running snap's etcd, keeps them only in its temp directory, and **shreds** the snapshot and the
restored copy: both hold every Secret in the cluster.

**A real restore** — a majority of control planes lost, at least one survivor — is Canonical's
*Recover a cluster after quorum loss*
(<https://documentation.ubuntu.com/canonical-kubernetes/latest/snap/howto/restore-quorum/>, read
2026-10-15): `sudo snap stop k8s` on every survivor; `k8sd cluster-recover` on the one with the newest
Raft log (`/var/snap/k8s/common/var/lib/k8sd/state/database`), lost nodes set to `spare`, its
`recovery_db.tar.gz` copied to every survivor; an `etcdctl snapshot save` on one survivor (client
certificate `/etc/kubernetes/pki/apiserver-etcd-client.{crt,key}`); `etcdutl snapshot restore` on every
survivor into `/var/snap/k8s/common/var/lib/etcd/data` with each node's own `--name`,
`--initial-advertise-peer-urls` and the combined `--initial-cluster`, read from
`/var/snap/k8s/common/args/etcd`; `sudo snap start k8s`; `k8s status --wait-ready`. It recovers k8sd's
store and etcd only — **not persistent volumes**. Not rehearsed here: the drill proves the snapshot and
the tools; rehearsing the whole procedure needs a cluster it is safe to break.

### 3.12 Secrets encrypted at rest (backlog 3.64, STIG V-274882)

**Why.** On 2026-10-15 the API servers had no `--encryption-provider-config`: every Secret was plain
in etcd, in every etcd snapshot and in every disk copy of a control plane. Kubernetes STIG V-274882
(CAT I): *"If the setting encryption-provider-config is not configured, this is a finding … If the
identity provider is specified as the first provider for the resource, this is also a finding."*
Canonical's STIG configuration does not cover it. The STIG's check reads `/etc/kubernetes/manifests`;
Canonical has no manifests — the equivalent is `/var/snap/k8s/common/args/kube-apiserver`, and the
proof is what etcd holds (`encrypt check`).

**The provider** — Kubernetes' own table (`encrypt-data.md`, kubernetes/website, read 2026-10-15):
`aescbc` *"Weak"*, *"Not recommended due to CBC's vulnerability to padding oracle attacks"*; `aesgcm`
*"Must be rotated every 200,000 writes"*, *"Not recommended for use except when an automated key
rotation scheme is implemented"*; both *"Key material accessible from control plane host"*;
`secretbox` is XSalsa20, **not FIPS-approved**; `kms v2` needs a key service the enclave does not
have. **`aesgcm`, decided by Brian 2026-10-15.** The rotation here is **scripted, run by an operator
on a schedule — not a timer**: whether that is the "automated scheme" Kubernetes means is a judgement
for the assessor, recorded in POA&M ENG-76. The API server is Go's OpenSSL build
(`GOEXPERIMENT=opensslcrypto`, calling `EVP_aes_256_gcm` — read from the snap's own binary) and runs
with the FIPS provider loaded (§3.9). `K8S_SECRETS_PROVIDER=aescbc` is the one-line alternative for a
new cluster; switching a live one is not built.

**The keys** derive on each control plane from one passphrase, `K8S_SECRETS_PASS` —
PBKDF2-HMAC-SHA256, 600,000 iterations, salt `k8s-secrets-at-rest/gen<N>` — held like the pgBackRest
passphrase: the site credentials, a sealed envelope marked with its fingerprint (`airgap-media.md`
§9.6). So the three API servers and any rebuild compute the **same** keys and no key is ever copied
between machines. The config, `/var/snap/k8s/common/etc/configurations/enclave-encryption.yaml`
(root 0600), holds the derived keys — **never print it**. Its `# enclave-state:` line says which key
writes and lists each key's fingerprint, not the key.

**Steps, because there are three API servers** (Kubernetes' procedure): a Secret written by an API
server holding the new key cannot be read by one without it. So **stage** gives every API server the
key without using it; **apply** makes each write with it; **rewrite** stores every existing Secret
again; **retire** — once etcd proves every Secret is under the new key — removes the older key and the
plain-text reader (`identity`), Kubernetes' last two steps. Each config change restarts that node's API server (`snap restart k8s.kube-apiserver`) — if it
holds the VIP, the VIP moves (3–4 s, C1).

**Run it — one block at a time, in this order.** First commit, then push the repository to the three
control planes (`push-repo-to-host.sh` sends `HEAD`).

```bash
### MACHINE: k8s-cp-01 (10.2.20.171) — 0. the check, BEFORE anything changes: it must report every Secret PLAIN ###
if [ "$(hostname -s)" != k8s-cp-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh encrypt check
fi
```

Expected: `V-274882: OPEN`, every Secret counted as plain, and etcd's count matching the API's. This
is the check seen failing before it is trusted to pass — the 2026-10-15 probe lesson. A count of 0, or
etcd and the API disagreeing, is reported as *the check did not work*, never as a pass.

```bash
### MACHINE: k8s-cp-01, then k8s-cp-02, then k8s-cp-03 — 1. STAGE, one at a time ###
case "$(hostname -s)" in k8s-cp-0[1-3]) sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh encrypt stage ;; *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

Asks for the passphrase twice (unless the credentials file holds it) and prints its **fingerprint —
it must be the same on all three**. Writes the config with `identity` still first, adds the argument,
restarts, and proves the restarted API server still reads every Secret.

```bash
### MACHINE: k8s-cp-01, then k8s-cp-02, then k8s-cp-03 — 2. APPLY, only after all three are staged ###
case "$(hostname -s)" in k8s-cp-0[1-3]) sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh encrypt apply ;; *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

No passphrase: it reorders the keys already staged. Then a **canary** Secret is written through this
API server and read back through all three by address — the proof that every API server holds the
same key. A control plane that cannot read it was not staged: stage it **at once**.

```bash
### MACHINE: k8s-cp-01 (10.2.20.171) — 3. REWRITE, once, after all three apply ###
if [ "$(hostname -s)" != k8s-cp-01 ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh encrypt rewrite
fi
```

Refuses unless a canary written through **each** control plane is stored under the current key, read
raw from etcd. Then Kubernetes' documented `kubectl get secrets -A -o json | kubectl replace -f -`,
piped, never to a file. A conflict, from a Secret changed in between, gets retried. It ends with
`encrypt check`, which must now say every Secret is under the current key.

```bash
### MACHINE: k8s-cp-01, then k8s-cp-02, then k8s-cp-03 — 4. RETIRE, after the rewrite ###
case "$(hostname -s)" in k8s-cp-0[1-3]) sudo ~/canonical-k8s/scripts/install/07-kubernetes.sh encrypt retire ;; *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

Runs `encrypt check` itself and refuses unless every Secret is under the current key. Then the config
keeps only that key: the older one goes, and so does `identity`, so this API server can no longer
serve a Secret stored in the clear. It restarts and proves it still reads every Secret. Then `verify`:
section 6 checks this node's API server.

**A new cluster** needs no stage, apply or rewrite. `node-prep` writes the config, with the key
writing, on each control plane before its API server first starts. `render_config` adds the argument
to the bootstrap and join configs. After the build: `encrypt check`, then `encrypt retire` on each
control plane.

**Rotation** uses the same steps. Raise `K8S_SECRETS_GEN` in `07-kubernetes.sh` by one and commit it:
a control plane rebuilt later reads it there. Then push, stage ×3, apply ×3, rewrite, retire ×3. Rotate
at the annual review, or sooner if `encrypt check`'s write count nears 200,000. `stage` derives every
key the node already holds again and compares it, so a mistyped passphrase is refused rather than
stored. Retiring an old key **does** protect something. The passphrase never sits on the host, so a
later compromise of a control plane cannot read etcd snapshots taken under a retired key. To read
such a snapshot, derive its key again from the envelope with `K8S_SECRETS_GEN=<old> encrypt stage`.
Rotation serves AES-GCM's per-key write limit, **not a compromise**: a leaked passphrase needs a new
passphrase, and a re-key procedure that accepts one is **not built**.

**What it protects, and what not** (Kubernetes says it plainly: a key held on the host *"fails to
protect against a host compromise"*). Protected: etcd's data read through its client port, etcd
snapshots and the G9 backups, as long as the passphrase is not with them. **Not** protected: anyone
with root on a control plane, or with a disk copy of one — the key file sits beside etcd on the same
disk. Against stolen drives, LUKS on the hosts covers both. KMS v2 with an external key service would
close the gap; the enclave has none (§7).

**Backing out** one node, while no Secret is yet stored under a key that node would lose:
`sudo cp -p /var/snap/k8s/common/args/kube-apiserver.pre-3.64 /var/snap/k8s/common/args/kube-apiserver
&& sudo snap restart k8s.kube-apiserver`. **After `rewrite`, never remove the config**: the Secrets are
unreadable without it. Going back to plain means `identity` first and another rewrite.

## 4. What has been verified (2026-10-14)

| | how |
|---|---|
| ✅ hardening, all seven | `DONE pass=211 fail=4` each; `--finish`: default-deny proven, DNS both ways, seed + provisioning shredded, cold boot clean |
| ✅ dual-stack nodes | `kubectl get node` → `InternalIP=10.2.20.171` **and** `InternalIP=fd6e:32f0:f4b3:20::171`; `ip -br addr` inside cp-01 |
| ✅ FIPS kernel and base snaps | `fips_enabled=1`; every node `6.8.0-138-fips`; `snap list`: core22 `20260125+fips`, snapd `2.78+fips`, all `held` |
| ✅ registry path | containerd's `config_path` read on the machine: `/etc/containerd/hosts.d` — the docs give two paths |
| ✅ HA | `k8s status`: three voters, `high availability: yes` |
| ✅ images from Harbor | every pod Running; the speaker image (95 MB) pulled in 3.4 s; no other source exists in the gap |
| ✅ taints | `node-role.kubernetes.io/control-plane` on cp-01..03 only |
| ✅ **FIPS in the running processes** | `verify` §2 on cp-01, 15:10 UTC: kube-apiserver, kube-controller-manager, kube-scheduler, kubelet, etcd, k8sd and containerd **each have `/snap/core22/2383/…/libcrypto.so.3` AND `…/ossl-modules-3/fips.so` mapped** (`/proc/<pid>/maps`). The classic-confinement question of 3.25 answered by measurement. The container processes (cilium-agent, coredns, metrics-server) map a `fips.so` from **their own image** — which build that is, is Q-CORE |
| ✅ **FIPS fails CLOSED** | `/snap/k8s/current/bin/etcd --version` run outside the snap's environment on cp-01 (2026-10-15) **refused to start**: `panic: opensslcrypto: FIPS mode requested (system FIPS mode) but not available: OpenSSL 3.0.2` — without the snap's provider setup it stops rather than fall back to non-FIPS crypto. The cluster's etcd is **v3.6.13** (the snap's `bom.json`) |
| ✅ DNS | CoreDNS answers `kubernetes.default` → 10.152.183.1, and forwards `svc-mgmt-01.enclave.internal` → 10.2.20.161 (the routed path of trap 7) |
| ✅ **dual-stack LoadBalancer** | the test Service got `10.2.20.200` **and** `fd6e:32f0:f4b3:20::200`; answers over both from cp-01, and over UDP and TCP **from stage-01, outside the cluster** — no ufw rule for it exists, so Cilium's eBPF path is confirmed ahead of ufw (POA&M ENG-75) |
| ✅ **audit policy K-A** | a probe Secret's value — plain and base64 — absent from `/var/log/kubernetes/audit.log`; its create logged at `Metadata`, no request body |
| ✅ **API VIP** | cp-01 holds `10.2.20.170`, cp-02/03 standby; from svc-mgmt-01 the API answers on it (HTTP 401) and `k8s-api.enclave.internal` resolves to it; stage-01 is dropped — not an allowed source |
| ✅ Harbor as the image source | Harbor's own pull counts (`/api/v2.0/projects/canonical/repositories`, anonymous): 9 for `cilium`, `pause` and `metallb-speaker` — the seven nodes plus the two read-backs of `images-check`; 2 for the CSI images, which nothing runs (local-storage off) |

### 4.1 Survivability — measured, one failure at a time

Probes, one sample per second throughout: the whoami LoadBalancer address (`10.2.20.200`) from
stage-01, and the API on the VIP from svc-mgmt-01 — with which control plane holds the VIP, read
from svc-mgmt-01's neighbour table. "Down" means no answer within 1 s. The probes are now
`07-kubernetes.sh probe service|api|patroni`, each refusing to start until it has seen itself fail (§4.2).

| test | what was done | measured |
|---|---|---|
| ✅ **C1 — a control plane lost** (2026-10-14) | `virsh destroy k8s-cp-01` (hard power-off) on host-1 — the VIP holder | **API unreachable 4 s** (15:52:42 → 15:52:46): the VIP moved to cp-02 in 2 s, the API answered through it 2 s later. ⚠️ *service continuity NOT measured — see the probe retraction below*. With cp-01 down: etcd `ok` on 2 of 3, a write created, read back and deleted. **Rejoin:** `virsh start`, Ready in ~2 min, etcd caught up, no pod stuck; the VIP **stayed on cp-02** (`nopreempt`); two API blips of 1 s and 2 s while cp-01's etcd member resynced — slow answers, the VIP never moved |
| ✅ **C2 — a worker lost** (2026-10-14) | `virsh destroy k8s-wk-01` (~16:14:40) — one of the four whoami pods on it | ⚠️ *service continuity NOT measured — see the probe retraction below*. wk-01 `unreachable` + `NoExecute` taint at 16:15:30 (the ~50 s grace); its pod **evicted at ~16:20:31, exactly the 5-minute toleration**, a replacement Running on wk-02 by 16:22 — no operator action (a Deployment needs no fencing; a StatefulSet would — decision H2). One 1 s API blip at 16:17:45, VIP unmoved. **Rejoin:** `virsh start`, Ready with no taints in ~2 min, the stale pod cleared. Running pods are not rebalanced back (wk-02 keeps two) |
| ⚠️ **C2b — the node announcing the service address lost** (2026-10-14) | `virsh destroy k8s-wk-01` while it answered for `10.2.20.200` (read from stage-01's neighbour table) | the address moved to wk-04 (stage-01's neighbour table) — ⚠️ *service continuity NOT measured — see the probe retraction below*; the "under ~2 s" failover time first reported is **withdrawn**. The announcer also moves when a node *joins*: cp-01 took it on rejoining after C1, wk-01 after C2 |
| ✅ **C3 — a whole host lost** (2026-10-15) | `virsh destroy` of host-2's three guests at once, ~00:58:24: **cp-02 (the VIP holder), wk-02 (two of the four test pods), pg-02 (Postgres's synchronous standby)** | **API back in ~3 s** (VIP to cp-01, 00:58:25 → 00:58:28). ⚠️ *service continuity NOT measured — see the probe retraction below*. Kubernetes writable on 2 of 3 etcd. **Postgres:** pg-01 leader throughout; Patroni reported no synchronous standby for 12 s (00:58:39 → 00:58:51) then named pg-03; a write after committed in ms — **C3b settled it: PostgreSQL never committed unprotected** — the 12 s was Patroni's bookkeeping. **Rejoin:** pg-02 back as a replica at 01:03:35, lag 0, same timeline, no rewind; pg-03 kept the sync role; cp-02/wk-02 Ready, no pod stuck; VIP stayed on cp-01; two 1–2 s API blips during etcd resync, as in C1 |
| ✅ **C3b — Postgres's synchronous standby lost, measured inside PostgreSQL** (2026-10-15) | `virsh destroy pg-03` (then the sync standby) with a loop on pg-01 sampling `synchronous_standby_names` and timing a write twice a second | **No unprotected window:** the setting went straight `"pg-03"` → `"pg-02"`, never empty. **A write stalled 36.4 s** (01:12:32 → 01:13:09), released the moment pg-02 became synchronous — Patroni's `ttl` 30 + `loop_wait` 10. Writes pause, nothing is lost (backlog 3.62) |
| ✅ **C4 — etcd snapshot and restore drill** (2026-10-15) | `etcd-drill` on cp-01 | tools matched the cluster (etcd v3.6.13), checksum-verified; **snapshot 55 MB — revision 2,206,250, 755 keys**; checked (`etcdutl snapshot status`); **restored into a scratch directory** (its hash checked by the restore); both copies shredded. Proves a snapshot of this cluster restores with these tools; the full quorum-loss procedure (§3.11) is documented, not rehearsed |
| ✅ **C5 — the whole cluster cold-started** (2026-10-15) | all seven nodes shut down cleanly (`virsh shutdown`, worker then control plane on each host), then started — the three control planes together, the workers 90 s later | **The cluster came back by itself, to exactly where it was: `verify` 28 of 28 at 01:31:46.** API (the only sound probe): unreachable from 01:27:37 (last control plane stopping) — first answer **01:29:35** on cp-02 — then 1–4 s blips while etcd and the nodes settled, steady from **01:31:01**. etcd formed quorum from cold with no intervention. Postgres and the hosts were not stopped; the whole-enclave power-down is 3.57's order, with Kubernetes to be added to it |
| ⚠️ unprompted API blips | — | Between the tests, 18:30–18:44 UTC: **four blips of 1–2 s** on the VIP with no failure injected and the VIP unmoved. "Down" is "no answer within 1 s", so most likely a slow API server on these 4-thread hosts, not an outage. Measured, not explained — worth chasing if it appears on production hardware |

**⚠️ RETRACTION, 2026-10-15 01:33 UTC — the test-service probe could not see an outage.** It counted any output from `dig` as an answer, and on a timeout `dig` prints `;; communications error … timed out` to the same output — found when it logged *no* outage during C5 with every node off, and proven against an address nothing answers. So the claims "the test service never missed a probe" in C1, C2, C2b and C3 are **unproven**, and C2b's "under ~2 s" is withdrawn. The **API** probe (HTTP code) and the **Patroni** probe (parsed JSON) were sound: their gaps and the Postgres findings stand. The service probe now requires an actual `IN A`/`IN AAAA` answer and has been run against a known-down address before use.

**Re-measured with the fixed probe, 2026-10-15 01:34–01:42 UTC** (one sample every 1–2 s from stage-01):

| event | measured |
|---|---|
| **the announcing node dies** (wk-01, no test pod on it) | **no failed sample** — MetalLB moved `10.2.20.200` to cp-02 faster than the probe samples |
| **a node rejoins** (wk-01 back) | **7 s outage** (01:38:56 → 01:39:03) — MetalLB moves the address back to the rejoining node and the hand-over is not clean |
| **a worker holding half the backends dies** (wk-02, 2 of 4 pods) | **~51 s of intermittent failures**, about every other request (01:40:27 → 01:41:18): the dead pods stay in rotation until Kubernetes marks the node `NotReady` (~50 s grace) and removes their endpoints |

**So a worker loss is not seamless for clients:** for ~50 s the share of requests aimed at that worker's pods fails. Backlog 3.63 holds the options.


### 4.2 Repeating the failover tests

Everything below is what was run on 2026-10-14/15, in the form to run it again. One failure at a
time; bring the failed machine back before the next test. **Expected results are §4.1's.**

**Before:** the test workload exists (`verify` creates it — four `whoami` pods, one per worker, on
the address `10.2.20.200`), and svc-mgmt-01 and svc-obs-01 have the current repository
(`push-repo-to-host.sh 10.2.20.161` and `.164` from stage-01).

**1. Start the three probes**, each in its own session, for the length of the session. Each first
proves it can see a failure (its self-test against a dead target) and refuses to start otherwise;
each prints only changes, with how long the previous state lasted. The start lines name the node
announcing the service address, the node holding the API VIP, and Patroni's leader and synchronous
standby — which decide the targets below.

```bash
### MACHINE: svc-mgmt-01 (10.2.20.161) — two sessions: the service, and the API through the VIP ###
~/canonical-k8s/scripts/install/07-kubernetes.sh probe service 90
~/canonical-k8s/scripts/install/07-kubernetes.sh probe api 90
```

```bash
### MACHINE: svc-obs-01 (10.2.20.164) — Patroni's view (8008 is open to this machine) ###
~/canonical-k8s/scripts/install/07-kubernetes.sh probe patroni 90
```

**2. The tests.** `virsh destroy` is a pulled power cord; `virsh start` brings the guest back. Run each
on the host the guest lives on (`vm-specs.env` placement: cp-0N and wk-0N on host-N, wk-04 on host-4).

| test | do this, on the guest's host | read |
|---|---|---|
| **C1** a control plane | `sudo virsh destroy k8s-cp-0N` — the one the api probe names as VIP holder | api probe: the gap and the new holder. Then on another control plane, the write test below. Restore: `sudo virsh start k8s-cp-0N`; the VIP must **stay** where it went (`nopreempt`) |
| **C2** a worker | `sudo virsh destroy k8s-wk-0N` — one with test pods (`kubectl -n enclave-verify get pods -o wide`) | service probe: partial failures for ~50 s (3.63); on a control plane, `kubectl get node k8s-wk-0N -o jsonpath='{.spec.taints}'` — `unreachable:NoExecute` and its time; the pod replaced 5 min later |
| **C2b** the announcer | `sudo virsh destroy` the node the service probe names | service probe: should not fail; on its restart, the address moves back (~7 s, 3.63) |
| **C3** a whole host | `for v in k8s-cp-0N k8s-wk-0N pg-0N; do sudo virsh destroy $v; done` | all three probes; the database write test below on the Patroni leader |
| **C3b** Postgres's sync standby, from inside | the write loop below on the **leader**, then `sudo virsh destroy pg-0N` on the **sync standby's** host ~15 s later | the loop: a write stall (~36 s, 3.62) and `synchronous_standby_names` going straight to the other standby — **it must never print `[]`** |
| **C4** etcd | `sudo …/07-kubernetes.sh etcd-drill` on a control plane (§3.11) | `etcd drill passed` |
| **C5** cold start | the stop block, then the start block, below — then `verify` | `verify` 28/28 |

The **cluster write test** (C1, C3), on a surviving control plane:

```bash
### MACHINE: a surviving control plane (k8s-cp-0N) ###
case "$(hostname -s)" in k8s-cp-0[1-3])
  sudo k8s kubectl get nodes | grep cp-0
  sudo k8s kubectl get --raw='/readyz?verbose' | grep -E 'etcd|readyz check'
  sudo k8s kubectl -n enclave-verify create configmap c-write-test --from-literal=at="$(date -u +%T)" \
    && sudo k8s kubectl -n enclave-verify get configmap c-write-test -o jsonpath='{.data.at}{"\n"}' \
    && sudo k8s kubectl -n enclave-verify delete configmap c-write-test ;;
  *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

The **database write loop** (C3, C3b), on the Patroni leader — a throwaway table in the `postgres`
database, never the application's; prints only state changes and writes slower than 200 ms:

```bash
### MACHINE: the Patroni leader (pg-0N) ###
case "$(hostname -s)" in pg-0[1-3])
sudo -u postgres bash -s <<'EOS'
psql -d postgres -X -q -c 'CREATE TABLE IF NOT EXISTS c3b_probe (at timestamptz)'
for i in $(seq 1 150); do
  s=$(psql -d postgres -X -At -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC','HH24:MI:SS'), '[' || current_setting('synchronous_standby_names') || ']', coalesce((SELECT string_agg(application_name || '=' || sync_state, ',' ORDER BY application_name) FROM pg_stat_replication), 'no-standbys')")
  t0=$(date +%s%N); psql -d postgres -X -q -c 'INSERT INTO c3b_probe VALUES (now())'; t1=$(date +%s%N)
  echo "$s| insert $(( (t1 - t0) / 1000000 )) ms"
  sleep 0.5
done | awk -F'|' '{ split($4, a, " "); key = $2 "|" $3; if (key != last || a[2] > 200) print; last = key }'
psql -d postgres -X -q -c 'DROP TABLE c3b_probe'
EOS
;; *) echo "WRONG MACHINE: $(hostname -s)" ;; esac
```

**C5's stop and start** — the same block on host-1..4 at once, the stop first:

```bash
### MACHINE: host-1, host-2, host-3 or host-4 — STOP: worker, then control plane ###
case "$(hostname -s)" in host-1) G="k8s-wk-01 k8s-cp-01" ;; host-2) G="k8s-wk-02 k8s-cp-02" ;; host-3) G="k8s-wk-03 k8s-cp-03" ;; host-4) G="k8s-wk-04" ;; *) G="" ;; esac
if [ -z "$G" ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  for V in $G; do sudo virsh shutdown "$V"
    for _ in $(seq 1 120); do [ "$(sudo virsh domstate "$V")" = "shut off" ] && break; sleep 1; done
    echo "$V: $(sudo virsh domstate "$V") at $(date -u +%T)"; done
fi
```

```bash
### MACHINE: host-1, host-2, host-3 or host-4 — START: control planes together, workers 90 s later ###
case "$(hostname -s)" in host-1) C=k8s-cp-01; W=k8s-wk-01 ;; host-2) C=k8s-cp-02; W=k8s-wk-02 ;; host-3) C=k8s-cp-03; W=k8s-wk-03 ;; host-4) C=""; W=k8s-wk-04 ;; *) W="" ;; esac
if [ -z "$W" ]; then echo "WRONG MACHINE: $(hostname -s)"; else
  if [ -n "$C" ]; then sudo virsh start "$C"; fi
  sleep 90; sudo virsh start "$W"
fi
```

**After the tests:** `verify` (28/28), then `verify --cleanup` only if the test workload is no longer
wanted. Record each result in §4.1 with its times — measured, never "it seemed fine".

## 5. Traps hit — each fixed in a script

1. **New scripts went in as mode 644** (the file was created by a tool, not `cp`) — `sudo` said
   "command not found". Every step script is tracked 100755.
2. **`snap list NAME` exits 1 for a snap not yet installed**; under `set -e` and `pipefail` that ended
   `node-prep` **silently**. Fixed and proven with a control; the same trap fixed in the sysctl
   read-back's diagnostic line.
3. **The `snapd` snap is a prerequisite of k8s** and was never staged — snapd went to the store.
   Now pinned (FIPS, rev 28333), on the mirror, and side-loaded first.
4. **A pasted placeholder reached k8sd as a token** and came back as a bare `EOF`. Tokens now
   travel as files and are shape-checked first.
5. **An unknown host key** — `push-repo-to-host.sh` refused, correctly. Verify against the console
   record (§3.4), never `accept-new`.
6. **The composer checked the data pool for every guest** and refused wk-04 on host-4, which has
   none. It checks only for a guest that has a data disk.
7. **ufw dropped routed pod traffic.** `[UFW BLOCK] IN=lxc… OUT=enp1s0`: the MetalLB controller's
   calls to the API (`10.1.3.89 → 10.2.20.171:6443`) and CoreDNS's forwarding to the enclave DNS
   (`10.1.1.71 → 10.2.20.161:53`). Reverse-path filtering ruled out first (counter 0).
   `stig-tailor.sh ufw_route_rules()`: per node, pods → enclave subnet and pods → pods, both
   families. A node built before 2026-10-14 needs `sudo stig-tailor.sh ufw --apply` once.
8a. **ufw dropped service traffic to a pod on the announcing node, and MetalLB's gossip** (found with the fixed
   probe, 2026-10-15): when wk-02 both announced `10.2.20.200` and ran two of the four pods, half the requests
   failed for minutes while Kubernetes showed everything Ready — `[UFW BLOCK] IN=enp1s0 OUT=cilium_host
   SRC=10.2.20.160 DST=10.1.4.x DPT=1053`: traffic redirected to a *local* pod takes the kernel's routed path.
   And `DPT=7946` from the other nodes: MetalLB's memberlist, in neither of Canonical's port lists. Fixed in
   `stig-tailor.sh`: a routed rule enclave subnet → pod ranges (both families), and 7946/tcp+udp from the seven
   nodes, registered in the PPSM register first. Every node needs `sudo stig-tailor.sh ufw --apply` once.
   **Proven 2026-10-15 01:58 UTC:** 40 queries from stage-01 to the service's NodePort on each of wk-02 (2 local
   pods — the failing case), wk-03 (1) and wk-01 (0): **120 of 120 answered**; the LoadBalancer address 40 of 40.
   Re-applying ufw on a live node drops traffic for a few seconds (the reset) — a maintenance-window step.
8. **No default route** turns "service has no backend" into an instant `network is unreachable` /
   `no route to host` instead of a timeout — read it as "nothing behind that Service yet".

## 6. Owed — the rest of B-07

1. ~~**Verify**~~ ✅ **done 2026-10-14** — §3.9, §4. `verify --fips-only` on all four workers **ok** the same
   day — kubelet, containerd, k8sd and k8s-apiserver-proxy on core22's `fips.so` too.
2. ~~**The API VIP**~~ ✅ live 2026-10-14 (§3.10).
3. ~~**K-B** — sshd disabled on the workers~~ — **reversed 2026-10-14: ssh stays on** (§2, POA&M AO-21).
4. ✅ **Survivability (C)** — C1–C5 passed 2026-10-14/15, service continuity re-measured with the fixed probe and two
   firewall gaps fixed (§4.1, §4.2, §5 trap 8a).
5. 🔴 **Secrets at rest — V-274882, CAT I (backlog 3.64).** Checked 2026-10-15: **not encrypted**. Decided the same day:
   `aesgcm`, keys from a sealed passphrase. **Built** (`encrypt`, §3.12) and tested off the cluster — the snap's own v1.36.4
   API server parses all three config forms, and rejects a bad key. **Not yet applied** to the cluster.
6. ⬜ **Cluster monitoring (G10)** — Prometheus scrapes none of the seven nodes: no alert for a `NotReady` node, etcd, the VIP
   moving or a certificate expiring.
7. ⬜ **Routine etcd backups (G9)** — the drill (§3.11) is one-off; a nightly snapshot needs encryption (it holds every Secret)
   and a home.
8. ⬜ **Kubernetes in the whole-enclave power-down order** (3.57, contingency plan §5.3) — the blocks exist (§4.2, C5).
9. ⬜ **The application front door** — the gateway is enabled but unexercised, `*.apps` points at a placeholder, and Q-CORE (i)
   (is the gateway's TLS FIPS?) is open. With the vendor's application.
10. Then **B-08 Ceph** — unblocked 2026-10-15: 3.48 (wk-04's lab OSD an LV on host-4's OS disk; production a dedicated
   drive) and 3.61 (host-4's copy to host-3 in the lab) both decided — START-HERE's lab-vs-production table.

## 7. Known gaps carried elsewhere

- **3.59** — Harbor's scan finds Critical and High CVEs in 11 of Canonical's 12 images (Go stdlib,
  `x/crypto`, `grpc`): ask Canonical, POA&M rows.
- **3.60** — node-prep, bootstrap and the joins are hand-run; the unattended rebuild (2.6) cannot
  have that.
- **The in-gap image fetch:** svc-repo-01 refuses directory listings, so the runbook's `wget -r` of
  `/oci/` cannot enumerate a layout. `images-load` must fetch by known paths before production.
- **STIG rescan:** Cilium writes `/etc/sysctl.d/99-zzz-override_cilium.conf` (`rp_filter=0`; the
  STIG wants 1) — a finding the datapath requires; document, do not revert. And the ufw `allow` rows
  on Kubernetes ports are the same rate-limit finding as Harbor's and PostgreSQL's.
