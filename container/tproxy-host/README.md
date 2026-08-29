# SCG Host-Network Transparent Proxy

Self-contained OCI image that runs on the **host network** and intercepts
traffic with iptables, making plain HTTP services accessible only via HTTPS.

## Default Configuration

Out of the box, the image intercepts **local port 4200** and terminates TLS:

```
Browser/app ──https://localhost:4200──→ [OUTPUT REDIRECT 4200→4201] ──→ SCG (TLS on :4201) ──plain──→ backend (127.0.0.1:4200)
```

- Local clients connect to `https://localhost:4200`
- iptables transparently redirects local traffic for `127.0.0.1:4200` to the
  gateway on port `4201` (intercept mode `egress_redirect`,
  `match_dst: ["127.0.0.1"]`, `match_dports: "4200"`; the intercept installs
  the `::1` mirror redirect as well)
- The gateway listens on loopback only — `127.0.0.1:4201` (`secure-4200`) and
  `[::1]:4201` (`secure-4200-v6`, terminating the mirrored IPv6 redirect) —
  terminates TLS, and forwards plain HTTP to `127.0.0.1:4200`
- Your application continues listening on port 4200 as before

The shipped `configs/scg.user.json` declares exactly this flow as connection
`secure-4200`.

Recommended deployment default:

- keep the editable config on the host
- mount that folder into the container at `/etc/scg/config`
- run the gateway against that mounted config directory instead of relying on
  the baked-in copy

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

## Building the Image

```bash
./build.sh
```

This produces `scg-gateway.tar` (~40 MB as a compressed podman OCI archive;
the uncompressed docker-archive variant is ~100 MB).

| Variant | Command |
|---|---|
| Also package the sample nginx demo image | `./build.sh --with-demo` |
| Force Docker as the build/export runtime | `./build.sh --runtime docker` |
| Build only, skip the tar export | `./build.sh --no-export` |

`build.sh` auto-detects the container runtime (podman preferred, then
docker). Podman exports a true OCI archive; a Docker-built tar is still
loadable by either runtime, just in docker-archive format.

## Independent Gateway Deployment From OCI Image Tar

Use this path when you want to deploy only the SCG gateway image on a target
host, without the sample demo containers from this repo.

The commands below write `<runtime>` where either `podman` or `docker` works —
the invocations are identical. With podman, run the containers rootful
(`sudo`) because host networking and `NET_ADMIN` are required.

### 1. Build the gateway tar

```bash
./build.sh                       # podman preferred: OCI archive
./build.sh --runtime docker      # docker-archive instead
```

This creates `scg-gateway.tar`.

### 2. Copy the tar to the target machine

Transfer `scg-gateway.tar` to the host where you want the gateway to run.

### 3. Load the tar on the target host

```bash
<runtime> load -i scg-gateway.tar
```

### 4. Create the mounted host config directory

This is the recommended default deployment model. Use a host path such as
`/opt/scg/config` and mount it into the container as `/etc/scg/config`.

If you still have this repo available, seed the host config directory from
`SCG-deploy-methods/container/tproxy-host/configs/`:

```bash
mkdir -p /opt/scg/config
cp -a configs/. /opt/scg/config/
```

If you only have the image tar on the target machine, extract the baked-in
config from the loaded image instead:

```bash
mkdir -p /opt/scg/config
<runtime> create --name scg-config-seed scg-gateway:latest
<runtime> cp scg-config-seed:/etc/scg/config/. /opt/scg/config/
<runtime> rm scg-config-seed
```

### 5. Prepare the target host

Before starting the gateway container, make sure:

- your real backend application is already listening on the host
- the backend address/port matches `/opt/scg/config/scg.user.json`
- for the default config, that means the backend serves plain traffic on
  `127.0.0.1:4200`

If your backend uses a different port or host, update the files in
`/opt/scg/config`, re-sign them, and then reload the gateway (see steps 8 and
"Changing the Intercepted Port" below).

### 6. Run only the gateway container

The command below makes the mounted host config folder the default and also
enables file watching for edit-on-demand updates:

