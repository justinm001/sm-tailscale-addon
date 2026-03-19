#!/bin/bash
# Install Tailscale for the correct architecture
set -e

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  TS_ARCH="amd64" ;;
    aarch64) TS_ARCH="arm64" ;;
    armv7l)  TS_ARCH="arm" ;;
    *)       TS_ARCH="amd64" ;;
esac

VERSION=$(curl -sf https://pkgs.tailscale.com/stable/ | grep -oP 'tailscale_\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$VERSION" ]; then
    VERSION="1.80.3"
fi

URL="https://pkgs.tailscale.com/stable/tailscale_${VERSION}_${TS_ARCH}.tgz"
echo "Installing Tailscale $VERSION for $TS_ARCH..."

curl -fsSL "$URL" -o /tmp/tailscale.tgz
tar xzf /tmp/tailscale.tgz -C /tmp
cp /tmp/tailscale_*/tailscale /usr/local/bin/
cp /tmp/tailscale_*/tailscaled /usr/local/bin/
rm -rf /tmp/tailscale*

echo "Tailscale installed."
