#!/usr/bin/env bash
# =========================================================================================
# 03-compose-vm.sh - compose one enclave VM from the Minimal cloud image.
#
#     MACHINE: runs ON the virtualisation host (host-4 for the service VMs).
#     It REFUSES a guest whose PLACE_<GUEST> in vm-specs.env names another host (backlog 2.7).
#
#     sudo ./03-compose-vm.sh svc-mgmt-01
#     sudo ./03-compose-vm.sh svc-mgmt-01 -n        show what it would do, touch nothing
#     sudo ./03-compose-vm.sh svc-mgmt-01 --destroy remove it and its disk
#     ./03-compose-vm.sh plan                       does THIS host fit the guests mapped to it
#     ./03-compose-vm.sh plan --spec                what each host must have - no hardware
#     sudo ./03-compose-vm.sh pg-01 --harden [--cred-dir DIR]
#         the guest hardens ITSELF from first boot (B-06): a read-only provisioning disk carries
#         the repo, its credentials file and audit-offload key (DIR/credentials.<vm>.env and
#         DIR/audit-offload.<vm>.key, default /mnt/cred/site = the enclave-cred stick), the
#         host's Pro token and the answer file. Watch the console log.
#     sudo ./03-compose-vm.sh pg-01 --finish [--no-reboot]    after DONE: checks from outside,
#         shreds the seed + provisioning disk, proves it still boots, prints the register line
#
# There are fourteen of these in vm-specs.env, so it is a composer rather than a one-off. Everything
# comes from two files and nothing is typed twice:
#     scripts/enclave/enclave-addresses.env   who is at which address
#     scripts/enclave/vm-specs.env            cpu / ram / disk / image / mirror
#
# WHY THE CLOUD IMAGE AND NOT THE SERVER ISO:
#   A cloud image needs no installer, so composing a VM is one command that either works or
#   does not - no autoinstall to debug, no console to watch. The runbook asked for "standard
#   server" on the service VMs for diagnostic tooling; VM_EXTRA_PACKAGES names that tooling
#   explicitly, which produces the same ability from an auditable list rather than from
#   whatever an ISO happened to ship. Better evidence for the same outcome.
#
# The VM gets NO DEFAULT ROUTE, like its host. It reaches the enclave /24 (10.2.20.0/24) and nothing else.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCLAVE_DIR="${ENCLAVE_DIR:-$SELF/../enclave}"
DRY=0; DESTROY=0; VM=""; PLAN_ARG=""; HARDEN=0; CRED_DIR="${CRED_DIR:-/mnt/cred/site}"; FINISH=0; NO_REBOOT=0

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" -eq 1 ]; then echo "  DRY: $*"; else "$@"; fi; }


# =========================================================================================
# plan - what runs where, and does it fit.  backlog 2.7.
#
#     ./03-compose-vm.sh plan            VERIFY: measures THIS host, checks its guests fit
#     ./03-compose-vm.sh plan --spec     SPEC:   no hardware needed, prints the requirement
#
# VERIFY is the gate before composing anything: it reads threads, RAM and free space FROM THE
# MACHINE and refuses a layout that does not fit, instead of finding out on the fourth guest.
# SPEC runs anywhere, including before the hardware exists - it turns the map into the BOM
# argument (RAM per host, devices per host) rather than an estimate.
#
# IT RECOMMENDS AND VERIFIES. It never moves a guest or rewrites the map: an algorithm quietly
# reshuffling guests between sites is the opposite of a repeatable build.
# =========================================================================================
plan_hosts() {   # every host named by the map, in order
  local v; for v in $(compgen -A variable PLACE_ 2>/dev/null); do
    case "$v" in PLACE_BACKUP_SECOND) continue ;; esac
    printf '%s\n' "${!v}"
  done | sort -u
}
plan_guests_on() {  # guests the map places on $1
  local host="$1" v g; for v in $(compgen -A variable PLACE_ 2>/dev/null); do
    case "$v" in PLACE_BACKUP_SECOND) continue ;; esac
    [ "${!v}" = "$host" ] || continue
    g="$(echo "${v#PLACE_}" | tr 'A-Z_' 'a-z-')"
    [ -n "${!v}" ] && printf '%s\n' "$g"
  done | sort
}
plan_sum() {  # <host> -> "vcpu ram_mb disk_gb data_gb count", from the specs
  local host="$1" g sv vc rm dk dt; local tv=0 tr=0 td=0 tdd=0 n=0
  for g in $(plan_guests_on "$host"); do
    sv="VM_$(echo "$g" | tr 'a-z-' 'A-Z_')"; [ -n "${!sv:-}" ] || continue
    IFS=: read -r vc rm dk dt <<< "${!sv}"
    tv=$((tv+vc)); tr=$((tr+rm)); td=$((td+dk)); tdd=$((tdd+${dt:-0})); n=$((n+1))
  done
  printf '%s %s %s %s %s' "$tv" "$tr" "$td" "$tdd" "$n"
}