```bash
<runtime> run -d \
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

Edit the host-side files in `/opt/scg/config`. The most common file to change
is `/opt/scg/config/scg.user.json`.

Important:

- `scg.user.json` and `scg.defaults.json` are signature-checked
- after editing them, re-sign with
  `./resign.sh --key /path/OUTSIDE/repo/signing.key.pem --config-dir /opt/scg/config`
- use `./resign.sh --key ... --validate` to also verify the signatures after
  signing
- the private signing key must never live inside this repository or the image;
  generate one with `resign.sh --help`'s keygen snippet
- if you do not want the signing key on the target host, re-sign on a trusted
  admin machine and copy the updated signed files into `/opt/scg/config`

With `--watch`, new config is picked up automatically for new connections.
Without `--watch`, send `SIGHUP` to reload:

```bash
<runtime> kill --signal HUP scg-gateway
```

Existing connections are not interrupted; new connections use the new config.

### 9. Operate the gateway

```bash
<runtime> logs -f scg-gateway    # follow logs
<runtime> stop scg-gateway       # stop
<runtime> rm scg-gateway         # remove
```

### Mounted config is the default pattern

The mounted folder approach above is the recommended default deployment
pattern. The baked-in `/etc/scg/config` inside the image is mainly useful as:

- a seed source for `/opt/scg/config`
- a fallback for very static deployments
- a way to bootstrap a fresh host before switching to a mounted config directory

## Running the Packaged Demo From Tar

The `demo.sh` helper drives the packaged nginx + gateway demo from the tar
files produced by `./build.sh --with-demo`. It auto-detects the runtime
(podman preferred, then docker); override with `--runtime docker|podman`.
Prefix the commands with `sudo` when using podman.

```bash
./demo.sh load       # load scg-gateway.tar + scg-demo-nginx.tar
./demo.sh up         # start nginx + gateway (HTTPS mode)

./demo.sh stop       # switch to plain HTTP
curl http://localhost:4200/

./demo.sh start      # switch TLS interception back on
curl -k https://localhost:4200/

./demo.sh status     # show current mode
./demo.sh down       # remove both demo containers
```

The helper keeps `nginx` on the host network and toggles only the gateway
container, so you can verify the fallback between direct HTTP and intercepted
HTTPS on the same port.

## Changing the Intercepted Port

To protect a different port (e.g., **8080** instead of 4200):

1. Edit your mounted host config, for example `/opt/scg/config/scg.user.json`:
   - Change `ingress.endpoint.port` to your new gateway TLS port (e.g., 8081)
   - Change `ingress.intercept.match_dports` to `"8080"`
   - Keep `ingress.intercept.match_dst` aligned with the local backend address
     (for the default browser flow this is `["127.0.0.1"]`)
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
   <runtime> kill --signal HUP scg-gateway
   ```

   Or, if you started it with `--watch`, just wait a couple of seconds for
   auto-reload.

If you prefer a static baked-in config instead, you can still rebuild the
image tar after editing and signing, or mount any signed config directory at
runtime via `-v /path/to/my-configs:/etc/scg/config:ro`.

## Adding Multiple Services

Add more connections to `configs/scg.user.json`. The first entry below is the
shipped default; the second adds an 8080 service behind a TLS listener on
8081:

```json
{
  "connections": [
    {
      "connection_id": "secure-4200",
      "ingress": {
        "endpoint": { "ip": "127.0.0.1", "port": 4201 },
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
        "endpoint": { "ip": "::", "port": 8081 },
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

Each connection independently intercepts its configured port. (The snippet
shows only the fields that vary; keep the other fields of the shipped
`secure-4200` connection — `transport`, `protection`, `traffic_class` — in
each real entry.)

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

- **Startup**: creates the `SCG_ENCRYPT` chain in the `nat` table and adds
  REDIRECT rules — for the default `egress_redirect` mode these hang off the
  `OUTPUT` chain (locally generated traffic), with the gateway's own UID
  exempted to avoid redirect loops and a best-effort `ip6tables` mirror for
  `::1`
- **Shutdown** (SIGTERM): flushes the chain and removes routing policy
- **Forced kill**: next startup idempotently cleans up stale rules

No manual iptables scripting is needed. The container is fully self-configuring.

## Requirements

- Linux host with iptables (iptables-nft or iptables-legacy)
- Podman ≥ 4.0 (or Docker with `--privileged`)
- `CAP_NET_ADMIN` + `CAP_NET_RAW`
- Host network mode (`--network host`)
