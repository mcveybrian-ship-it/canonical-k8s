#!/usr/bin/env bash
# =========================================================================================
# alert-mail.sh - email the enclave's alerts to a person, from OUTSIDE the gap.
# LAB ONLY (backlog 3.72) - not part of the product.
#
#     MACHINE: stage-01. It reads Alertmanager on svc-obs-01 over SSH once a minute (stage-01 already
#     reaches into the enclave with the build01 key) and sends mail itself. The enclave sends nothing
#     out: its Alertmanager keeps its one dashboard receiver, as the acting AO decided (Q26, 2026-09-18).
#     Linux only - it runs as a systemd timer on stage-01; there is nothing to run on Windows.
#
#     sudo ./alert-mail.sh setup     ask for the sending account, its app password and the recipient;
#                                    write /etc/enclave-lab/alert-mail.env (encadmin, 0600) and the
#                                    timer units - installed, NOT started
#          ./alert-mail.sh test      send one test message - proves the account before anything relies on it
#     sudo ./alert-mail.sh enable    start the once-a-minute timer; the first run sends ONE summary of
#                                    what is already firing, not a message per alert
#          ./alert-mail.sh run       one pass - what the timer runs
#          ./alert-mail.sh status    the settings (password masked), what was last seen, the timer
#     sudo ./alert-mail.sh disable   stop the timer; the settings stay
#
# WHAT GETS MAILED: every alert of severity ALERT_MAIL_SEVERITY (critical), plus every alert whose name
# matches ALERT_MAIL_ALSO (^Backup - the NAS rules among them), minus ALERT_MAIL_EXCLUDE. Each one twice:
# when it starts and when it clears, grouped per pass. AptMetadataStale and StigScanStale are warnings
# that run for weeks; they stay on the dashboard. If stage-01 cannot read the alerts for
# ALERT_MAIL_BLIND_MIN minutes it mails that too - a relay that has gone quiet must not look like calm.
#
# WHY GOOGLE AND HOW (2026-10-28, from Google's own pages, fetched that day): smtp.gmail.com, port 465 SSL
# (or 587 TLS), signed in with the full address and an APP PASSWORD - which needs 2-Step Verification and
# may be unavailable on an organisation account. Since 2025-05-01 Workspace refuses a device signing in
# with an ordinary password. Brian, 2026-10-28: Google mail, read-and-send from stage-01 (option A).
# =========================================================================================
set -euo pipefail

CONF="${ALERT_MAIL_CONF:-/etc/enclave-lab/alert-mail.env}"
UNIT=enclave-alert-mail
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
RUN_USER="${ALERT_MAIL_USER:-encadmin}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!]  %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

# The settings: defaults here, the person-specific and secret ones in $CONF. Read, never sourced as
# root - the file belongs to the account the timer runs as.
load_conf() {
  ALERT_MAIL_SMTP_HOST=smtp.gmail.com; ALERT_MAIL_SMTP_PORT=465
  ALERT_MAIL_SMTP_USER=""; ALERT_MAIL_SMTP_PASS=""; ALERT_MAIL_TO=""
  ALERT_MAIL_SEVERITY=critical; ALERT_MAIL_ALSO='^Backup'; ALERT_MAIL_EXCLUDE=''
  ALERT_MAIL_OBS=10.2.20.164; ALERT_MAIL_SSH_USER=encadmin; ALERT_MAIL_SSH_KEY="/home/$RUN_USER/.ssh/build01"
  ALERT_MAIL_BLIND_MIN=10
  ALERT_MAIL_STATE="${ALERT_MAIL_STATE:-/home/$RUN_USER/.local/state/enclave-alert-mail/state.json}"
  [ -r "$CONF" ] || die "no readable $CONF - run: sudo $SELF setup"
  local k v
  while IFS='=' read -r k v; do
    case "$k" in ALERT_MAIL_[A-Z_]*) v="${v%\'}"; v="${v#\'}"; printf -v "$k" '%s' "$v" ;; esac
  done < <(grep -E '^ALERT_MAIL_[A-Z_]+=' "$CONF")
  export ALERT_MAIL_SMTP_HOST ALERT_MAIL_SMTP_PORT ALERT_MAIL_SMTP_USER ALERT_MAIL_SMTP_PASS ALERT_MAIL_TO \
         ALERT_MAIL_SEVERITY ALERT_MAIL_ALSO ALERT_MAIL_EXCLUDE ALERT_MAIL_OBS ALERT_MAIL_BLIND_MIN ALERT_MAIL_STATE
}

