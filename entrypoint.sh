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

# --- DNS-SD SRV target (host_name) ---
# mDNS hostname conflicts can rename the responder's .local name while the
# SRV records keep the configured target, leaving it unresolvable. Pointing
# host_name at the host's unicast DNS name avoids that entirely.
#   HOST_NAME=<fqdn>            force a specific name
#   AUTO_HOST_NAME=TRUE|FALSE   derive it from reverse DNS (default TRUE);
#                               only used when it forward-resolves back to
#                               this host's address, otherwise the mDNS
#                               default (<hostname>.local) stays in effect
if ! grep -q '"host_name"' "$CONFIG"; then
    host_name=""
    if [ -n "${HOST_NAME:-}" ]; then
        host_name="$HOST_NAME"
        echo "Using DNS-SD host_name from HOST_NAME: $host_name"
    elif [ "${AUTO_HOST_NAME:-TRUE}" = "TRUE" ]; then
        primary_ip="$(hostname -I 2>/dev/null | cut -d' ' -f1)"
        if [ -n "$primary_ip" ]; then
            # reverse lookup: "<ip> <canonical name>"
            set -- $(getent hosts "$primary_ip" 2>/dev/null) || true
            candidate="${2:-}"
            # accept only a real FQDN that resolves back to the same address
            case "$candidate" in
                *.*)
                    if getent hosts "$candidate" 2>/dev/null | grep -qw "$primary_ip"; then
                        host_name="$candidate"
                        echo "Using DNS-SD host_name from reverse DNS: $host_name ($primary_ip)"
                    else
                        echo "Reverse DNS name '$candidate' does not resolve back to $primary_ip - keeping mDNS default"
                    fi
                    ;;
                *)
                    echo "No usable reverse DNS name for $primary_ip - keeping mDNS default"
                    ;;
            esac
        fi
    fi
    if [ -n "$host_name" ] && command -v jq >/dev/null 2>&1; then
        jq --arg h "$host_name" '. + {host_name: $h}' "$CONFIG" > /run/registry-effective.json \
            && CONFIG=/run/registry-effective.json
    fi
fi

echo "Starting nmos-cpp-registry with config: $CONFIG"
cat "$CONFIG"
echo

# Registry serves the admin UI (nmos-js) from ./admin, so run from /home.
cd /home
exec /home/nmos-cpp-registry "$CONFIG"
