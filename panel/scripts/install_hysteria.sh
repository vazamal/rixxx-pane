#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
#  Hysteria2 Auto-Installer — by RIXXX (multi-arch)
#  Panel Naive + Mieru + Hysteria2 by RIXXX
#
#  Integrates Hy2 as a THIRD protocol into the existing Naive+Mieru panel.
#  KEY DIFFERENCES from the standalone donor installer:
#    • PORT is configurable (HY_PORT, default 443/udp) — coexists with Caddy
#      on 443/tcp. Naive uses TCP/443, Hy2 uses UDP/HY_PORT.
#    • Users live in the panel's SQLite `users` table (shared pool). The panel
#      backend (writeHysteriaConfig) rewrites the `auth.userpass` block from the
#      DB. The bootstrap config below writes an EMPTY userpass map; the panel
#      fills it in on first apply (and on every add/delete/edit).
#    • Certificate is SHARED with Caddy (USE_CADDY_CERT=1) — no second ACME,
#      no second email. Our Caddy already runs `protocols h1 h2` (HTTP/3 OFF)
#      so UDP/443 is already free; we still keep the H3-disable safety net for
#      any legacy Caddyfile that predates that change.
#
#  ENV:
#    HY_DOMAIN       (required) — server domain (matches Caddy site + cert CN)
#    HY_PORT         (optional) — UDP listen port, default 443
#    HY_EMAIL        (optional) — only used in standalone ACME mode
#    HY_PASSWORD     (optional) — bootstrap fallback password (panel overwrites)
#    USE_CADDY_CERT  (0/1)      — 1 = reuse Caddy's cert (recommended), default 1
# ═══════════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

DOMAIN="${HY_DOMAIN:-}"
HY_PORT="${HY_PORT:-443}"
EMAIL="${HY_EMAIL:-admin@example.com}"
PASSWORD="${HY_PASSWORD:-}"
USE_CADDY_CERT="${USE_CADDY_CERT:-1}"

if [[ -z "$DOMAIN" ]]; then
  echo "ERROR: missing env HY_DOMAIN"
  exit 1
fi

# Validate port is numeric and in range.
if ! [[ "$HY_PORT" =~ ^[0-9]+$ ]] || (( HY_PORT < 1 || HY_PORT > 65535 )); then
  echo "ERROR: HY_PORT must be 1–65535 (got: $HY_PORT)"
  exit 1
fi

log()  { echo "$1"; }
step() { echo "STEP:$1"; }

case "$(uname -m)" in
  x86_64)  HY_ARCH="amd64" ;;
  aarch64) HY_ARCH="arm64" ;;
  armv7l)  HY_ARCH="arm"   ;;
  *)       HY_ARCH="amd64" ;;
esac
log "  Arch: $(uname -m) → Hy2:${HY_ARCH}"
log "  Порт Hy2: ${HY_PORT}/udp (Naive остаётся на 443/tcp)"

# ══════════════════════════════════════════════════════
step 1
log "▶ Установка зависимостей..."
# ══════════════════════════════════════════════════════

apt-get update -qq -o DPkg::Lock::Timeout=60 2>/dev/null || true
apt-get install -y -qq curl wget jq libcap2-bin ca-certificates 2>/dev/null || true
log "✅ Зависимости готовы"

# ══════════════════════════════════════════════════════
step 2
log "▶ UDP-оптимизации..."
# ══════════════════════════════════════════════════════

cat > /etc/sysctl.d/99-rixxx-tune.conf << 'SYSCTLEOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=2500000
net.core.wmem_default=2500000
net.ipv4.tcp_fastopen=3
SYSCTLEOF
sysctl --system >/dev/null 2>&1 || true

log "✅ Сетевой тюнинг применён"

# ══════════════════════════════════════════════════════
step 3
log "▶ Настройка файрволла (UFW, если активен)..."
# ══════════════════════════════════════════════════════

