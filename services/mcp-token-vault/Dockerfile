# syntax=docker/dockerfile:1
FROM rust:1-slim AS build
WORKDIR /src
# cmake: aws-lc-rs (reqwest's rustls backend) builds its C sources with it.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake \
    && rm -rf /var/lib/apt/lists/*
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release && cp target/release/mcp-token-vault /usr/local/bin/

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /usr/local/bin/mcp-token-vault /
ENTRYPOINT ["/mcp-token-vault"]
