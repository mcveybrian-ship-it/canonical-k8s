#!/usr/bin/env bash
# =========================================================================================
# monitoring.sh - put a metrics exporter on an enclave machine, correctly.
#
#     MACHINE: any in-gap machine. Refuses outside the boundary.
#
#     sudo ./monitoring.sh exporter          node-exporter: install, bind, prune collectors
#     sudo ./monitoring.sh libvirt           per-guest metrics, HYPERVISORS ONLY
#     sudo ./monitoring.sh collector         prometheus + alertmanager + grafana, configured
#     ./monitoring.sh status                 what is running here and where it is bound
#
# WHY A SCRIPT FOR WHAT LOOKS LIKE ONE apt-get:
#
#   The install is one command. Everything that makes it SAFE differs per machine, and doing
#   that by hand five times is how one machine ends up wrong:
#
#   1. THE BIND ADDRESS. The package binds *:9100 - every interface, exactly the shape of the
#      postfix finding in 6.3e. Each machine must bind its OWN enclave address, which this
#      reads from enclave-addresses.env rather than being told.
#
#   2. THE COLLECTOR TIMERS. prometheus-node-exporter-collectors installs FIVE systemd timers -
#      apt, ipmitool-sensor, mellanox-hca-temp, nvme, smartmon. On a VM four of them collect
#      nothing forever: no BMC, no Mellanox card, no NVMe, no SMART behind virtio. On host-4
#      nvme and smartmon are genuinely useful because it has real disks.
#      **So decide from the HARDWARE, not from a list.** Each timer is kept only if the thing
#      it reads actually exists on this machine.
#
#   3. THE FIREWALL. 9100 exposes every mount, interface, process count and kernel version.
#      The rule belongs in stig-tailor.sh's ufw table, source-restricted to the collector -
#      not poked in by hand here. This script SAYS SO and does not touch ufw.
# =========================================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
[ -f "$HERE/enclave-addresses.env" ] && . "$HERE/enclave-addresses.env"

NE_DEFAULTS=/etc/default/prometheus-node-exporter
LV_DEFAULTS=/etc/default/prometheus-libvirt-exporter
NE_PORT="${NODE_EXPORTER_PORT:-9100}"
LV_PORT="${LIBVIRT_EXPORTER_PORT:-9177}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*"; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# THE MACHINE'S OWN ENCLAVE ADDRESS, from the one file that owns addressing.
# Never `hostname -I` - stage-01 is multi-homed and that would pick whichever interface the
# kernel listed first, which is how a service ends up bound to the internet-facing NIC.
my_enclave_ip() {
  local me key ip
  me="$(hostname -s)"
  key="$(printf '%s' "$me" | tr '[:lower:]-' '[:upper:]_')"
  ip="$(eval "printf '%s' \"\${$key:-}\"")"
  printf '%s' "$ip"
}

guard_in_gap() {
  local me; me="$(hostname -s)"
  case "$me" in
    stage-01|build-01)
      die "monitoring.sh does not run on $me - it is outside the ATO boundary." ;;
  esac
}

# ---- keep a collector only if the hardware it reads is present --------------------------
have_ipmi()     { [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ] || [ -e /dev/ipmidev/0 ]; }
have_mellanox() { [ -d /sys/class/infiniband ] && [ -n "$(ls -A /sys/class/infiniband 2>/dev/null)" ]; }
have_nvme()     { compgen -G '/dev/nvme[0-9]*n[0-9]*' >/dev/null 2>&1; }
have_smart()    { compgen -G '/dev/sd[a-z]' >/dev/null 2>&1 || have_nvme; }

