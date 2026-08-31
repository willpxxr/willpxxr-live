FROM rust:1-slim AS build
WORKDIR /src
COPY . .
RUN cargo build --release

FROM gcr.io/distroless/cc-debian12
COPY --from=build /src/target/release/mcp-token-vault /
ENTRYPOINT ["/mcp-token-vault"]