# Only touch UFW if it is installed AND already active — the panel install
# manages its own firewall policy. We just make sure UDP/HY_PORT is open.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
  ufw allow "${HY_PORT}/udp" >/dev/null 2>&1 || true
  log "✅ UFW: ${HY_PORT}/udp открыт"
else
  log "  UFW не активен — пропускаем (порт откроется на уровне провайдера/iptables)"
fi

# ══════════════════════════════════════════════════════
step 4
log "▶ Загрузка Hysteria2 (arch: ${HY_ARCH})..."
# ══════════════════════════════════════════════════════

HY_VERSION=$(curl -fsSL --connect-timeout 10 \
  https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null \
  | jq -r '.tag_name' 2>/dev/null || echo "")
[[ -z "$HY_VERSION" || "$HY_VERSION" == "null" ]] && HY_VERSION="app/v2.5.2"

log "  Версия: ${HY_VERSION}"
HY_URL="https://github.com/apernet/hysteria/releases/download/${HY_VERSION}/hysteria-linux-${HY_ARCH}"

wget -q --timeout=120 "${HY_URL}" -O /usr/local/bin/hysteria 2>&1 || {
  log "⚠ Не удалось скачать ${HY_VERSION}, fallback → app/v2.5.2"
  wget -q --timeout=120 \
    "https://github.com/apernet/hysteria/releases/download/app/v2.5.2/hysteria-linux-${HY_ARCH}" \
    -O /usr/local/bin/hysteria || {
    log "ERROR: Не удалось скачать hysteria!"
    exit 1
  }
}

if [[ ! -s /usr/local/bin/hysteria ]]; then
  log "ERROR: бинарник hysteria пустой"
  exit 1
fi

chmod +x /usr/local/bin/hysteria
setcap 'cap_net_bind_service=+ep' /usr/local/bin/hysteria 2>/dev/null || true

HY_VER=$(/usr/local/bin/hysteria version 2>&1 | head -n1 || echo "unknown")
log "✅ Hysteria2 установлена: $HY_VER"

# ══════════════════════════════════════════════════════
step 5
log "▶ Создание базового конфига..."
# ══════════════════════════════════════════════════════

# ── Dedicated service user (Cascade Variant 1) ───────────────────────────────
# Hy2 runs as its OWN system user 'hysteria' (NOT root) so the cascade relay can
# scope its egress with `iptables -m owner --uid-owner hysteria` (exactly like
# Mieru's mita user). Without a distinct uid the cascade could not tell Hy2's
# egress apart from every other root process. The unit keeps
# AmbientCapabilities=CAP_NET_BIND_SERVICE so a non-root user can still bind :443.
HY_USER="hysteria"
if ! id "$HY_USER" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$HY_USER" 2>/dev/null \
    || useradd --system --no-create-home --shell /bin/false "$HY_USER" 2>/dev/null || true
  log "  Создан системный пользователь ${HY_USER}"
fi
# Give hysteria read access to Caddy's cert (Caddy writes key as caddy:caddy 0640)
# by putting it in the caddy group. Harmless if caddy group is absent.
if getent group caddy &>/dev/null; then
  usermod -aG caddy "$HY_USER" 2>/dev/null || true
  log "  ${HY_USER} добавлен в группу caddy (чтение сертификата)"
fi

mkdir -p /etc/hysteria
# Config is owned by the service user (it only reads it); dir traversable.
chown -R "$HY_USER":"$HY_USER" /etc/hysteria 2>/dev/null || true

# Bootstrap config. The panel backend (writeHysteriaConfig) OWNS the
# `auth.userpass` map and rewrites it from the SQLite users table on every
# add/delete/edit. We seed it with an OPTIONAL bootstrap password so the
# service can start immediately even before the first panel apply.
cat > /etc/hysteria/config.yaml << HYCFGEOF
# ═══════════════════════════════════════════════
#  Hysteria2 — by RIXXX  (managed by RIXXX Panel)
#  https://v2.hysteria.network/
#  ⚠ auth.userpass ниже управляется панелью (SQLite users где protocols
#     содержит "hy2"). Ручные правки в этом блоке будут перезаписаны.
# ═══════════════════════════════════════════════