# The relay itself. Python's own smtplib, so the password never appears in a process list.
RELAY_PY="$(cat <<'PYEOF'
import email.utils, json, os, re, smtplib, ssl, sys, time
from email.message import EmailMessage

# ONE LINE ON FAILURE: the journal and the operator get the reason, not two tracebacks.
sys.excepthook = lambda t, v, tb: print(f"  [x] {t.__name__}: {v}", file=sys.stderr)
E = os.environ
mode = sys.argv[1]
state_path = E["ALERT_MAIL_STATE"]
now = time.time()

def send(subject, body):
    m = EmailMessage()
    m["From"] = E["ALERT_MAIL_SMTP_USER"]; m["To"] = E["ALERT_MAIL_TO"]
    m["Subject"] = subject; m["Date"] = email.utils.formatdate(localtime=False)
    m["Message-ID"] = email.utils.make_msgid(domain="stage-01.lab")
    m.set_content(body)
    port = int(E["ALERT_MAIL_SMTP_PORT"])
    # VERIFY THE SERVER. smtplib's own default context does not check the certificate at all.
    ctx = ssl.create_default_context()
    if port == 465:
        s = smtplib.SMTP_SSL(E["ALERT_MAIL_SMTP_HOST"], port, timeout=30, context=ctx)
    else:
        s = smtplib.SMTP(E["ALERT_MAIL_SMTP_HOST"], port, timeout=30); s.starttls(context=ctx)
    try:
        s.ehlo()
        s.user, s.password = E["ALERT_MAIL_SMTP_USER"], E["ALERT_MAIL_SMTP_PASS"]
        # AUTH LOGIN IN TWO STEPS (2026-10-29). Gmail closes the connection on smtplib's default - AUTH PLAIN
        # with the credentials on the same line - for ANY account, and answers every other form properly.
        # Measured from stage-01 with a made-up account: the default 'Connection unexpectedly closed';
        # PLAIN in two steps, LOGIN in two steps and LOGIN in one line each a clean 535 (wrong password).
        s.auth("LOGIN", s.auth_login, initial_response_ok=False)
        s.send_message(m)
    except smtplib.SMTPAuthenticationError as e:
        raise RuntimeError(f"Google refused the sign-in ({e.smtp_code}): check the address and that the app "
                           f"password is current - {e.smtp_error.decode(errors='replace')[:120]}") from None
    finally:
        try: s.quit()
        except Exception: pass

if mode == "test":
    send("[enclave lab] test - the alert relay can send",
         "This is a test from alert-mail.sh on stage-01.\n\nIf you are reading it, the account works. "
         "Enable the relay with: sudo ./scripts/lab/alert-mail.sh enable\n")
    print("  [ok] test message sent to " + E["ALERT_MAIL_TO"]); sys.exit(0)

try:
    st = json.load(open(state_path))
except FileNotFoundError:
    st = None
except Exception as e:
    print(f"  [!]  state file unreadable ({e}) - starting over", file=sys.stderr); st = None

def save(s):
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    tmp = state_path + ".tmp"; json.dump(s, open(tmp, "w"), indent=1); os.replace(tmp, state_path)

raw = sys.stdin.read()
try:
    alerts = json.loads(raw)
    assert isinstance(alerts, list)
except Exception:
    alerts = None

s = st or {"alerts": {}, "blind_since": None, "blind_mailed": False, "started": None}
if alerts is None:                                     # could not read Alertmanager this pass
    s["blind_since"] = s["blind_since"] or now
    mins = (now - s["blind_since"]) / 60
    print(f"  [!]  could not read the alerts ({mins:.0f} min)", file=sys.stderr)
    if mins >= float(E["ALERT_MAIL_BLIND_MIN"]) and not s["blind_mailed"]:
        send("[enclave lab] the alert relay is BLIND",
             f"stage-01 has not been able to read Alertmanager on {E['ALERT_MAIL_OBS']} for {mins:.0f} minutes.\n\n"
             "Until this clears, NO alert reaches your mail - check svc-obs-01 on the Grafana dashboard.\n"
             "On stage-01: journalctl -u enclave-alert-mail -n 30\n")
        s["blind_mailed"] = True
    save(s); sys.exit(1)
