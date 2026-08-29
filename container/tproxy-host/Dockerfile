# SCG Host-Network TPROXY Gateway
#
# Self-contained OCI image that runs on the host network and intercepts
# traffic based on the baked-in signed lite config.
#
# The default config intercepts port 4200 and terminates TLS (making
# local browser/app traffic for http://localhost:4200 require
# https://localhost:4200 instead). To change ports or add
# services, mount an override config dir at /etc/scg/config.
#
# Build context: the parent directory that contains the sibling checkouts
# (SCG/, ale-frame/, SCG-deploy-methods/).

# Stage 1: Build the gateway binary
FROM rust:1.89-bookworm AS builder

RUN apt-get update && apt-get install -y \
    libssl-dev \
    pkg-config \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY SCG/ ./SCG/
COPY ale-frame/ ./ale-frame/

WORKDIR /build/SCG
# Redirect the private ale-frame git dependency to the sibling copied into the
# build context — works offline and without GitHub credentials.
RUN printf '\n[patch."https://github.com/TianTomascsik/ale-frame.git"]\nale-frame = { path = "../ale-frame" }\n' >> Cargo.toml
RUN cargo build --release -p gateway

# Stage 2: Minimal runtime image
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    iproute2 \
    iptables \
    kmod \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/SCG/target/release/gateway /usr/local/bin/gateway

# Bake in the signed config (can be overridden via volume mount)
COPY SCG-deploy-methods/container/tproxy-host/configs/ /etc/scg/config/

# Create runtime directories
RUN mkdir -p /var/lib/scg/config-generations /run/scg /var/log/scg

# Metadata
LABEL org.opencontainers.image.title="SCG Transparent Proxy" \
      org.opencontainers.image.description="Self-configuring TLS gateway with iptables intercept" \
      org.opencontainers.image.version="1.0"

ENTRYPOINT ["gateway"]
CMD ["--config-dir", "/etc/scg/config", "--log-stdout"]