# Caddy занимает TCP/${HY_PORT}; Hy2 работает поверх QUIC (UDP), TCP ему не нужен.
listen: :${HY_PORT}

auth:
  type: userpass
  userpass:
HYCFGEOF

# Seed a bootstrap credential only if provided (so the service is valid on
# first boot). The panel replaces the whole map on first apply.
if [[ -n "$PASSWORD" ]]; then
  echo "    bootstrap: \"${PASSWORD}\"" >> /etc/hysteria/config.yaml
else
  echo "    {}" >> /etc/hysteria/config.yaml
fi

cat >> /etc/hysteria/config.yaml << 'HYMASQEOF'

# Маскировка: отдаёт ту же статичную страницу что Caddy. Нет лишних
# внешних запросов → нет ошибок H3_GENERAL_PROTOCOL_ERROR в логах.
masquerade:
  type: file
  file:
    dir: /var/www/html
HYMASQEOF

# Ensure a masquerade HTML root exists (standalone Hy2 without Caddy).
mkdir -p /var/www/html
if [[ ! -f /var/www/html/index.html ]]; then
  cat > /var/www/html/index.html << 'MASQEOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Loading</title>
<style>body{background:#080808;height:100vh;margin:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif}.bar{width:200px;height:3px;background:#151515;overflow:hidden;border-radius:2px;margin-bottom:25px}.fill{height:100%;width:40%;background:#fff;animation:slide 1.4s infinite ease-in-out}@keyframes slide{0%{transform:translateX(-100%)}50%{transform:translateX(50%)}100%{transform:translateX(200%)}}.t{color:#555;font-size:13px;letter-spacing:3px;font-weight:600}</style>
</head><body><div class="bar"><div class="fill"></div></div><div class="t">LOADING CONTENT</div></body></html>
MASQEOF
fi

if [[ "$USE_CADDY_CERT" == "1" ]]; then
  # ── Освобождаем UDP/443 для Hy2: наш Caddy уже с `protocols h1 h2` (HTTP/3
  # OFF), но на случай легаси-Caddyfile — отключаем H3 и перезагружаем Caddy.
  # Мы правим ИМЕННО naive-Caddyfile панели: /etc/caddy-naive/Caddyfile.
  CADDYFILE=""
  for CF in /etc/caddy-naive/Caddyfile /etc/caddy/Caddyfile; do
    [[ -f "$CF" ]] && { CADDYFILE="$CF"; break; }
  done

  if [[ -n "$CADDYFILE" ]] && ! grep -q "protocols h1 h2" "$CADDYFILE"; then
    log "  Отключаем HTTP/3 в Caddy (${CADDYFILE}) — освобождаем UDP/${HY_PORT}..."
    cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%s)" 2>/dev/null || true
    if command -v python3 >/dev/null 2>&1; then
      CF_PATH="$CADDYFILE" python3 << 'PYEOF' || true
import re, os
p = os.environ['CF_PATH']
with open(p) as f: src = f.read()
m = re.match(r'^\s*\{([^{}]*)\}', src, re.DOTALL)
if m:
    inner = m.group(1)
    if 'protocols h1 h2' not in inner:
        new_inner = inner.rstrip() + '\n  servers {\n    protocols h1 h2\n  }\n'
        src = '{' + new_inner + '}' + src[m.end():]
else:
    src = '{\n  servers {\n    protocols h1 h2\n  }\n}\n\n' + src
