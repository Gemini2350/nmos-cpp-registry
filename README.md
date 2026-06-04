# nmos-cpp-registry (latest) — Docker image

[![build-and-push](https://github.com/Gemini2350/nmos-cpp-registry/actions/workflows/docker.yml/badge.svg)](https://github.com/Gemini2350/nmos-cpp-registry/actions/workflows/docker.yml)

A self-contained Docker build of the **latest** [Sony nmos-cpp](https://github.com/sony/nmos-cpp)
NMOS registry, bundled with the [nmos-js](https://github.com/sony/nmos-js) browser UI.

This exists because the commonly-recommended
[rhastie/build-nmos-cpp](https://github.com/rhastie/build-nmos-cpp) image is
pinned to an old nmos-cpp commit (Dec 2022) and to **Conan 1.x**, which upstream
nmos-cpp no longer supports. Current nmos-cpp requires **Conan 2.20+** and
**CMake 3.24+** with the new `conan_provider.cmake` integration — handled here.

## What's in the image

| Component | Detail |
|-----------|--------|
| `nmos-cpp-registry` | Built from `sony/nmos-cpp` (pinned commit, see `Dockerfile`), Conan 2 toolchain, `Release` build |
| nmos-js Web UI | Served by the registry itself at `/admin/` on the registry port (`8010`) |
| DNS-SD | Apple **mDNSResponder** built into the image (no host Avahi conflict) |
| MQTT broker | **mosquitto** for IS-07 event transport, on `1883`, advertised via mDNS (`_nmos-mqtt._tcp`) |
| Base | `ubuntu:24.04`, multi-stage → slim runtime |

## Quick start (Docker Hub)

```sh
docker run -d --network host --restart unless-stopped \
  --name nmos-cpp-registry gemini2350/nmos-cpp-registry:latest
```

Then open `http://<host>:8010/admin/`.

## Build it yourself

```sh
git clone https://github.com/Gemini2350/nmos-cpp-registry.git
cd nmos-cpp-registry
docker build -t nmos-cpp-registry .
# or: make build
```

The first build is slow (Conan compiles any dependencies without prebuilt
binaries for your platform). Subsequent builds are cached.

To bump to a newer upstream commit without editing the Dockerfile:

```sh
docker build --build-arg NMOS_CPP_VERSION=<git-sha> -t nmos-cpp-registry .
```

## Run

mDNS needs host networking so NMOS nodes on the LAN can discover the registry:

```sh
docker run -d --network host --name nmos-cpp-registry \
  --restart unless-stopped nmos-cpp-registry
```

or:

```sh
docker compose up -d        # uses docker-compose.yml (host network)
```

## Ports

| Port | Purpose |
|------|---------|
| 8010 | IS-04 Registration API + Query API (HTTP) **and** the nmos-js browser UI at `/admin/` |
| 8011 | Query API WebSocket |
| 1883 | MQTT broker (mosquitto) for IS-07 |
| 5353/udp | mDNS / DNS-SD |

- Browser UI: `http://<host>:8010/admin/`
- Point NMOS Crosspoint's registry setting at `http://<host>:8010`.

The UI and the API share port 8010 (`admin_port` == `http_port` in `registry.json`).
To split them onto separate ports again, set `admin_port` to e.g. `3208`.

## Configuration

Defaults live in [`registry.json`](registry.json). Override by mounting your own:

```sh
docker run -d --network host \
  -v "$(pwd)/registry.json:/home/registry.json:ro" \
  nmos-cpp-registry
```

Or point at a different file inside the container with `-e REGISTRY_JSON=/path.json`.

Environment variables:

| Variable | Default | Effect |
|----------|---------|--------|
| `REGISTRY_JSON` | `/home/registry.json` | Path to the registry config inside the container |
| `UPDATE_LABEL` | `FALSE` | If `TRUE`, stamp the registry `label` with the container hostname |
| `RUN_MQTT` | `TRUE` | Start the bundled mosquitto MQTT broker (IS-07) |
| `MQTT_PORT` | `1883` | MQTT broker listen port |
| `ADVERTISE_MQTT` | `TRUE` | Advertise the broker via mDNS (`_nmos-mqtt._tcp`) |

The default [`registry.json`](registry.json) sets **`ptp_domain_number: 0`**, so the
IS-09 System API at `/x-nmos/system/v1.0/global/` reports PTP domain `0`
(nmos-cpp's own default is `127`). Change it there if your PTP domain differs.

Full list of settings:
<https://github.com/sony/nmos-cpp/blob/master/Development/nmos/settings.h>

## Notes

- This image runs **HTTP only** (no TLS), which is what NMOS Crosspoint expects
  by default. For secure (BCP-003-01) operation you'd add certificates and the
  corresponding `registry.json` settings (and a reverse proxy or native
  `server_secure`).
- A **mosquitto** MQTT broker for IS-07 is bundled on port `1883` and advertised
  via mDNS. Disable it with `-e RUN_MQTT=FALSE`.

## Continuous integration

`.github/workflows/docker.yml` builds the image on every push to `main` (and on
`v*` tags) and pushes it to Docker Hub. For it to publish, add two repository
secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|--------|-------|
| `DOCKERHUB_USERNAME` | your Docker Hub username (also the image namespace) |
| `DOCKERHUB_TOKEN` | a Docker Hub access token (Docker Hub → Account Settings → Security) |

The workflow builds `linux/amd64` only. arm64 via QEMU on hosted runners is too
slow for this C++/Conan build; enable it with a native arm runner or run
`make buildx` locally.

## Credits

Built on [sony/nmos-cpp](https://github.com/sony/nmos-cpp) and
[sony/nmos-js](https://github.com/sony/nmos-js) (both Apache-2.0). Inspired by
[rhastie/build-nmos-cpp](https://github.com/rhastie/build-nmos-cpp).
