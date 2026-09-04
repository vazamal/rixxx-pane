#!/usr/bin/env bash
# ==============================================================================
# cascade_mieru.sh — Mieru cascade (Variant B) orchestrator  v1.5.8
#
# Implements the proven "redsocks + iptables + mieru-client" relay chain so the
# panel can enable/disable a mieru+mieru cascade entirely from the web UI.
#
#   Client → Entry node (this host: mita) → mieru-client (SOCKS5 :1080)
#          → redsocks (:12345) → iptables REDSOCKS → Exit node (mita) → internet
#
# This script is invoked by the panel backend (panel/server/index.js):
#   bash cascade_mieru.sh setup    --exit-host H --exit-port-start P --exit-port-end P \
#                                  --exit-user U --exit-pass PW
#   bash cascade_mieru.sh teardown
#   bash cascade_mieru.sh status
#
# Design notes (mirrors the field-tested manual guide; avoids its pitfalls):
#   • mieru-client config uses "profiles" (plural). "profile" → unknown field.
#   • Bug 95: "mtu" and "multiplexing" live INSIDE each profile (not top-level).
#     mtu "must be the same as proxy server" (default 1400, valid 1280-1400).
#     The key is derived from username+password+system time, so those must match
#     the exit user EXACTLY and both clocks must be NTP-synced (else the server
#     can't decrypt → NewSession/NewSessionDecrypted stay 0 and traffic is dropped).
#   • mieru.service uses Type=forking + "mieru start" ("mieru run" does NOT exist).
#   • redsocks is restarted together with mieru via ExecStartPost (else traffic
#     stops flowing through the cascade after a mieru restart).
#   • A RETURN rule for the EXIT node IP prevents an iptables routing loop.
#   • BUG-172: watchdog probes the FULL chain AS the mita user (iptables →
#     redsocks → mieru), so a redsocks event-loop deadlock (process alive, port
#     open, but no events serviced) is detected; it then restarts the actual
#     culprit (redsocks if only the chain is wedged, else mieru+redsocks). A
#     nightly redsocks recycle (04:00) pre-empts long-uptime event-loop wedges.
#   • Lazy install (A2): mieru-client + redsocks are installed on first setup.
#
# Idempotent: re-running setup re-applies cleanly. teardown leaves a clean host.
# ==============================================================================
set -euo pipefail

# ── Paths / constants ─────────────────────────────────────────────────────────
MIERU_CLIENT_BIN="/usr/bin/mieru"
MIERU_CLIENT_CONFIG="/var/lib/rixxx-panel/mieru-client-config.json"
MIERU_SERVICE="/etc/systemd/system/mieru.service"
REDSOCKS_CONF="/etc/redsocks.conf"
WATCHDOG_BIN="/usr/local/bin/mieru-watchdog.sh"
CRON_FILE="/etc/cron.d/mieru-cascade-watchdog"
STATE_FILE="/var/lib/rixxx-panel/cascade-mieru.state"

SOCKS5_PORT=1080          # mieru-client local SOCKS5 listener (127.0.0.1 only)
REDSOCKS_PORT=12345       # redsocks transparent redirector (127.0.0.1 only)
RPC_PORT=8964             # mieru-client RPC port

MIERU_RELEASES="https://api.github.com/repos/enfein/mieru/releases/latest"

log()  { echo "[cascade] $*"; }
err()  { echo "[cascade][ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
ACTION="${1:-}"; shift || true

EXIT_HOST=""
EXIT_PORT_START="2012"
EXIT_PORT_END="2022"
EXIT_USER=""
EXIT_PASS=""
EXIT_MTU="1400"          # Bug 95: must match the exit (mita) mtu; default 1400.
EXIT_MUX="MULTIPLEXING_LOW"   # Bug 95: mieru client default; explicit for clarity.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exit-host)        EXIT_HOST="${2:-}";        shift 2 ;;
    --exit-port-start)  EXIT_PORT_START="${2:-}";  shift 2 ;;
    --exit-port-end)    EXIT_PORT_END="${2:-}";    shift 2 ;;
    --exit-user)        EXIT_USER="${2:-}";        shift 2 ;;
    --exit-pass)        EXIT_PASS="${2:-}";        shift 2 ;;
    --exit-mtu)         EXIT_MTU="${2:-1400}";     shift 2 ;;
    --exit-mux)         EXIT_MUX="${2:-MULTIPLEXING_LOW}"; shift 2 ;;
    *) shift ;;
  esac
