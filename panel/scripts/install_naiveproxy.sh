#!/usr/bin/env bash
# Install / update NaiveProxy (caddy-naive) binary
# Usage: bash install_naiveproxy.sh [--update]
set -euo pipefail

CADDY_BIN="/usr/local/bin/caddy-naive"
NAIVE_RELEASES="https://api.github.com/repos/klzgrad/naiveproxy/releases/latest"

case "$(uname -m)" in
  x86_64|amd64)  NAIVE_ARCH="linux-amd64"  ;;
  aarch64|arm64) NAIVE_ARCH="linux-arm64"  ;;
  armv7l)        NAIVE_ARCH="linux-arm"    ;;
  *) echo "[ERROR] Unsupported arch: $(uname -m)"; exit 1 ;;
esac

echo "[naive] Fetching latest release info..."
release_json=$(curl -fsSL "$NAIVE_RELEASES")
tag=$(echo "$release_json" | jq -r '.tag_name')
echo "[naive] Latest: $tag"

asset_url=$(echo "$release_json" | jq -r \
  --arg arch "$NAIVE_ARCH" \
  '.assets[] | select(.name | test("naiveproxy-.*" + $arch)) | select(.name | test("\\.tar\\.xz|\\.tar\\.gz|\\.zip")) | .browser_download_url' \
  | head -1)

[[ -z "$asset_url" ]] && { echo "[ERROR] No asset found for $NAIVE_ARCH"; exit 1; }

tmp_dir=$(mktemp -d)
archive_name=$(basename "$asset_url")
echo "[naive] Downloading $asset_url"
wget -q --show-progress -O "$tmp_dir/$archive_name" "$asset_url"

cd "$tmp_dir"
[[ "$archive_name" == *.tar.xz ]] && tar -xJf "$archive_name"
[[ "$archive_name" == *.tar.gz ]] && tar -xzf "$archive_name"
[[ "$archive_name" == *.zip   ]] && unzip -q  "$archive_name"

caddy_bin=$(find "$tmp_dir" -type f -name "caddy*" ! -name "*.xz" ! -name "*.gz" ! -name "*.zip" | head -1)
[[ -z "$caddy_bin" ]] && { echo "[ERROR] caddy binary not found in archive"; rm -rf "$tmp_dir"; exit 1; }

install -m 755 "$caddy_bin" "$CADDY_BIN"
rm -rf "$tmp_dir"
cd /

echo "[naive] Installed: $("$CADDY_BIN" version 2>/dev/null | head -1 || echo $tag)"