with open(p, 'w') as f: f.write(src)
print("Caddyfile updated: HTTP/3 disabled")
PYEOF
    fi
    systemctl reload caddy-naive 2>/dev/null || systemctl restart caddy-naive 2>/dev/null \
      || systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
    sleep 2
    log "✅ HTTP/3 отключён, UDP/${HY_PORT} свободен"
  else
    log "  Caddy уже без HTTP/3 (или Caddyfile не найден) — UDP/${HY_PORT} свободен"
  fi

  # Caddy может получить сертификат от любого CA (LE / ZeroSSL / Google) и
  # хранить его в РАЗНЫХ местах в зависимости от того, как задан data-dir:
  #   • XDG-стиль (User=caddy, HOME=/var/lib/caddy) → .local/share/caddy
  #   • XDG_DATA_HOME=/var/lib/caddy напрямую       → /var/lib/caddy/caddy   ← частый!
  #   • root-запуск                                  → /root/.local/share/caddy
  #   • системный /etc                               → /etc/ssl/caddy и т.п.
  # Раньше мы искали только XDG-путь и промахивались на серверах с data-dir
  # /var/lib/caddy → сертификат «не найден» → в конфиг попадала заглушка без
  # tls: → Hy2 падал с «tls: must set either tls or acme». Теперь ищем по всем
  # известным корням И делаем широкий find по /var/lib/caddy + /root/.local как
  # финальный фолбэк (ловит любой нестандартный data-dir).
  CADDY_CERT_ROOTS=(
    "/var/lib/caddy/caddy/certificates"
    "/var/lib/caddy/.local/share/caddy/certificates"
    "/root/.local/share/caddy/certificates"
    "/home/caddy/.local/share/caddy/certificates"
    "/etc/caddy/certificates"
  )
  CADDY_CERT_DIR=""

  # Хелпер: находит пару .crt/.key для домена в списке корней ИЛИ широким find.
  find_caddy_cert() {
    local found
    for ROOT in "${CADDY_CERT_ROOTS[@]}"; do
      [[ -d "$ROOT" ]] || continue
      found=$(find "$ROOT" -type f -name "${DOMAIN}.crt" 2>/dev/null | head -1)
      if [[ -n "$found" && -f "${found%.crt}.key" ]]; then
        echo "$found"; return 0
      fi
    done
    # Широкий фолбэк — любой нестандартный data-dir под /var/lib/caddy или /root.
    for BASE in /var/lib/caddy /root/.local /home; do
      [[ -d "$BASE" ]] || continue
      found=$(find "$BASE" -type f -name "${DOMAIN}.crt" 2>/dev/null | head -1)
      if [[ -n "$found" && -f "${found%.crt}.key" ]]; then
        echo "$found"; return 0
      fi
    done
    return 1
  }

  log "  Ждём сертификат от Caddy (до 150с, любой CA, любой data-dir)..."
  for i in $(seq 1 75); do
    FOUND="$(find_caddy_cert || true)"
    if [[ -n "$FOUND" ]]; then
      CADDY_CERT_DIR="$(dirname "$FOUND")"
      CA_NAME="$(basename "$(dirname "$CADDY_CERT_DIR")")"
      log "✅ Сертификат найден (${i}х2 с) — CA: ${CA_NAME} — ${CADDY_CERT_DIR}"
      break
    fi
    sleep 2
  done

  if [[ -z "$CADDY_CERT_DIR" ]]; then
    log "⚠ Сертификат Caddy не найден за 150с."
    log "  Hy2 НЕ запускается с собственным ACME (риск Let's Encrypt 429)."
    log "  Ставим self-heal: как только Caddy выпустит сертификат — tls: блок"
    log "  допишется автоматически и Hy2 стартанёт (проверка каждую минуту)."
    cat >> /etc/hysteria/config.yaml << 'HYNOTLSEOF'