cmd_exporter() {
  guard_in_gap; need_root
  local me ip; me="$(hostname -s)"; ip="$(my_enclave_ip)"
  [ -n "$ip" ] || die "no enclave address for '$me' in enclave-addresses.env.
       Add it there first - this script will not guess an interface."

  say "installing prometheus-node-exporter on $me"
  DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus-node-exporter 2>&1 | tail -3

  # ---- bind to THIS machine's enclave address -------------------------------------------
  [ -f "$NE_DEFAULTS" ] || die "no $NE_DEFAULTS - did the package install?"
  cp -a "$NE_DEFAULTS" "/var/backups/$(basename "$NE_DEFAULTS").$(date +%Y%m%dT%H%M%S)"
  # SET the existing line, never append. An appended ARGS= works (the file is sourced, last
  # wins) and leaves two lines that disagree - someone edits the first one and nothing changes.
  if grep -q '^ARGS=' "$NE_DEFAULTS"; then
    sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=${ip}:${NE_PORT}\"|" "$NE_DEFAULTS"
  else
    printf 'ARGS="--web.listen-address=%s:%s"\n' "$ip" "$NE_PORT" >> "$NE_DEFAULTS"
  fi
  local n; n="$(grep -c '^ARGS=' "$NE_DEFAULTS")"
  [ "$n" -eq 1 ] || {
    warn "$NE_DEFAULTS has $n ARGS lines - collapsing to the last one"
    local keep; keep="$(grep '^ARGS=' "$NE_DEFAULTS" | tail -1)"
    sed -i '/^ARGS=/d' "$NE_DEFAULTS"; printf '%s\n' "$keep" >> "$NE_DEFAULTS"
  }

  # ---- prune collectors whose hardware is not here ---------------------------------------
  say ""
  say "collector timers - kept only where the hardware exists:"
  local t hw
  for t in apt ipmitool-sensor mellanox-hca-temp nvme smartmon; do
    case "$t" in
      apt)               hw=yes ;;                                   # pending updates: always useful
      ipmitool-sensor)   have_ipmi     && hw=yes || hw=no ;;
      mellanox-hca-temp) have_mellanox && hw=yes || hw=no ;;
      nvme)              have_nvme     && hw=yes || hw=no ;;
      smartmon)          have_smart    && hw=yes || hw=no ;;
    esac
    systemctl list-unit-files "prometheus-node-exporter-$t.timer" >/dev/null 2>&1 || continue
    if [ "$hw" = yes ]; then
      systemctl enable --now "prometheus-node-exporter-$t.timer" >/dev/null 2>&1 || true
      printf '     %-20s KEPT      the hardware is present\n' "$t"
    else
      systemctl disable --now "prometheus-node-exporter-$t.timer" >/dev/null 2>&1 || true
      printf '     %-20s disabled  nothing on this machine to read\n' "$t"
    fi
  done

  systemctl restart prometheus-node-exporter
  sleep 2
  # PROVE THE BIND, do not assume it. A wildcard here is the postfix finding again.
  local bound
  bound="$(ss -tlnH "sport = :$NE_PORT" 2>/dev/null | awk '{print $4}' | head -1)"
  case "$bound" in
    "$ip:$NE_PORT") ok "bound $bound" ;;
    ""|*)           warn "expected $ip:$NE_PORT but ss says '${bound:-nothing listening}'"
                    warn "  the package may be ignoring ARGS - check: systemctl cat prometheus-node-exporter"
                    return 1 ;;
  esac
  curl -sf "http://$ip:$NE_PORT/metrics" >/dev/null 2>&1 \
    && ok "serving metrics" || { warn "bound but not serving"; return 1; }

  say ""
  warn "9100 IS NOT FIREWALLED BY THIS SCRIPT, deliberately."
  say "   It exposes every mount, interface, process count and kernel version on this box."
  say "   The rule belongs in stig-tailor.sh's ufw table, source-restricted to the collector:"
  say "     sudo ./stig-tailor.sh ufw          # plan"
  say "     sudo ./stig-tailor.sh ufw --apply"
  say "   ufw is only ENABLED on machines with a rule table. Where it is not enabled, this"
  say "   port is open to the whole enclave - which is why the gap must be shut."
}

cmd_libvirt() {
  guard_in_gap; need_root
  local me ip; me="$(hostname -s)"; ip="$(my_enclave_ip)"
  command -v virsh >/dev/null 2>&1 \
    || die "no virsh on $me - the libvirt exporter belongs on a HYPERVISOR."
  [ -n "$ip" ] || die "no enclave address for '$me' in enclave-addresses.env"

  # WHY THIS AND NOT JUST node-exporter IN THE GUEST: it reports per-guest CPU, disk and
  # network FROM THE HYPERVISOR, so a VM that is too sick to report its own metrics still has
  # metrics. That is the difference between monitoring and monitoring that helps at 3am.
  say "installing prometheus-libvirt-exporter on $me"
  DEBIAN_FRONTEND=noninteractive apt-get install -y prometheus-libvirt-exporter 2>&1 | tail -3
  if [ -f "$LV_DEFAULTS" ]; then
    cp -a "$LV_DEFAULTS" "/var/backups/$(basename "$LV_DEFAULTS").$(date +%Y%m%dT%H%M%S)"
    if grep -q '^ARGS=' "$LV_DEFAULTS"; then
      sed -i "s|^ARGS=.*|ARGS=\"--web.listen-address=${ip}:${LV_PORT}\"|" "$LV_DEFAULTS"
    else
      printf 'ARGS="--web.listen-address=%s:%s"\n' "$ip" "$LV_PORT" >> "$LV_DEFAULTS"
    fi
  else
    warn "no $LV_DEFAULTS - check how this package takes its arguments before trusting the bind"
  fi
  systemctl restart prometheus-libvirt-exporter 2>/dev/null || true
  sleep 2
  ss -tlnH "sport = :$LV_PORT" 2>/dev/null | awk '{print "     bound " $4}' | head -1
  curl -sf "http://$ip:$LV_PORT/metrics" 2>/dev/null | grep -c '^libvirt' \
    | sed 's/^/     libvirt metrics exposed: /' || warn "not serving on $ip:$LV_PORT"
  say ""
  warn "add $LV_PORT to the ufw table too, source-restricted to the collector."
}