done

[[ $EUID -ne 0 ]] && die "must run as root"

# ── mita uid (owner-match for iptables) ───────────────────────────────────────
mita_uid() {
  id -u mita 2>/dev/null || echo ""
}

# ── hysteria uid (owner-match so Hy2 egress ALSO goes through the cascade) ────
# Hy2 runs as its own 'hysteria' user (see install_hysteria.sh). When Hy2 is
# installed we add the SAME REDSOCKS owner-match for its uid, so enabling the
# cascade relays all three protocols (Naive via upstream URL, Mieru + Hy2 via
# redsocks owner-match). Returns "" if Hy2 isn't installed → rule is skipped,
# so a Mieru-only box is completely unaffected.
hy2_uid() {
  # Only claim a uid if Hy2 is actually installed (guard: no stray owner rule).
  if [[ -x /usr/local/bin/hysteria && -f /etc/hysteria/config.yaml ]]; then
    id -u hysteria 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# ── Resolve exit host → IPv4 (needed for the anti-loop RETURN rule) ────────────
resolve_exit_ip() {
  local host="$1"
  # Already an IPv4 literal?
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$host"; return 0
  fi
  local ip
  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
  [[ -z "$ip" ]] && ip=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
  echo "$ip"
}

# ── Lazy install: mieru-client + redsocks (A2) ────────────────────────────────
ensure_packages() {
  # redsocks via apt
  if ! command -v redsocks &>/dev/null; then
    log "installing redsocks…"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq redsocks 2>/dev/null || apt-get install -y redsocks || \
      die "failed to install redsocks"
  fi

  # iptables + persistence helper
  command -v iptables &>/dev/null || apt-get install -y -qq iptables 2>/dev/null || true
  command -v dig &>/dev/null || apt-get install -y -qq dnsutils 2>/dev/null || true

  # mieru client (.deb) — the panel/install ships mita; the client binary may
  # not be present. Install it from the same GitHub release as mita.
  if [[ ! -x "$MIERU_CLIENT_BIN" ]] || ! "$MIERU_CLIENT_BIN" version &>/dev/null; then
    log "installing mieru client…"
    local arch deb_arch
    case "$(uname -m)" in
      x86_64|amd64)  deb_arch="amd64" ;;
      aarch64|arm64) deb_arch="arm64" ;;
      armv7l)        deb_arch="armhf" ;;
      *) die "unsupported arch: $(uname -m)" ;;
    esac
    local rel url deb
    rel=$(curl -fsSL "$MIERU_RELEASES" 2>/dev/null) || die "cannot reach GitHub API for mieru"
    url=$(echo "$rel" | jq -r --arg a "$deb_arch" \
      '.assets[] | select(.name | test("mieru_.*" + $a + "\\.deb")) | .browser_download_url' | head -1)
    [[ -z "$url" || "$url" == "null" ]] && \
      url=$(echo "$rel" | jq -r --arg a "$deb_arch" \
        '.assets[] | select(.name | test("^mieru.*" + $a + "\\.deb")) | .browser_download_url' | head -1)
    [[ -z "$url" || "$url" == "null" ]] && die "no mieru client .deb for $deb_arch"
    deb=$(mktemp /tmp/mieru-client-XXXXXX.deb)
    log "downloading $url"
    wget -q -O "$deb" "$url" || die "failed to download mieru client"
    dpkg -i "$deb" 2>/dev/null || apt-get install -f -y
    rm -f "$deb"
  fi
  log "packages ready ✓"
}

