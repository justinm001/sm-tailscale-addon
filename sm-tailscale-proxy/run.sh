#!/bin/bash
# =============================================================================
# SM Tailscale Proxy Add-on for Home Assistant
# Runs Tailscale exit node + SOCKS5 proxy + management reporting
# =============================================================================
set -e

VERSION="1.1.0"

# Read config from HA add-on options
CONFIG="/data/options.json"
NODE_ID=$(jq -r '.node_id' "$CONFIG")
MGMT_URL=$(jq -r '.mgmt_url' "$CONFIG")
MGMT_KEY=$(jq -r '.mgmt_key' "$CONFIG")
SOCKS_PORT=$(jq -r '.socks_port' "$CONFIG")
STATUS_INTERVAL=$(jq -r '.status_interval' "$CONFIG")

# Default node ID to hostname if not set
if [ -z "$NODE_ID" ] || [ "$NODE_ID" = "null" ] || [ "$NODE_ID" = "" ]; then
    NODE_ID=$(hostname)
fi

echo ""
echo "============================================"
echo " SM Tailscale Proxy Add-on v${VERSION}"
echo "============================================"
echo ""
echo "  Node ID:     $NODE_ID"
echo "  SOCKS Port:  $SOCKS_PORT"
echo "  Mgmt URL:    $MGMT_URL"
echo ""

# ============================================================
# Detect platform
# ============================================================
PLATFORM="ha-addon"
DEVICE_MODEL="Home Assistant OS"
if [ -f /proc/device-tree/model ]; then
    DEVICE_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
fi
echo "  Platform: $PLATFORM"
echo "  Device:   $DEVICE_MODEL"
echo ""

# ============================================================
# Enable IP forwarding
# ============================================================
echo "[1/4] Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || true
echo "  Done."

# ============================================================
# Start Tailscale
# ============================================================
echo "[2/4] Starting Tailscale..."

# Persist Tailscale state across restarts
mkdir -p /data/tailscale

# Start tailscaled daemon
tailscaled \
    --state=/data/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    --tun=userspace-networking &

sleep 3

# Check if already authenticated
if tailscale status --json 2>/dev/null | jq -e '.Self.Online' > /dev/null 2>&1; then
    echo "  Already connected."
    tailscale up --advertise-exit-node --hostname="$NODE_ID" --reset 2>/dev/null || true
else
    echo ""
    echo "  ================================================"
    echo "  TAILSCALE AUTH REQUIRED"
    echo "  Check the add-on logs for the login URL"
    echo "  ================================================"
    echo ""
    tailscale up --advertise-exit-node --hostname="$NODE_ID" 2>&1 || true
fi

TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
echo "  Tailscale IP: $TS_IP"
echo ""

# ============================================================
# Start SOCKS5 proxy
# ============================================================
echo "[3/4] Starting SOCKS5 proxy on port $SOCKS_PORT..."
microsocks -i 0.0.0.0 -p "$SOCKS_PORT" &
SOCKS_PID=$!
echo "  SOCKS5 PID: $SOCKS_PID"

# ============================================================
# IP Intelligence + Registration
# ============================================================
echo "[4/4] Detecting IP and registering..."
register_node() {
    PUB_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    IP_DATA=$(curl -sf --max-time 5 "http://ip-api.com/json/$PUB_IP?fields=status,city,regionName,country,isp,org,as,hosting" 2>/dev/null || echo "{}")

    IP_CITY=$(echo "$IP_DATA" | jq -r '.city // ""' 2>/dev/null)
    IP_REGION=$(echo "$IP_DATA" | jq -r '.regionName // ""' 2>/dev/null)
    IP_COUNTRY=$(echo "$IP_DATA" | jq -r '.country // ""' 2>/dev/null)
    IP_ISP=$(echo "$IP_DATA" | jq -r '.isp // ""' 2>/dev/null)
    IP_ORG=$(echo "$IP_DATA" | jq -r '.org // ""' 2>/dev/null)
    IP_ASN=$(echo "$IP_DATA" | jq -r '.as // ""' 2>/dev/null)
    IP_HOSTING=$(echo "$IP_DATA" | jq -r '.hosting // false' 2>/dev/null)

    IP_TYPE="business"
    if [ "$IP_HOSTING" = "true" ]; then
        IP_TYPE="datacenter"
    else
        ISP_L=$(echo "$IP_ISP" | tr '[:upper:]' '[:lower:]')
        case "$ISP_L" in
            *comcast*|*spectrum*|*at\&t*|*verizon*|*cox*|*frontier*|*charter*|*t-mobile*|*centurylink*|*mediacom*|*xfinity*|*optimum*|*starlink*|*hughesnet*|*brightspeed*|*ziply*|*suddenlink*|*altice*|*astound*|*wow*|*breezeline*|*cable*one*|*midco*|*windstream*|*earthlink*|*consolidated*)
                IP_TYPE="residential" ;;
        esac
    fi

    echo "  Public IP: $PUB_IP ($IP_TYPE)"
    echo "  Location:  $IP_CITY, $IP_REGION"
    echo "  ISP:       $IP_ISP"
}
register_node