# ---- finish (B-06 slice 4, decision D6, 2026-09-27) --------------------------------------
# Run ON the guest's host once its console log says DONE. In order:
#   1. READ that the guest's LAST run reached DONE, and what it reported deleting - from every
#      console log, oldest first: virtlogd rotates at 2 MB into a 0600 file (found in slice 3), so
#      a run can straddle two files and the live one alone can miss the start.
#   2. CHECK FROM OUTSIDE what the guest cannot check on itself - this replaces 05's old off-box
#      [y/N]: ssh answers through its firewall; a port nothing opens to this host is DROPPED (a
#      timeout is ufw's default-deny; "refused" would be a closed port with no firewall in front);
#      the enclave DNS resolves it both ways, asked directly so /etc/hosts cannot answer instead.
#      TIME IS NOT CHECKABLE FROM OUTSIDE TODAY - no guest is scraped and no clock-offset alert
#      exists anywhere. Said on every run, never skipped silently: backlog 3.39.
#   3. DETACH AND SHRED the seed (admin hash, keys) and the provisioning disk (credentials file,
#      Pro token) - D6. Neither is used after first boot. Failed checks do NOT stop this: the
#      disks cannot help a recovery, and the secrets on them should not outlive a failed check.
#   4. PROVE IT STILL BOOTS: a COLD restart (shutdown + start - a guest reboot keeps the same qemu
#      and the disks it had), then ssh must answer again and the console must show no failed unit
#      beyond FINISH_EXPECTED_FAILED (vm-specs.env). --no-reboot skips it and says so.
#   5. PRINT THE REGISTER LINE for airgap-media §9.
# -n does 1 and 2 only. Exit 1 if any check failed - after 3 and 4 have still been done.
FINISH_PROBE_PORT="${FINISH_PROBE_PORT:-65531}"
FINISH_WAIT="${FINISH_WAIT:-240}"
# ANY host key type, and GENTLY. Found on pg-01 2026-09-27, the first live finish: `-t ed25519`
# got nothing, because FIPS OpenSSH (guest and host) offers only ECDSA and RSA - a false "ssh does
# NOT answer". And the wait loop knocked every few seconds, while a guest's ssh rule is `ufw limit`
# (6 connections per 30 s from one source, DROP after that, the window renewed by every attempt):
# finish locked its own host out of the guest for as long as it kept knocking. 12 s apart stays
# under the limit.
FINISH_KNOCK=12
# THE REGISTER LINE IS WRITTEN WHEN THE SHREDDING HAPPENS, and a re-run reprints THAT - found on
# pg-01's second finish run, 2026-09-27: it found both disks already gone and still printed
# "shredded <now>", a false entry in an audit record. No secret in it; root-owned, 0644.
FINISH_RECORD_DIR="${FINISH_RECORD_DIR:-/var/lib/enclave/finish}"
_ssh_answers() { [ -n "$(ssh-keyscan -T 5 "$ADDRESS" 2>/dev/null)" ]; }
cmd_finish() {
  local logdir="$POOL/console" prov="$POOL/seed/$VM-prov.iso" logs prog last bad=0
  virsh dominfo "$VM" >/dev/null 2>&1 || die "$VM is not defined on $(hostname -s)"
  logs="$(ls -1r "$logdir/$VM-console.log"* 2>/dev/null || true)"
  [ -n "$logs" ] || die "no console log for $VM in $logdir"

  # 1. the last run
  prog="$(while IFS= read -r _f; do cat "$_f"; done <<< "$logs" | tr -d '\r' \
          | grep -ao "ENCLAVE-HARDEN $VM .*" || true)"
  last="$(printf '%s\n' "$prog" | tail -1)"
  case "$last" in
    "ENCLAVE-HARDEN $VM DONE"*) ok "last run reached DONE: ${last#ENCLAVE-HARDEN "$VM" DONE }" ;;
    "") die "no ENCLAVE-HARDEN line for $VM in its console log - composed with --harden, or run by hand?" ;;
    *)  die "$VM's last run did not finish. Its last line:
         $last
       finish only follows DONE; a halted guest keeps its disks until it is fixed and re-run." ;;
  esac
  local deleted done_at
  deleted="$(printf '%s' "$last" | sed -n 's/.* deleted:\([^@]*\).*/\1/p' | sed 's/^ *//; s/ *$//')"
  done_at="$(printf '%s' "$last" | sed -n 's/.* @\([0-9T:Z-]*\)$/\1/p')"
  case "$deleted" in
    *KEPT*|""|nothing) warn "the guest did NOT report deleting its credentials ('${deleted:-no report}') - check it by hand"; bad=1 ;;
    *credentials.env*) ok "the guest deleted its own: $deleted" ;;
    *) warn "the guest's deletion report does not name credentials.env: $deleted"; bad=1 ;;
  esac

  # 2. from outside
  say ""; say "checks from outside $VM ($ADDRESS), made from $(hostname -s):"
  # One silent miss is not a verdict: this host may be inside a ufw-limit window left by an
  # earlier run's knocking (pg-01's second finish, 2026-09-27). Wait the window out, ask once more.
  if _ssh_answers || { say "  ssh did not answer - waiting 35 s in case this host is rate-limited, then once more"; sleep 35; _ssh_answers; }; then
    ok "ssh answers through its firewall (22/tcp)"
  else warn "ssh does NOT answer - the only way in besides the console"; bad=1; fi
  local rc=0
  timeout 6 bash -c "exec 3<>/dev/tcp/$ADDRESS/$FINISH_PROBE_PORT" 2>/dev/null || rc=$?
  case "$rc" in
    124) ok "port $FINISH_PROBE_PORT is DROPPED (timed out) - the firewall is default-deny" ;;
    0)   warn "port $FINISH_PROBE_PORT ANSWERED - something listens and the firewall lets this host in"; bad=1 ;;
    *)   warn "port $FINISH_PROBE_PORT was REFUSED, not dropped - no firewall in front of it (is ufw active?)"; bad=1 ;;
  esac
  local dns fwd rev
  dns="$("$ENCLAVE_DIR/apply-addresses.sh" resolver-check 2>/dev/null || true)"
  if [ -z "$dns" ]; then warn "the enclave DNS is not answering - forward and reverse NOT checked"; bad=1
  else
    fwd="$(dig +short +time=3 +tries=1 @"$dns" "$VM.$DOMAIN" A 2>/dev/null | tail -1 || true)"
    rev="$(dig +short +time=3 +tries=1 @"$dns" -x "$ADDRESS" 2>/dev/null | tail -1 || true)"
    if [ "$fwd" = "$ADDRESS" ]; then ok "enclave DNS $dns: $VM.$DOMAIN -> $fwd"
    else warn "enclave DNS $dns: $VM.$DOMAIN -> '${fwd:-nothing}', expected $ADDRESS"; bad=1; fi
    if [ "$rev" = "$VM.$DOMAIN." ]; then ok "enclave DNS $dns: $ADDRESS -> $rev"
    else warn "enclave DNS $dns: $ADDRESS -> '${rev:-nothing}', expected $VM.$DOMAIN."; bad=1; fi
  fi
  warn "time sync: NOT checked from outside - no guest is scraped and no clock-offset alert exists (backlog 3.39)"

  if [ "$DRY" -eq 1 ]; then say ""; say "-n: stopping here - nothing detached, shredded or restarted"; return "$bad"; fi

  # 3. detach and shred - the persistent config first, so the next start cannot ask for a file
  #    that is gone; then the file. A re-run finds both already gone and says so.
  local placed="" path tgt shredded=0 record="$FINISH_RECORD_DIR/$VM.register"
  [ -e "$prov" ] && placed="$(date -u -r "$prov" +%FT%TZ)"
  say ""
  for path in "$SEED" "$prov"; do
    tgt="$(virsh domblklist "$VM" --details --inactive 2>/dev/null | awk -v p="$path" '$4==p {print $3}')"
    [ -n "$tgt" ] || tgt="$(virsh domblklist "$VM" --details 2>/dev/null | awk -v p="$path" '$4==p {print $3}')"
    if [ -n "$tgt" ]; then
      virsh detach-disk "$VM" "$tgt" --persistent >/dev/null 2>&1 \
        || virsh detach-disk "$VM" "$tgt" --config >/dev/null 2>&1 \
        || die "could not detach $tgt ($path) from $VM - nothing shredded"
    fi
    ! virsh dumpxml --inactive "$VM" | grep -qF "$path" \
      || die "$path is still in $VM's configuration - refusing to shred a disk the next start needs"
    if [ -e "$path" ]; then shred -u "$path" && ok "detached${tgt:+ ($tgt)} and shredded: $path" && shredded=$((shredded + 1))
    else ok "already gone: $path"; fi
  done

  # 4. prove it boots without them
  if [ "$NO_REBOOT" -eq 1 ]; then
    warn "--no-reboot: NOT proven that $VM boots without its seed. When convenient:"
    warn "  sudo virsh shutdown $VM ; (wait for 'shut off') ; sudo virsh start $VM"
  else
    local before=0 i st new failed
    before="$(wc -l < "$logdir/$VM-console.log" 2>/dev/null || echo 0)"
    say "cold restart of $VM (shutdown + start) to prove it boots without them ..."
    virsh shutdown "$VM" >/dev/null 2>&1 || true
    for i in $(seq 1 "$FINISH_WAIT"); do
      st="$(virsh domstate "$VM" 2>/dev/null || true)"; [ "$st" = "shut off" ] && break; sleep 1
    done
    if [ "$st" != "shut off" ]; then
      warn "$VM did not shut down in ${FINISH_WAIT}s - nothing forced. The disks ARE shredded; start it by hand."
      bad=1
    else
      virsh start "$VM" >/dev/null || die "virsh start $VM failed after the disks were removed"
      chmod 0644 "$logdir/$VM-console.log" 2>/dev/null || true
      local up=0 deadline=$((SECONDS + FINISH_WAIT))
      sleep 20                                  # let it boot before the first knock
      while [ "$SECONDS" -lt "$deadline" ]; do
        if _ssh_answers; then up=1; break; fi
        sleep "$FINISH_KNOCK"
      done
      if [ "$up" -eq 1 ]; then
        ok "$VM is back and ssh answers"
      else warn "$VM did not answer ssh within the wait after the restart"; bad=1; fi
      if virsh domblklist "$VM" --details | grep -qF -e "$SEED" -e "$prov"; then
        warn "a removed disk is still attached after the restart"; bad=1
      else ok "running without seed or provisioning disk"; fi
      [ -z "$DATA_DISK" ] || say "  its data disk is vdb from this boot on (it was vdc behind the seed) - mount it by LABEL or UUID, never /dev/vdX (B-06a)"
      # The console since the start. If it rotated meanwhile, the whole new file is all "since".
      if [ "$(wc -l < "$logdir/$VM-console.log")" -lt "$before" ]; then before=0; fi
      new="$(tail -n +"$((before + 1))" "$logdir/$VM-console.log" | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g')"
      failed="$(printf '%s\n' "$new" | grep -ao 'Failed to start [^ ]*' | awk '{print $4}' | sort -u \
                | grep -vxF -f <(printf '%s\n' ${FINISH_EXPECTED_FAILED:-} | awk 'NF') || true)"
      if [ -n "$failed" ]; then warn "failed at boot, beyond the expected (${FINISH_EXPECTED_FAILED:-none}): $(printf '%s' "$failed" | tr '\n' ' ')"; bad=1
      else ok "no unit failed at boot beyond the expected (${FINISH_EXPECTED_FAILED:-none})"; fi
      if printf '%s\n' "$new" | grep -qaiE 'fallback datasource|DataSourceNone'; then
        warn "cloud-init fell back to no datasource - it may have rewritten the network config"; bad=1
      fi
    fi
  fi

  # 5. the register line - written by the run that shredded, reprinted (never re-invented) after
  say ""
  say "REGISTER - airgap-media §9, copy into the custody log:"
  if [ "$shredded" -gt 0 ]; then
    install -d -m 0755 "$FINISH_RECORD_DIR"
    {
      printf '  credentials.%s.env   placed %s by 03-compose-vm.sh --harden on %s\n' "$VM" "${placed:-(unknown - no provisioning disk found)}" "$(hostname -s)"
      printf '                        deleted from %s %s by the guest itself: %s\n' "$VM" "${done_at:-(no time in the log - that run predates timestamps)}" "${deleted:-none reported}"
      printf '                        provisioning disk + seed shredded %s by %s on %s\n' "$(date -u +%FT%TZ)" "${SUDO_USER:-root}" "$(hostname -s)"
    } > "$record"
    chmod 0644 "$record"
    cat "$record"
  elif [ -r "$record" ]; then
    cat "$record"; say "  (reprinted from $record - written by the finish run that shredded)"
  else
    say "  credentials.$VM.env   disks already gone, and no record of when - shredded by an earlier"
    say "                        finish that predates $record (or by --destroy). Fill the times by hand."
  fi
  say ""
  [ "$bad" -eq 0 ] && ok "finish: $VM is done" || warn "finish: done, but a check above FAILED - read it before calling $VM finished"
  return "$bad"
}

