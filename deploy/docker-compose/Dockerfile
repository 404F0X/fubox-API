FROM rust:bookworm AS builder
WORKDIR /app
COPY . .
ARG BIN=ai-gateway
RUN cargo build --release --bin ${BIN}

FROM debian:bookworm-slim
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ARG BIN=ai-gateway
COPY --from=builder /app/target/release/${BIN} /usr/local/bin/app
COPY examples/config.example.yaml /app/config/config.yaml
ENTRYPOINT ["/usr/local/bin/app"]
