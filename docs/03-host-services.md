# Step 03 — libvirt on host-4, and the volumes the service VMs live on

**Machine: `host-4` (`10.0.20.158`).** Everything in this document runs on the host being
prepared. Nothing here runs on `stage-01`.

Step 02 left host-4 with an encrypted OS, an unlocked-by-keyfile `crypt-data`, and an empty
`vg-data`. This step turns it into a virtualisation host that can compose `svc-mgmt-01`,
`svc-repo-01` and Harbor. It is the last step before the enclave services in step 04.

**Every subcommand refuses to run on a machine the params do not describe.** `BRIDGE_ADDRESS`
is the host's own address, so it identifies the box without hardcoding a hostname, and it is
checked across every interface — after the bridge step the address lives on `br0`, not the NIC.
Paste a step into the wrong window and you get `Wrong machine. Nothing was done.`

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

### 3.1 What the bridge actually does — run it by hand once

**Run this sequence yourself the first time.** The script does exactly the same thing; doing
it by hand once is what makes the script debuggable at 2am on a host you cannot ssh into.

**The idea in one line:** today `enp42s0` holds the IP address. After this, `enp42s0` holds
*nothing* and becomes a plain switch port, and a new virtual device `br0` holds the address
and passes frames between the NIC and every VM attached to it.

```
BEFORE                          AFTER
enp42s0  10.0.20.158            enp42s0  (no address, enslaved)
                                   |
                                br0     10.0.20.158
                                   |
                                vnet0 -> svc-repo-01  10.0.20.161
```

**Step 1 — write down what you are changing from.** If anything goes wrong this is what you
restore to, and on an air-gapped host you cannot look it up later.

```bash
### MACHINE: host-4 (10.0.20.158) ###
ip -br addr show enp42s0
ip route
sudo cp -a /etc/netplan /root/netplan.bak-$(date +%F)
```

**Step 1a — the collision you will hit, and why the old file has to go.**

The step-02 autoinstall writes `50-cloud-init.yaml` defining the NIC as **`primary`** with
`match: name: "en*"` — *not* as `enp42s0`. Netplan merges configuration by that id, so simply
adding a bridge file produces **two units matching the same physical NIC**:

```
10-netplan-enp42s0.network   Match Name=enp42s0   Bridge=br0
10-netplan-primary.network   Match Name=en*       Address=10.0.20.158/24
```

One bridges the NIC, the other still assigns the address to it. Which wins depends on the
lexical order of generated filenames. That is not a configuration to put on a host you cannot
reach.

**And `addresses: []` in the later file does not fix it.** Netplan *merges* keys, it does not
replace them, so the address from the earlier file survives. Verified with
`netplan generate --root-dir` before trusting it:

| Approach | `primary` unit | |
|---|---|---|
| Add a bridge file, keep `50-cloud-init.yaml` | `Address=...` **and** `Bridge=br0` | broken |
| Override with `addresses: []` | `Address=...` **and** `Bridge=br0` | **still broken** |
| One file, `50-cloud-init.yaml` moved away | `Bridge=br0` | correct |

So move it out of `/etc/netplan` first:

```bash
### MACHINE: host-4 (10.0.20.158) ###
sudo mkdir -p /root/netplan.pre-bridge
sudo mv /etc/netplan/50-cloud-init.yaml /root/netplan.pre-bridge/
ls /etc/netplan/
```

**Know what the safety net does and does not cover.** `netplan try`'s revert restores
`/run/systemd/network` — your *connectivity* — but it does **not** restore `/etc/netplan`. From
`configmanager.py`, `revert()` only unlinks files netplan itself added. A file you moved stays
moved. To undo by hand:

```bash
### MACHINE: host-4 — console or ssh ###
sudo cp /root/netplan.pre-bridge/* /etc/netplan/
sudo rm -f /etc/netplan/70-bridge.yaml
sudo netplan apply
```

**Step 2 — write the bridge config.** Netplan reads every `*.yaml` in `/etc/netplan` in
filename order, so `70-bridge.yaml` is applied after `50-cloud-init.yaml` and wins. Mode
`600`, because netplan warns loudly about world-readable configs.

```bash
### MACHINE: host-4 (10.0.20.158) ###
sudo tee /etc/netplan/70-bridge.yaml >/dev/null <<'YAML'
network:
  version: 2
  ethernets:
    enp42s0:
      dhcp4: false
      dhcp6: false
  bridges:
    br0:
      interfaces: [enp42s0]
      dhcp4: false
      dhcp6: false
      addresses: [10.0.20.158/24]
YAML
sudo chmod 600 /etc/netplan/70-bridge.yaml
```

Line by line:

