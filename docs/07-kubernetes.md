# 07 — Kubernetes (backlog B-07)

**Status: 🔄 IN PROGRESS. The cluster has been running since 2026-10-14 (03:15–04:00 UTC):** seven nodes
`Ready`, `high availability: yes` (three etcd voters), every pod Running, load balancer enabled.
**Verified 2026-10-14 15:10 UTC — `07-kubernetes.sh verify`, all 28 checks passed** (§4). **Still owed, in order:**
the API VIP (keepalived), ssh off on the workers (K-B), and the survivability tests. The live list is `docs/backlog.md` row B-07; this document is
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
| API VIP | 10.2.20.170 | — | keepalived — **not yet configured** |

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
| K-B | **sshd off on the workers** (V-242393/242394) once joined and verified; maintenance by serial console | 2026-10-14, Brian | complies; every guest has a console through its host |
| K-C | **Pod Security `baseline`** (Canonical's default, V-254800) | 2026-10-14, Brian | the vendor's images are unmeasured; revisit `restricted` once they run |
| — | **snapd: the FIPS build** from `fips-updates/candidate` | 2026-10-14, Brian | `fips-updates/stable` was empty; snapd verifies every snap's signature. Q-CORE asks when stable carries it |
| — | local-storage **off**; CoreDNS forwards to the **enclave DNS**; `--address` always explicit | 2026-10-14 | node-local volumes do not survive their node; the node resolver 127.0.0.53 means nothing in a pod; there is no default route to find |

The STIG arguments are **Canonical's own**, read from the pinned snap
(`/snap/k8s/current/k8s/resources/configurations/disa-stig/{bootstrap,control-plane,worker}.yaml`).
`render_config` takes them as written and replaces only `--audit-policy-file` (K-A) and
`--admission-control-config-file` (K-C, the same baseline file named explicitly), and adds
`--node-ip <v4>,<v6>`. Canonical's audit-policy file says *Metadata* in its comment while its one
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
planes, the K-A audit policy. Safe to repeat.

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
| ✅ DNS | CoreDNS answers `kubernetes.default` → 10.152.183.1, and forwards `svc-mgmt-01.enclave.internal` → 10.2.20.161 (the routed path of trap 7) |
| ✅ **dual-stack LoadBalancer** | the test Service got `10.2.20.200` **and** `fd6e:32f0:f4b3:20::200`; answers over both from cp-01, and over UDP and TCP **from stage-01, outside the cluster** — no ufw rule for it exists, so Cilium's eBPF path is confirmed ahead of ufw (POA&M ENG-75) |
| ✅ **audit policy K-A** | a probe Secret's value — plain and base64 — absent from `/var/log/kubernetes/audit.log`; its create logged at `Metadata`, no request body |
| ✅ Harbor as the image source | Harbor's own pull counts (`/api/v2.0/projects/canonical/repositories`, anonymous): 9 for `cilium`, `pause` and `metallb-speaker` — the seven nodes plus the two read-backs of `images-check`; 2 for the CSI images, which nothing runs (local-storage off) |

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
8. **No default route** turns "service has no backend" into an instant `network is unreachable` /
   `no route to host` instead of a timeout — read it as "nothing behind that Service yet".

## 6. Owed — the rest of B-07

1. ~~**Verify**~~ ✅ **done 2026-10-14** — §3.9, §4. `verify --fips-only` on the workers still to run, so the
   worker-side processes (kubelet, containerd, k8sd, k8s-apiserver-proxy) are measured as well.
2. **The API VIP** — keepalived on the control planes, VRRP unicast (the ufw rows exist).
3. **K-B** — sshd disabled on the workers.
4. **Survivability (C):** a control plane off, a worker off, a whole host off; an etcd snapshot
   and restore; a full planned shutdown in the 3.57 order.
5. Then **B-08 Ceph** — blocked on backlog 3.48 (wk-04 has no OSD device).

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