# ⚠ Сертификат не был готов при установке.
# Self-heal-таймер (hy2-cert-selfheal.timer) сам допишет tls: блок и
# перезапустит hysteria-server, как только Caddy выпустит сертификат.
# Ручная починка (если таймер отключён):
#   1) find /var/lib/caddy -name '*.crt'
#   2) tls:
#        cert: /var/lib/caddy/.../<domain>.crt
#        key:  /var/lib/caddy/.../<domain>.key
#   3) systemctl restart hysteria-server
HYNOTLSEOF

    # ── Self-heal: скрипт ищет cert по тем же корням и, найдя, впишет tls: ──
    cat > /usr/local/bin/hy2-cert-selfheal.sh << SELFHEALEOF
#!/usr/bin/env bash
# Авто-починка Hy2 TLS: ждёт появления Caddy-сертификата для домена и,
# как только он есть, дописывает tls: блок в /etc/hysteria/config.yaml
# и перезапускает hysteria-server. Ставится установщиком, когда cert
# ещё не готов. Само-деактивируется после успеха.
set -euo pipefail
DOMAIN="${DOMAIN}"
CFG="/etc/hysteria/config.yaml"

# Уже есть tls: (или acme:) — чинить нечего, гасим таймер.
if grep -qE '^(tls|acme):' "\$CFG" 2>/dev/null; then
  systemctl disable --now hy2-cert-selfheal.timer >/dev/null 2>&1 || true
  exit 0
fi

CERT_ROOTS=(
  "/var/lib/caddy/caddy/certificates"
  "/var/lib/caddy/.local/share/caddy/certificates"
  "/root/.local/share/caddy/certificates"
  "/home/caddy/.local/share/caddy/certificates"
  "/etc/caddy/certificates"
)
FOUND=""
for R in "\${CERT_ROOTS[@]}"; do
  [[ -d "\$R" ]] || continue
  FOUND="\$(find "\$R" -type f -name "\${DOMAIN}.crt" 2>/dev/null | head -1)"
  [[ -n "\$FOUND" && -f "\${FOUND%.crt}.key" ]] && break || FOUND=""
done
if [[ -z "\$FOUND" ]]; then
  for B in /var/lib/caddy /root/.local /home; do
    [[ -d "\$B" ]] || continue
    FOUND="\$(find "\$B" -type f -name "\${DOMAIN}.crt" 2>/dev/null | head -1)"
    [[ -n "\$FOUND" && -f "\${FOUND%.crt}.key" ]] && break || FOUND=""
  done
fi
[[ -z "\$FOUND" ]] && exit 0   # ещё нет — попробуем в следующий тик

