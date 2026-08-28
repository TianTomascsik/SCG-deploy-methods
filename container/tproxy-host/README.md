# SCG Host-Network Transparent Proxy

Self-contained OCI image that runs on the **host network** and intercepts
traffic with iptables, making plain HTTP services accessible only via HTTPS.

## Default Configuration

Out of the box, the image intercepts **local port 4200** and terminates TLS:

```
Browser/app ──https://localhost:4200──→ [OUTPUT REDIRECT 4200→4201] ──→ SCG (TLS on :4201) ──plain──→ backend (127.0.0.1:4200)
```

- Local clients connect to `https://localhost:4200`
- iptables transparently redirects local traffic for `127.0.0.1:4200` to the gateway on port `4201`
- Gateway terminates TLS and forwards plain HTTP to `127.0.0.1:4200`
- Your application continues listening on port 4200 as before

Recommended deployment default:

- keep the editable config on the host
- mount that folder into the container at `/etc/scg/config`
- run the gateway against that mounted config directory instead of relying on the baked-in copy

## Browser Demo With Sample NGINX

This repo also includes a ready-made host-network demo that starts:

- `nginx` serving plain HTTP on `127.0.0.1:4200`
- the SCG host gateway intercepting local browser traffic and upgrading it to TLS

Run it with:

```bash
cd /path/to/parent/SCG-deploy-methods/container/tproxy-host
./test_nginx_host.sh
```

Then open:

```text
https://localhost:4200
```

Accept the self-signed certificate warning once. You should see the
"SCG TProxy Host Demo" page.

To switch modes manually with the current Docker-host demo:

```bash
docker stop scg_tproxy_gateway     # HTTP mode on http://localhost:4200
docker start scg_tproxy_gateway    # HTTPS mode on https://localhost:4200
```

Or use the helper:

```bash
./gateway.sh stop
./gateway.sh start
./gateway.sh status
```

## Quick Start

### 1. Build the image

```bash
./build.sh
```

This produces `scg-gateway.tar` (~40 MB).

To also package the sample host-network nginx demo for Podman:

```bash
./build.sh --with-demo
```

That additionally produces `scg-demo-nginx.tar`.

To force Docker as the build/export runtime:

```bash
./build.sh --runtime docker --with-demo
```

## Independent Gateway Deployment From OCI Image Tar

Use this path when you want to deploy only the SCG gateway image on a target
host, without the sample demo containers from this repo.

### 1. Build the gateway tar

Prefer Podman if you specifically want an OCI archive:

```bash
./build.sh --runtime podman
```

This creates:

```text
scg-gateway.tar
```

If you build with Docker instead:

```bash
./build.sh --runtime docker
```

the resulting tar is still loadable, but it will be a Docker archive rather
than a Podman-generated OCI archive.

### 2. Copy the tar to the target machine

Transfer:

```text
scg-gateway.tar
```

to the host where you want the gateway to run.

### 3. Load the tar on the target host

With Podman:

```bash
podman load -i scg-gateway.tar
```

With Docker:

```bash
docker load -i scg-gateway.tar
```

### 4. Create the mounted host config directory

This is the recommended default deployment model.

Use a host path such as:

```text
/opt/scg/config
```

and mount it into the container as:

```text
/etc/scg/config
```

If you still have this repo available, seed the host config directory from:

```text
SCG-deploy-methods/container/tproxy-host/configs/
```

For example:

```bash
mkdir -p /opt/scg/config
cp -a configs/. /opt/scg/config/
```

If you only have the image tar on the target machine, you can extract the
baked-in config from the loaded image first.

With Podman:

```bash
mkdir -p /opt/scg/config
podman create --name scg-config-seed scg-gateway:latest
podman cp scg-config-seed:/etc/scg/config/. /opt/scg/config/
podman rm scg-config-seed
```

With Docker:

```bash
mkdir -p /opt/scg/config
docker create --name scg-config-seed scg-gateway:latest
docker cp scg-config-seed:/etc/scg/config/. /opt/scg/config/
docker rm scg-config-seed
```