# ── Write mieru-client config ─────────────────────────────────────────────────
# Schema reference: https://github.com/enfein/mieru/blob/main/docs/client-install.md
#
# Bug 95 (handshake parity): the mieru key is derived from username + password +
# system time, so those MUST byte-match the exit (mita) user; and `mtu`
# "must be the same as proxy server" (default 1400). Earlier this generator
# claimed `mtu` was an "unsupported / unknown field" and omitted it — that was
# WRONG: `mtu` belongs inside each profile (the *profiles* array), not at the top
# level. We now emit `mtu` and `multiplexing` per profile so the client matches
# the exit. (Traffic pattern need NOT match per the official docs, so we don't
# inject one — that keeps the implicit pattern free on each side.)
write_mieru_client_config() {
  mkdir -p "$(dirname "$MIERU_CLIENT_CONFIG")"

  # Build server portBindings array for the full exit port range.
  local port_bindings
  port_bindings=$(python3 - "$EXIT_PORT_START" "$EXIT_PORT_END" <<'PYEOF'
import json, sys
s = int(sys.argv[1]); e = int(sys.argv[2])
print(json.dumps([{"port": p, "protocol": "TCP"} for p in range(s, e + 1)]))
PYEOF
)

  python3 - "$EXIT_HOST" "$EXIT_USER" "$EXIT_PASS" "$port_bindings" "$RPC_PORT" "$SOCKS5_PORT" "$EXIT_MTU" "$EXIT_MUX" \
    > "$MIERU_CLIENT_CONFIG" <<'PYEOF'
import json, sys
host, user, pw, pb_json, rpc, socks5, mtu, mux = sys.argv[1:9]
try:
    mtu_i = int(mtu)
except (TypeError, ValueError):
    mtu_i = 1400
# mieru accepts mtu between 1280 and 1400.
if mtu_i < 1280 or mtu_i > 1400:
    mtu_i = 1400
mux = (mux or "MULTIPLEXING_LOW").strip()
if mux not in ("MULTIPLEXING_OFF", "MULTIPLEXING_LOW",
               "MULTIPLEXING_MIDDLE", "MULTIPLEXING_HIGH"):
    mux = "MULTIPLEXING_LOW"
cfg = {
    "profiles": [
        {
            "profileName": "cascade",
            "user": {"name": user, "password": pw},
            "servers": [
                {
                    "ipAddress": host,
                    "domainName": "",
                    "portBindings": json.loads(pb_json),
                }
            ],
            # Bug 95: mtu + multiplexing live INSIDE the profile (per official schema).
            "mtu": mtu_i,
            "multiplexing": {"level": mux},
            "handshakeMode": "HANDSHAKE_STANDARD",
        }
    ],
    "activeProfile": "cascade",
    "rpcPort": int(rpc),
    "socks5Port": int(socks5),
    "socks5ListenLAN": False,
    "loggingLevel": "INFO",
}
print(json.dumps(cfg, indent=2))
PYEOF
  chmod 600 "$MIERU_CLIENT_CONFIG"
  log "mieru-client config written → $MIERU_CLIENT_CONFIG (mtu=$EXIT_MTU, mux=$EXIT_MUX) ✓"
}

# ── Write mieru.service (Type=forking + mieru start; restart redsocks after) ──
write_mieru_service() {
  cat > "$MIERU_SERVICE" <<SVCEOF
[Unit]
Description=Mieru Client (cascade relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=root
ExecStart=${MIERU_CLIENT_BIN} start
ExecStop=${MIERU_CLIENT_BIN} stop
# Reload the client config on (re)start so panel changes take effect.
ExecStartPre=${MIERU_CLIENT_BIN} apply config ${MIERU_CLIENT_CONFIG}
# Keep redsocks bound to mieru lifecycle — else traffic stops after a restart.
# Bug 94: '-' makes a non-zero exit non-fatal; '--no-block' returns immediately so
# this ExecStartPost can never time out / deadlock against redsocks' ordering.
ExecStartPost=-/bin/systemctl --no-block restart redsocks
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVCEOF
  log "mieru.service written ✓"
}

# ── Write redsocks.conf ───────────────────────────────────────────────────────
write_redsocks_conf() {
  cat > "$REDSOCKS_CONF" <<RSEOF
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = ${REDSOCKS_PORT};
    ip = 127.0.0.1;
    port = ${SOCKS5_PORT};
    type = socks5;
}
RSEOF
  log "redsocks.conf written ✓"
}