# ---- the collector -----------------------------------------------------------------------
#
# WHAT TO SCRAPE. Machine <TAB> role. Addresses are resolved from enclave-addresses.env, never
# written here - two copies of an address are two copies that drift.
#
# Machines that do not exist yet are listed anyway and show as DOWN. That is deliberate: a
# target list that only contains what is already running cannot tell you something is missing.
scrape_targets() {
cat <<'EOF'
host-4	hypervisor
svc-mgmt-01	maas
svc-repo-01	mirror
svc-harbor-01	registry
svc-obs-01	observability
EOF
}
# Hypervisors additionally run the libvirt exporter - per-guest metrics FROM the host.
scrape_hypervisors() { printf 'host-4\n'; }

GRAFANA_DEB="${GRAFANA_DEB:-grafana_13.2.1_33191028959_linux_amd64.deb}"
GRAFANA_SHA="${GRAFANA_SHA:-b4f088f661c5103746f23cb5cbbe2b2bb2e18ba9870ad68a3c2a90451f511ded}"
PROM_RETENTION_TIME="${PROM_RETENTION_TIME:-90d}"
PROM_RETENTION_SIZE="${PROM_RETENTION_SIZE:-100GB}"

# Set an ARGS= line, exactly once. Appending works - the file is sourced and the last wins -
# and leaves two lines that disagree, so someone edits the first and nothing changes.
set_args() {
  local f="$1" val="$2"
  [ -f "$f" ] || { warn "no $f"; return 1; }
  cp -a "$f" "/var/backups/$(basename "$f").$(date +%Y%m%dT%H%M%S)"
  if grep -q '^ARGS=' "$f"; then sed -i "s|^ARGS=.*|ARGS=\"$val\"|" "$f"
  else printf 'ARGS="%s"\n' "$val" >> "$f"; fi
  local n; n="$(grep -c '^ARGS=' "$f")"
  if [ "$n" -ne 1 ]; then
    local keep; keep="$(grep '^ARGS=' "$f" | tail -1)"
    sed -i '/^ARGS=/d' "$f"; printf '%s\n' "$keep" >> "$f"
    warn "$(basename "$f") had $n ARGS lines - collapsed to one"
  fi
}