### 5. Prepare the target host

Before starting the gateway container, make sure:

- your real backend application is already listening on the host
- the backend address/port matches `/opt/scg/config/scg.user.json`
- for the default config, that means the backend serves plain traffic on `127.0.0.1:4200`

If your backend uses a different port or host, update the files in
`/opt/scg/config`, re-sign them, and then reload the gateway.

### 6. Run only the gateway container

The commands below make the mounted host config folder the default and also
enable file watching for edit-on-demand updates.

With Podman:

```bash
podman run -d \
  --name scg-gateway \
  --network host \
  --privileged \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --restart unless-stopped \
  -v /opt/scg/config:/etc/scg/config:ro \
  scg-gateway:latest \
  --config-dir /etc/scg/config --log-stdout --watch
```

With Docker:

```bash
docker run -d \
  --name scg-gateway \
  --network host \
  --privileged \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  --restart unless-stopped \
  -v /opt/scg/config:/etc/scg/config:ro \
  scg-gateway:latest \
  --config-dir /etc/scg/config --log-stdout --watch
```

This starts only the gateway. Your application remains a separate host process
or service that the gateway forwards to.

Note:

- the bind mount is read-only only from the container side
- you still edit the files normally on the host in `/opt/scg/config`
- `--watch` makes the gateway poll for config changes about every 2 seconds

### 7. Verify the deployment

For the default host-loopback config:

```bash
curl -k https://localhost:4200/
```

If the gateway is running and the backend is reachable, the request should
return your backend response through TLS.

### 8. Edit the config on demand

Edit the host-side files in:

```text
/opt/scg/config
```

The most common file to change is:

```text
/opt/scg/config/scg.user.json
```

Important:

- `scg.user.json` and `scg.defaults.json` are signature-checked
- after editing them, re-sign with `./resign.sh --key /path/OUTSIDE/repo/signing.key.pem` (add `--config-dir /opt/scg/config` for a mounted config)
- use `./resign.sh --key ... --validate` to also verify the signatures after signing
- the private signing key must never live inside this repository or the image; generate one with `resign.sh --help`'s keygen snippet
- if you do not want the signing key on the target host, re-sign on a trusted admin machine and copy the updated signed files into `/opt/scg/config`

With `--watch`, new config is picked up automatically for new connections.
Without `--watch`, send `SIGHUP` to reload:

With Podman:

```bash
podman kill --signal HUP scg-gateway
```

With Docker:

```bash
docker kill --signal HUP scg-gateway
```

Existing connections are not interrupted; new connections use the new config.

### 9. Operate the gateway

Show logs:

```bash
podman logs -f scg-gateway
```

or:

```bash
docker logs -f scg-gateway
```

Stop it:

```bash
podman stop scg-gateway
```

or:

```bash
docker stop scg-gateway
```

Remove it:

```bash
podman rm scg-gateway
```

or:

```bash
docker rm scg-gateway
```

### 10. Mounted config is the default pattern

The mounted folder approach above is now the recommended default deployment
pattern. The baked-in `/etc/scg/config` inside the image is mainly useful as:

- a seed source for `/opt/scg/config`
- a fallback for very static deployments
- a way to bootstrap a fresh host before switching to a mounted config directory

### Demo workflows

### 3a. Run the full sample demo from OCI tar with Podman

Use the packaged demo images plus the helper script:

```bash
sudo ./podman-demo.sh load
sudo ./podman-demo.sh up
```

Then:

```bash
sudo ./podman-demo.sh stop     # switch to plain HTTP
curl http://localhost:4200/

sudo ./podman-demo.sh start    # switch TLS interception back on
curl -k https://localhost:4200/
```

The helper keeps `nginx` on the host network and toggles only the gateway
container, so you can verify the fallback between direct HTTP and intercepted
HTTPS on the same port.

### 3b. Run the full sample demo from tar with Docker

Build tar images with Docker:

```bash
./build.sh --runtime docker --with-demo
```

Load and run them with the Docker helper:

```bash
./docker-demo.sh load
./docker-demo.sh up
```

