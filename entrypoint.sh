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

# Optional MQTT broker (mosquitto) for IS-07 event transport.
#   RUN_MQTT=TRUE|FALSE      start the broker            (default TRUE)
#   MQTT_PORT=<port>         broker listen port          (default 1883)
#   ADVERTISE_MQTT=TRUE|FALSE  advertise it via mDNS     (default TRUE)
if [ "${RUN_MQTT:-TRUE}" = "TRUE" ] && command -v mosquitto >/dev/null 2>&1; then
    MQTT_PORT="${MQTT_PORT:-1883}"
    mqtt_conf="/run/mosquitto-nmos.conf"
    {
        echo "listener ${MQTT_PORT}"
        echo "allow_anonymous true"
    } > "$mqtt_conf"
    echo "Starting MQTT broker (mosquitto) on port ${MQTT_PORT}"
    mosquitto -d -c "$mqtt_conf" || echo "WARN: mosquitto failed to start"

    if [ "${ADVERTISE_MQTT:-TRUE}" = "TRUE" ] && command -v dns-sd >/dev/null 2>&1; then
        mqtt_ip="$(hostname -I 2>/dev/null | cut -d' ' -f1)"
        echo "Advertising MQTT broker via mDNS: nmos-cpp_mqtt_${mqtt_ip}:${MQTT_PORT}"
        dns-sd -R "nmos-cpp_mqtt_${mqtt_ip}:${MQTT_PORT}" _nmos-mqtt._tcp local "${MQTT_PORT}" \
            api_proto=mqtt api_auth=false &
    fi
else
    echo "MQTT broker disabled (RUN_MQTT=${RUN_MQTT:-TRUE})"
fi

echo "Starting nmos-cpp-registry with config: $CONFIG"
cat "$CONFIG"
echo

# Registry serves the admin UI (nmos-js) from ./admin, so run from /home.
cd /home
exec /home/nmos-cpp-registry "$CONFIG"
