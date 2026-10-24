# Find eligible builder and runner images on Docker Hub:
# https://hub.docker.com/r/hexpm/elixir/tags

ARG ELIXIR_VERSION=1.18.5
ARG ERLANG_VERSION=27.3.4.19
ARG DEBIAN_VERSION=bookworm-20261005-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git ca-certificates curl \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# Compile the release
RUN mix compile

# Pre-download tailwind binary using curl (supports arch detection & avoids Erlang :httpc 10KB header limits on GitHub Releases)
RUN ARCH=$(case $(dpkg --print-architecture) in amd64) echo "x64" ;; arm64) echo "arm64" ;; armhf) echo "armv7" ;; *) dpkg --print-architecture ;; esac) && \
    mkdir -p /app/_build && \
    curl -fsSL "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.3/tailwindcss-linux-${ARCH}" -o /app/_build/tailwind-linux-${ARCH}-4.3.3 && \
    chmod +x /app/_build/tailwind-linux-${ARCH}-4.3.3

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
  apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Install Litestream for SQLite continuous replication
RUN ARCH=$(dpkg --print-architecture) && \
  curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-${ARCH}.tar.gz" -o /tmp/litestream.tar.gz && \
  tar -C /usr/local/bin -xzf /tmp/litestream.tar.gz && \
  rm -f /tmp/litestream.tar.gz && \
  chmod +x /usr/local/bin/litestream

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/deal_scout ./
COPY config/litestream.yml /etc/litestream.yml
COPY scripts/server-entrypoint.sh /app/bin/entrypoint
RUN chmod +x /app/bin/entrypoint

# Prepare data directory for SQLite volume and Litestream replica
RUN mkdir -p /data/litestream && chown -R nobody:root /data

USER nobody

EXPOSE 8080

CMD ["/app/bin/entrypoint"]