| Line | Why |
|---|---|
| `enp42s0: dhcp4: false` | the NIC must stop claiming an address of its own — it is now just a port |
| `interfaces: [enp42s0]` | this is the enslaving. The NIC becomes a member of the bridge |
| `addresses: [10.0.20.158/24]` | the host's address moves to `br0`, unchanged, so nothing else on your LAN notices |
| **no `routes:`** | deliberate. host-4 is air-gapped and has **no default route** — adding a gateway here would silently undo that |
| **no `nameservers:`** | same reason: there is no DNS to reach |
| **no `parameters:`** | see below — a bridge with custom parameters makes `netplan try` refuse to run |

**Why there is no `parameters:` block, and it is not an oversight.**

The obvious thing to write is `stp: false` and `forward-delay: 0`. Do that and `netplan try`
**refuses to run at all**:

```
br0: reverting custom parameters for bridges and bonds is not supported

Please carefully review the configuration and use 'netplan apply' directly.
```

It exits *before applying anything* — so the config never lands, and the safety net you thought
you had does not exist. From `try_command.py`:

```python
for itf in multi_iface.values():
    if not itf._is_trivial_compound_itf:
        reason = "reverting custom parameters for bridges and bonds is not supported"
```

Setting either parameter is exactly what makes `_is_trivial_compound_itf` false. Confirmed
against the netplan bindings:

| Config | `_is_trivial_compound_itf` | `netplan try` |
|---|---|---|
| with `parameters:` | `False` | **refuses** |
| without | `True` | works, auto-reverts |

And the two settings only restate the kernel's own defaults — a Linux bridge has STP off unless
you turn it on. So omitting them costs nothing and buys back a config that can roll itself
back. **If you ever do need custom bridge parameters, apply them with `netplan apply` at the
console** — there is no safety net on that path.

**Step 3 — check the syntax, then check the result.** `generate` parses the config and writes
the systemd units without touching the running network.

```bash
### MACHINE: host-4 (10.0.20.158) ###
sudo netplan generate
sudo grep -l 'Address=10.0.20.158/24' /run/systemd/network/*
sudo grep -E 'Name=|Address=|Bridge=' /run/systemd/network/*.network
```

`sudo` on the greps is not optional - netplan writes those units root-only, and without it
you get three "Permission denied" lines and no answer.

Silence from `generate` means it parsed. The `grep` must return **exactly one file**, and it
must be `10-netplan-br0.network`. Two files means the NIC is being bridged *and* addressed —
stop and go back to step 1a. An error here costs you nothing; the same error in step 4 costs a
walk.

**Step 4 — apply it with the safety net.** `netplan try` applies the config, then waits. If
you do not press ENTER within the timeout, **it puts everything back automatically**.

```bash
### MACHINE: host-4 (10.0.20.158) ###
sudo netplan try --timeout 120
```

What you will see: your ssh session may freeze for a few seconds as the address moves. That is
normal — the address is the same, so the session usually survives. **Do not press ENTER until
you have proved it works in a second window.**

**Step 5 — prove it from somewhere else, then confirm.** Open a *second* terminal:

```bash
### MACHINE: stage-01 ###
ssh encadmin@10.0.20.158 'ip -br addr show br0; ip -br link show enp42s0'
```

You want `br0` holding `10.0.20.158/24`, and `enp42s0` UP with no address. **Only then** go
back to the first window and press ENTER.

**If you pressed nothing and the session died:** wait two full minutes. `netplan try` reverts
on its own and the host comes back on the same address. That is the entire point of using it.

**If you confirmed a broken config:** that is the walk to the rack. At the console:

```bash
### MACHINE: host-4 — physical console ###
sudo rm /etc/netplan/70-bridge.yaml
sudo netplan apply
```

**Step 6 — stop libvirt's NAT network**, so nothing accidentally lands on 192.168.122.0/24:

```bash
### MACHINE: host-4 (10.0.20.158) ###
sudo virsh net-destroy default
sudo virsh net-autostart default --disable
sudo virsh net-list --all
```

`default` should read `inactive` / `no`. It is disabled rather than deleted — an inactive
network costs nothing and leaves the option open.

From here a VM joins the LAN with `--network bridge=br0` instead of `--network default`.

## 4. The data volumes — one, not one per service

The step-02 autoinstall creates `vg-data` on top of `crypt-data` **with no logical volumes**,
because the sizes depend on what services land here — which is this step's decision, not the
installer's.

**It is one volume, and the reasoning matters more than the number.** `svc-repo-01` and
`svc-harbor-01` are **VMs** (runbook §1.1), so their storage lives inside their virtual disks.
A `/srv/repo` mounted on the host would be a second copy of storage that belongs in the guest.

Everything host-4 must carry on `vg-data`:

| VM | Disk (runbook §1.5) |
|---|---|
| `svc-repo-01` | 1 TB — 320 GB today, grows every patch cycle |
| `svc-harbor-01` | 500 GB |
| `svc-mgmt-01` | 100 GB |
| `k8s-wk-04` OS | 100 GB |
| | **1.7 T of a 1.9 T `vg-data`** |

