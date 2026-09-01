# syntax=docker/dockerfile:1
# cargo-chef layer split: the dependency tree compiles in its own layer
# (recipe.json = Cargo.toml/lock fingerprint), so gha layer-cache hits skip
# the multi-minute dep compilation for source-only commits -- important
# because CI builds on every push to main (the GitOps app pins its image to
# sha-<commit>) and BuildKit cache mounts would be ephemeral on GHA runners.
FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /src
# cmake: aws-lc-rs (reqwest's rustls backend) builds its C sources with it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS build
COPY --from=planner /src/recipe.json recipe.json
# Layer-cached while Cargo.toml/Cargo.lock are unchanged; /src/target from
# this layer carries the prebuilt deps into the build below.
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release && cp target/release/mcp-token-vault /usr/local/bin/

FROM gcr.io/distroless/cc-debian13:nonroot
COPY --from=build /usr/local/bin/mcp-token-vault /
ENTRYPOINT ["/mcp-token-vault"]
