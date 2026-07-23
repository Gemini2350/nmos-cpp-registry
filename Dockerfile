# syntax=docker/dockerfile:1
#
# nmos-cpp-registry + nmos-js Web UI
# -----------------------------------
# Builds the *latest* Sony nmos-cpp registry (Conan 2 toolchain) together with
# the Sony nmos-js browser UI, served by the registry itself on its admin port.
#
# This replaces the outdated rhastie/build-nmos-cpp image, which is pinned to an
# old nmos-cpp commit and to Conan 1.x (no longer supported upstream).
#
# Pin/override versions at build time, e.g.:
#   docker build --build-arg NMOS_CPP_VERSION=<sha> -t nmos-cpp-registry .

############################################################
# Stage 1 — build the nmos-js browser UI (static files)
############################################################
# Node 20 LTS: comfortably satisfies nmos-js + is12-client deps (some require
# node >=18/20). react-scripts 5 / webpack 5 build fine here, no OpenSSL workarounds.
FROM node:20-bullseye-slim AS js-build

ARG NMOS_JS_VERSION=8ff0aa2a4496b52da600cee77cf3e5c3e38948b3
# Do not fail the build on lint warnings, and skip source maps to save space.
ENV CI=false
ENV GENERATE_SOURCEMAP=false

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates jq \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable

WORKDIR /src
RUN git clone https://github.com/sony/nmos-js.git . \
    && git checkout ${NMOS_JS_VERSION}

# Main app. Bake the IS-12 Device Model Browser base path into config.json so the
# Devices page can launch the IS-12 client we ship at /admin/is12-client/.
WORKDIR /src/Development
RUN jq '."IS-12 Browser".value = "/admin/is12-client"' src/config.json > src/config.tmp \
    && mv src/config.tmp src/config.json \
    && yarn install --network-timeout 1000000 \
    && yarn build
# -> static site in /src/Development/build

# IS-12 Device Model Browser (separate CRA app, added by nmos-js PR #157).
# Built under the /admin/is12-client sub-path via PUBLIC_URL so its assets resolve.
WORKDIR /src/is12-client
RUN yarn install --network-timeout 1000000 \
    && PUBLIC_URL=/admin/is12-client yarn build
# -> static site in /src/is12-client/build

############################################################
# Stage 2 — build nmos-cpp-registry + mDNSResponder
############################################################
FROM ubuntu:24.04 AS cpp-build

ENV DEBIAN_FRONTEND=noninteractive
ARG NMOS_CPP_VERSION=d1c8da7bedd237f7c87b41b82376dea1c9637691
ARG MDNS_VERSION=878.260.1

# Toolchain + everything Conan may need to build dependencies from source.
RUN apt-get update && apt-get install -y --no-install-recommends \
        g++ make build-essential patch pkg-config \
        autoconf automake libtool m4 perl \
        python3 python3-venv python3-pip \
        git curl ca-certificates zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Recent CMake (>=3.24 required) and Conan 2 in an isolated venv
# (Ubuntu 24.04 marks the system Python as externally managed).
RUN python3 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install --no-cache-dir "cmake>=3.24" "conan>=2.20,<3"

# --- nmos-cpp source ---
WORKDIR /src
RUN curl -fsSL https://codeload.github.com/sony/nmos-cpp/tar.gz/${NMOS_CPP_VERSION} \
    | tar zx --strip-components=1

# --- Apple mDNSResponder (DNS-SD), patched as nmos-cpp expects ---
WORKDIR /opt
RUN curl -fsSL https://codeload.github.com/apple-oss-distributions/mDNSResponder/tar.gz/mDNSResponder-${MDNS_VERSION} \
        | tar zx \
    && mv mDNSResponder-mDNSResponder-${MDNS_VERSION} mDNSResponder \
    && patch -d mDNSResponder -p1 < /src/Development/third_party/mDNSResponder/unicast.patch \
    && patch -d mDNSResponder -p1 < /src/Development/third_party/mDNSResponder/permit-over-long-service-types.patch \
    && patch -d mDNSResponder -p1 < /src/Development/third_party/mDNSResponder/poll-rather-than-select.patch \
    && make -C mDNSResponder/mDNSPosix os=linux \
    && make -C mDNSResponder/mDNSPosix os=linux install
# Installs libdns_sd.so + dns_sd.h so nmos-cpp can link against it.

# --- build the registry ---
# NMOS_CPP_USE_AVAHI=OFF  -> link the Apple mDNSResponder built above
# NMOS_CPP_BUILD_EXAMPLES=ON is REQUIRED: the nmos-cpp-registry target lives
# behind that flag in Development/CMakeLists.txt. We still build only the
# registry target to keep the build lean.
WORKDIR /src/Development
RUN conan profile detect --force \
    && cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES=third_party/cmake/conan_provider.cmake \
        -DNMOS_CPP_USE_AVAHI=OFF \
        -DNMOS_CPP_BUILD_EXAMPLES=ON \
        -DNMOS_CPP_BUILD_TESTS=OFF \
    && cmake --build build --target nmos-cpp-registry --parallel "$(nproc)"

############################################################
# Stage 3 — slim runtime image
############################################################
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
LABEL org.opencontainers.image.title="nmos-cpp-registry" \
      org.opencontainers.image.description="Sony nmos-cpp registry (latest) + nmos-js UI for NMOS Crosspoint" \
      org.opencontainers.image.source="https://github.com/sony/nmos-cpp"

# Runtime libs. Conan links its dependencies statically, so we mainly need
# libstdc++ (already present) plus libdns_sd from mDNSResponder, installed below.
# mosquitto: an MQTT broker for IS-07 event transport (optional, started by entrypoint).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates make \
        libssl3 libatomic1 \
        mosquitto \
    && rm -rf /var/lib/apt/lists/*

# Bring over the patched mDNSResponder tree and install only its artifacts
# (the install targets just copy what was compiled in stage 2 — no rebuild).
COPY --from=cpp-build /opt/mDNSResponder /opt/mDNSResponder
RUN make -C /opt/mDNSResponder/mDNSPosix os=linux install \
    && apt-get purge -y make && apt-get autoremove -y \
    && rm -rf /opt/mDNSResponder /etc/nsswitch.conf.pre-mdns

# Registry binary, browser UI and default config.
COPY --from=cpp-build /src/Development/build/nmos-cpp-registry /home/nmos-cpp-registry
COPY --from=js-build  /src/Development/build                   /home/admin
# IS-12 Device Model Browser, served by the registry at /admin/is12-client/.
COPY --from=js-build  /src/is12-client/build                   /home/admin/is12-client
COPY registry.json entrypoint.sh /home/
RUN chmod +x /home/entrypoint.sh

# 8010 IS-04 Registration/Query API + admin UI (nmos-js, served at /admin/)
# 8011 Query API WebSocket   1883 MQTT broker (IS-07)   5353/udp mDNS
EXPOSE 8010 8011 1883 5353/udp

# WORKDIR matters: the registry serves the admin UI from ./admin
WORKDIR /home
ENTRYPOINT ["/home/entrypoint.sh"]
