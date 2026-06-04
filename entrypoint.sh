#!/usr/bin/env bash
# Entrypoint for the nmos-cpp-registry container.
set -e

# If arguments were given, run them instead of the registry (handy for debugging,
# e.g. `docker run --rm -it nmos-cpp-registry bash`).
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

CONFIG="${REGISTRY_JSON:-/home/registry.json}"

# Optionally stamp the registry label with the container hostname so multiple
# registries are easy to tell apart. Enable with -e UPDATE_LABEL=TRUE.
if [ "${UPDATE_LABEL:-FALSE}" = "TRUE" ] && command -v sed >/dev/null 2>&1; then
    tmp="$(mktemp)"
    sed "s/\"label\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"label\": \"$(hostname)\"/" "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
fi

echo "Starting mDNSResponder (DNS-SD)..."
# The mDNSResponder install ships an init script; fall back to the daemon directly.
if [ -x /etc/init.d/mdns ]; then
    /etc/init.d/mdns start || true
elif command -v mdnsd >/dev/null 2>&1; then
    mdnsd || true
fi
sleep 1

echo "Starting nmos-cpp-registry with config: $CONFIG"
cat "$CONFIG"
echo

# Registry serves the admin UI (nmos-js) from ./admin, so run from /home.
cd /home
exec /home/nmos-cpp-registry "$CONFIG"