Then toggle between modes:

```bash
./docker-demo.sh stop      # plain HTTP on http://localhost:4200
./docker-demo.sh start     # HTTPS interception on https://localhost:4200
./docker-demo.sh status
```

## Changing the Intercepted Port

To protect a different port (e.g., **8080** instead of 4200):

1. Edit your mounted host config, for example `/opt/scg/config/scg.user.json`:
   - Change `ingress.endpoint.port` to your new gateway TLS port (e.g., 8081)
   - Change `ingress.intercept.match_dports` to `"8080"`
   - Keep `ingress.intercept.match_dst` aligned with the local backend address (for the default browser flow this is `["127.0.0.1"]`)
   - Change `paths[0].egress.endpoint.port` to `8080`

2. Re-sign the config:
   ```bash
   ./resign.sh --key /path/OUTSIDE/repo/signing.key.pem --config-dir /opt/scg/config
   ```

   Or with openssl directly (the same detached-signature format):
   ```bash
   openssl pkeyutl -sign -inkey /path/OUTSIDE/repo/signing.key.pem -rawin \
     -in /opt/scg/config/scg.user.json | openssl base64 -A \
     > /opt/scg/config/scg.user.json.sig
   ```

3. Let the running gateway pick up the change:
   ```bash
   docker kill --signal HUP scg-gateway
   ```

   Or, if you started it with `--watch`, just wait a couple of seconds for auto-reload.

If you prefer a static baked-in config instead, you can still rebuild the image tar after editing and signing.

Mount the config directory at runtime like this:

```bash
podman run -d \
  --name scg-gateway \
  --network host \
  --privileged \
  -v /path/to/my-configs:/etc/scg/config:ro \
  scg-gateway:latest \
  --config-dir /etc/scg/config --log-stdout --watch
```

## Adding Multiple Services

Add more connections to `configs/scg.user.json`:

```json
{
  "connections": [
    {
      "connection_id": "secure-4200",
      "ingress": {
        "endpoint": { "ip": "0.0.0.0", "port": 4201 },
        "intercept": {
          "mode": "egress_redirect",
          "match_dports": "4200",
          "match_dst": ["127.0.0.1"]
        }
      },
      "paths": [{ "egress": { "endpoint": { "host": "127.0.0.1", "port": 4200 } } }]
    },
    {
      "connection_id": "secure-8080",
      "ingress": {
        "endpoint": { "ip": "0.0.0.0", "port": 8081 },
        "intercept": {
          "mode": "egress_redirect",
          "match_dports": "8080",
          "match_dst": ["127.0.0.1"]
        }
      },
      "paths": [{ "egress": { "endpoint": { "host": "127.0.0.1", "port": 8080 } } }]
    }
  ]
}
```

Each connection independently intercepts its configured port.

## Config Structure

```
configs/
├── scg.defaults.json       Platform defaults (crypto profiles, runtime config)
├── scg.defaults.json.sig   Ed25519 signature
├── scg.user.json           Deployment-specific connections & intercept rules
├── scg.user.json.sig       Ed25519 signature
├── scg.lite.schema.json    Validation schema
└── trust/
    └── config-signing.pub.pem   Trust anchor (public key)
```

The gateway verifies signatures on startup (fail-closed). The private signing
key is kept outside the image and outside this repository, for re-signing only.

## How It Works

The SCG gateway reads the `intercept` block from each connection and
**automatically installs/removes iptables rules** at startup/shutdown:

- **Startup**: creates `SCG_ENCRYPT` chain in `nat` table, adds REDIRECT rules
- **Shutdown** (SIGTERM): flushes the chain and removes routing policy
- **Forced kill**: next startup idempotently cleans up stale rules

No manual iptables scripting is needed. The container is fully self-configuring.

## Requirements

- Linux host with iptables (iptables-nft or iptables-legacy)
- Podman ≥ 4.0 (or Docker with `--privileged`)
- `CAP_NET_ADMIN` + `CAP_NET_RAW`
- Host network mode (`--network host`)
