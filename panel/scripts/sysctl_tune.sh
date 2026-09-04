#!/usr/bin/env bash
# Apply system-level network tuning (BBR, UDP buffers, TCP Fast Open, conntrack)
# Usage: bash sysctl_tune.sh [--dry-run]
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SYSCTL_FILE="/etc/sysctl.d/99-rixxx-panel.conf"

apply_setting() {
  local key="$1" val="$2"
  if $DRY_RUN; then
    echo "[dry-run] sysctl $key=$val"
  else
    sysctl -w "$key=$val" 2>/dev/null || true
  fi
}

echo "[tune] Applying network optimisations..."

# BBR congestion control
apply_setting net.core.default_qdisc fq
apply_setting net.ipv4.tcp_congestion_control bbr

# UDP buffers (important for Mieru performance)
apply_setting net.core.rmem_max 134217728
apply_setting net.core.wmem_max 134217728
apply_setting net.core.rmem_default 16777216
apply_setting net.core.wmem_default 16777216
apply_setting net.core.netdev_max_backlog 65536

# TCP buffers
apply_setting net.ipv4.tcp_rmem "4096 87380 134217728"
apply_setting net.ipv4.tcp_wmem "4096 65536 134217728"

# TCP Fast Open
apply_setting net.ipv4.tcp_fastopen 3

# Conntrack (for heavy load)
apply_setting net.nf_conntrack_max 524288 2>/dev/null || true
apply_setting net.netfilter.nf_conntrack_max 524288 2>/dev/null || true

# IP forwarding (useful when acting as a proxy gateway)
apply_setting net.ipv4.ip_forward 1

# Backlog
apply_setting net.core.somaxconn 65535
apply_setting net.ipv4.tcp_max_syn_backlog 65535

if ! $DRY_RUN; then
  # Persist settings
  cat > "$SYSCTL_FILE" <<SYSCONF
# Panel Naive + Mieru — network tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_forward = 1
SYSCONF
  echo "[tune] Settings saved to $SYSCTL_FILE"
fi

echo "[tune] Done ✓"
