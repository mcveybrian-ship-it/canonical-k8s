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
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
# THE SYSTEMD COLLECTOR IS DELIBERATELY NARROWED. Unrestricted it emits several series for
# every unit on the box - hundreds of them, most of which nobody will ever look at, on a
# Prometheus with a 90d retention. Named units only: the ones a machine exists to run.
SYSTEMD_UNITS="${SYSTEMD_UNITS:-(auditd|chrony|sshd|ssh|ufw|nginx|docker|containerd|grafana-server|prometheus|prometheus-alertmanager|prometheus-node-exporter|prometheus-libvirt-exporter|libvirtd|virtqemud|postgresql.*|maas-.*|named|bind9|dailyaidecheck|vm-backup|enclave-facts)\\.(service|timer)}"
LV_PORT="${LIBVIRT_EXPORTER_PORT:-9177}"

# THE DATASOURCE UID IS A CONTRACT between the provisioning file and every dashboard JSON.
# Grafana invents a random uid when the provisioning file omits one, and a dashboard that
# names a uid nothing has renders "No data" on every panel with the reason buried in a
# tooltip. Declared here, written by ensure_datasource(), and checked by `dashboards`.
DS_UID="${GRAFANA_DS_UID:-enclave-prometheus}"

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
  # THE TEXTFILE DIRECTORY is what lets anything on this machine publish a metric without
  # writing an exporter: drop a .prom file in, node-exporter serves it. It is how the
  # compliance facts (STIG residual, cert expiry, AIDE, auditd) reach Prometheus at all.
  # root writes, the prometheus user reads - never the other way round.
  install -d -m 0755 -o root -g prometheus "$TEXTFILE_DIR" 2>/dev/null \
    || install -d -m 0755 "$TEXTFILE_DIR"

  local ne_args="--web.listen-address=${ip}:${NE_PORT}"
  ne_args="$ne_args --collector.textfile.directory=$TEXTFILE_DIR"
  ne_args="$ne_args --collector.systemd --collector.systemd.unit-include=$SYSTEMD_UNITS"

  # NOT sed. The value contains '|' (the systemd unit regex) and would need a delimiter no
  # future value can contain - there is no such character. Replacing the line by filtering
  # and appending cannot be broken by ANY content, which is the property worth having in a
  # file that decides whether this machine reports metrics at all.
  if grep -q '^ARGS=' "$NE_DEFAULTS"; then
    local ne_tmp; ne_tmp="$(mktemp)"
    grep -v '^ARGS=' "$NE_DEFAULTS" > "$ne_tmp"
    printf 'ARGS="%s"\n' "$ne_args" >> "$ne_tmp"
    cat "$ne_tmp" > "$NE_DEFAULTS"      # > not mv: keeps the package's owner and mode
    rm -f "$ne_tmp"
  else
    printf 'ARGS="%s"\n' "$ne_args" >> "$NE_DEFAULTS"
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
  local page; page="$(curl -sf "http://$ip:$NE_PORT/metrics" 2>/dev/null)" \
    || { warn "bound but not serving"; return 1; }
  ok "serving metrics"

  # ASK THE RUNNING EXPORTER WHICH COLLECTORS IT LOADED. A flag it rejects outright stops
  # the service and the bind check above catches that - but a flag it ACCEPTS and cannot
  # act on (an unreadable textfile directory, systemd unreachable) leaves it serving
  # happily with the collector silently absent, and every compliance panel empty.
  local c
  for c in textfile systemd; do
    if printf '%s' "$page" | grep -q "node_scrape_collector_success{collector=\"$c\"} 1"; then
      ok "collector '$c' loaded and succeeding"
    else
      warn "COLLECTOR '$c' IS NOT REPORTING SUCCESS - compliance facts will not arrive."
      printf '%s' "$page" | grep "node_scrape_collector_success{collector=\"$c\"}" \
        | sed 's/^/       /' || say "       it is not in /metrics at all"
    fi
  done

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

# ---- ALERT THRESHOLDS. Parameters, because "what counts as too full" is a site decision.
# Every one is overridable from the environment so a noisy site can widen them without
# editing a script, and the values that were chosen are written down next to them.
AL_CPU_PCT="${AL_CPU_PCT:-85}"            # sustained CPU above this is a problem
AL_CPU_FOR="${AL_CPU_FOR:-10m}"           # ...but only if it lasts. A build spikes; a loop does not stop
AL_MEM_PCT="${AL_MEM_PCT:-10}"            # MemAvailable below this fraction of total
AL_MEM_FOR="${AL_MEM_FOR:-10m}"
AL_FS_WARN_PCT="${AL_FS_WARN_PCT:-20}"    # free space warning
AL_FS_CRIT_PCT="${AL_FS_CRIT_PCT:-10}"    # free space critical
AL_FS_WARN_FOR="${AL_FS_WARN_FOR:-15m}"
AL_FS_CRIT_FOR="${AL_FS_CRIT_FOR:-5m}"
AL_AUDIT_PCT="${AL_AUDIT_PCT:-25}"        # TIGHTER for /var/log/audit - see the rule comment
AL_FS_PREDICT_HRS="${AL_FS_PREDICT_HRS:-4}"   # "will be full within N hours" at the current rate
AL_DOWN_FOR="${AL_DOWN_FOR:-2m}"

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