if s["blind_mailed"]:
    send("[enclave lab] the alert relay can see again",
         f"stage-01 is reading Alertmanager again after {(now - s['blind_since']) / 60:.0f} minutes. "
         "Anything that started meanwhile is in the next message.\n")
s["blind_since"] = None; s["blind_mailed"] = False

sev = set(E["ALERT_MAIL_SEVERITY"].split(","))
also = re.compile(E["ALERT_MAIL_ALSO"]) if E["ALERT_MAIL_ALSO"] else None
excl = re.compile(E["ALERT_MAIL_EXCLUDE"]) if E["ALERT_MAIL_EXCLUDE"] else None
def wanted(a):
    n = a["labels"].get("alertname", ""); v = a["labels"].get("severity", "")
    if excl and excl.search(n): return False
    return v in sev or bool(also and also.search(n))
cur = {a["fingerprint"]: a for a in alerts if wanted(a)}

def line(a):
    l = a["labels"]; an = a.get("annotations", {})
    where = l.get("machine") or l.get("instance") or ""
    what = ", ".join(f"{k}={v}" for k, v in sorted(l.items()) if k not in ("alertname", "severity", "machine", "instance", "job", "enclave", "role"))
    out = f"- {l.get('alertname')} [{l.get('severity', '?')}] {where} {what}".rstrip()
    out += f"\n    since {a.get('startsAt', '')[:16].replace('T', ' ')} UTC"
    for k in ("summary", "description", "action"):
        if an.get(k): out += f"\n    {k}: {an[k]}"
    return out

if st is None:                                         # the first pass: one summary, no flood
    s["started"] = now
    body = (f"The alert relay on stage-01 is running. From now on you get a message when a matching alert "
            f"starts and when it clears (severity {E['ALERT_MAIL_SEVERITY']}, plus names matching "
            f"'{E['ALERT_MAIL_ALSO']}').\n\nAlready firing ({len(cur)}):\n\n" + "\n\n".join(line(a) for a in cur.values()))
    send(f"[enclave lab] relay started - {len(cur)} alert(s) already firing", body)
    s["alerts"] = {fp: {"name": a["labels"].get("alertname"), "line": line(a)} for fp, a in cur.items()}
    save(s); print(f"  [ok] first pass: summary of {len(cur)} sent"); sys.exit(0)

new = [a for fp, a in cur.items() if fp not in s["alerts"]]
gone = [(fp, v) for fp, v in s["alerts"].items() if fp not in cur]
if new:
    names = sorted({a["labels"].get("alertname") for a in new})
    send(f"[enclave lab] FIRING {len(new)}: {', '.join(names)[:120]}", "\n\n".join(line(a) for a in new))
if gone:
    names = sorted({v["name"] for _, v in gone})
    send(f"[enclave lab] RESOLVED {len(gone)}: {', '.join(names)[:120]}",
         "These have cleared:\n\n" + "\n\n".join(v["line"] for _, v in gone))
s["alerts"] = {fp: {"name": a["labels"].get("alertname"), "line": line(a)} for fp, a in cur.items()}
save(s)
print(f"  [ok] {len(cur)} matching active, {len(new)} new, {len(gone)} resolved")
PYEOF
)"

fetch() {  # Alertmanager's active, unsilenced alerts as JSON on stdout - nothing on failure
  ssh -n -i "$ALERT_MAIL_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=10 \
      "$ALERT_MAIL_SSH_USER@$ALERT_MAIL_OBS" \
      'curl -sf --max-time 20 "http://127.0.0.1:9093/api/v2/alerts?active=true&silenced=false&inhibited=false"' 2>/dev/null
}

cmd_run() {
  load_conf
  [ "$(id -un)" = "$RUN_USER" ] || die "run as $RUN_USER - the state, the SSH key and the settings are that account's"
  fetch | python3 -I -c "$RELAY_PY" run
}

cmd_test() {
  load_conf
  [ -n "$ALERT_MAIL_SMTP_USER" ] && [ -n "$ALERT_MAIL_SMTP_PASS" ] && [ -n "$ALERT_MAIL_TO" ] \
    || die "the sending account, password or recipient is empty in $CONF - run: sudo $SELF setup"
  python3 -I -c "$RELAY_PY" test < /dev/null
}