# ── iptables REDSOCKS chain (idempotent) ──────────────────────────────────────
apply_iptables() {
  local exit_ip="$1" uid="$2"

  # Remove any previous chain first (idempotent re-apply).
  clear_iptables

  iptables -t nat -N REDSOCKS 2>/dev/null || true

  # Never touch local / loopback traffic.
  iptables -t nat -A REDSOCKS -d 0.0.0.0/8       -j RETURN
  iptables -t nat -A REDSOCKS -d 10.0.0.0/8      -j RETURN
  iptables -t nat -A REDSOCKS -d 127.0.0.0/8     -j RETURN
  iptables -t nat -A REDSOCKS -d 169.254.0.0/16  -j RETURN
  iptables -t nat -A REDSOCKS -d 172.16.0.0/12   -j RETURN
  iptables -t nat -A REDSOCKS -d 192.168.0.0/16  -j RETURN
  iptables -t nat -A REDSOCKS -d 224.0.0.0/4     -j RETURN
  iptables -t nat -A REDSOCKS -d 240.0.0.0/4     -j RETURN

  # CRITICAL anti-loop: traffic to the exit node must bypass redsocks.
  [[ -n "$exit_ip" ]] && iptables -t nat -A REDSOCKS -d "${exit_ip}/32" -j RETURN

  # Everything else (TCP) → redsocks.
  iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports "${REDSOCKS_PORT}"

  # Apply ONLY to traffic owned by the mita user (the proxied client traffic).
  if [[ -n "$uid" ]]; then
    iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "$uid" -j REDSOCKS
  else
    err "mita uid not found — cannot scope iptables to mita user"
    return 1
  fi

  # ALSO relay Hy2 egress through the same cascade when Hy2 is installed.
  # hy2_uid() returns "" on a Mieru-only box → this whole block is a no-op there.
  # Hy2's QUIC replies to clients are UDP; REDSOCKS only REDIRECTs `-p tcp`, so
  # the client return-path is never captured — only Hy2's outbound TCP to the
  # internet is relayed. The shared exit_ip RETURN rule (above) is the anti-loop
  # for this uid too, since it lives in the REDSOCKS chain both jumps target.
  local hyuid; hyuid=$(hy2_uid)
  if [[ -n "$hyuid" ]]; then
    iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "$hyuid" -j REDSOCKS
    log "cascade: Hy2 egress relayed too (hysteria uid=$hyuid) ✓"
  fi

  # Persist if iptables-persistent is available; else install it.
  if ! command -v netfilter-persistent &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent 2>/dev/null || true
  fi
  command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null || true
  log "iptables REDSOCKS chain applied (exit_ip=${exit_ip:-none}, uid=$uid) ✓"
}

clear_iptables() {
  local uid; uid=$(mita_uid)
  # Remove OUTPUT jump(s) to REDSOCKS for the mita uid (loop until none remain).
  if [[ -n "$uid" ]]; then
    while iptables -t nat -C OUTPUT -p tcp -m owner --uid-owner "$uid" -j REDSOCKS 2>/dev/null; do
      iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "$uid" -j REDSOCKS 2>/dev/null || break
    done
  fi
  # Same for the hysteria uid (Hy2 egress rule). id -u directly (not hy2_uid) so
  # the rule is removed even if Hy2 was since uninstalled but the rule lingers.
  local hyuid; hyuid=$(id -u hysteria 2>/dev/null || echo "")
  if [[ -n "$hyuid" ]]; then
    while iptables -t nat -C OUTPUT -p tcp -m owner --uid-owner "$hyuid" -j REDSOCKS 2>/dev/null; do
      iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "$hyuid" -j REDSOCKS 2>/dev/null || break
    done
  fi
  # Bug 150: also strip ANY remaining OUTPUT rule that jumps to REDSOCKS, even if
  # mita's uid changed or the user was removed — parse the rule numbers and delete
  # from the bottom up so a stale jump can never survive a teardown.
  local nums
  nums=$(iptables -t nat -L OUTPUT -n --line-numbers 2>/dev/null | awk '$2=="REDSOCKS"{print $1}' | sort -rn)
  for n in $nums; do
    iptables -t nat -D OUTPUT "$n" 2>/dev/null || true
  done
  # Flush + delete the chain.
  iptables -t nat -F REDSOCKS 2>/dev/null || true
  iptables -t nat -X REDSOCKS 2>/dev/null || true
  command -v netfilter-persistent &>/dev/null && netfilter-persistent save 2>/dev/null || true
}

