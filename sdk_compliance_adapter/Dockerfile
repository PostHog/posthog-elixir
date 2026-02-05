# Build stage - use Debian for better compatibility
FROM elixir:1.17 AS builder

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Set build environment
ENV MIX_ENV=prod

# Copy the main SDK source
COPY mix.exs mix.lock ./
COPY lib ./lib
COPY config ./config

# Copy the adapter
COPY sdk_compliance_adapter/mix.exs ./sdk_compliance_adapter/
COPY sdk_compliance_adapter/lib ./sdk_compliance_adapter/lib
COPY sdk_compliance_adapter/config ./sdk_compliance_adapter/config

# Fetch and compile dependencies for the adapter
WORKDIR /app/sdk_compliance_adapter
RUN mix deps.get --only prod
RUN mix compile

# Build release
RUN mix release

# Runtime stage - use same base as build to avoid OpenSSL mismatch
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libstdc++6 \
    openssl \
    libncurses6 \
    locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Copy the release from builder
COPY --from=builder /app/sdk_compliance_adapter/_build/prod/rel/sdk_compliance_adapter ./

# Set environment
ENV PORT=8080

EXPOSE 8080

CMD ["bin/sdk_compliance_adapter", "start"]
