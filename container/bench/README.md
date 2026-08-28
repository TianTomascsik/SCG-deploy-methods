# Benchmark topologies (reference only)

The `2c`/`3c`/`gw2c`/`gw3c` compose topologies and their entrypoints drive the
`bench_*` micro-benchmark binaries. Building them requires an additional
sibling checkout, `SCG-Interface-benchmarks/`, next to `SCG/` and `ale-frame/`
in the build context — that repository is **not published**, so these
topologies are not expected to build standalone. They are kept as a reference
for how the benchmark campaigns were containerized.

The `Dockerfile` here is also used by `../docker-compose.proxy.yml`, which has
the same unpublished dependency. Everything else under `container/` builds
without it.