`k8s-wk-04`'s Ceph OSD is **not** in that total — it gets the raw third NVMe (`nvme2n1`),
deliberately left unmatched by the step-02 disk patterns.

1.7 T of 1.9 T leaves no room to snapshot a VM before changing it. So the VM disks are
**sparse qcow2 in a single pool** rather than fixed LVs: `svc-repo-01` is created with a 1 TB
virtual disk but consumes only what it actually holds, ~325 GB today. qcow2 costs a little
performance against a raw LV; for a package repo, a registry and MAAS that is not measurable,
and the flexibility is worth far more than the loss.

```
DATA_LVS='libvirt:100%FREE:/var/lib/libvirt/images'
```

A size ending in `%` is passed to `lvcreate -l`; anything else to `-L`. If you later decide a
service really does want its own LV, add it to `DATA_LVS` and re-run `datavg` — it is
idempotent and will only create what is missing.

`/var/lib/libvirt/images` mounts plain `defaults`. It **cannot** take `nodev`: guests need
device nodes inside their images.

The script runs `mount -a` at the end. A broken `fstab` on a host with no default route is the
same trip to the rack as a broken bridge, so it is proven before you reboot into it.

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

## 5a. Two traps found on the first cold boot

**`systemctl is-active libvirtd` is not a health check on 24.04.** libvirt is socket-activated:
`libvirtd.socket` listens, and `libvirtd.service` only starts when something connects. Straight
after a reboot the service reads `inactive` on a perfectly healthy host. The first version of
`verify` tested exactly that and reported:

```
  [!!] libvirtd not active
  [!!] default NAT network is ACTIVE - VMs may land on 192.168.122.0/24
```

Both were wrong, and the second was caused by the first — `virsh net-info` failed against a
daemon that had not started yet, so the check could not find `Active: no` and assumed the worst.
`verify` now asks `virsh -c qemu:///system version`, which is both the thing we actually depend
on and the thing that triggers the activation.

**`inactive` is not the same as disabled.** The real state after that boot was:

```
default   inactive   Autostart: yes
```

Inactive *today*, but set to start on boot. `virbr0` and `192.168.122.1` come back the next
time something starts it. `verify` now checks **both** fields and only passes when active and
autostart are each `no`.

That is what `03-host-services.sh libvirt` does. If you installed libvirt by hand, run that
subcommand anyway — the packages are only half of it.

## 6. What this step deliberately does NOT do

No Pro attach, no FIPS, no STIG, no MAAS.

- **Hardening is step 05, not step 03.** Pro attach inside the gap needs the contract server,
  which lives on a VM that does not exist until step 04.
- **MAAS is step 04.** It is a service *on* `svc-mgmt-01`, and `svc-mgmt-01` cannot be composed
  until this step finishes.

---

## 7. State as built

host-4, 2026-09-02, verified from `stage-01` rather than asserted.

**After `apt` and `libvirt`:**

```
virsh    : 10.0.0
libvirtd : active, enabled
groups   : encadmin adm cdrom sudo dip plugdev kvm lxd libvirt
/dev/kvm : present
ovmf     : /usr/share/OVMF/OVMF_CODE_4M.fd
apt      : all three InRelease files fetched from 10.0.20.160, signatures verified
           libvirt-daemon-system 10.0.0-2ubuntu8.16 <- noble-updates/main on the mirror
```

**After `datavg`** — note the whole chain, which is the point:

```
nvme1n1 -> crypt-data (LUKS) -> vg-data -> vg--data-libvirt -> /var/lib/libvirt/images
1.9T, ext4, defaults, UUID in fstab, mount -a clean
```

Every VM disk therefore lands on encrypted storage by construction. There is nothing extra to
remember when composing a guest.

**After the bridge:**

```
br0       UP    10.0.20.158/24
enp42s0   UP    (no address), member of br0
routes    10.0.20.0/24 dev br0        <- no default route
stp_state 0                           <- kernel default, as predicted when dropping parameters
/etc/netplan/  70-bridge.yaml only    <- 50-cloud-init.yaml moved to /root/netplan.pre-bridge/
systemd-networkd enabled
```

`forward_delay` reads 1500 (centiseconds) but is only consulted when STP is enabled, so it is
inert here.

**After a cold boot and `libvirt`, verified from `stage-01`:**

```
default net : Active=no  Autostart=no
pool        : images  active  autostart yes
free space  : 1.8T on /var/lib/libvirt/images
bridge      : 10.0.20.158/24, members: enp42s0
```

`./03-host-services.sh verify` returns `[ok] step 03 complete`.

**Host preparation is done. `svc-mgmt-01` is not yet composed** — that is the remainder of
step 03, and the first thing that will actually use any of this.