# ── Watchdog (cron, 3 consecutive failures → self-heal) ───────────────────────
# BUG-172 (CRITICAL, field-reported on v1.2.6): after 2-5 days of uptime clients
#   suddenly time out while `mita`/`redsocks` still show `active (running)` and
#   the panel stays up. Root cause: redsocks' libevent event-loop can dead-lock
#   under long uptime / connection micro-storms — the process is alive and the
#   :12345 port is still bound, but it stops processing socket events (an strace
#   of the hung redsocks shows ZERO syscalls while a real client request sits
#   there). The cascade data-plane is dead even though every unit is "healthy".
#
#   Why the OLD watchdog missed it: it probed `curl --socks5 127.0.0.1:1080`,
#   which talks to mieru-client DIRECTLY and completely bypasses iptables AND
#   redsocks. mieru-client is fine, so the probe succeeded, the watchdog decided
#   "internet is up", and never restarted anything — while real client traffic
#   (which DOES traverse iptables → redsocks → mieru) black-holed.
#
#   The fix: probe the WHOLE chain exactly as a real client does — generate the
#   request AS the `mita` user so it is caught by the
#   `OUTPUT -m owner --uid-owner <mita> -j REDSOCKS` rule and forced through
#   iptables → redsocks → mieru. Then heal the ACTUAL culprit:
#     • chain fails but raw SOCKS5 (mieru) still works → redsocks is the wedged
#       component → restart redsocks (the common case: the libevent deadlock).
#     • chain AND raw SOCKS5 both fail → mieru itself is down → restart mieru,
#       then redsocks (redsocks must reconnect to a freshly-restarted mieru).
write_watchdog() {
  cat > "$WATCHDOG_BIN" <<'WDEOF'
#!/usr/bin/env bash
# mieru cascade watchdog (BUG-172) — probe the FULL chain as the mita user, so a
# redsocks event-loop deadlock (process alive, port open, but not servicing
# events) is actually detected. Self-heal the real culprit; act only after 3
# consecutive failures to avoid flapping on a transient network blip.
LOG=/var/log/cascade-watchdog.log
PROBE_URL="https://api.ipify.org"

# One end-to-end probe through iptables → redsocks → mieru, run AS mita.
chain_ok() {
  sudo -u mita curl -s --connect-timeout 5 --max-time 10 "$PROBE_URL" >/dev/null 2>&1
}
# Raw mieru-client SOCKS5 probe (bypasses iptables+redsocks) — used ONLY to tell
# a redsocks deadlock apart from a dead mieru tunnel.
socks_ok() {
  curl -s --socks5 127.0.0.1:1080 --connect-timeout 5 --max-time 10 "$PROBE_URL" >/dev/null 2>&1
}

FAILS=0
for i in 1 2 3; do
  chain_ok && exit 0
  FAILS=$((FAILS+1))
  sleep 5
done

# 3 consecutive end-to-end failures → the cascade data-plane is down. Heal it.
if socks_ok; then
  # mieru tunnel is alive but the full chain is broken → redsocks is wedged
  # (the classic libevent deadlock). Restarting redsocks alone clears it.
  systemctl restart redsocks
  echo "[$(date '+%F %T')] cascade watchdog: chain DOWN but SOCKS5 up → redsocks deadlock, restarted redsocks" >> "$LOG"
else
  # mieru tunnel itself is down → restart mieru, then redsocks so it re-dials
  # the freshly-restarted SOCKS5 listener.
  systemctl restart mieru
  sleep 2
  systemctl restart redsocks
  echo "[$(date '+%F %T')] cascade watchdog: chain+SOCKS5 DOWN → restarted mieru + redsocks" >> "$LOG"
fi
WDEOF
  chmod +x "$WATCHDOG_BIN"
  cat > "$CRON_FILE" <<CRONEOF
# Mieru cascade watchdog — probe the full chain every 5 minutes (BUG-172).
*/5 * * * * root $WATCHDOG_BIN >/dev/null 2>&1
# Preventive daily redsocks recycle at 04:00 — redsocks is historically prone to
# slow FD/memory leaks and event-loop wedges over 24/7 uptime; a nightly restart
# keeps the event-loop fresh (mieru session survives; brief <1s cascade blip).
0 4 * * * root systemctl restart redsocks >/dev/null 2>&1
CRONEOF
  log "watchdog + cron installed ✓ (full-chain probe + nightly redsocks recycle)"
}