CDIR="\$(dirname "\$FOUND")"
# Grant the hysteria user (group caddy) read access; fall back to world-read.
if getent group caddy >/dev/null 2>&1; then
  _p="\$CDIR"
  while [[ "\$_p" == /var/lib/caddy* || "\$_p" == /root/.local* || "\$_p" == /home/* ]]; do
    chgrp caddy "\$_p" 2>/dev/null || true; chmod g+rx "\$_p" 2>/dev/null || true
    _p="\$(dirname "\$_p")"
  done
  chgrp caddy "\$FOUND" "\${FOUND%.crt}.key" 2>/dev/null || true
  chmod g+r  "\$FOUND" "\${FOUND%.crt}.key" 2>/dev/null || true
else
  chmod -R o+rX "\$(dirname "\$CDIR")" 2>/dev/null || true
fi

# Убрать placeholder-комментарий и дописать реальный tls: блок.
sed -i '/# ⚠ Сертификат не был готов при установке./,/#   3) systemctl restart hysteria-server/d' "\$CFG"
cat >> "\$CFG" << TLSBLK

tls:
  cert: \${CDIR}/\${DOMAIN}.crt
  key:  \${CDIR}/\${DOMAIN}.key
TLSBLK

systemctl reset-failed hysteria-server >/dev/null 2>&1 || true
systemctl restart hysteria-server >/dev/null 2>&1 || true

# Успех — переключиться на постоянный cert-watcher и погасить self-heal.
cat > /etc/systemd/system/caddy-cert-watcher.path << WEOF
[Unit]
Description=Watch Caddy cert for changes -> restart hysteria-server
[Path]
PathModified=\${CDIR}
[Install]
WantedBy=multi-user.target
WEOF
cat > /etc/systemd/system/caddy-cert-watcher.service << 'WSEOF'
[Unit]
Description=Restart hysteria-server on Caddy cert change
[Service]
Type=oneshot
ExecStart=/bin/systemctl restart hysteria-server.service
WSEOF
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now caddy-cert-watcher.path >/dev/null 2>&1 || true
systemctl disable --now hy2-cert-selfheal.timer >/dev/null 2>&1 || true
SELFHEALEOF
    chmod +x /usr/local/bin/hy2-cert-selfheal.sh

    cat > /etc/systemd/system/hy2-cert-selfheal.service << 'SHSVCEOF'
[Unit]
Description=Hy2 TLS self-heal (wait for Caddy cert, then enable tls: + start Hy2)
After=caddy-naive.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hy2-cert-selfheal.sh
SHSVCEOF

    cat > /etc/systemd/system/hy2-cert-selfheal.timer << 'SHTMREOF'
[Unit]
Description=Periodically try to self-heal Hy2 TLS until Caddy cert appears

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
SHTMREOF

    systemctl daemon-reload
    systemctl enable --now hy2-cert-selfheal.timer >/dev/null 2>&1 || true
    log "✅ hy2-cert-selfheal.timer активен — Hy2 стартанёт сам после выдачи сертификата"
  else
    # Grant the 'hysteria' user (member of group caddy) read access to the cert.
    # Prefer group-based perms over world-readable: make the whole Caddy data
    # dir group-traversable for caddy and the key group-readable. Falls back to
    # world-read only if the caddy group is unavailable.
    if getent group caddy &>/dev/null; then
      # Make every dir from /var/lib/caddy down to the cert dir group-traversable.
      _p="$CADDY_CERT_DIR"
      while [[ "$_p" == /var/lib/caddy* || "$_p" == /root/.local* || "$_p" == /home/* ]]; do
        chgrp caddy "$_p" 2>/dev/null || true
        chmod g+rx "$_p" 2>/dev/null || true
        _p="$(dirname "$_p")"
      done
      chgrp caddy "${CADDY_CERT_DIR}/${DOMAIN}.crt" "${CADDY_CERT_DIR}/${DOMAIN}.key" 2>/dev/null || true
      chmod g+r  "${CADDY_CERT_DIR}/${DOMAIN}.crt" "${CADDY_CERT_DIR}/${DOMAIN}.key" 2>/dev/null || true
    else
      chmod -R o+rX "$(dirname "$CADDY_CERT_DIR")" 2>/dev/null || true
    fi

    cat >> /etc/hysteria/config.yaml << HYTLSEOF

tls:
  cert: ${CADDY_CERT_DIR}/${DOMAIN}.crt
  key:  ${CADDY_CERT_DIR}/${DOMAIN}.key
HYTLSEOF

    # Watcher: при обновлении сертификата Caddy → рестарт Hy2.
    cat > /etc/systemd/system/caddy-cert-watcher.path << WATCHEOF
[Unit]
Description=Watch Caddy cert for changes -> restart hysteria-server

[Path]
PathModified=${CADDY_CERT_DIR}

[Install]
WantedBy=multi-user.target
WATCHEOF

    cat > /etc/systemd/system/caddy-cert-watcher.service << 'WATCHSVCEOF'
[Unit]
Description=Restart hysteria-server on Caddy cert change

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart hysteria-server.service
WATCHSVCEOF

    systemctl daemon-reload
    systemctl enable caddy-cert-watcher.path >/dev/null 2>&1 || true
    systemctl start  caddy-cert-watcher.path >/dev/null 2>&1 || true
    log "✅ caddy-cert-watcher настроен"
  fi

else
  # Standalone Hy2: собственный ACME-сертификат (порт 80 должен быть свободен).
  cat >> /etc/hysteria/config.yaml << HYACMEEOF

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}
  ca: letsencrypt
  listenHost: 0.0.0.0
HYACMEEOF
fi

cat >> /etc/hysteria/config.yaml << 'HYBWEOF'

ignoreClientBandwidth: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false
HYBWEOF

# Traffic Stats API (loopback only) → lets the panel read per-user up/down bytes
# via GET http://127.0.0.1:9999/traffic (like `mita get users` does for Mieru).
# Secret is generated per-install; the panel reads it back from this file.
HY_STATS_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
cat >> /etc/hysteria/config.yaml << HYSTATSEOF

# ── Traffic Stats API (управляется панелью — не редактируйте вручную) ──
trafficStats:
  listen: 127.0.0.1:9999
  secret: "${HY_STATS_SECRET}"
HYSTATSEOF

# The config was written by root via `cat >`, so it ends up root-owned. Hand it
# (and the dir) back to the service user with explicit modes — otherwise the
# non-root hysteria service hits "open config.yaml: permission denied" on start.
chown -R "$HY_USER":"$HY_USER" /etc/hysteria 2>/dev/null || true
chmod 750 /etc/hysteria 2>/dev/null || true
chmod 640 /etc/hysteria/config.yaml 2>/dev/null || true

log "✅ Конфиг /etc/hysteria/config.yaml создан (порт ${HY_PORT}/udp)"

# ══════════════════════════════════════════════════════
step 6
log "▶ Systemd сервис Hysteria..."
# ══════════════════════════════════════════════════════

if [[ "$USE_CADDY_CERT" == "1" ]]; then
  HY_AFTER="After=network.target network-online.target caddy-naive.service"
  HY_WANTS="Wants=caddy-naive.service"
else
  HY_AFTER="After=network.target network-online.target"
  HY_WANTS=""
fi

cat > /etc/systemd/system/hysteria-server.service << HYSVCEOF
[Unit]
Description=Hysteria2 Server (by RIXXX)
Documentation=https://v2.hysteria.network/
${HY_AFTER}
${HY_WANTS}
Requires=network-online.target
StartLimitIntervalSec=60s
StartLimitBurst=3

[Service]
Type=simple
User=hysteria
Group=hysteria
# SupplementaryGroups=caddy → read the shared Caddy cert (key is caddy:caddy 0640).
SupplementaryGroups=caddy
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
HYSVCEOF

systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1 || true

log "✅ Systemd сервис создан"

# ══════════════════════════════════════════════════════
step 7
log "▶ Запуск Hysteria2..."
# ══════════════════════════════════════════════════════

systemctl restart hysteria-server 2>&1 || true

for i in $(seq 1 20); do
  STATUS=$(systemctl is-active hysteria-server 2>/dev/null || echo "unknown")
  if [[ "$STATUS" == "active" ]]; then
    log "✅ Hysteria2 запущена (${i}с)"
    break
  elif [[ "$STATUS" == "failed" ]]; then
    log "⚠ hysteria-server: failed — смотрите ниже:"
    journalctl -u hysteria-server -n 20 --no-pager 2>/dev/null || true
    systemctl reset-failed hysteria-server 2>/dev/null || true
    systemctl start hysteria-server 2>/dev/null || true
    break
  fi
  sleep 1
  if [[ $i -eq 20 ]]; then
    log "⚠ Hy2 не запустилась за 20с. Диагностика:"
    log "  journalctl -u hysteria-server -n 50 --no-pager"
  fi
done

step DONE
log ""
log "╔════════════════════════════════════════════════════╗"
log "║   ✅ Hysteria2 успешно установлен!                 ║"
log "║   Домен: ${DOMAIN}"
log "║   Порт : ${HY_PORT}/udp"
log "║   hysteria2://****@${DOMAIN}:${HY_PORT}?sni=${DOMAIN}"
log "╚════════════════════════════════════════════════════╝"
log ""

exit 0