cmd_plan() {
  local spec=0; [ "${1:-}" = --spec ] && spec=1
  local me; me="$(hostname -s)"
  local reserve="${HOST_RESERVE_MB:-4096}" fail=0
  printf '\n  PLACEMENT PLAN - VM_PROFILE=%s\n\n' "$VM_PROFILE"

  local h vc rm dk dt n
  printf '  %-8s %-5s %-9s %-10s %-9s %s\n' HOST GUESTS vCPU RAM DISK "guests"
  for h in $(plan_hosts); do
    read -r vc rm dk dt n <<< "$(plan_sum "$h")"
    printf '  %-8s %-5s %-9s %-10s %-9s %s\n' "$h" "$n" "$vc" \
      "$(( (rm + reserve) / 1024 )) GiB" "$(( dk + dt )) GB" "$(plan_guests_on "$h" | tr '\n' ' ')"
  done
  printf '\n  RAM includes %s MiB reserved for each host itself.\n' "$reserve"
  printf '  DISK is the qcow2 CEILING, deliberately over-committed - the disks are sparse.\n'

  # ---- rules that hold whatever the hardware is -----------------------------------------
  printf '\n  RULES\n'
  local grp m seen dup
  IFS='|' read -ra GRPS <<< "${ANTI_AFFINITY:-}"
  for grp in "${GRPS[@]:-}"; do
    [ -n "$grp" ] || continue
    seen=""; dup=""
    for m in $grp; do
      h="$(vm_place "$m")"; [ -n "$h" ] || continue
      case " $seen " in *" $h "*) dup="$dup $m@$h" ;; esac
      seen="$seen $h"
    done
    if [ -n "$dup" ]; then
      warn "anti-affinity BROKEN for [$grp ] -$dup"; fail=1
    else
      ok "anti-affinity holds: $grp"
    fi
  done
  local second="${PLACE_BACKUP_SECOND:-}"
  if [ -z "$second" ]; then
    warn "no PLACE_BACKUP_SECOND - the backups have no copy off their own host (red flag 1.2)"; fail=1
  elif [ "$second" = ring ]; then
    # Each host's second copy goes to the next host, the last wrapping to the first. Every
    # guest then has a copy on a machine that is not the one running it.
    local -a ring=(); while read -r h; do [ -n "$(plan_guests_on "$h")" ] && ring+=("$h"); done < <(plan_hosts)
    if [ "${#ring[@]}" -lt 2 ]; then
      warn "PLACE_BACKUP_SECOND=ring needs at least two hosts running guests - name a host instead"; fail=1
    else
      local i nxt line=""
      for i in "${!ring[@]}"; do
        nxt="${ring[$(( (i+1) % ${#ring[@]} ))]}"
        line="$line ${ring[$i]}->$nxt"
      done
      ok "backup ring:$line"
    fi
  else
    local stranded; stranded="$(plan_guests_on "$second" | tr '\n' ' ')"
    if [ -n "$stranded" ]; then
      warn "second backup copy is on $second, which also RUNS: $stranded - those guests have no off-host copy"; fail=1
    else
      ok "second backup copy on $second, which runs no guests"
    fi
  fi

  [ "$spec" -eq 1 ] && { printf '\n  SPEC MODE - no hardware was measured. Per host, the design needs:\n'
    printf '    RAM     the figure above, and the drives below are a CHASSIS decision:\n'
    printf '    devices OS (mirrored pair) - etcd - database data - one per Ceph OSD - VM pool\n'
    printf '            ~6 drives per host; see backlog 2.8\n\n'; return 0; }

  # ---- verify against THIS machine ------------------------------------------------------
  read -r vc rm dk dt n <<< "$(plan_sum "$me")"
  printf '\n  VERIFY - %s, measured now\n' "$me"
  if [ "$n" -eq 0 ]; then
    say "the map places no guest on $me - nothing to check here"; printf '\n'; return 0
  fi
  local have_threads have_ram_mb
  have_threads="$(nproc)"
  have_ram_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
  local need_ram=$(( rm + reserve ))
  if [ "$need_ram" -le "$have_ram_mb" ]; then
    ok "RAM: need $((need_ram/1024)) GiB (guests + reserve), have $((have_ram_mb/1024)) GiB"
  else
    warn "RAM: need $((need_ram/1024)) GiB, have only $((have_ram_mb/1024)) GiB - THIS LAYOUT DOES NOT FIT"; fail=1
  fi
  # vCPU over-subscription is a choice, not a fault - the lab runs 2:1 deliberately. Report it.
  if [ "$vc" -le "$have_threads" ]; then
    ok "vCPU: $vc assigned, $have_threads threads"
  else
    say "[--] vCPU: $vc assigned on $have_threads threads - $(( (vc*10+have_threads/2) / have_threads ))/10 : 1 over-subscription (deliberate in the lab)"
  fi
  # || true: df fails when the pool is not there, and under `set -e` an unguarded assignment
  # from a failing pipeline ENDS THE SCRIPT SILENTLY - which it did on 2026-09-20, skipping
  # every check after this line and still exiting 0. A missing pool must be reported, not fatal.
  local pool_avail; pool_avail="$(df -BG --output=avail "$POOL" 2>/dev/null | tail -1 | tr -dc 0-9 || true)"
  if [ -n "$pool_avail" ]; then
    # The ceiling is over-committed on purpose; what matters is that today's guests fit.
    if [ "$dk" -le "$pool_avail" ]; then
      ok "pool $POOL: ${pool_avail} GB free, ${dk} GB of ceilings - fits even unsparse"
    else
      warn "pool $POOL: ${pool_avail} GB free vs ${dk} GB of ceilings - sparse today, and it CAN fill. Watch it or grow the pool"
    fi
  else
    warn "cannot measure $POOL - is it mounted?"
  fi
  if [ "$dt" -gt 0 ]; then
    local dpool="${VM_POOL_DATA:-}" dsize
    [ -n "$dpool" ] || { warn "guests here want ${dt} GB of data disk and VM_POOL_DATA is unset"; fail=1; }
    # Data disks are RESERVED (3.42), so the pool's SIZE must hold them all - a hard fit, not a
    # ceiling. And the pool must be its own mount, or the data disk lands on the OS drive (3.43).
    if [ -n "$dpool" ]; then
      if ! mountpoint -q "$dpool" 2>/dev/null; then
        warn "data pool $dpool is not a mounted volume on $me - a data disk would land on the OS drive"; fail=1
      else
        dsize="$(df -BG --output=size "$dpool" 2>/dev/null | tail -1 | tr -dc 0-9 || true)"
        if [ -n "$dsize" ] && [ "$dt" -le "$dsize" ]; then
          ok "data pool $dpool: ${dsize} GB volume holds the ${dt} GB of reserved data disks"
        else
          warn "data pool $dpool: ${dsize:-?} GB volume, ${dt} GB of RESERVED data disks - does not fit"; fail=1
        fi
      fi
    fi
  fi
  # THE RING BACKUP COPY IS REAL BYTES ON THIS HOST'S IMAGES POOL (3.42). With PLACE_BACKUP_SECOND
  # ring, every host running guests also receives the previous host's copy - host-1 held host-4's
  # 173.7 GB on 2026-09-27, and this planner said "plan holds" without counting a byte of it.
  if [ "${PLACE_BACKUP_SECOND:-}" = ring ] && [ -n "$pool_avail" ]; then
    local psize reserve_copy="${BACKUP_COPY_RESERVE_GB:-200}"
    psize="$(df -BG --output=size "$POOL" 2>/dev/null | tail -1 | tr -dc 0-9 || true)"
    if [ -n "$psize" ] && [ $(( dk + reserve_copy )) -le "$psize" ]; then
      ok "pool $POOL: ${psize} GB holds ${dk} GB of OS-disk ceilings plus a ${reserve_copy} GB backup-copy reserve (BACKUP_COPY_RESERVE_GB)"
    else
      warn "pool $POOL: ${psize:-?} GB vs ${dk} GB of OS-disk ceilings + ${reserve_copy} GB backup-copy reserve - over-committed; the copy is real bytes, the OS disks are sparse. Watch it"
    fi
  fi
  printf '\n'
  [ "$fail" -eq 0 ] || die "the plan does not hold on $me - fix the map or the hardware before composing"
  ok "plan holds on $me"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    --destroy)    DESTROY=1; shift ;;
    --spec)       PLAN_ARG=--spec; shift ;;
    --harden)     HARDEN=1; shift ;;
    --finish)     FINISH=1; shift ;;
    --no-reboot)  NO_REBOOT=1; shift ;;
    --cred-dir)   [ $# -ge 2 ] || die "--cred-dir needs a directory"; CRED_DIR="$2"; shift 2 ;;
    -h|--help)    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option $1" ;;
    *)            VM="$1"; shift ;;
  esac
