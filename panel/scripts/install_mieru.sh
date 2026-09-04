#!/usr/bin/env bash
# Install / update Mieru (mita) from GitHub releases via .deb package
# Usage: bash install_mieru.sh [--update]
set -euo pipefail

MIERU_RELEASES="https://api.github.com/repos/enfein/mieru/releases/latest"

case "$(uname -m)" in
  x86_64|amd64)  DEB_ARCH="amd64"  ;;
  aarch64|arm64) DEB_ARCH="arm64"  ;;
  armv7l)        DEB_ARCH="armhf"  ;;
  *) echo "[ERROR] Unsupported arch: $(uname -m)"; exit 1 ;;
esac

echo "[mieru] Fetching latest release info..."
release_json=$(curl -fsSL "$MIERU_RELEASES")
tag=$(echo "$release_json" | jq -r '.tag_name')
echo "[mieru] Latest: $tag"

asset_url=$(echo "$release_json" | jq -r \
  --arg arch "$DEB_ARCH" \
  '.assets[] | select(.name | test("mita.*" + $arch + "\\.deb")) | .browser_download_url' \
  | head -1)

if [[ -z "$asset_url" ]]; then
  asset_url=$(echo "$release_json" | jq -r \
    --arg arch "$DEB_ARCH" \
    '.assets[] | select(.name | test($arch + "\\.deb")) | .browser_download_url' \
    | head -1)
fi

[[ -z "$asset_url" ]] && { echo "[ERROR] No .deb found for $DEB_ARCH"; exit 1; }

deb_file=$(mktemp /tmp/mieru-XXXXXX.deb)
echo "[mieru] Downloading $asset_url"
wget -q --show-progress -O "$deb_file" "$asset_url"

echo "[mieru] Installing .deb package..."
dpkg -i "$deb_file" 2>/dev/null || apt-get install -f -y
rm -f "$deb_file"

# Enable and start mita service
systemctl daemon-reload
systemctl enable mita 2>/dev/null || true
systemctl restart mita 2>/dev/null || true

echo "[mieru] Installed: $(mita version 2>/dev/null | head -1 || echo $tag)"