cmd_collector() {
  guard_in_gap; need_root
  local me ip; me="$(hostname -s)"; ip="$(my_enclave_ip)"
  [ -n "$ip" ] || die "no enclave address for '$me' in enclave-addresses.env"
  [ "$me" = "${SVC_OBS_01_NAME:-svc-obs-01}" ] || warn "this is $me, not svc-obs-01 - continuing anyway"

  say "installing the collector on $me ($ip)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    prometheus prometheus-alertmanager prometheus-node-exporter 2>&1 | tail -3

  # ---- bindings. EVERY ONE of these packages defaults to all interfaces ------------------
  # node-exporter, prometheus, alertmanager and grafana all bind *:PORT out of the box, and
  # alertmanager opens a CLUSTER port (9094) on top for HA gossip. That is the postfix finding
  # (6.3e) five times over. Prometheus and alertmanager have no business being reachable from
  # anywhere - Grafana proxies to them over loopback.
  set_args /etc/default/prometheus \
    "--web.listen-address=127.0.0.1:9090 --storage.tsdb.retention.time=$PROM_RETENTION_TIME --storage.tsdb.retention.size=$PROM_RETENTION_SIZE"
  set_args /etc/default/prometheus-alertmanager \
    "--web.listen-address=127.0.0.1:9093 --cluster.listen-address="
  set_args /etc/default/prometheus-node-exporter "--web.listen-address=${ip}:${NE_PORT}"

  # ---- scrape config, generated from enclave-addresses.env -------------------------------
  local cfg=/etc/prometheus/prometheus.yml
  [ -f "$cfg" ] && cp -a "$cfg" "/var/backups/prometheus.yml.$(date +%Y%m%dT%H%M%S)"
  {
    printf '# Generated by scripts/enclave/monitoring.sh - do not edit by hand.\n'
    printf '# Targets come from enclave-addresses.env; edit scrape_targets() in the script.\n'
    printf 'global:\n  scrape_interval: 15s\n  evaluation_interval: 15s\n'
    printf '  external_labels:\n    enclave: %s\n\n' "${ENCLAVE_DOMAIN:-enclave.internal}"
    printf 'alerting:\n  alertmanagers:\n    - static_configs:\n        - targets: ['"'"'127.0.0.1:9093'"'"']\n\n'
    printf 'scrape_configs:\n'
    printf '  - job_name: prometheus\n    static_configs:\n      - targets: ['"'"'127.0.0.1:9090'"'"']\n\n'
    printf '  - job_name: node\n    static_configs:\n'
    local m role a key
    while IFS=$'\t' read -r m role; do
      [ -n "${m:-}" ] || continue
      key="$(printf '%s' "$m" | tr '[:lower:]-' '[:upper:]_')"
      a="$(eval "printf '%s' \"\${$key:-}\"")"
      [ -n "$a" ] || { warn "no address for $m - skipped"; continue; }
      printf "      - targets: ['%s:%s']\n        labels: {machine: %s, role: %s}\n" \
             "$a" "$NE_PORT" "$m" "$role"
    done < <(scrape_targets)
    printf '\n  # per-guest CPU, disk and network FROM the hypervisor, so a VM too sick to\n'
    printf '  # report its own metrics still has metrics\n'
    printf '  - job_name: libvirt\n    static_configs:\n'
    while IFS= read -r m; do
      [ -n "${m:-}" ] || continue
      key="$(printf '%s' "$m" | tr '[:lower:]-' '[:upper:]_')"
      a="$(eval "printf '%s' \"\${$key:-}\"")"
      [ -n "$a" ] || continue
      printf "      - targets: ['%s:%s']\n        labels: {machine: %s, role: hypervisor}\n" \
             "$a" "$LV_PORT" "$m"
    done < <(scrape_hypervisors)
  } > "$cfg"
  chown root:root "$cfg"; chmod 0644 "$cfg"
  # THE SYNTAX GATE. Same idea as visudo -c and sh -n: never reload a config that has not
  # been checked, on a service you are about to depend on.
  promtool check config "$cfg" >/dev/null 2>&1 \
    && ok "prometheus.yml generated and valid" \
    || { promtool check config "$cfg" 2>&1 | sed 's/^/       /'; die "generated config is INVALID - not reloading"; }

  # ---- grafana, from the mirror, checksum-verified ---------------------------------------
  if ! dpkg -s grafana >/dev/null 2>&1; then
    local url="https://${REPO_ADDRESS:-svc-repo-01.${ENCLAVE_DOMAIN:-enclave.internal}}/debs/$GRAFANA_DEB"
    say "fetching grafana from the mirror: $url"
    local tmp; tmp="$(mktemp -d)"
    if curl -fsS -o "$tmp/$GRAFANA_DEB" "$url"; then
      # VERIFY BEFORE INSTALL. The .deb is carried rather than repo-installed precisely so
      # there is no third-party signing key in the trust store - the checksum IS the control.
      if printf '%s  %s\n' "$GRAFANA_SHA" "$tmp/$GRAFANA_DEB" | sha256sum -c - >/dev/null 2>&1; then
        ok "grafana checksum verified"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$tmp/$GRAFANA_DEB" 2>&1 | tail -3
      else
        rm -rf "$tmp"; die "GRAFANA CHECKSUM MISMATCH - not installing. Re-carry the .deb."
      fi
    else
      warn "could not fetch $url - carry $GRAFANA_DEB into /srv/repo/debs/ on the mirror first"
    fi
    rm -rf "$tmp"
  else
    ok "grafana already installed"
  fi

  if dpkg -s grafana >/dev/null 2>&1; then
    local gd=/etc/default/grafana-server
    cp -a "$gd" "/var/backups/grafana-server.$(date +%Y%m%dT%H%M%S)" 2>/dev/null || true
    local k kv
    for kv in "GF_SERVER_HTTP_ADDR=$ip" "GF_SERVER_HTTP_PORT=3000"; do
      k="${kv%%=*}"
      grep -q "^$k=" "$gd" 2>/dev/null && sed -i "s|^$k=.*|$kv|" "$gd" || printf '%s\n' "$kv" >> "$gd"
    done
    install -d -m 0755 /etc/grafana/provisioning/datasources
    # PROVISIONED, NOT CLICKED. A rebuilt collector comes up with its datasource already
    # configured; clicking it in the UI works once.
    cat > /etc/grafana/provisioning/datasources/enclave-prometheus.yaml <<'DS'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
