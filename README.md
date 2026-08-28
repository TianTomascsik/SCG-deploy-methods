# SCG deploy-methods

Generic, reusable deployment methods for the
[Secure Communication Gateway (SCG)](https://github.com/TianTomascsik/SCG) —
container images, docker-compose topologies, and a self-contained
host-network TPROXY demo.

## Layout

| Path | Description |
|---|---|
| `container/` | Multi-stage Dockerfiles, compose topologies, and entrypoint scripts |
| `container/tproxy-host/` | Self-contained host-network TPROXY gateway image with a **signed** lite config (its own [README](container/tproxy-host/README.md)) |
| `container/nginx-demo-production/` | Production-style nginx demo behind the gateway, also signed-config based |
| `container/bench/` | Legacy benchmark topologies, kept as reference (its own [README](container/bench/README.md)) |

### Compose topologies (`container/docker-compose.*.yml`)

| Topology | What it models |
|---|---|
| `proxy` | explicit proxy hop: producer → gateway (TLS-wrap) → consumer |
| `nginx-demo` / `nginx-switchable` / `nginx-tproxy` | browser-facing nginx demos behind the gateway |
| `production` | bare gateway, all config host-mounted — no nginx |
| `bench/2c` | producer → gateway → consumer (two containers + gateway) |
| `bench/3c` | producer → encrypt gateway → decrypt gateway → consumer |
| `bench/gw2c` / `bench/gw3c` | the same, with the gateway(s) in dedicated containers |

Smoke tests: `container/test_nginx_demo.sh` builds, starts, and verifies the
`nginx-demo` topology end to end; `container/test_nginx_tproxy.sh` does the
same for the 4-container `nginx-tproxy` topology.

## Prerequisites & build context

The images build the gateway from source. The build context is the **parent
directory that contains the sibling checkouts**, laid out like this:

```
parent/                       <- docker build context
├── SCG/                      <- github.com/TianTomascsik/SCG
├── ale-frame/                <- github.com/TianTomascsik/ale-frame
└── SCG-deploy-methods/      <- this repository
```

Example:

```bash
cd parent/
docker build -f SCG-deploy-methods/container/Dockerfile .
```

> **Note — bench topologies:** the benchmark topologies under
> [`container/bench/`](container/bench/) (`2c`/`3c`/`gw2c`/`gw3c`), and the
> `proxy` topology that shares their image, additionally expect a legacy
> `SCG-Interface-benchmarks/` sibling that provides the `bench_*`
> micro-benchmark binaries. That repository is not published; these topologies
> are kept for reference and are not expected to build outside the original
> environment. The gateway image, the TPROXY demo, and the nginx demos build
> without it.

## Security notes

- **Demo-grade privileges:** most compose services run with
  `privileged: true` (or `cap_add: NET_ADMIN/NET_RAW`) because TPROXY and
  WireGuard need network-admin rights. This is acceptable for local demos and
  benchmarks; a production deployment should grant only the specific
  capabilities it needs.
- **`--features dev` images:** the shipped Dockerfiles build the gateway with
  the `dev` feature, which additionally accepts the *unsigned* single-file
  `--config` loader. Production builds should omit it so only the signed,
  layered `--config-dir` configuration (Ed25519 signatures + pinned schema
  hash, fail-closed) is accepted.
- **Config signing:** the signed config dirs under `container/*/configs/` are
  verified against the trust anchor `configs/trust/config-signing.pub.pem`.
  The private signing key lives **outside** this repository; see
  `container/tproxy-host/resign.sh --help` for generating a keypair and
  re-signing after config edits.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.