# PROVISIONED, NOT CLICKED. A rebuilt collector comes up with its datasource already
# configured, and with the SAME uid every time - clicking it in the UI gets a random one.
ensure_datasource() {
  local f=/etc/grafana/provisioning/datasources/enclave-prometheus.yaml
  install -d -m 0755 /etc/grafana/provisioning/datasources
  cat > "$f" <<DS
# Generated by scripts/enclave/monitoring.sh - do not edit by hand.
apiVersion: 1
# deleteDatasources IS LOAD-BEARING, and leaving it out took Grafana down on 2026-09-14.
#
# Grafana's provisioner UPDATES AN EXISTING DATASOURCE BY UID. This one was first created
# without a uid, so Grafana had assigned a random one; pinning a uid afterwards makes that
# update look up a uid its database has never seen. It does not fall back to the name and
# it does not create a new record - it fails provisioning, and provisioning is a hard
# dependency of the HTTP server, so GRAFANA EXITS 1 AND WILL NOT START. From the outside
# that is an nginx 502 with nothing in nginx's own logs to explain it.
#
# Deleting by name first is Grafana's documented answer and it is safe to leave here
# permanently: a datasource holds no data, only the pointer, so delete-then-create on each
# start costs nothing and makes the uid authoritative rather than whatever was assigned the
# first time this machine was built.
deleteDatasources:
  - name: Prometheus
    orgId: 1
datasources:
  - name: Prometheus
    uid: $DS_UID
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
DS
  chown root:grafana "$f"; chmod 0640 "$f"
  ok "datasource provisioned with uid '$DS_UID'"
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
    printf 'rule_files:\n  - /etc/prometheus/rules/*.yml\n\n'
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

  # nginx is REQUIRED - it is what puts Grafana behind TLS. enable-tls.sh checks for it and
  # dies rather than installing it, so install it here or the collector ends up on plain http.
  command -v nginx >/dev/null 2>&1 \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y nginx 2>&1 | tail -2

  if dpkg -s grafana >/dev/null 2>&1; then
    local gd=/etc/default/grafana-server
    cp -a "$gd" "/var/backups/grafana-server.$(date +%Y%m%dT%H%M%S)" 2>/dev/null || true
    # GRAFANA BINDS LOOPBACK AND NOTHING ELSE.
    #
    # nginx terminates TLS with an enclave certificate and proxies to it - the same
    # arrangement svc-mgmt-01 already uses for its contracts server. Grafana on the enclave
    # address would mean the admin password and every session cookie crossing the enclave in
    # clear, which is exactly what it did before 2026-09-14.
    #
    # GF_SERVER_ROOT_URL is the part that gets missed: Grafana builds absolute URLs for login
    # redirects from it, and left at the default it sends the browser back to plain http on
    # the first redirect - the padlock appears, then quietly goes away.
    local k kv fqdn="${me}.${ENCLAVE_DOMAIN:-enclave.internal}"
    for kv in "GF_SERVER_HTTP_ADDR=127.0.0.1" "GF_SERVER_HTTP_PORT=3000" \
              "GF_SERVER_ROOT_URL=https://${fqdn}/"; do
      k="${kv%%=*}"
      grep -q "^$k=" "$gd" 2>/dev/null && sed -i "s|^$k=.*|$kv|" "$gd" || printf '%s\n' "$kv" >> "$gd"
    done
    ensure_datasource
    systemctl daemon-reload
    systemctl enable --now grafana-server >/dev/null 2>&1 || true
  fi

  # ---- TLS in front of Grafana ----------------------------------------------------------
  local chain="/etc/ssl/enclave/${me}.fullchain.crt"
  if [ -f "$chain" ]; then
    say ""
    say "certificate present - putting nginx in front of Grafana"
    "$HERE/enable-tls.sh" "$me" "$chain" --proxy http://127.0.0.1:3000 || \
      warn "enable-tls.sh failed - Grafana is on loopback only, so it is UNREACHABLE until this is fixed"
    "$HERE/enable-tls.sh" --redirect-http || warn "--redirect-http failed; :80 will not redirect"
  else
    say ""
    warn "NO CERTIFICATE at $chain - Grafana is bound to loopback and therefore UNREACHABLE."
    warn "  That is deliberate: it must not be served over plain http. Issue one:"
    say  "    on $me       : sudo $HERE/ca.sh request $me"
    say  "    on svc-mgmt-01: sudo $HERE/ca.sh sign-server <the csr>"
    say  "    back on $me  : put the fullchain at $chain, then re-run: sudo $0 collector"
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
    # Grafana must be on LOOPBACK. If it is on the enclave address it is reachable without
    # TLS, and the certificate work in front of it is decoration.
    if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qx "127.0.0.1:3000"; then
      printf '     %-24s ok (loopback - nginx fronts it)\n' "127.0.0.1:3000"
    else
      printf '  [!] %-24s grafana is NOT on loopback - it may be serving plain http\n' "127.0.0.1:3000"; bad=1
    fi
    if [ -f "/etc/ssl/enclave/${me}.fullchain.crt" ]; then
      ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*):443$' \
        && printf '     %-24s ok (nginx, enclave cert)\n' "0.0.0.0:443" \
        || { printf '  [!] %-24s nginx is NOT serving 443\n' "0.0.0.0:443"; bad=1; }
    fi
  }
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '^(\*|0\.0\.0\.0|\[::\]):(9090|9093|9094|9100|3000)$'; then
    warn "a monitoring port is on ALL INTERFACES - the postfix shape (6.3e)"; bad=1
  fi
  [ "$bad" -eq 0 ] || return 1

  say ""
  ok "collector up. Targets take one scrape_interval to report:"
  say "   curl -s 'http://127.0.0.1:9090/api/v1/targets?state=any'"
  if [ -f "/etc/ssl/enclave/${me}.fullchain.crt" ]; then
    say "   grafana: https://${me}.${ENCLAVE_DOMAIN:-enclave.internal}/  - set the admin"
    say "            password AT THE BROWSER PROMPT, over TLS. Never in a terminal."
  fi
  warn "retention is ${PROM_RETENTION_TIME} / ${PROM_RETENTION_SIZE} - the TIME is a placeholder"
  warn "  until the AO answers. The SIZE cap is the real protection: it stops a noisy month"
  warn "  filling the disk and taking down the machine you use to find out why."
}