done
[ -n "$VM" ] || { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }


[ -r "$ENCLAVE_DIR/enclave-addresses.env" ] || die "no enclave-addresses.env in $ENCLAVE_DIR"
[ -r "$ENCLAVE_DIR/vm-specs.env" ]          || die "no vm-specs.env in $ENCLAVE_DIR"
# shellcheck disable=SC1090
. "$ENCLAVE_DIR/enclave-addresses.env"
# shellcheck disable=SC1090
. "$ENCLAVE_DIR/vm-specs.env"

# `plan` answers "what runs where, and does it fit" and composes nothing. It needs the two
# env files above and nothing else - no root, no libvirt - so it runs before any of the
# machine-specific checks below, and on a machine that holds no guests at all.
if [ "$VM" = plan ]; then POOL="${VM_POOL:-}"; cmd_plan "$PLAN_ARG"; exit 0; fi

# svc-mgmt-01 -> SVC_MGMT_01
KEY_NAME="$(echo "$VM" | tr 'a-z-' 'A-Z_')"
ADDRESS="${!KEY_NAME:-}"
SPEC_VAR="VM_$KEY_NAME"; SPEC="${!SPEC_VAR:-}"
[ -n "$ADDRESS" ] || die "$VM has no address. Add $KEY_NAME to enclave-addresses.env."
[ -n "$SPEC" ]    || die "$VM has no spec. Add $SPEC_VAR to vm-specs.env."
# vcpus:ram_mb:disk_gb[:data_gb] - the 4th field is OPTIONAL and reads as empty when absent,
# so every spec written before 2026-09-16 behaves exactly as it did.
IFS=: read -r VCPUS RAM_MB DISK_GB DATA_GB <<< "$SPEC"

POOL="${VM_POOL:?}"; BRIDGE="${VM_BRIDGE:?}"; DOMAIN="${ENCLAVE_DOMAIN:?}"
DISK="$POOL/$VM.qcow2"
SEED="$POOL/seed/$VM-seed.iso"

# A SECOND disk, on a DIFFERENT PHYSICAL DEVICE. Only pg-01..03 use it today: their data and
# WAL belong on the 1 TB M.2, not on the 256 GB M.2 that already carries the host OS and
# k8s-cp-0N - two databases fsyncing through one device is how you get spurious leader
# elections in both etcd clusters at once. VM_POOL_DATA is where; unset means no data disk,
# and asking for one without it is refused rather than silently landed on the OS device.
DATA_POOL="${VM_POOL_DATA:-}"
DATA_DISK=""
if [ -n "${DATA_GB:-}" ] && [ -n "$DATA_POOL" ]; then DATA_DISK="$DATA_POOL/$VM-data.qcow2"; fi