# Initial registration with mgmt
curl -sf -X POST \
    -H "Content-Type: application/json" -H "X-Api-Key: $MGMT_KEY" \
    -d "{\"machine\":\"$NODE_ID\",\"event\":\"ts_device_install\",\"version\":\"$VERSION\",\"data\":{\"type\":\"tailscale_device\",\"tailscale_ip\":\"$TS_IP\",\"public_ip\":\"$PUB_IP\",\"ip_type\":\"$IP_TYPE\",\"ip_city\":\"$IP_CITY\",\"ip_region\":\"$IP_REGION\",\"ip_country\":\"$IP_COUNTRY\",\"ip_isp\":\"$IP_ISP\",\"ip_asn\":\"$IP_ASN\",\"socks_port\":$SOCKS_PORT,\"platform\":\"$PLATFORM\",\"device\":\"$DEVICE_MODEL\"}}" \
    "$MGMT_URL/api/errors" > /dev/null 2>&1 && echo "  Registered with mgmt." || echo "  Mgmt offline (will retry)."

echo ""
echo "============================================"
echo " SM Tailscale Proxy Ready — $NODE_ID"
echo "============================================"
echo ""
echo "  Tailscale IP:  $TS_IP"
echo "  SOCKS proxy:   $TS_IP:$SOCKS_PORT"
echo "  Public IP:     $PUB_IP ($IP_TYPE)"
echo "  Location:      $IP_CITY, $IP_REGION"
echo ""

# ============================================================
# Status reporter loop (replaces cron)
# ============================================================
echo "Starting status reporter (every ${STATUS_INTERVAL}s)..."

while true; do
    sleep "$STATUS_INTERVAL"

    TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online // false' 2>/dev/null || echo "false")
    PUB_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")

    MEM_TOTAL=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo "0")
    MEM_FREE=$(free -m 2>/dev/null | awk '/Mem:/ {print $7}' || echo "0")
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}' || echo "0")
    SOCKS_OK=$(ss -tlnp 2>/dev/null | grep -c ":${SOCKS_PORT}" || echo "0")
    LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' || echo "0")
    DISK_PCT=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0")
    UPTIME=$(uptime -p 2>/dev/null || echo "unknown")

    # Refresh IP intel every 15 minutes
    CACHE="/tmp/sm_ip_intel.json"
    NEED=1
    if [ -f "$CACHE" ]; then
        AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
        [ $AGE -lt 900 ] && NEED=0
    fi
    if [ $NEED -eq 1 ] && [ "$PUB_IP" != "unknown" ]; then
        curl -sf --max-time 5 "http://ip-api.com/json/$PUB_IP?fields=city,regionName,country,isp,org,as,hosting" > "$CACHE" 2>/dev/null || true
    fi

    IP_CITY=$(jq -r '.city // ""' "$CACHE" 2>/dev/null || echo "")
    IP_REGION=$(jq -r '.regionName // ""' "$CACHE" 2>/dev/null || echo "")
    IP_ISP=$(jq -r '.isp // ""' "$CACHE" 2>/dev/null || echo "")
    IP_ASN=$(jq -r '.as // ""' "$CACHE" 2>/dev/null || echo "")
    IP_HOSTING=$(jq -r '.hosting // false' "$CACHE" 2>/dev/null || echo "false")

    IP_TYPE="business"
    [ "$IP_HOSTING" = "true" ] && IP_TYPE="datacenter"
    ISP_L=$(echo "$IP_ISP" | tr '[:upper:]' '[:lower:]')
    case "$ISP_L" in
        *comcast*|*spectrum*|*at\&t*|*verizon*|*cox*|*frontier*|*charter*|*t-mobile*|*centurylink*|*xfinity*|*optimum*|*starlink*|*hughesnet*|*brightspeed*|*suddenlink*|*altice*|*astound*|*breezeline*|*windstream*)
            IP_TYPE="residential" ;;
    esac

    curl -sf -X POST -H "Content-Type: application/json" -H "X-Api-Key: $MGMT_KEY" \
        -d "{\"machine\":\"$NODE_ID\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"tailscale_device\",\"tailscale_ip\":\"$TS_IP\",\"tailscale_online\":$TS_STATUS,\"public_ip\":\"$PUB_IP\",\"ip_type\":\"$IP_TYPE\",\"ip_city\":\"$IP_CITY\",\"ip_region\":\"$IP_REGION\",\"ip_isp\":\"$IP_ISP\",\"ip_asn\":\"$IP_ASN\",\"socks_port\":$SOCKS_PORT,\"socks_running\":$SOCKS_OK,\"uptime\":\"$UPTIME\",\"mem_total_mb\":$MEM_TOTAL,\"mem_free_mb\":$MEM_FREE,\"cpu_temp_c\":$CPU_TEMP,\"load_avg\":$LOAD,\"disk_pct\":$DISK_PCT}" \
        "$MGMT_URL/api/status" > /dev/null 2>&1

    # Restart microsocks if it died
    if ! kill -0 $SOCKS_PID 2>/dev/null; then
        echo "$(date): microsocks died, restarting..."
        microsocks -i 0.0.0.0 -p "$SOCKS_PORT" &
        SOCKS_PID=$!
    fi
done