# ------------------------------------------------------------------------------ rules
# ALERT RULES LIVE IN PROMETHEUS, NOT IN GRAFANA.
#
# Grafana's own alerting stores rules in its SQLite database, which means they are not in
# this repository, do not travel on the transfer media, and are lost with the VM. Prometheus
# rule files are text: versioned here, regenerated on a rebuild, and reviewable by someone
# who is not allowed to log in to Grafana.
#
# EVERY ALERT CARRIES AN `action` ANNOTATION. An alert that says only what happened makes
# the reader work out what to do at the worst possible moment. Say it in the alert.
cmd_rules() {
  need_root
  local me; me="$(hostname -s)"
  [ "$me" = "${SVC_OBS_01_NAME:-svc-obs-01}" ] || warn "this is $me, not the collector - continuing anyway"
  command -v promtool >/dev/null 2>&1 || die "promtool not found - is prometheus installed?"

  local dir=/etc/prometheus/rules
  install -d -m 0755 "$dir"
  local f="$dir/enclave.yml"
  [ -f "$f" ] && cp -a "$f" "/var/backups/$(basename "$f").$(date +%Y%m%dT%H%M%S)"

  cat > "$f" <<EOF
# Generated by scripts/enclave/monitoring.sh - do not edit by hand.
# Thresholds are parameters; see AL_* at the top of that script.
groups:

  # ---------------------------------------------------------------- availability
  # FIRST, BECAUSE WITHOUT IT THE REST ARE MEANINGLESS. A machine that has stopped
  # reporting cannot breach a CPU threshold, so silence looks identical to health.
  - name: enclave-availability
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: ${AL_DOWN_FOR}
        labels:
          severity: critical
        annotations:
          summary: "{{ \$labels.machine }} ({{ \$labels.job }}) is not responding to scrapes"
          description: "Prometheus has had no answer from {{ \$labels.instance }} for ${AL_DOWN_FOR}."
          action: >-
            Check the machine is up and the exporter is running:
            'systemctl status prometheus-node-exporter' on {{ \$labels.machine }}.
            If the machine is a guest, check it from host-4 with 'virsh list --all'.
            Remember ufw enforces on svc-repo-01 and svc-obs-01 - a firewall change can
            look exactly like a dead machine.

  # ---------------------------------------------------------------- cpu
  - name: enclave-cpu
    rules:
      - alert: HighCPU
        expr: 100 - (avg by (machine, instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > ${AL_CPU_PCT}
        for: ${AL_CPU_FOR}
        labels:
          severity: warning
        annotations:
          summary: "{{ \$labels.machine }} CPU at {{ printf \"%.0f\" \$value }}% for ${AL_CPU_FOR}"
          description: "Sustained CPU above ${AL_CPU_PCT}%. A build or a scan spikes; a runaway loop does not stop."
          action: >-
            'top -b -n1 | head -20' on {{ \$labels.machine }}.
            On svc-mgmt-01 check MAAS first - it has been seen invoking machine-resources
            through sudo roughly twice a second, which also floods the audit log.

  # ---------------------------------------------------------------- memory
  - name: enclave-memory
    rules:
      - alert: MemoryPressure
        expr: (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 < ${AL_MEM_PCT}
        for: ${AL_MEM_FOR}
        labels:
          severity: warning
        annotations:
          summary: "{{ \$labels.machine }} has {{ printf \"%.1f\" \$value }}% memory available"
          description: "MemAvailable below ${AL_MEM_PCT}% of total for ${AL_MEM_FOR}."
          action: >-
            'ps -eo pid,rss,comm --sort=-rss | head' on {{ \$labels.machine }}.
            MemAvailable already accounts for reclaimable cache, so this is real pressure,
            not just a warm page cache.

  # ---------------------------------------------------------------- filesystems
  # vfat is excluded: /boot/efi is tiny, static, and only changes on a bootloader update,
  # so a percentage alert on it is pure noise.
  - name: enclave-filesystems
    rules:
      - alert: FilesystemFillingWarning
        expr: (node_filesystem_avail_bytes{fstype!~"vfat|tmpfs|squashfs|overlay"} / node_filesystem_size_bytes) * 100 < ${AL_FS_WARN_PCT}
        for: ${AL_FS_WARN_FOR}
        labels:
          severity: warning
        annotations:
          summary: "{{ \$labels.machine }}:{{ \$labels.mountpoint }} {{ printf \"%.1f\" \$value }}% free"
          description: "Below ${AL_FS_WARN_PCT}% free for ${AL_FS_WARN_FOR}."
          action: >-
            'du -x -h -d1 {{ \$labels.mountpoint }} | sort -rh | head' on {{ \$labels.machine }}.
            Log rotation on these machines was broken until 2026-09-14 - confirm
            /etc/logrotate.d/rsyslog still carries its 'su' line before hunting elsewhere.

      - alert: FilesystemFillingCritical
        expr: (node_filesystem_avail_bytes{fstype!~"vfat|tmpfs|squashfs|overlay"} / node_filesystem_size_bytes) * 100 < ${AL_FS_CRIT_PCT}
        for: ${AL_FS_CRIT_FOR}
        labels:
          severity: critical
        annotations:
          summary: "{{ \$labels.machine }}:{{ \$labels.mountpoint }} only {{ printf \"%.1f\" \$value }}% free"
          description: "Below ${AL_FS_CRIT_PCT}% free. Services begin failing in ways that do not name the disk."
          action: >-
            Free space now. A full / stops sudo from writing its timestamp and a full
            /var/lib/libvirt/images pauses every guest on host-4.

      # /var/log/audit IS NOT AN ORDINARY FILESYSTEM ON A STIG MACHINE.
      # auditd's configured disk_full_action decides what happens when it fills, and the
      # options include halting the system. It gets a wider margin than anything else here.
      - alert: AuditFilesystemFilling
        expr: (node_filesystem_avail_bytes{mountpoint="/var/log/audit"} / node_filesystem_size_bytes{mountpoint="/var/log/audit"}) * 100 < ${AL_AUDIT_PCT}
        for: ${AL_FS_CRIT_FOR}
        labels:
          severity: critical
        annotations:
          summary: "{{ \$labels.machine }} audit partition {{ printf \"%.1f\" \$value }}% free"
          description: "The audit partition is filling. auditd's disk_full_action governs what happens at zero, and that can include halting the machine."
          action: >-
            'sudo grep -E \"^(max_log_file|num_logs|disk_full_action|space_left)\" /etc/audit/auditd.conf'
            on {{ \$labels.machine }}. The trail is bounded by max_log_file x num_logs; if
            usage is climbing anyway, something is generating audit records at an abnormal
            rate. Do NOT simply delete audit logs - they are evidence.

      - alert: FilesystemWillFillSoon
        expr: predict_linear(node_filesystem_avail_bytes{fstype!~"vfat|tmpfs|squashfs|overlay"}[6h], ${AL_FS_PREDICT_HRS} * 3600) < 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "{{ \$labels.machine }}:{{ \$labels.mountpoint }} will be full within ${AL_FS_PREDICT_HRS}h at the current rate"
          description: "Trend over the last 6 hours projects exhaustion within ${AL_FS_PREDICT_HRS} hours."
          action: >-
            This fires while there is still room, which is the point. Find what is growing:
            'du -x -h -d1 {{ \$labels.mountpoint }} | sort -rh | head' on {{ \$labels.machine }}.

      # A filesystem that has gone read-only is usually a disk or controller error, and it
      # is silent: writes fail, services log to a filesystem that cannot accept the log.
      - alert: FilesystemReadOnly
        expr: node_filesystem_readonly{fstype!~"vfat|tmpfs|squashfs|overlay"} == 1
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "{{ \$labels.machine }}:{{ \$labels.mountpoint }} has gone READ-ONLY"
          description: "The kernel remounted it read-only, which usually means an I/O error."
          action: >-
            'sudo dmesg | tail -40' on {{ \$labels.machine }} and look for I/O errors.
            Do not simply remount read-write - find out why first.
EOF
  chmod 0644 "$f"

  # VALIDATE BEFORE RELOADING. A bad rule file makes Prometheus refuse to start, which would
  # take out the monitoring at the moment it is needed.
  if ! promtool check rules "$f" >/dev/null 2>&1; then
    promtool check rules "$f" 2>&1 | sed 's/^/       /'
    rm -f "$f"
    die "generated rules are INVALID - removed, nothing reloaded"
  fi
  ok "rules valid: $(promtool check rules "$f" 2>&1 | grep -oE '[0-9]+ rules found' || echo 'checked')"

  # A VALID CONFIG THAT DOES NOT REFERENCE THE RULES IS STILL VALID.
  #
  # The first version tested `promtool check config` here and treated a pass as proof the
  # rules would load. A prometheus.yml with no rule_files section passes that check
  # perfectly - it is simply a config that loads no rules. So the script printed
  # "rules valid: 8 rules found", reloaded, and left Prometheus running with ZERO rules,
  # which reads exactly like success. Ask the RUNNING PROCESS instead, at the end.
  local cfg=/etc/prometheus/prometheus.yml
  if ! grep -qE '^rule_files:' "$cfg"; then
    cp -a "$cfg" "/var/backups/prometheus.yml.$(date +%Y%m%dT%H%M%S)"
    # Insert after the alerting block, before scrape_configs - order does not matter to
    # Prometheus, but keeping it above scrape_configs keeps the file readable.
    if grep -qE '^scrape_configs:' "$cfg"; then
      sed -i '0,/^scrape_configs:/s||rule_files:\n  - /etc/prometheus/rules/*.yml\n\nscrape_configs:|' "$cfg"
    else
      printf '\nrule_files:\n  - /etc/prometheus/rules/*.yml\n' >> "$cfg"
    fi
    ok "added rule_files to $cfg"
  fi

  if ! promtool check config "$cfg" >/dev/null 2>&1; then
    promtool check config "$cfg" 2>&1 | sed 's/^/       /'
    die "prometheus.yml is INVALID after the edit - nothing reloaded, see the backup in /var/backups"
  fi

  systemctl reload prometheus 2>/dev/null || systemctl restart prometheus
  sleep 3

  # VERIFY AGAINST THE RUNNING PROCESS, NOT AGAINST THE FILE ON DISK.
  local n
  n="$(curl -s http://127.0.0.1:9090/api/v1/rules 2>/dev/null \
       | python3 -c 'import json,sys; print(sum(len(g["rules"]) for g in json.load(sys.stdin)["data"]["groups"]))' 2>/dev/null)"
  if [ "${n:-0}" -gt 0 ]; then
    ok "prometheus reloaded - $n rule(s) ACTIVE in the running process"
    curl -s http://127.0.0.1:9090/api/v1/rules 2>/dev/null \
      | python3 -c 'import json,sys
for g in json.load(sys.stdin)["data"]["groups"]:
    for r in g["rules"]:
        print("       %-28s %s" % (r["name"], r.get("state","")))' 2>/dev/null
  else
    warn "PROMETHEUS IS RUNNING WITH ZERO RULES - the file is valid but is not being read."
    say  "  check:  grep -A2 '^rule_files:' $cfg"
    say  "  and:    ls -la /etc/prometheus/rules/"
    return 1
  fi
  say "   see them at:  http://127.0.0.1:9090/rules   (tunnel from your desk)"
}

# ------------------------------------------------------------------------------ dashboards
# DASHBOARDS ARE FILES IN THIS REPOSITORY, NOT OBJECTS IN GRAFANA'S DATABASE.
#
# A dashboard built in the Grafana UI lives in its SQLite database. It is not version
# controlled, it does not travel on the transfer media, nobody can review it in a diff, and
# it dies with the VM. Provisioned dashboards are read from disk at start-up and on a timer,
# so the file is the source of truth and the UI becomes a view of it.
#
# The consequence is worth knowing before someone spends an afternoon in the UI: edits made
# in Grafana to a provisioned dashboard CANNOT be saved back over it. Change the JSON here,
# re-run this, and Grafana picks it up.
# ----------------------------------------------------------------------------- facts
# COMPLIANCE FACTS AS METRICS.
#
# Everything here is already measured somewhere on this machine and then thrown away: the
# STIG residual sits in an XML nobody opens, certificate expiry lives in a runbook table
# that goes stale, AIDE mails a report to a mailbox that cannot leave the enclave. This
# turns each of them into a series so it can be graphed, alerted on, and shown to an
# assessor as a trend rather than an assertion.
#
# THE ONE RULE THAT MATTERS: A MISSING SOURCE MUST NEVER RENDER AS ZERO FINDINGS.
# A dashboard that reads "0 Open" because a scan was never run looks exactly like a
# dashboard that reads "0 Open" because the machine is clean. So every family publishes a
# companion enclave_facts_source_ok{source="..."}, and a family with no source emits NO
# SAMPLES AT ALL - "No data" on a panel is honest, a zero is a lie.
cmd_facts() {
  need_root; guard_in_gap
  install -d -m 0755 "$TEXTFILE_DIR" 2>/dev/null || true
  local out="$TEXTFILE_DIR/enclave-compliance.prom" tmp
  tmp="$(mktemp "$TEXTFILE_DIR/.facts.XXXXXX")" || die "cannot write in $TEXTFILE_DIR"

  LC_ALL=C python3 - > "$tmp" <<'FACTSPY'
import os, sys, glob, csv, time, subprocess, collections, calendar

OUT = []
SRC = {}                      # source -> 1 ok / 0 present-but-unreadable ; absent = no entry

def emit(name, value, labels=None, help=None, typ="gauge"):
    OUT.append((name, labels or {}, value, help, typ))

def run(cmd, timeout=20):
    """Capture stdout AND say nothing on failure. Swallowed output has cost this project
    three evenings, so callers must decide what a failure means - never this helper."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:
        return 127, "", str(e)

def utc_epoch(text):
    """systemd prints 'Mon 2026-09-14 02:05:18 UTC'. %Z round-trips badly, and these
    machines are all UTC by build (the operator is US Central, the boxes are not), so the
    weekday and zone are dropped and the rest read as UTC."""
    try:
        parts = text.split()
        if len(parts) >= 3:
            t = time.strptime(parts[1] + " " + parts[2], "%Y-%m-%d %H:%M:%S")
            return calendar.timegm(t)
    except Exception:
        pass
    return None

# ---------------------------------------------------------------- FIPS and reboot state
try:
    v = int(open("/proc/sys/crypto/fips_enabled").read().strip())
    emit("enclave_fips_enabled", v, help="1 if the kernel is running in FIPS mode")
    SRC["fips"] = 1
except Exception:
    SRC["fips"] = 0

emit("enclave_reboot_required", 1 if os.path.exists("/var/run/reboot-required") else 0,
     help="1 if a package update is waiting on a reboot to take effect")

# ---------------------------------------------------------------------- USG / OpenSCAP
# usg audit writes /var/lib/usg/usg-results-YYYYMMDD.HHMM.xml, 0600 root:root. Newest wins.
xmls = sorted(glob.glob("/var/lib/usg/usg-results-*.xml"), key=os.path.getmtime)
if xmls:
    newest = xmls[-1]
    try:
        import xml.etree.ElementTree as ET
        c = collections.Counter()
        # iterparse, not parse: these are 8 MB and this runs every 15 minutes.
        for _, el in ET.iterparse(newest, events=("end",)):
            if el.tag.endswith("rule-result"):
                for ch in el:
                    if ch.tag.endswith("}result") or ch.tag == "result":
                        c[(ch.text or "unknown").strip()] += 1
                        break
                el.clear()
        for k, n in c.items():
            emit("enclave_usg_rules", n, {"result": k},
                 help="XCCDF rule-results from the newest usg audit on this machine")
        emit("enclave_usg_scan_time_seconds", int(os.path.getmtime(newest)),
             help="mtime of the newest usg results XML - a green score from a stale scan is not a pass")
        SRC["usg"] = 1
    except Exception:
        SRC["usg"] = 0

# ------------------------------------------------------------- Evaluate-STIG against V1R6
# NEVER from Previous/. Evaluate-STIG archives each prior run under <MACHINE>/Previous/,
# and a path sort puts the archive last - which is how a report described a scan 20 minutes
# older than the one that had just finished (stig-tools.sh has the same guard).
# AND SCOPED TO THIS MACHINE. /srv/stig-evidence is also the directory stage-01 collects
# every machine's evidence INTO, so an unscoped glob would happily describe svc-harbor-01
# on host-4. Evaluate-STIG names the directory after the hostname, uppercased.
me = os.uname()[1].split(".")[0]
csvs = [f for f in glob.glob("/srv/stig-evidence/*/Checklist/*COMBINED*.csv") if "/Previous/" not in f]
mine = [f for f in csvs if ("/%s/" % me.upper()) in f.upper()]
if csvs and not mine:
    SRC["estig"] = 0          # evidence is here, but none of it is THIS machine's
csvs = mine
if csvs:
    newest = max(csvs, key=os.path.getmtime)
    try:
        rows = list(csv.DictReader(open(newest, encoding="utf-8-sig")))
        c = collections.Counter(r.get("Status", "?") for r in rows)
        for k, n in c.items():
            emit("enclave_stig_controls", n, {"status": k},
                 help="DISA V1R6 controls by status: NF not a finding, O open, NR not reviewed, NA not applicable")
        sev = collections.Counter(r.get("Severity", "?") for r in rows if r.get("Status") == "O")
        for k, n in sev.items():
            emit("enclave_stig_open_by_severity", n, {"severity": k},
                 help="Open V1R6 controls by severity")
        emit("enclave_stig_controls_total", len(rows), help="controls assessed in the newest checklist")
        emit("enclave_stig_scan_time_seconds", int(os.path.getmtime(newest)),
             help="mtime of the newest COMBINED checklist")
        SRC["estig"] = 1
    except Exception:
        SRC["estig"] = 0

# ------------------------------------------------------------------ certificate expiry
# The runbook carries an expiry calendar that is correct on the day it is written. This is
# the same three dates, measured.
certs = sorted(set(glob.glob("/etc/ssl/enclave/*.crt")
                   + glob.glob("/usr/local/share/ca-certificates/*.crt")))
if certs:
    ok_any = 0
    for f in certs:
        rc, o, _ = run(["openssl", "x509", "-noout", "-enddate", "-subject", "-in", f])
        if rc != 0:
            continue
        end = cn = None
        for line in o.splitlines():
            if line.startswith("notAfter="):
                t = line.split("=", 1)[1].strip()
                for fmt in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y"):
                    try:
                        end = calendar.timegm(time.strptime(t.replace(" GMT", ""), fmt.replace(" %Z", "")))
                        break
                    except Exception:
                        continue
            elif line.startswith("subject="):
                for part in line.split("CN"):
                    if part.startswith(" = ") or part.startswith("="):
                        cn = part.split("=", 1)[1].strip().split(",")[0]
        if end:
            emit("enclave_cert_expiry_seconds", end,
                 {"file": os.path.basename(f), "cn": cn or "unknown"},
                 help="unix time at which this certificate stops being valid")
            ok_any = 1
    SRC["certs"] = ok_any

# ------------------------------------------------------------------------------ auditd
# lost and backlog are the two numbers that say whether the audit trail is COMPLETE. A
# machine can pass every audit rule check while silently dropping records.
rc, o, _ = run(["auditctl", "-s"])
if rc == 0:
    SRC["auditd"] = 1
    for line in o.split("\n"):
        f = line.split()
        if len(f) >= 2 and f[0] in ("enabled", "lost", "backlog", "backlog_limit", "failure"):
            try:
                emit("enclave_auditd_" + f[0], int(f[1]),
                     help="auditctl -s: " + f[0] + " (lost > 0 means audit records were DROPPED)")
            except ValueError:
                pass
else:
    SRC["auditd"] = 0

# -------------------------------------------------------------------------------- AIDE
# dailyaidecheck.timer is the STIG's file-integrity mechanism on Ubuntu. What matters is
# not that the timer exists but that the last run finished and when.
# LoadState IS THE GUARD. `systemctl show` on a unit that does not exist exits 0 and prints
# defaults, so without this a machine with no AIDE at all published
# enclave_aide_last_exit_code 0 - a clean bill of health from a check that never ran.
rc, o, _ = run(["systemctl", "show", "dailyaidecheck.service", "-p", "LoadState",
                "-p", "ExecMainStartTimestamp", "-p", "ExecMainStatus", "-p", "Result"])
if rc == 0 and "LoadState=loaded" in o:
    SRC["aide"] = 1
    kv = dict(l.split("=", 1) for l in o.strip().splitlines() if "=" in l)
    ts = utc_epoch(kv.get("ExecMainStartTimestamp", ""))
    if ts:
        emit("enclave_aide_last_run_seconds", ts, help="unix time the last AIDE check started")
    if ts:                    # no start timestamp means it has never run - say nothing
        try:
            emit("enclave_aide_last_exit_code", int(kv.get("ExecMainStatus", "") or -1),
                 help="exit status of the last AIDE check; non-zero means it found changes or failed")
        except ValueError:
            pass
for db in ("/var/lib/aide/aide.db", "/var/lib/aide/aide.db.new"):
    if os.path.exists(db):
        emit("enclave_aide_db_age_seconds", int(time.time() - os.path.getmtime(db)),
             {"db": os.path.basename(db)}, help="age of the AIDE baseline database")

# ------------------------------------------------------------------ accounts and lockout
# pam_faillock tallies live in /run/faillock, one file per user, on tmpfs. deny=3 and
# unlock_time=0 here, so a tally that reaches 3 is a PERMANENT lockout until cleared - the
# thing that locked this operator out of host-4.
try:
    n = sum(1 for f in glob.glob("/run/faillock/*") if os.path.getsize(f) > 0)
    emit("enclave_faillock_users_with_failures", n,
         help="users with a non-empty pam_faillock tally; deny=3 unlock_time=0 means 3 is permanent")
    SRC["accounts"] = 1
except Exception:
    SRC["accounts"] = 0

rc, o, _ = run(["journalctl", "--since", "-24h", "-t", "sudo", "-o", "cat", "--no-pager"], timeout=60)
if rc == 0:
    emit("enclave_failed_sudo_24h", sum(1 for l in o.splitlines() if "authentication failure" in l),
         help="failed sudo authentications in the last 24h, from the journal")
    emit("enclave_sudo_invocations_24h", sum(1 for l in o.splitlines() if "COMMAND=" in l),
         help="total sudo invocations in the last 24h - svc-mgmt-01 runs ~1.7 per SECOND and nobody knows why")

# ------------------------------------------------------------------------- USB storage
# V-270718 checks modprobe.d and NEVER lsmod, so this reads the same place the control does.
blocked = 0
for f in glob.glob("/etc/modprobe.d/*.conf"):
    try:
        t = open(f, errors="ignore").read()
        if "usb-storage" in t and ("install usb-storage /bin/false" in t or "blacklist usb-storage" in t):
            blocked = 1
    except Exception:
        pass
emit("enclave_usb_storage_blocked", blocked,
     help="1 if usb-storage is blocked in modprobe.d, which is where V-270718 looks")

# --------------------------------------------------------------------------- producer
emit("enclave_facts_generated_seconds", int(time.time()),
     help="unix time this file was written - if it stops moving, every metric above is stale")
for k, v in sorted(SRC.items()):
    emit("enclave_facts_source_ok", v, {"source": k},
         help="1 if this source was readable. ABSENT means the source does not exist on this machine - which is not the same as zero findings")

# ------------------------------------------------------------------------------ output
seen = set()
for name, labels, value, help, typ in OUT:
    if name not in seen:
        seen.add(name)
        if help:
            print("# HELP %s %s" % (name, help))
        print("# TYPE %s %s" % (name, typ))
    if labels:
        ls = ",".join('%s="%s"' % (k, str(v).replace('\\', '').replace('"', ''))
                      for k, v in sorted(labels.items()))
        print("%s{%s} %s" % (name, ls, value))
    else:
        print("%s %s" % (name, value))
FACTSPY

  # A PRODUCER THAT WROTE NOTHING MUST NOT REPLACE A GOOD FILE. Truncating the old one
  # would turn "the script broke" into "this machine has no findings", which is the exact
  # failure this whole file is written to avoid.
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; die "facts produced NO output - $out left as it was"; fi
  chmod 0644 "$tmp"; mv -f "$tmp" "$out"
  ok "wrote $out"
  say "   $(grep -vc '^#' "$out") samples, $(grep -c '^# HELP' "$out") metric families"
  grep '^enclave_facts_source_ok' "$out" | sed 's/^/     /'
}

# Install the timer that keeps the facts fresh. 15 minutes: these are daily-to-weekly facts,
# and a scrape interval is not a measurement interval.
cmd_facts_timer() {
  need_root; guard_in_gap
  cat > /etc/systemd/system/enclave-facts.service <<UNIT
[Unit]
Description=Publish enclave compliance facts for node-exporter
After=network.target

[Service]
Type=oneshot
ExecStart=$HERE/monitoring.sh facts
UNIT
  cat > /etc/systemd/system/enclave-facts.timer <<'UNIT'
[Unit]
Description=Refresh enclave compliance facts every 15 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now enclave-facts.timer >/dev/null 2>&1 || die "could not enable enclave-facts.timer"
  systemctl start enclave-facts.service || warn "first run failed - journalctl -u enclave-facts"
  ok "enclave-facts.timer enabled"
  systemctl list-timers enclave-facts.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/     /'
}

cmd_dashboards() {
  need_root
  local me; me="$(hostname -s)"
  [ "$me" = "${SVC_OBS_01_NAME:-svc-obs-01}" ] || warn "this is $me, not the collector - continuing anyway"
  command -v grafana >/dev/null 2>&1 || [ -d /etc/grafana ] || die "grafana does not look installed here"

  local src; src="$HERE/dashboards"
  [ -d "$src" ] || die "no dashboards directory at $src"
  local n; n="$(find "$src" -name '*.json' | wc -l)"
  [ "$n" -gt 0 ] || die "no .json dashboards in $src"

  # Validate BEFORE installing. A malformed dashboard is silently skipped by Grafana with
  # nothing but a line in its log, so it would look exactly like a dashboard that never
  # existed - which is the same class of failure as a rule file that is never read.
  local bad=0 f
  for f in "$src"/*.json; do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null \
      || { warn "INVALID JSON: $f"; bad=1; }
  done
  [ "$bad" -eq 0 ] || die "refusing to install invalid dashboards"

  # THE UID DRIFT CHECK. This is the failure that cost an evening on 2026-09-14: the panels
  # asked for 'enclave-prometheus', the provisioning file named no uid at all, and all 17
  # panels read "No data" with the real reason only in a hover tooltip. Two hardcoded
  # strings in two files WILL drift; compare them instead of trusting them.
  ensure_datasource
  local drift
  drift="$(python3 - "$DS_UID" "$src" <<'UID'
import json,sys,glob,os
want,src=sys.argv[1],sys.argv[2]
bad=set()
def walk(o):
    if isinstance(o,dict):
        if o.get("type")=="prometheus" and "uid" in o and o["uid"]!=want:
            bad.add(o["uid"])
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
for f in sorted(glob.glob(os.path.join(src,"*.json"))):
    walk(json.load(open(f)))
print(" ".join(sorted(bad)))
UID
)"
  [ -z "$drift" ] || die "dashboard panels reference datasource uid(s) [$drift] but the
       provisioned datasource is '$DS_UID'. Grafana will render every panel empty.
       Fix the uid in $src/*.json, or set GRAFANA_DS_UID."

  local dst=/var/lib/grafana/dashboards
  install -d -m 0755 -o grafana -g grafana "$dst" 2>/dev/null || install -d -m 0755 "$dst"
  for f in "$src"/*.json; do
    install -m 0644 "$f" "$dst/$(basename "$f")"
    chown grafana:grafana "$dst/$(basename "$f")" 2>/dev/null || true
    say "installed $(basename "$f")"
  done

  # The provider tells Grafana where to look. foldersFromFilesStructure is off deliberately -
  # one folder keeps the enclave's dashboards together.
  cat > /etc/grafana/provisioning/dashboards/enclave.yaml <<'PROV'
# Generated by scripts/enclave/monitoring.sh - do not edit by hand.
apiVersion: 1
providers:
  - name: enclave
    orgId: 1
    folder: Enclave
    type: file
    disableDeletion: false
    # Re-read from disk on this interval, so a re-run of `monitoring.sh dashboards`
    # takes effect without restarting Grafana.
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
PROV
  chmod 0644 /etc/grafana/provisioning/dashboards/enclave.yaml
  ok "provider written: /etc/grafana/provisioning/dashboards/enclave.yaml"

  systemctl restart grafana-server 2>/dev/null || systemctl restart grafana 2>/dev/null \
    || warn "could not restart grafana - restart it by hand"

  # WAIT FOR IT TO ACTUALLY COME BACK, and say so in its own words if it does not.
  # Grafana treats provisioning as a hard dependency of its HTTP server: one bad file and
  # it exits 1 in a loop. nginx then serves 502 with nothing in ITS log, which is how a
  # Grafana problem gets diagnosed as a broken web server. Ask Grafana, not systemd -
  # `is-active` says `activating` during a crash loop.
  local up=0 i
  for i in $(seq 1 30); do
    curl -sf --max-time 2 http://127.0.0.1:3000/api/health >/dev/null 2>&1 && { up=1; break; }
    sleep 2
  done
  if [ "$up" -ne 1 ]; then
    warn "GRAFANA DID NOT COME BACK on 127.0.0.1:3000 after 60s. nginx will serve 502."
    say  "  Its own last error:"
    journalctl -u grafana-server -n 200 --no-pager 2>/dev/null \
      | grep -oE 'Datasource provisioning error: .*|Dashboard provisioning error: .*|failed to load .*' \
      | tail -3 | sed 's/^/       /'
    die "grafana is down - fix the above before anything else. Full log:
       journalctl -u grafana-server -n 60 --no-pager"
  fi
  ok "grafana is up on 127.0.0.1:3000"

  # VERIFY AGAINST WHAT GRAFANA LOADED, not against the files just written. Grafana skips a
  # dashboard it cannot parse and carries on, so "the file is on disk" proves nothing.
  #
  # NOT via /api/search: it returns 401 without credentials, and on 2026-09-14 this check
  # reported "5 dashboards loaded" when one was installed - len() of the 401 error object
  # {extra,message,messageId,statusCode,traceID} is 5. A verification that counts the keys
  # of an error message is worse than no verification, because it is believed.
  #
  # Grafana's own database answers it with no credentials and no guessing. python3 carries
  # sqlite3 in the standard library, so this adds no package.
  local db=/var/lib/grafana/grafana.db
  say ""
  if [ -f "$db" ]; then
    local rows
    rows="$(python3 - "$db" <<'SQL' 2>&1
import sqlite3,sys
try:
    c=sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    # is_folder is deprecated in newer Grafana and may be gone; fall back rather than
    # reporting zero, which would read as "nothing loaded".
    try:
        r=c.execute("select uid,title from dashboard where is_folder=0 order by title").fetchall()
    except sqlite3.OperationalError:
        r=c.execute("select uid,title from dashboard order by title").fetchall()
    print(len(r))
    for uid,title in r: print("       %s  (%s)" % (title,uid))
except Exception as e:
    print("ERR %s" % e)
SQL
)"
    local count; count="$(printf '%s' "$rows" | head -1)"
    case "$count" in
      ERR*|"") warn "could not read $db - $rows" ;;
      0)       warn "GRAFANA LOADED NO DASHBOARDS. Its own words:"
               journalctl -u grafana-server -n 200 --no-pager 2>/dev/null \
                 | grep -i "dashboard" | grep -iE "error|fail|skip" | tail -5 | sed 's/^/       /' ;;
      *)       ok "grafana loaded $count dashboard(s):"
               printf '%s\n' "$rows" | tail -n +2 ;;
    esac
  else
    warn "no $db - cannot verify what grafana loaded; check the UI by eye"
  fi
  say ""
  say "on this machine:  https://127.0.0.1/          (nginx 443 -> grafana 3000)"
  say "from a desk:      https://svc-obs-01.enclave.internal:8443/   via the stage-01 tunnel"
  say "                  -> Dashboards -> Enclave"
  say ""
  warn "EDITS MADE IN THE GRAFANA UI CANNOT BE SAVED back over a provisioned dashboard."
  say  "  Change scripts/enclave/dashboards/*.json and re-run this instead."
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
  rules)      shift; cmd_rules "$@" ;;
  facts)      shift; cmd_facts "$@" ;;
  facts-timer) shift; cmd_facts_timer "$@" ;;
  dashboards) shift; cmd_dashboards "$@" ;;
  status)   shift; cmd_status "$@" ;;
  *) printf 'usage: %s {exporter|libvirt|collector|rules|facts|facts-timer|dashboards|status}\n' "$0" >&2; exit 2 ;;
esac