# ---- destroy ----------------------------------------------------------------------------
if [ "$DESTROY" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  say "this DESTROYS $VM and $DISK"
  run virsh destroy "$VM" 2>/dev/null || true
  # --nvram also deletes the guest's UEFI variable store; undefine refuses a UEFI guest
  # without it (or --keep-nvram).
  run virsh undefine "$VM" --nvram 2>/dev/null || true
  run rm -f "$DISK" "$SEED" ${DATA_DISK:+"$DATA_DISK"}
  # The provisioning disk (--harden) holds this guest's credentials file and the Pro token: shred.
  if [ -e "$POOL/seed/$VM-prov.iso" ]; then run shred -u "$POOL/seed/$VM-prov.iso"; fi
  ok "$VM removed"; exit 0
fi

# ---- refuse to compose a guest anywhere but its declared home ----------------------------
# CHECKED BEFORE THE ROOT CHECK, DELIBERATELY: being on the wrong machine needs no
# privilege to discover, and an operator on the wrong host should be told THAT rather
# than being asked for a sudo password first.
# backlog 2.7. THIS WAS A WARNING, AND IT NAMED host-4 UNCONDITIONALLY - which is exactly how
# every service VM came to live on one machine (red flag 1.2). A warning refuses nothing, and
# the composer had no idea where a guest was supposed to live. The placement map in
# vm-specs.env is now the authority, and putting a guest somewhere else is an EDIT TO THE MAP,
# reviewable in git, rather than a decision made at a keyboard at 2am.
PLACE="$(vm_place "$VM")"
[ -n "$PLACE" ] || die "$VM has no declared home.
       Add PLACE_$KEY_NAME='host-N' to vm-specs.env - nothing is composed without one.
       Check the layout first:  $0 plan --spec"
PLACE_ADDR_VAR="$(echo "$PLACE" | tr 'a-z-' 'A-Z_')"; PLACE_ADDR="${!PLACE_ADDR_VAR:-}"
ME="$(hostname -s)"
if [ "$DRY" -eq 0 ] && [ "$ME" != "$PLACE" ] \
   && ! { [ -n "$PLACE_ADDR" ] && ip -br addr | grep -qw "${PLACE_ADDR%%/*}"; }; then
  die "$VM belongs on $PLACE (VM_PROFILE=$VM_PROFILE) and this machine is $ME.
       Either run it on $PLACE, or change PLACE_$KEY_NAME in vm-specs.env and say why."
fi
[ "$DRY" -eq 1 ] || ok "placement: $VM -> $PLACE (this machine)"

[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"

if [ "$FINISH" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "--finish reads the console logs (0600 after a rotation) - run with sudo, -n included"
  cmd_finish && exit 0 || exit 1
fi


# These describe the target host, so they are checked for a real run only. A dry run must be
# usable anywhere - reviewing the rendered cloud-init is exactly what it is for.
if [ "$DRY" -eq 0 ]; then
  virsh version >/dev/null 2>&1 || die "cannot reach libvirt - run 03-host-services.sh libvirt"
  if virsh dominfo "$VM" >/dev/null 2>&1; then
    die "$VM already exists. Remove it first:  sudo $0 $VM --destroy"
  fi
  mountpoint -q "$POOL" || warn "$POOL is not its own volume - VM disks will fill the root fs"
  # A DATA DISK ON AN UNMOUNTED POOL IS A DATA DISK ON THE OS DRIVE. Found 2026-09-27 checking
  # host-3 for pg-03: it has no images-data volume, and the `install -d` below would have created
  # the directory on /var (30 GB, the OS disk) and put the database there. Refuse instead.
  if [ -n "$DATA_DISK" ] && ! mountpoint -q "$DATA_POOL"; then
    die "$VM wants a data disk in $DATA_POOL, and that is not a mounted volume on $(hostname -s).
       It would land on the OS drive. Build the data pool first (03-host-services.sh datavg,
       DATA_LVS with a libvirt-data volume), then compose."
  fi
fi

# ---- tools -------------------------------------------------------------------------------
MISSING=""
for c in cloud-localds qemu-img virt-install; do command -v "$c" >/dev/null || MISSING="$MISSING $c"; done
if [ -n "$MISSING" ] && [ "$DRY" -eq 0 ]; then
  say "installing tooling for:$MISSING"
  run apt-get install -y --no-install-recommends cloud-image-utils qemu-utils \
    || die "could not install cloud-image-utils / qemu-utils - is apt pointed at the mirror?"
fi
[ -r "$VM_BASE_IMAGE" ] || [ "$DRY" -eq 1 ] || die "no base image at $VM_BASE_IMAGE
       Copy it from stage-01:
         scp encadmin@${STAGE_01:-stage-01}:/srv/bundle-staging/media/ubuntu-24.04-minimal-cloudimg-amd64.img \\
             $VM_BASE_IMAGE"

# CAN QEMU REACH ITS DISKS? Checked BEFORE anything is created or any password asked for.
# qemu runs as QEMU_USER (libvirt-qemu), and on a hardened host a directory created under
# root's umask 077 is 0700 - found 2026-09-27 on host-1, where /var/lib/libvirt was 0700 and
# virt-install failed on the data disk only after the admin password had been typed.
QEMU_USER="${QEMU_USER:-libvirt-qemu}"
if [ "$DRY" -eq 0 ] && id "$QEMU_USER" >/dev/null 2>&1; then
  _blocked=""
  for _d in "$POOL" ${DATA_POOL:+"$DATA_POOL"}; do
    runuser -u "$QEMU_USER" -- test -x "$_d" 2>/dev/null || _blocked="$_blocked $_d"
  done
  [ -z "$_blocked" ] || die "$QEMU_USER cannot reach:$_blocked
       qemu runs as $QEMU_USER and needs search (x) on every directory above its disks.
       Look for a 0700 parent:   namei -m$_blocked
       On host-1/host-2 it was /var/lib/libvirt (0700 from root's umask 077; the package ships 0755):
         sudo chmod 0755 /var/lib/libvirt
       03-host-services.sh datavg now sets it; this host was prepared before that fix."
  ok "qemu ($QEMU_USER) can reach:$( printf ' %s' "$POOL" ${DATA_POOL:+"$DATA_POOL"})"
fi
# ---- the admin password -------------------------------------------------------------------
# ASKED BEFORE ANYTHING IS CREATED (3.38). It used to be asked after the OS and data disks were
# made; on 2026-09-27 a mistyped pair killed a pg-01 recompose and left disks with no domain.
# Now a typo, a bad hash or a refused credentials file costs nothing - no file exists yet.
#
# EVERY VM GETS ONE, and it is not optional.
#
# The composer used to create the user with `sudo: ALL=(ALL) NOPASSWD:ALL` and NO password at
# all. That works right up until the DISA STIG is applied: usg removes NOPASSWD (correctly -
# STIG requires sudo to authenticate), and sudo then asks for a password that was never set.
# There is no number of attempts that succeeds. On svc-harbor-01 on 2026-09-08 that locked
# the only sudo-capable account out of root on a headless VM, recoverable only by editing the
# disk offline from the hypervisor.
#
# Had it been found later it would have done that to all six Kubernetes nodes at once.
#
# NOPASSWD is KEPT as well, deliberately: it is convenient before hardening, and STIG removes
# it afterwards - at which point the password below is what keeps the machine usable.
#
# A HASH goes in the user-data, never the password. cloud-init's user-data sits on the seed
# ISO and in /var/lib/cloud on the guest, both readable.
#
# WHERE THE HASH COMES FROM (3.32): VM_ADMIN_PASSWORD_HASH in the environment > the same key in
# the site credentials file (/etc/enclave/credentials.env, root 600 - see credentials.sh) >
# asked for here. One hash for every guest built from that file.
VM_ADMIN_HASH="${VM_ADMIN_PASSWORD_HASH:-}"; VM_ADMIN_SRC="VM_ADMIN_PASSWORD_HASH (environment)"
if [ -z "$VM_ADMIN_HASH" ] && [ "$DRY" -eq 0 ]; then
  # shellcheck source=../enclave/credentials.sh
  . "$ENCLAVE_DIR/credentials.sh"
  cred_require_safe
  VM_ADMIN_HASH="$(cred_get VM_ADMIN_PASSWORD_HASH)"; VM_ADMIN_SRC="$ENCLAVE_CREDENTIALS"
fi
if [ -n "$VM_ADMIN_HASH" ]; then
  # CHECK THE SHAPE: a truncated paste would set a password that matches nothing, and the
  # lock-out above would only show up after hardening.
  [[ "$VM_ADMIN_HASH" =~ ^\$6\$[^\$]+\$[./A-Za-z0-9]+$ ]] \
    || die "the VM admin hash from $VM_ADMIN_SRC is not SHA-512 crypt (\$6\$...) - nothing created"
  ok "VM admin password: hash from $VM_ADMIN_SRC - no prompt"
elif [ "$DRY" -eq 0 ]; then
  if [ -t 0 ]; then
    printf '  no VM_ADMIN_PASSWORD_HASH set - enter a password for %s on %s\n' "${VM_USER:-encadmin}" "$VM"
    # THREE TRIES, like passwd. A mismatch used to die - and it came AFTER the disks were made.
    _try=1
    while :; do
      read -rsp '  password: ' _p1; echo
      read -rsp '  again:    ' _p2; echo
      [ -n "$_p1" ] || die "refusing to create a VM with an empty password - STIG will make it unusable"
      [ "$_p1" = "$_p2" ] && break
      [ "$_try" -lt 3 ] || die "the two entries did not match 3 times - nothing created"
      warn "the two entries do not match - try again ($_try of 3)"; _try=$((_try + 1))
    done
    # -stdin keeps it off the command line and out of ps.
    VM_ADMIN_HASH=$(printf '%s' "$_p1" | openssl passwd -6 -stdin) || die "hashing failed"
    unset _p1 _p2
  else
    die "no VM_ADMIN_PASSWORD_HASH and no terminal to prompt on.
      Unattended:     VM_ADMIN_PASSWORD_HASH in $ENCLAVE_CREDENTIALS (make-credentials.sh)
      Or for one run: VM_ADMIN_PASSWORD_HASH='<hash>' sudo -E ./03-compose-vm.sh $VM"
  fi
fi

# ---- --harden: what the guest needs to harden ITSELF (B-06 slice 3) ------------------------
# GATHERED AND CHECKED BEFORE ANYTHING IS CREATED, like the password above (3.38): a missing
# token found after the disks exist is the same wasted round trip. Each input is the one a person
# would otherwise carry to the guest by hand:
#   the repo            - EXACTLY the files push-repo delivered (.pushed-files), never the whole
#                         directory, which can hold anything put there since
#   credentials.<vm>    - from CRED_DIR (the enclave-cred stick, mounted read-only - airgap-media
#                         §9); checked by the SAME reader the guest will use, and it must carry
#                         THIS guest's break-glass key, so another machine's file is refused
#   the Pro token       - the host's own copy (D3)
#   the answer file     - the host's own copy (the one its own scan used)
PROV=""
if [ "$HARDEN" -eq 1 ]; then
  PROV="$POOL/seed/$VM-prov.iso"
  REPO_ROOT="$(cd "$SELF/../.." && pwd)"
  GUEST_CRED="$CRED_DIR/credentials.$VM.env"
  PRO_TOKEN="${PRO_TOKEN_FILE:-$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.pro-contract-token}"
  ANSWER_FILE="${STIG_ANSWER_FILE:-/srv/stig-tools/Ubuntu24_AnswerFile.xml}"
  # Its audit-offload key - every guest but the collector, which delivers to itself. 05's
  # auditoffload step proves it reaches the collector, so a missing key would halt the run late.
  AUDIT_KEY_SRC=""
  [ "$ADDRESS" = "${SVC_OBS_01:-}" ] || AUDIT_KEY_SRC="$CRED_DIR/audit-offload.$VM.key"
  # A guest with no firewall table would harden for ten minutes and halt at tailor. Say so now.
  if ! awk '/^ufw_rules\(\) \{/{f=1;next} f&&/^EOF$/{exit} f' "$ENCLAVE_DIR/stig-tailor.sh" \
       | awk -F'\t' -v m="$VM" '$1==m {found=1} END {exit !found}'; then
    die "$VM has no ufw rule table in stig-tailor.sh - its unattended run would halt at tailor.
       Write its rows first (decision D5: each port registered in ppsm-services.tsv)."
  fi
  if [ "$DRY" -eq 1 ]; then
    say "harden  : would build $PROV from:"
    say "            repo        $REPO_ROOT ($([ -s "$REPO_ROOT/.pushed-files" ] && echo "$(wc -l < "$REPO_ROOT/.pushed-files") files per .pushed-files" || echo 'NO .pushed-files - a real run refuses'))"
    say "            credentials $GUEST_CRED"
    say "            Pro token   $PRO_TOKEN"
    say "            answers     $ANSWER_FILE"
    say "            audit key   ${AUDIT_KEY_SRC:-(none - $VM is the collector)}"
  else
    command -v genisoimage >/dev/null || die "no genisoimage - it comes with cloud-image-utils, which cloud-localds needs too"
    [ -s "$REPO_ROOT/.pushed-files" ] && [ -s "$REPO_ROOT/.pushed-from" ] || die "no .pushed-files in $REPO_ROOT.
       It lists exactly what push-repo delivered, so nothing else can reach a guest. Re-push:
         (on stage-01)  ./scripts/install/push-repo-to-host.sh $(hostname -s)"
    ! grep -qE '^/|(^|/)\.\.(/|$)' "$REPO_ROOT/.pushed-files" \
      || die "$REPO_ROOT/.pushed-files has an absolute or .. path - refusing to build from it"
    [ -e "$GUEST_CRED" ] || die "no credentials file for $VM at $GUEST_CRED.
       Mount the enclave-cred stick read-only there (airgap-media §9), or pass --cred-dir."
    # shellcheck source=../enclave/credentials.sh
    . "$ENCLAVE_DIR/credentials.sh"
    ENCLAVE_CREDENTIALS="$GUEST_CRED" cred_require_safe
    for _k in GRUB_PASSWORD_HASH ADMIN2_PASSWORD_HASH "BREAKGLASS_PASSWORD_HASH_$KEY_NAME"; do
      [ -n "$(ENCLAVE_CREDENTIALS="$GUEST_CRED" cred_get "$_k")" ] \
        || die "$GUEST_CRED has no $_k - it is not $VM's file, or it was made without it"
    done
    [ -s "$PRO_TOKEN" ]   || die "no Pro token at $PRO_TOKEN (D3: the host's own copy) - or set PRO_TOKEN_FILE"
    if [ -n "$AUDIT_KEY_SRC" ]; then
      [ -e "$AUDIT_KEY_SRC" ] || die "no audit-offload key for $VM at $AUDIT_KEY_SRC - make-credentials.sh makes one
       per machine beside its credentials file; without it 05 halts at its auditoffload step."
      [ "$(stat -c '%U %a' "$AUDIT_KEY_SRC")" = "root 600" ] || die "$AUDIT_KEY_SRC is not root 600 ($(stat -c '%U %a' "$AUDIT_KEY_SRC")) - refusing a readable private key"
      ssh-keygen -y -f "$AUDIT_KEY_SRC" >/dev/null 2>&1 || die "$AUDIT_KEY_SRC does not parse as a private key"
    fi
    [ -s "$ANSWER_FILE" ] || die "no answer file at $ANSWER_FILE - push one to this host first:
         (on stage-01)  ./scripts/enclave/stig-tools.sh answers $(hostname -s)"
    ok "harden  : credentials ($GUEST_CRED), ${AUDIT_KEY_SRC:+audit key, }token, answer file, repo $(cut -c1-7 "$REPO_ROOT/.pushed-from") - all present"
  fi
fi

say "vm      : $VM  ($ADDRESS)"
say "spec    : ${VCPUS} vCPU, ${RAM_MB} MB, ${DISK_GB} GB sparse"
say "bridge  : $BRIDGE"

# ---- disk --------------------------------------------------------------------------------
# 0711: qemu can open a seed by its path, other users cannot list the directory - every
# seed carries the admin password hash and the authorized keys.
run install -d -m 0711 "$POOL/seed"
# Log the serial console to a file AND keep an interactive pty. A VM with no default route
# that fails to bring up networking is invisible: no ssh, and the log is the only evidence of
# what went wrong once nobody is watching.
#
# THIS WAS HALF-BROKEN UNTIL 2026-09-11 AND NOBODY NOTICED FOR A WEEK.
#   --console pty,target_type=serial   +   --serial file,path=...
# looks like "both", and is not. In libvirt a <console> with target type='serial' is a VIEW of
# the first serial port, not a second device - they share alias serial0 - so the two requests
# were reconciled and the FILE definition won. Every VM came out with:
#     <serial type='file'> ... <console type='file'>
# and NO pty at all. `virsh console` then fails with
#     error: internal error: character device serial0 is not using a PTY
# meaning no VM in the enclave had an interactive console: nothing could type a GRUB password,
# drive a rescue shell, or answer an fsck prompt. The recovery route the runbook advertised
# did not exist. See runbook 6.3j.
#
# The fix is ONE device that does both - a pty with a <log> child, supported by libvirt >=1.3.3
# (host has 10.0.0) and exposed by virt-install 4.1.0 as log.file / log.append.
LOGDIR="$POOL/console"
run install -d -m 0755 "$LOGDIR"
# The log is written by qemu, which recreates it under its own umask - so pre-creating it
# 0644 does NOT survive. It has to be chmod'd again AFTER virt-install has started the
# domain. A diagnostic nobody can read without an interactive sudo is only half a fix.
# A full copy, NOT a backing-file overlay. An overlay would save a few hundred MB per VM and
# tie all ten to one file: delete or corrupt the base and every VM dies at once, and the base
# can never be retired. A converted copy costs ~600 MB each - 6 GB across the fleet, against
# 1.9 TB - and each VM is then independent. Cheap insurance.
run qemu-img convert -f qcow2 -O qcow2 "$VM_BASE_IMAGE" "$DISK"
# Grows the VIRTUAL size only (still sparse); cloud-init's growpart extends the root
# filesystem into it on first boot.
run qemu-img resize "$DISK" "${DISK_GB}G"
ok "disk    : $DISK (independent copy, sparse, grown to ${DISK_GB}G)"

if [ -n "${DATA_GB:-}" ]; then
  [ -n "$DATA_POOL" ] || die "$VM asks for a ${DATA_GB}G data disk but VM_POOL_DATA is unset.
      A data disk on the OS device is not a data disk - the point of asking for one is that it
      is a different spindle. Set VM_POOL_DATA in vm-specs.env to a path on the data device."
  run install -d -m 0711 "$DATA_POOL"
  # CREATE, not convert - a data disk is blank, there is no base image for it.
  # RESERVED, NOT SPARSE (backlog 3.42, decided 2026-09-27). A sparse database disk promises space
  # it does not hold: on host-1 the ring backup copy filled the same volume to 25.8 GB free while
  # pg-01's 150 GiB disk had 24 MB allocated - the day the volume fills, PostgreSQL's writes fail.
  # falloc reserves every block at create time (fallocate - seconds, not a zero-fill), so a full
  # volume fails the copy or the compose, never a database write.
  [ -e "$DATA_DISK" ] || run qemu-img create -f qcow2 -o preallocation=falloc \
      "$DATA_DISK" "${DATA_GB}G"
  ok "data    : $DATA_DISK (${DATA_GB}G, RESERVED - preallocated, not sparse)"
  # IT LANDS AT vdc, BEHIND THE READ-ONLY SEED - AND THAT IS NOT STABLE. The seed disk is
  # only needed for the first boot; detach it later and the data disk moves vdc -> vdb.
  # So MOUNT IT BY UUID OR LABEL, NEVER BY /dev/vdX. An fstab entry naming vdc is a machine
  # that boots fine today and comes up with no database directory after the seed is removed.
  say "        mount it by UUID or LABEL - it is vdc now and would become vdb if the"
  say "        seed disk is ever detached. Never put /dev/vdX in its fstab."
fi

# ---- cloud-init --------------------------------------------------------------------------
# The hosts block comes from apply-addresses.sh so there is exactly one renderer. A VM that
# writes its own copy is a second source of truth waiting to disagree.
HOSTS_BLOCK="$("$ENCLAVE_DIR/apply-addresses.sh" render | sed 's/^/      /')"
# THE RESOLVER, FROM THE SAME RENDERER (backlog 6b.1e). Without it every VM is born with no
# enclave DNS - hosts-file names work, *.apps and CoreDNS forwarding do not. Included ONLY if
# the DNS server answers now: a resolver pointed at a dead server adds a timeout to every
# lookup the hosts file does not cover, which is worse than no resolver.
RESOLVER_WF=""; RESOLVER_RUN=""
if DNS_ADDR="$("$ENCLAVE_DIR/apply-addresses.sh" resolver-check 2>/dev/null)"; then
  RESOLVER_WF="  - path: /etc/systemd/resolved.conf.d/10-enclave-dns.conf
    permissions: '0644'
    content: |
$("$ENCLAVE_DIR/apply-addresses.sh" resolver | sed 's/^/      /')"
  RESOLVER_RUN="  - [ systemctl, restart, systemd-resolved ]"
  ok "resolver  : enclave DNS $DNS_ADDR answers - the VM will use it from first boot"
else
  warn "resolver  : enclave DNS is NOT answering - this VM gets /etc/hosts only."
  warn "            Afterwards, ON the VM: sudo ./apply-addresses.sh resolver-install"
fi
# Shared operator tmux config, same file the bare-metal hosts get.
TMUX_CONF=""
[ -r "$ENCLAVE_DIR/tmux.conf" ] && TMUX_CONF="$(sed 's/^/      /' "$ENCLAVE_DIR/tmux.conf")"
# The enclave root CA, so a VM trusts the PKI from its first boot rather than needing a visit.
# A machine that does not trust the root cannot reach an HTTPS mirror - and the failure looks
# like a certificate problem on the SERVER, which is where people look first.
# EVERY anchor in trust-anchors/, not just this CA's root. A site running DoD PKI drops its
# roots in there and composed VMs pick them up with no change here - which is the whole point
# of that directory being a directory.
ANCHOR_DIR="$ENCLAVE_DIR/trust-anchors"
ROOT_CA=""; ANCHOR_COUNT=0
if [ -d "$ANCHOR_DIR" ]; then
  for _a in "$ANCHOR_DIR"/*.crt; do
    [ -r "$_a" ] || continue
    # Each anchor is its own list entry: "    - |" then the PEM indented under it.
    ROOT_CA="${ROOT_CA}    - |
$(sed 's/^/      /' "$_a")
"
    ANCHOR_COUNT=$((ANCHOR_COUNT + 1))
  done
fi
# Delivered through cloud-init's `ca_certs` module, NOT through write_files plus a runcmd.
# The module order on a composed VM, read off svc-mgmt-01 rather than remembered:
#
#   cloud_init_modules   ... write_files, ca_certs, ...
#   cloud_config_modules ... apt_configure, runcmd, ...        <- runcmd only WRITES the script
#   cloud_final_modules  ... package_update_upgrade_install, ..., scripts_user
#                                                              ^ this is where runcmd RUNS
#
# So packages install before runcmd ever executes. `update-ca-certificates` in runcmd is too
# late by two module groups: with an https mirror the very first apt run happens against an
# untrusted root and fails, on a VM with no other route to a package. ca_certs runs in the
# first group, before apt_configure has even read the sources.
#
# An empty block is omitted entirely - `ca_certs: trusted: [ ]` with no cert is a parse error
# waiting for the one build where root-ca.crt has not been staged yet.
CA_CERTS_BLOCK=""
if [ "$ANCHOR_COUNT" -gt 0 ]; then
  CA_CERTS_BLOCK="ca_certs:
  trusted:
${ROOT_CA%$'\n'}"
fi
# Find the keys under sudo, which is how this always runs. $HOME is /root there, so the
# operator's own authorized_keys is invisible unless SUDO_USER is resolved back to a home
# directory - and the failure looks like "you have no keys" rather than "I looked in the
# wrong place".
SSH_KEY_SEARCH="${VM_SSH_KEYS:-}"
if [ -z "$SSH_KEY_SEARCH" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [ -n "$SUDO_HOME" ] && SSH_KEY_SEARCH="$SUDO_HOME/.ssh/authorized_keys"
  fi
  SSH_KEY_SEARCH="$SSH_KEY_SEARCH $HOME/.ssh/authorized_keys /root/.ssh/authorized_keys"
fi

SSH_KEYS_YAML=""
for k in $SSH_KEY_SEARCH; do
  [ -r "$k" ] || continue
  while IFS= read -r line; do
    case "$line" in ssh-*|ecdsa-*) SSH_KEYS_YAML="$SSH_KEYS_YAML      - \"$line\""$'\n' ;; esac
  done < "$k"
done
[ -n "$SSH_KEYS_YAML" ] || die "no ssh public keys found. Looked in:
$(for k in $SSH_KEY_SEARCH; do printf '         %s%s\n' "$k" "$([ -r "$k" ] && echo ' (readable, but no ssh-* lines)' || echo ' (not readable)')"; done)
       Set VM_SSH_KEYS to a file containing them. Without a key the VM has no default
       route AND no way in - it would boot and be unreachable."

TMP="$(mktemp -d)"; PSTAGE=""
# PSTAGE holds the guest's credentials file and the Pro token while the provisioning disk is
# built - shredded on ANY exit, not only the happy path.
cleanup() {
  rm -rf "$TMP"
  if [ -n "$PSTAGE" ] && [ -d "$PSTAGE" ]; then
    shred -u "$PSTAGE/credentials.env" "$PSTAGE/pro-contract-token" "$PSTAGE/audit-offload.key" 2>/dev/null || true
    rm -rf "$PSTAGE"
  fi
}
trap cleanup EXIT

# --harden: mount the provisioning disk READ-ONLY, let 05 install what is on it, and reboot ONCE
# after cloud-final so the hardening unit starts at a clean boot (05 first-boot says why).
# The reboot is conditional: if first-boot failed, the guest stays up with the reason on its
# console instead of rebooting into nothing.
HARDEN_RUNCMD=""; HARDEN_POWER=""
if [ -n "$PROV" ]; then
  HARDEN_RUNCMD='  - [ sh, -c, "mkdir -p /mnt/enclave-prov && mount -o ro LABEL=ENCLAVE-PROV /mnt/enclave-prov && bash /mnt/enclave-prov/repo/scripts/install/05-harden-host.sh first-boot /mnt/enclave-prov; rc=$?; umount /mnt/enclave-prov 2>/dev/null; exit $rc" ]'
  HARDEN_POWER='power_state:
  mode: reboot
  message: "enclave-harden: provisioned - rebooting once; it hardens itself from the next boot"
  timeout: 120
  condition: [ test, -e, /var/lib/enclave/provisioned ]'
fi
# A fresh instance-id on every compose, so cloud-init treats a recomposed guest as a first
# boot and runs the whole user-data again.
cat > "$TMP/meta-data" <<EOF
instance-id: $VM-$(date +%s)
local-hostname: $VM
EOF

# No gateway4 and no nameservers: this VM is air-gapped exactly like its host.
# Match on en* rather than naming the interface. A virtio NIC comes up as enp1s0 on some
# machine types and ens3 on others, and guessing wrong produces a VM with no address AND no
# default route - unreachable, recoverable only from the console. Same idiom the host
# autoinstall uses for the same reason.
cat > "$TMP/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: false
    dhcp6: false
    addresses: [$ADDRESS/24]
EOF

cat > "$TMP/user-data" <<EOF
#cloud-config
hostname: $VM
fqdn: $VM.$DOMAIN
prefer_fqdn_over_hostname: false
manage_etc_hosts: false

users:
  - name: ${VM_USER:-encadmin}
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: $VM_ADMIN_HASH
    ssh_authorized_keys:
$SSH_KEYS_YAML
# preserve_sources_list: true is LOAD-BEARING. With the 'primary'/'security' form, cloud-init
# generates ubuntu.sources from ITS OWN template - default suites and components - and does so
# AFTER write_files, silently overwriting the file below. On svc-mgmt-01 (2026-09-03) that
# produced:
#     Suites: noble noble-updates noble-backports
#     Components: main universe restricted multiverse
# against a mirror carrying only main+universe and no backports, so apt-get update 404'd on
# every one of them. cloud-init then fell back to trying 'snap install' for each package -
# 30 seconds apiece against a store it cannot reach - and sat in 'running' for minutes.
# Preserving the list and writing the file ourselves is the only way to control components.
$CA_CERTS_BLOCK

apt:
  preserve_sources_list: true

write_files:
  - path: /etc/apt/sources.list.d/ubuntu.sources
    permissions: '0644'
    content: |
      # Enclave mirror. No default route on this VM; reachable on the local subnet only.
      Types: deb
      URIs: $VM_MIRROR_URL
      Suites: $VM_MIRROR_SUITES
      Components: $VM_MIRROR_COMPONENTS
      Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
  - path: /etc/tmux.conf
    permissions: '0644'
    content: |
$TMUX_CONF
  - path: /etc/hosts
    permissions: '0644'
    content: |
      127.0.0.1       localhost
      127.0.1.1       $VM $VM.$DOMAIN
      ::1             localhost ip6-localhost ip6-loopback
$HOSTS_BLOCK
$RESOLVER_WF

package_update: true
packages: [$(echo "${VM_EXTRA_PACKAGES:-}" | tr ' ' '\n' | sed '/^$/d' | paste -sd, -)]

runcmd:
  - [ systemctl, enable, --now, ssh ]
$RESOLVER_RUN
  - [ sh, -c, "ip route | grep -q '^default' && echo 'WARNING: this VM has a default route' >> /etc/enclave-build-info || echo 'gateway=none-airgapped-no-default-route' >> /etc/enclave-build-info" ]
  - [ sh, -c, "echo \"composed=\$(date -Is) by 03-compose-vm.sh\" >> /etc/enclave-build-info" ]
$HARDEN_RUNCMD
$HARDEN_POWER

final_message: "$VM ready after \$UPTIME seconds"
EOF

if [ "$DRY" -eq 1 ]; then
  say ""; say "--- user-data that would be written ---"; sed 's/^/  /' "$TMP/user-data"
  say ""; say "--- network-config ---"; sed 's/^/  /' "$TMP/network-config"
  exit 0
fi

# See vm-specs.env for why UEFI is the default - SeaBIOS failures are invisible with
# --graphics none, because SeaBIOS only writes to VGA.
# '--boot uefi' is NOT plain UEFI - it selects the Microsoft-keys-enrolled Secure Boot
# firmware, under which Ubuntu's GRUB stopped with "prohibited by secure boot policy" and
# cloud-init never ran. Ask for the features explicitly instead of taking the default.
FIRMWARE_ARGS=()
case "${VM_FIRMWARE:-uefi}" in
  uefi)
    if [ "${VM_SECURE_BOOT:-false}" = "true" ]; then
      FIRMWARE_ARGS=(--boot uefi)
    else
      FIRMWARE_ARGS=(--boot "firmware=efi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no")
    fi ;;
  bios) FIRMWARE_ARGS=() ;;
  *)    die "VM_FIRMWARE must be 'uefi' or 'bios', not '${VM_FIRMWARE}'" ;;
esac

# The NoCloud seed image (volume label cidata): user-data, meta-data and network-config.
cloud-localds -N "$TMP/network-config" "$SEED" "$TMP/user-data" "$TMP/meta-data"
ok "seed    : $SEED"

# THE PROVISIONING DISK (--harden). Staged on /run - tmpfs - so the credentials file and the token
# never touch a disk on the way; Rock Ridge (-R, not -r) keeps their 0600 root inside the image.
PROV_DISK_ARGS=()
if [ -n "$PROV" ]; then
  PSTAGE="$(mktemp -d -p /run enclave-prov.XXXXXX)"
  mkdir -p "$PSTAGE/repo"
  tar -C "$REPO_ROOT" --no-recursion -cf - -T "$REPO_ROOT/.pushed-files" .pushed-from .pushed-files \
    | tar -C "$PSTAGE/repo" -xf - || die "could not copy the pushed files into the provisioning stage"
  install -m 0600 "$GUEST_CRED"  "$PSTAGE/credentials.env"
  install -m 0600 "$PRO_TOKEN"   "$PSTAGE/pro-contract-token"
  [ -z "$AUDIT_KEY_SRC" ] || install -m 0600 "$AUDIT_KEY_SRC" "$PSTAGE/audit-offload.key"
  install -m 0644 "$ANSWER_FILE" "$PSTAGE/Ubuntu24_AnswerFile.xml"
  printf "ENCLAVE_OPERATOR='%s'\n" "${VM_USER:-encadmin}" > "$PSTAGE/provision.env"
  ( umask 077; genisoimage -quiet -o "$PROV" -V ENCLAVE-PROV -R -input-charset utf-8 "$PSTAGE" ) \
    || die "genisoimage failed building $PROV"
  chmod 0600 "$PROV"
  _nfiles="$(find "$PSTAGE/repo" -type f | wc -l)"
  shred -u "$PSTAGE/credentials.env" "$PSTAGE/pro-contract-token"
  [ ! -e "$PSTAGE/audit-offload.key" ] || shred -u "$PSTAGE/audit-offload.key"
  rm -rf "$PSTAGE"; PSTAGE=""
  ok "prov    : $PROV ($_nfiles repo files, credentials, ${AUDIT_KEY_SRC:+audit key, }token, answers) - read-only, 0600"
  # AFTER the data disk, so a PG guest's data disk stays vdc (its fstab uses a LABEL anyway).
  PROV_DISK_ARGS=(--disk "path=$PROV,device=disk,bus=virtio,format=raw,readonly=on")
fi

# ---- define and start --------------------------------------------------------------------
# THE SEED GOES ON VIRTIO, NOT AS A SATA CDROM. Found on svc-mgmt-01 2026-09-03:
# virt-install's default for device=cdrom is the SATA bus, and an Ubuntu cloud image ships a
# TRIMMED INITRAMFS carrying only virtio drivers - no AHCI. The guest therefore enumerated
# only vda and never saw the seed at all:
#
#     virtio_blk virtio2: [vda] 209715200 512-byte logical blocks
#     vda: vda1 vda14 vda15 vda16          <- no sr0, no sda, no ata
#
# ds-identify then found no datasource and systemd SKIPPED every cloud-init unit, which
# produces no error and no output - the VM boots to a stock 'ubuntu' login with no address,
# looking alive and being useless. NoCloud matches on the filesystem label, not on the device
# being a cdrom, so a read-only virtio disk works and is visible to the trimmed initramfs.
# Data disk: cache=none so a database fsync reaches the device rather than the host page
# cache; discard=unmap so TRIM inside the guest returns space to the sparse qcow2.
DATA_DISK_ARGS=()
if [ -n "$DATA_DISK" ]; then
  DATA_DISK_ARGS=(--disk "path=$DATA_DISK,format=qcow2,bus=virtio,cache=none,io=native,discard=unmap")
fi

# host-passthrough: the guest sees the host CPU's real model and flags, not a generic one.
virt-install \
  --name "$VM" \
  --memory "$RAM_MB" --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --os-variant "${VM_OSVARIANT:-ubuntu24.04}" \
  "${FIRMWARE_ARGS[@]}" \
  --disk "path=$DISK,format=qcow2,bus=virtio" \
  --disk "path=$SEED,device=disk,bus=virtio,format=raw,readonly=on" \
  "${DATA_DISK_ARGS[@]}" \
  "${PROV_DISK_ARGS[@]}" \
  --network "bridge=$BRIDGE,model=virtio" \
  --graphics none \
  --console pty,target_type=serial \
  --serial "pty,log.file=$LOGDIR/$VM-console.log,log.append=on" \
  --import --noautoconsole
ok "defined and started"

# The guest starts with its host. After host-4's reboot on 2026-09-22 all four guests came
# back with nobody at a console (backlog 1.1).
virsh autostart "$VM" >/dev/null
ok "autostart enabled"

# Now that qemu has created it, make the console log readable over ssh.
chmod 0644 "$LOGDIR/$VM-console.log" 2>/dev/null \
  && ok "console log readable: $LOGDIR/$VM-console.log" \
  || warn "could not chmod the console log - it will need sudo to read"

# PROVE THE PTY EXISTS. The whole point of the change above is an interactive console, and the
# failure mode is silent - the VM runs perfectly and you find out only when you need it most.
if virsh dumpxml "$VM" 2>/dev/null | grep -q "<serial type='pty'>"; then
  ok "interactive console present - virsh console $VM will work"
else
  warn "NO PTY SERIAL - 'virsh console $VM' will fail with 'not using a PTY'."
  warn "  This VM has no interactive console. Offline disk editing (vm-rescue.sh) is the only"
  warn "  way back if it will not boot. See runbook 6.3j."
fi

say ""
say "cloud-init takes a minute or two. Watch it:"
say "    sudo virsh console $VM        (escape is Ctrl-])"
say "Or read the console log, which needs no interactive session:"
say "    sudo tail -f $LOGDIR/$VM-console.log"
say "Then, from anywhere on the subnet:"
say "    ssh ${VM_USER:-encadmin}@$ADDRESS 'cat /etc/enclave-build-info'"
if [ -n "$PROV" ]; then
  say ""
  # sudo AND the rotated files: virtlogd rotates a console log at 2 MB (max_size) and creates the
  # new one 0600 root - found in slice 3's first live run, 2026-09-27, 16 s after provision START.
  # A run can straddle the rotation, so read <vm>-console.log* (oldest first), not just the live one.
  say "--harden: it hardens ITSELF - do not log in. Progress, one line per step:"
  say "    sudo sh -c 'cat \$(ls -1r $LOGDIR/$VM-console.log*)' | grep -a ENCLAVE-HARDEN"
  say "  provision OK, one reboot, then every step to DONE (about 20 minutes). A HALTED line"
  say "  means read the log above it; the guest keeps its credentials for the re-run."
  say "  $PROV holds its credentials file and token until slice 4's finish shreds it."
fi