cmd_setup() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  [ "$(hostname -s)" = stage-01 ] || die "this is $(hostname -s) - the relay runs on stage-01 (outside the gap)"
  id "$RUN_USER" >/dev/null 2>&1 || die "no account $RUN_USER here"
  local u p to
  read -rp "  sending Google address (the account the app password belongs to): " u < /dev/tty
  read -rsp "  its 16-character app password (not shown): " p < /dev/tty; echo
  p="${p// /}"
  read -rp "  send alerts to: " to < /dev/tty
  [ -n "$u" ] && [ -n "$p" ] && [ -n "$to" ] || die "all three are needed - nothing written"
  install -d -m 0750 -o root -g "$RUN_USER" "$(dirname "$CONF")"
  ( umask 077
    { printf '# alert-mail.sh settings - LAB ONLY. Secret: never print this file, never commit it.\n'
      printf "ALERT_MAIL_SMTP_HOST='smtp.gmail.com'\nALERT_MAIL_SMTP_PORT='465'\n"
      printf "ALERT_MAIL_SMTP_USER='%s'\nALERT_MAIL_SMTP_PASS='%s'\nALERT_MAIL_TO='%s'\n" "$u" "$p" "$to"
      printf "# what gets mailed - see the header of alert-mail.sh\n"
      printf "ALERT_MAIL_SEVERITY='critical'\nALERT_MAIL_ALSO='^Backup'\nALERT_MAIL_EXCLUDE=''\n"
    } > "$CONF.new" )
  chown "$RUN_USER" "$CONF.new"; chmod 0600 "$CONF.new"; mv -f "$CONF.new" "$CONF"
  unset p
  ok "settings written: $CONF (owner $RUN_USER, 0600) - the password is in it and nowhere else"
  cat > "/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Email the enclave's alerts (lab only - reads Alertmanager on svc-obs-01 over SSH)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$RUN_USER
ExecStart=$SELF run
EOF
  cat > "/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Email the enclave's alerts every minute (lab only)

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  ok "units installed: $UNIT.service + .timer - NOT started"
  say "next:  ./alert-mail.sh test     then:  sudo ./alert-mail.sh enable"
}

cmd_enable() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  [ -f "/etc/systemd/system/$UNIT.timer" ] || die "not set up - run: sudo $SELF setup"
  systemctl enable --now "$UNIT.timer" >/dev/null || die "could not enable $UNIT.timer"
  systemctl start "$UNIT.service" || warn "the first pass failed - see: journalctl -u $UNIT -n 30"
  journalctl -u "$UNIT" -n 3 --no-pager -o cat 2>/dev/null | sed 's/^/     /'
  ok "running every minute"
}

cmd_disable() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
  ok "$UNIT.timer stopped - settings kept in $CONF"
}

cmd_status() {
  load_conf
  say "from     ${ALERT_MAIL_SMTP_USER:-NOT SET} via $ALERT_MAIL_SMTP_HOST:$ALERT_MAIL_SMTP_PORT  (password: $([ -n "$ALERT_MAIL_SMTP_PASS" ] && echo set || echo NOT SET))"
  say "to       ${ALERT_MAIL_TO:-NOT SET}"
  say "mails    severity $ALERT_MAIL_SEVERITY, plus names matching '$ALERT_MAIL_ALSO'$( [ -n "$ALERT_MAIL_EXCLUDE" ] && echo ", minus '$ALERT_MAIL_EXCLUDE'")"
  say "timer    $(systemctl is-active "$UNIT.timer" 2>/dev/null || true)"
  if [ -r "$ALERT_MAIL_STATE" ]; then
    python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print("  tracking", len(s["alerts"]), "alert(s):", ", ".join(sorted({v["name"] for v in s["alerts"].values()})) or "none")' "$ALERT_MAIL_STATE"
  else say "state    none yet - the first pass sends a summary"; fi
}

case "${1:-status}" in
  setup)   cmd_setup ;;
  test)    cmd_test ;;
  enable)  cmd_enable ;;
  run)     cmd_run ;;
  status)  cmd_status ;;
  disable) cmd_disable ;;
  *) printf 'usage: %s {setup|test|enable|run|status|disable}\n' "$0" >&2; exit 2 ;;
esac