remove_watchdog() {
  rm -f "$WATCHDOG_BIN" "$CRON_FILE"
}

# ── redsocks ↔ mieru systemd binding (drop-in) ────────────────────────────────
# Bug 94 (deadlock): the old drop-in had  Requires=mieru.service  while
# mieru.service has  ExecStartPost=systemctl restart redsocks. That is a circular
# start dependency: starting mieru triggers a redsocks (re)start, but redsocks
# Requires mieru to be fully up first → start-post timeout → both units flap in a
# restart loop and the relay never stabilises (client handshake never completes).
# Fix: keep only the soft ordering (After= + Wants=, NOT Requires=) so redsocks
# prefers to start after mieru but does not hard-block on it. The mieru
# ExecStartPost is also made non-blocking (see write_mieru_service).
write_redsocks_dropin() {
  mkdir -p /etc/systemd/system/redsocks.service.d
  cat > /etc/systemd/system/redsocks.service.d/cascade.conf <<DROPEOF
[Unit]
# Soft dependency only — order without a hard Requires (Bug 94: no restart loop).
After=mieru.service
Wants=mieru.service

[Service]
Restart=on-failure
RestartSec=5s
DROPEOF
}

remove_redsocks_dropin() {
  rm -f /etc/systemd/system/redsocks.service.d/cascade.conf
  rmdir /etc/systemd/system/redsocks.service.d 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# Actions
# ══════════════════════════════════════════════════════════════════════════════
do_setup() {
  [[ -z "$EXIT_HOST" ]] && die "--exit-host is required"
  [[ -z "$EXIT_USER" ]] && die "--exit-user is required"
  [[ -z "$EXIT_PASS" ]] && die "--exit-pass is required"

  local uid; uid=$(mita_uid)
  [[ -z "$uid" ]] && die "mita user not found — is Mieru (mita) installed?"

  local exit_ip; exit_ip=$(resolve_exit_ip "$EXIT_HOST")
  [[ -z "$exit_ip" ]] && die "could not resolve exit host '$EXIT_HOST' to an IPv4 address"
  log "exit host $EXIT_HOST → $exit_ip"

  # Bug 95: the mieru key is derived from username+password+system time, so the
  # entry and exit clocks must agree. Ensure NTP is on (best-effort, non-fatal).
  timedatectl set-ntp true 2>/dev/null || true
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
    log "⚠ NTP not yet synced on this (entry) node — make sure the EXIT node is also NTP-synced, else the handshake will fail (NewSessionDecrypted stays 0)."
  fi

  ensure_packages
  write_mieru_client_config
  write_mieru_service
  write_redsocks_conf
  write_redsocks_dropin
  write_watchdog

  systemctl daemon-reload
  systemctl enable redsocks 2>/dev/null || true
  systemctl enable mieru    2>/dev/null || true

  # Apply client config + start the relay. Bug 95: do NOT swallow apply errors —
  # an invalid field (or unknown field) is exactly what we need to see here.
  local apply_out
  if ! apply_out=$("$MIERU_CLIENT_BIN" apply config "$MIERU_CLIENT_CONFIG" 2>&1); then
    err "mieru apply config rejected the client config:"
    echo "$apply_out" | sed 's/\(password[^ ]*\)/***/Ig' >&2
    die "fix the client config and retry (see error above)"
  fi
  systemctl restart mieru   || die "mieru client failed to start (journalctl -u mieru)"
  sleep 2
  systemctl restart redsocks || die "redsocks failed to start (journalctl -u redsocks)"

  apply_iptables "$exit_ip" "$uid"

  # Persist cascade state for status/teardown.
  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$STATE_FILE" <<STEOF
exit_host=$EXIT_HOST
exit_ip=$exit_ip
exit_port_start=$EXIT_PORT_START
exit_port_end=$EXIT_PORT_END
enabled=1
STEOF
  chmod 600 "$STATE_FILE"

  log "cascade ENABLED ✓"
  do_status || true
}

# Bug 150: FULL, idempotent teardown — returns the host to its pre-cascade
# state in EVERY layer (iptables / redsocks / mieru-client / watchdog / state),
# leaving NO active artifact behind, and verifies egress is the native IP.
# Safe to run repeatedly (every step tolerates "already gone").
do_teardown() {
  log "tearing down cascade (full)…"

  # 1) NETWORK: drop the iptables REDSOCKS chain + the OUTPUT jump first, so no
  #    traffic is redirected the moment we stop the relay.
  clear_iptables

  # 2) WATCHDOG: cron + helper binary (else it would restart mieru after stop).
  remove_watchdog
  # Bug 150: also clear any watchdog failure-counter scratch file.
  rm -f /tmp/mieru-watchdog.fails 2>/dev/null || true

  # 3) MIERU-CLIENT service: stop, disable, reset-failed (so a stuck failed
  #    unit can't auto-restart), then remove the unit file.
  systemctl stop mieru        2>/dev/null || true
  systemctl disable mieru     2>/dev/null || true
  systemctl reset-failed mieru 2>/dev/null || true
  rm -f "$MIERU_SERVICE"

  # 4) REDSOCKS: remove the drop-in, stop, disable, reset-failed, AND delete the
  #    config file on disk (Bug 150a: redsocks.conf used to linger after
  #    disable — clean it so nothing references the dead relay).
  remove_redsocks_dropin
  systemctl stop redsocks         2>/dev/null || true
  systemctl disable redsocks      2>/dev/null || true
  systemctl reset-failed redsocks 2>/dev/null || true
  rm -f "$REDSOCKS_CONF"

  systemctl daemon-reload

  # 5) CREDENTIALS / CLIENT CONFIG: shred (contains the exit password).
  [[ -f "$MIERU_CLIENT_CONFIG" ]] && { shred -u "$MIERU_CLIENT_CONFIG" 2>/dev/null || rm -f "$MIERU_CLIENT_CONFIG"; }

  # 6) STATE: mark disabled (keep the file so status reads cleanly).
  [[ -f "$STATE_FILE" ]] && { echo "enabled=0" > "$STATE_FILE"; chmod 600 "$STATE_FILE"; } || true

  systemctl daemon-reload

  # 7) VERIFY: egress should now be the server's OWN public IP (relay gone).
  #    Best-effort — never fail teardown on a transient curl error.
  local direct_ip socks_dead="yes"
  systemctl is-active --quiet redsocks 2>/dev/null && socks_dead="no"
  direct_ip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
  log "teardown complete: redsocks_inactive=${socks_dead} native_egress=${direct_ip:-'(unknown)'}"
  log "cascade DISABLED ✓"
}

do_status() {
  echo "── Mieru cascade status ─────────────────────────────"
  local enabled="0"
  [[ -f "$STATE_FILE" ]] && enabled=$(grep -E '^enabled=' "$STATE_FILE" | cut -d= -f2)
  echo "  configured:        ${enabled:-0}"
  if [[ -f "$STATE_FILE" ]]; then
    grep -E '^exit_(host|ip|port)' "$STATE_FILE" | sed 's/^/  /' || true
  fi
  echo "  mieru.service:     $(systemctl is-active mieru 2>/dev/null || echo inactive)"
  echo "  redsocks.service:  $(systemctl is-active redsocks 2>/dev/null || echo inactive)"
  local socks_ok="no"
  ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${SOCKS5_PORT}" && socks_ok="yes"
  echo "  socks5 :${SOCKS5_PORT} listen:  $socks_ok"
  local jump="no"
  iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q REDSOCKS && jump="yes"
  echo "  iptables REDSOCKS: $jump"
  # Live egress IP check (best-effort).
  # Bug 152: the previous line concatenated the value with ITSELF — the
  # `${egress_ip:+ $egress_ip}${egress_ip:-...}` pattern prints " $egress_ip"
  # (non-empty branch) AND, because $egress_ip is non-empty, the second
  # expansion `${egress_ip:-fallback}` resolves to $egress_ip AGAIN → e.g.
  # "1.2.3.41.2.3.4". Build the string ONCE, trimmed, with a single fallback.
  local egress_ip
  egress_ip=$(curl -s --socks5 127.0.0.1:${SOCKS5_PORT} --max-time 8 https://api.ipify.org 2>/dev/null || echo "")
  egress_ip=$(printf '%s' "$egress_ip" | tr -d '[:space:]')
  if [[ -n "$egress_ip" ]]; then
    echo "  egress IP (socks5): $egress_ip"
  else
    echo "  egress IP (socks5): (unreachable)"
  fi

  # ── Bug 95: handshake-level diagnostics ─────────────────────────────────────
  # The mieru key = f(username, password, system clock). If the client can reach
  # the exit (TCP open) but the egress IP is empty, the handshake failed — almost
  # always a username/password mismatch or a client↔exit clock skew. Surface the
  # signals that actually explain it.
  echo "  ── handshake checks ──"
  # 1) mieru client connection test (talks the real protocol to the exit).
  if [[ -x "$MIERU_CLIENT_BIN" ]]; then
    local test_out
    test_out=$("$MIERU_CLIENT_BIN" test https://api.ipify.org 2>&1 | tail -3 || true)
    echo "  mieru test:        ${test_out:-'(no output)'}" | sed 's/\(password[^ ]*\)/***/Ig'
  fi
  # 2) profile sanity from the generated client config (no secrets printed).
  if [[ -f "$MIERU_CLIENT_CONFIG" ]] && command -v python3 &>/dev/null; then
    python3 - "$MIERU_CLIENT_CONFIG" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    p = (c.get("profiles") or [{}])[0]
    u = (p.get("user") or {}).get("name", "")
    srv = (p.get("servers") or [{}])[0]
    nports = len(srv.get("portBindings") or [])
    print("  client profile:    user=%s host=%s ports=%d mtu=%s mux=%s"
          % (u or "(empty!)", srv.get("ipAddress", "(empty!)"), nports,
             p.get("mtu", "(default)"),
             (p.get("multiplexing") or {}).get("level", "(default)")))
except Exception as e:
    print("  client profile:    (parse error: %s)" % e)
PYEOF
  fi
  # 3) clock sync — a >~1s skew between entry and exit breaks key derivation.
  local nowutc synced
  nowutc=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")
  echo "  entry clock (UTC): $nowutc  (NTP synced: $synced)"
  if [[ "$synced" != "yes" ]]; then
    echo "  ⚠ NTP not synced — key derivation depends on the system clock;"
    echo "    enable it:  timedatectl set-ntp true   (entry AND exit must match)"
  fi
  echo "─────────────────────────────────────────────────────"
  # Exit non-zero if requested-enabled but relay is down (useful for callers).
  if [[ "${enabled:-0}" == "1" ]]; then
    systemctl is-active --quiet mieru && systemctl is-active --quiet redsocks || return 1
  fi
  return 0
}

case "$ACTION" in
  setup)    do_setup ;;
  teardown) do_teardown ;;
  status)   do_status ;;
  *) die "usage: cascade_mieru.sh {setup|teardown|status} [--exit-host H --exit-port-start P --exit-port-end P --exit-user U --exit-pass PW]" ;;
esac
