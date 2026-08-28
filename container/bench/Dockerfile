# Multi-stage build for the benchmark/proxy topology containers
# (docker-compose.{2c,3c,gw2c,gw3c}.yml in this directory, plus
# ../docker-compose.proxy.yml).
#
# Build context: the parent directory of this repo, so the
# sibling source repos are available:
#   SCG/                       -> the gateway binary
#   ale-frame/                 -> gateway dependency (ALE framing)
#   SCG-Interface-benchmarks/  -> the bench_* micro-benchmark binaries
#     (these path-depend on SCG/crates/*, so SCG/ must be a sibling under /build)
#
# Stage 1: Build the gateway + all bench_* binaries
FROM rust:1.89-bookworm AS builder

RUN apt-get update && apt-get install -y \
    libssl-dev \
    pkg-config \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY SCG/ ./SCG/
COPY ale-frame/ ./ale-frame/
COPY SCG-Interface-benchmarks/ ./SCG-Interface-benchmarks/

# gateway (from the SCG workspace)
# --features dev: the entrypoint scripts generate an unsigned single-file
# --config at runtime, which a default (production) gateway build rejects
# (signed --config-dir only). A real production image should build
# without `dev` and mount a signed --config-dir instead.
RUN cargo build --release --manifest-path SCG/Cargo.toml -p gateway --features dev

# bench_* micro-benchmarks from the SCG-Interface-benchmarks workspace
RUN cargo build --release --manifest-path SCG-Interface-benchmarks/Cargo.toml \
    -p bench_tcp -p bench_udp -p bench_uds -p bench_shm -p bench_ktls \
    -p bench_receiver -p bench_gateway

# Stage 2: Runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    iproute2 \
    iptables \
    kmod \
    socat \
    && rm -rf /var/lib/apt/lists/*

# Copy all benchmark binaries + the gateway
COPY --from=builder /build/SCG-Interface-benchmarks/target/release/bench_tcp /usr/local/bin/
COPY --from=builder /build/SCG-Interface-benchmarks/target/release/bench_udp /usr/local/bin/
COPY --from=builder /build/SCG-Interface-benchmarks/target/release/bench_uds /usr/local/bin/
COPY --from=builder /build/SCG-Interface-benchmarks/target/release/bench_shm /usr/local/bin/
COPY --from=builder /build/SCG-Interface-benchmarks/target/release/bench_ktls /usr/local/bin/
COPY --from=builder /build/SCG-Interface-benchmarks/target/release/bench_receiver /usr/local/bin/
COPY --from=builder /build/SCG-Interface-benchmarks/target/release/bench_gateway /usr/local/bin/
COPY --from=builder /build/SCG/target/release/gateway /usr/local/bin/

# Copy entrypoint scripts (context is the parent directory of this repo)
COPY SCG-deploy-methods/container/bench/entrypoint_receiver.sh /usr/local/bin/
COPY SCG-deploy-methods/container/bench/entrypoint_benchmark.sh /usr/local/bin/
COPY SCG-deploy-methods/container/bench/entrypoint_consumer.sh /usr/local/bin/
COPY SCG-deploy-methods/container/bench/entrypoint_gateway.sh /usr/local/bin/
COPY SCG-deploy-methods/container/bench/entrypoint_downstream.sh /usr/local/bin/
COPY SCG-deploy-methods/container/entrypoint_proxy.sh /usr/local/bin/
COPY SCG-deploy-methods/container/entrypoint_proxy_producer.sh /usr/local/bin/
COPY SCG-deploy-methods/container/entrypoint_proxy_endpoint.sh /usr/local/bin/
COPY SCG-deploy-methods/container/entrypoint_nginx_demo.sh /usr/local/bin/
COPY SCG-deploy-methods/container/entrypoint_tproxy_encrypt.sh /usr/local/bin/
COPY SCG-deploy-methods/container/entrypoint_tproxy_decrypt.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint_*.sh

# Shared volume for CSV results
RUN mkdir -p /results

WORKDIR /benchmark
