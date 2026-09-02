# Step 03 — libvirt on host-4, and the volumes the service VMs live on

**Machine: `host-4` (`10.0.20.158`).** Everything in this document runs on the host being
prepared. Nothing here runs on `stage-01`.

Step 02 left host-4 with an encrypted OS, an unlocked-by-keyfile `crypt-data`, and an empty
`vg-data`. This step turns it into a virtualisation host that can compose `svc-mgmt-01`,
`svc-repo-01` and Harbor. It is the last step before the enclave services in step 04.

Everything is driven by [`scripts/install/03-host-services.sh`](../scripts/install/03-host-services.sh)
and parameterised in `scripts/install/03-host-services/services-params.env`. Every subcommand
is idempotent — running it twice reports `[--]` rather than failing.

---

## 1. Why this step exists at all

host-4 came out of step 02 unable to install a single package. It has **no default route** by
design, and its apt sources still pointed at `archive.ubuntu.com`, which it cannot reach.

It does not need the transfer SSD to get past that. **host-4 can reach `stage-01` on its own
subnet** — no default route required, because `10.0.20.160` is link-local to it. That is the
same mechanism `svc-repo-01` will use inside the gap, against a different server. Pointing
host-4 at `stage-01` now is therefore a **rehearsal of `restore-mirror.sh`'s end state**, and
the first time the mirror has been exercised by a real apt client over the network rather than
from `localhost`.

Verified before relying on it:

| Check | Result |
|---|---|
| host-4 default routes | `0` |
| host-4 → `10.0.20.160` nginx | `HTTP 200` |
| `stage-01` `net.ipv4.ip_forward` | `0` — **no path to the internet through it** |

That last row is the one that matters. host-4 reaching stage-01 does **not** put host-4 online,
because stage-01 will not forward. If you ever set `ip_forward=1` on stage-01, host-4 stops
being air-gapped and this arrangement becomes a finding.

---

## 2. The mirror URL is a parameter, and that is the whole point

```
MIRROR_URL='http://10.0.20.160/archive.ubuntu.com/ubuntu/'
```

Inside the gap this becomes `svc-repo-01` and **nothing else in the file changes**.

Two things that look wrong and are not:

- **`archive.ubuntu.com` appears in the URL.** It is a *path segment* — the mirror tree is
  served as `/archive.ubuntu.com/ubuntu/`. `grep` for that string will flag the live sources
  file; it is not a route out. Check `ip route` if you want the real answer.
- **`Components: main universe`, not the usual four.** `apt-mirror` pulled main+universe,
  amd64 only, with security folded into the archive tree. Listing `restricted` or `multiverse`
  makes `apt-get update` fail. The script refuses those two words outright rather than letting
  you discover it at the rack.

`ubuntu.sources.curtin.orig` and `ubuntu.sources.pre-mirror` sit alongside the live file. They
are **inert** — apt reads only `*.list` and `*.sources`. They become live the moment someone
renames one, so the script lists them rather than leaving them to be discovered.

---

## 3. VMs go on a bridge, not on libvirt's NAT

libvirt ships a `default` network that NATs to `192.168.122.0/24`. **That is unusable here.**
`svc-repo-01` has to serve apt to `host-1`, `host-2` and `host-3`; behind NAT it is reachable
only from host-4 itself. Same for `svc-mgmt-01`, which has to reach every host to run MAAS.

So the script stops the NAT network, disables its autostart, and puts the host address on a
bridge over the physical NIC.

**This is the one step that can strand the host.** `enp42s0` is host-4's only working NIC
(`wlo1` is a wireless adapter that must stay down — it is a STIG finding on an air-gapped
host). If the bridge config is wrong, an air-gapped machine with no default route becomes a
trip to the rack.

Three guards, in order:

1. It refuses if `BRIDGE_ADDRESS` is not **currently on** `BRIDGE_NIC` — if the params
   describe a different machine, applying them would strand this one.
2. It refuses to run without a TTY, so it can never happen unattended from a script.
3. It applies with `netplan try --timeout 120`, which **auto-reverts** unless you confirm. If
   your ssh session dies, wait two minutes and reconnect on the same address.

`bridge` is deliberately **excluded from `all`**. Every other subcommand is reversible over
ssh; this one is not.

Worth knowing: `cloud-init status` on host-4 is `disabled`, so it will not regenerate
`50-cloud-init.yaml` over the bridge config on the next boot. On a host where cloud-init is
still enabled you would also need `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`.

---

## 4. The data volumes

The step-02 autoinstall creates `vg-data` on top of `crypt-data` **with no logical volumes**,
because the sizes depend on what services land here — which is this step's decision, not the
installer's.

Default split of the 1.9 T `crypt-data`, all parameters:

| LV | Size | Mount | Why |
|---|---|---|---|
| `libvirt` | 700 G | `/var/lib/libvirt/images` | VM disks. Cannot take `nodev`. |
| `repo` | 500 G | `/srv/repo` | The 318 GB mirror, plus room to grow |
| `harbor` | 200 G | `/srv/harbor` | Container images |

That is ~1.4 T of 1.9 T, **deliberately under-allocated**: an LV extends online, shrinking one
does not. Leave the slack.

`repo` and `harbor` mount `nodev,nosuid` — STIG-relevant and free. `/var/lib/libvirt/images`
cannot take `nodev` without breaking device nodes in guests.

The script runs `mount -a` at the end. A broken `fstab` on a host with no default route is the
same trip to the rack as a broken bridge, so it is proven before you reboot into it.

---

## 5. Run it

```bash
### MACHINE: host-4 (10.0.20.158) ###
cd ~/canonical-k8s/scripts/install
cp 03-host-services/services-params.env.example 03-host-services/services-params.env
chmod 600 03-host-services/services-params.env
# edit: BRIDGE_NIC, BRIDGE_ADDRESS and MIRROR_URL must describe THIS machine
```

Everything except the bridge, in one go:

```bash
### MACHINE: host-4 (10.0.20.158) ###
sudo ./03-host-services.sh all
```

Then the bridge, **from a session you can afford to lose**:

```bash
### MACHINE: host-4 (10.0.20.158) ###
sudo ./03-host-services.sh bridge
```

And prove it:

```bash
### MACHINE: host-4 (10.0.20.158) ###
./03-host-services.sh verify
```

`verify` changes nothing and needs no root. It is the check to re-run after any reboot.

---

## 6. What this step deliberately does NOT do

No Pro attach, no FIPS, no STIG, no MAAS.

- **Hardening is step 05, not step 03.** Pro attach inside the gap needs the contract server,
  which lives on a VM that does not exist until step 04.
- **MAAS is step 04.** It is a service *on* `svc-mgmt-01`, and `svc-mgmt-01` cannot be composed
  until this step finishes.

---

## 7. State as built

Recorded 2026-09-02 on host-4, after `apt` and `libvirt`:

```
virsh    : 10.0.0
libvirtd : active, enabled
groups   : encadmin adm cdrom sudo dip plugdev kvm lxd libvirt
/dev/kvm : present
ovmf     : /usr/share/OVMF/OVMF_CODE_4M.fd
apt      : all three InRelease files fetched from 10.0.20.160, signatures verified
           libvirt-daemon-system 10.0.0-2ubuntu8.16 <- noble-updates/main on the mirror
```

Still outstanding on host-4 at that point: the bridge, the data LVs, and the storage pool.
