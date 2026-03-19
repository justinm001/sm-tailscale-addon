# SM Tailscale Proxy Add-on

Tailscale exit node with SOCKS5 proxy for the SM proxy network.
Rebuilt from setup_ts_device.sh to run as a Home Assistant add-on.

## What it does

- Runs Tailscale as an exit node
- SOCKS5 proxy (microsocks) on port 1080
- IP intelligence detection (residential/business/datacenter)
- Status reporting to mgmt server every 5 minutes
- Auto-restarts microsocks if it crashes
- Persists Tailscale auth state across restarts

## Configuration

- **node_id**: Device identifier (e.g. TS-OFFICE-1)
- **socks_port**: SOCKS5 proxy port (default 1080)
- **mgmt_url**: Management server URL
- **mgmt_key**: Management API key
- **status_interval**: Seconds between status reports (default 300)

## First Run

On first start, check the add-on logs for the Tailscale login URL.
Authenticate in your browser, then approve the exit node in the
Tailscale admin console at login.tailscale.com.