DS
    chown root:grafana /etc/grafana/provisioning/datasources/enclave-prometheus.yaml
    chmod 0640 /etc/grafana/provisioning/datasources/enclave-prometheus.yaml
    systemctl daemon-reload
    systemctl enable --now grafana-server >/dev/null 2>&1 || true
  fi

  systemctl restart prometheus prometheus-alertmanager prometheus-node-exporter
  sleep 4

  # ---- PROVE THE BINDS. A wildcard is the finding. -------------------------------------
  say ""
  say "bindings:"
  local bad=0 want
  for want in "127.0.0.1:9090" "127.0.0.1:9093" "${ip}:${NE_PORT}"; do
    if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qx "$want"; then
      printf '     %-24s ok\n' "$want"
    else
      printf '  [!] %-24s NOT BOUND AS EXPECTED\n' "$want"; bad=1
    fi
  done
  dpkg -s grafana >/dev/null 2>&1 && {
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qx "${ip}:3000" \
      && printf '     %-24s ok\n' "${ip}:3000" \
      || { printf '  [!] %-24s NOT BOUND AS EXPECTED\n' "${ip}:3000"; bad=1; }
  }
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(\*|0\.0\.0\.0|\[::\]):(9090|9093|9094|9100|3000)$'; then
    warn "a monitoring port is on ALL INTERFACES - the postfix shape (6.3e)"; bad=1
  fi
  [ "$bad" -eq 0 ] || return 1

  say ""
  ok "collector up. Targets take one scrape_interval to report:"
  say "   curl -s 'http://127.0.0.1:9090/api/v1/targets?state=any'"
  say "   grafana: http://${ip}:3000  - set the admin password AT THE BROWSER PROMPT"
  warn "retention is ${PROM_RETENTION_TIME} / ${PROM_RETENTION_SIZE} - the TIME is a placeholder"
  warn "  until the AO answers. The SIZE cap is the real protection: it stops a noisy month"
  warn "  filling the disk and taking down the machine you use to find out why."
}

cmd_status() {
  local me ip; me="$(hostname -s)"; ip="$(my_enclave_ip)"
  printf '\n  monitoring on %s (%s)\n\n' "$me" "${ip:-no enclave address}"
  local svc
  for svc in prometheus-node-exporter prometheus-libvirt-exporter prometheus prometheus-alertmanager grafana-server; do
    systemctl list-unit-files "$svc.service" >/dev/null 2>&1 || continue
    printf '     %-30s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null)"
  done
  printf '\n  listening:\n'
  ss -tlnH 2>/dev/null | awk '{print $4}' \
    | grep -E ':(9090|9093|9094|9100|9177|3000)$' | sort -u | sed 's/^/     /' \
    || printf '     nothing on a monitoring port\n'
  # A WILDCARD BIND IS THE FINDING, so name it rather than printing an address list.
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(\*|0\.0\.0\.0|\[::\]):(9100|9177|9090|9093|3000)$'; then
    printf '\n'
    warn "a monitoring port is bound to ALL INTERFACES - that is the postfix shape (6.3e)."
    warn "  Re-run: sudo $0 exporter"
  fi
  printf '\n  collector timers:\n'
  systemctl list-timers 'prometheus-node-exporter-*' --no-pager 2>/dev/null \
    | awk 'NR>1 && NF>3 {print "     " $NF}' | sed '/^\s*$/d' || true
  echo
}

case "${1:-status}" in
  exporter) shift; cmd_exporter "$@" ;;
  libvirt)  shift; cmd_libvirt "$@" ;;
  collector) shift; cmd_collector "$@" ;;
  status)   shift; cmd_status "$@" ;;
  *) printf 'usage: %s {exporter|libvirt|collector|status}\n' "$0" >&2; exit 2 ;;
esac
