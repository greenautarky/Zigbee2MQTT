#!/usr/bin/env bashio

bashio::log.info "Preparing to start..."

# Check if HA supervisor started
# Workaround for:
# - https://github.com/home-assistant/supervisor/issues/3884
# - https://github.com/zigbee2mqtt/hassio-zigbee2mqtt/issues/387
bashio::config.require 'data_path'

# Socat
if bashio::config.true 'socat.enabled'; then
    bashio::log.info "Socat enabled"
    SOCAT_MASTER=$(bashio::config 'socat.master')
    SOCAT_SLAVE=$(bashio::config 'socat.slave')

    # Validate input
    if [[ -z "$SOCAT_MASTER" ]]; then
    bashio::exit.nok "Socat is enabled but not started because no master address specified"
    fi
    if [[ -z "$SOCAT_SLAVE" ]]; then
    bashio::exit.nok "Socat is enabled but not started because no slave address specified"
    fi
    bashio::log.info "Starting socat"

    DATA_PATH=$(bashio::config 'data_path')
    SOCAT_OPTIONS=$(bashio::config 'socat.options')

    # Socat start configuration
    bashio::log.blue "Socat startup parameters:"
    bashio::log.blue "Options:     $SOCAT_OPTIONS"
    bashio::log.blue "Master:      $SOCAT_MASTER"
    bashio::log.blue "Slave:       $SOCAT_SLAVE"

    bashio::log.info "Starting socat process ..."
    exec socat $SOCAT_OPTIONS $SOCAT_MASTER $SOCAT_SLAVE &

    bashio::log.debug "Modifying process for logging if required"
    if bashio::config.true 'socat.log'; then
        bashio::log.debug "Socat loggin enabled, setting file path to $DATA_PATH/socat.log"
        exec &>"$DATA_PATH/socat.log" 2>&1
    else
    bashio::log.debug "No logging required"
    fi
else
    bashio::log.info "Socat not enabled"
fi

# GA default (2.12.1-7): link-quality sensors are created ENABLED in Home Assistant.
# Zigbee2MQTT publishes `linkquality` with `enabled_by_default: false`; the global
# `device_options.homeassistant.<object_id>` override is merged into every device's
# options (lib/model/device.ts) and applied to the discovery payload
# (lib/extension/homeassistant.ts). Single definition, used for the seed below AND
# for existing configurations. JSON is valid YAML flow syntax.
GA_DEVICE_OPTIONS='{"homeassistant":{"linkquality":{"enabled_by_default":true}}}'

# GA default (2.12.1-8): log at warning, to the console only (Odoo #1225).
# At info Zigbee2MQTT logged every MQTT payload, into the container log (the
# persistent journal) AND a second copy under <data_path>/log: ~1 MB/h of SD
# writes for nothing that is read. Every consumer of z2m's log acts on level
# "error" only (ga_manager zigbee_command_log.classify, ga_heating sync.py), so
# warning keeps all of it. Same pattern as device_options: seeded on a fresh
# install, supplied through the environment for an existing one, and a key the
# owner has set in configuration.yaml always wins.
GA_LOG_LEVEL='warning'
GA_LOG_OUTPUT='["console"]'

export ZIGBEE2MQTT_DATA="$(bashio::config 'data_path')"
if ! bashio::fs.file_exists "$ZIGBEE2MQTT_DATA/configuration.yaml"; then
    mkdir -p "$ZIGBEE2MQTT_DATA" || bashio::exit.nok "Could not create $ZIGBEE2MQTT_DATA"

    cat <<EOF > "$ZIGBEE2MQTT_DATA/configuration.yaml"
version: 4
homeassistant:
  enabled: true
advanced:
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
  log_level: ${GA_LOG_LEVEL}
  log_output: ${GA_LOG_OUTPUT}
device_options: ${GA_DEVICE_OPTIONS}
EOF
fi

# Existing configurations (seeded before 2.12.1-7) carry no `device_options`. Supply
# the GA default through Zigbee2MQTT's environment override, which Zigbee2MQTT also
# persists into configuration.yaml on its next settings write. A `device_options`
# block already in the file is the owner's and is never replaced; if it lacks the
# linkquality override, say so loudly instead of silently running without it.
if ! grep -q '^device_options:' "$ZIGBEE2MQTT_DATA/configuration.yaml"; then
    export ZIGBEE2MQTT_CONFIG_DEVICE_OPTIONS="${GA_DEVICE_OPTIONS}"
    bashio::log.info "GA default applied: device_options=${GA_DEVICE_OPTIONS}"
elif ! grep -q 'linkquality' "$ZIGBEE2MQTT_DATA/configuration.yaml"; then
    bashio::log.warning "configuration.yaml has its own device_options without a linkquality override; the GA default (linkquality enabled in Home Assistant) is NOT applied"
fi

# Logging defaults for configurations that do not set them (see GA_LOG_LEVEL).
if ! grep -qE '^[[:space:]]+log_level:' "$ZIGBEE2MQTT_DATA/configuration.yaml"; then
    export ZIGBEE2MQTT_CONFIG_ADVANCED_LOG_LEVEL="${GA_LOG_LEVEL}"
    bashio::log.info "GA default applied: advanced.log_level=${GA_LOG_LEVEL}"
fi
if ! grep -qE '^[[:space:]]+log_output:' "$ZIGBEE2MQTT_DATA/configuration.yaml"; then
    export ZIGBEE2MQTT_CONFIG_ADVANCED_LOG_OUTPUT="${GA_LOG_OUTPUT}"
    bashio::log.info "GA default applied: advanced.log_output=${GA_LOG_OUTPUT}"
fi

if bashio::config.has_value 'watchdog'; then
    export Z2M_WATCHDOG="$(bashio::config 'watchdog')"
    bashio::log.info "Enabled Zigbee2MQTT watchdog with value '$Z2M_WATCHDOG'"
fi

export NODE_PATH=/app/node_modules
export ZIGBEE2MQTT_CONFIG_FRONTEND='{"enabled":true,"port": 8099}'

if bashio::config.true 'disable_tuya_default_response'; then
    bashio::log.info "Disabling TuYa default responses"
    export DISABLE_TUYA_DEFAULT_RESPONSE="true"
fi

# Expose addon configuration through environment variables.
function export_config() {
    local key=${1}
    local subkey

    if bashio::config.is_empty "${key}"; then
        return
    fi

    for subkey in $(bashio::jq "$(bashio::config "${key}")" 'keys[]'); do
        export "ZIGBEE2MQTT_CONFIG_$(bashio::string.upper "${key}")_$(bashio::string.upper "${subkey}")=$(bashio::config "${key}.${subkey}")"
    done
}

export_config 'mqtt'
export_config 'serial'

if (bashio::config.is_empty 'mqtt' || ! (bashio::config.has_value 'mqtt.server' || bashio::config.has_value 'mqtt.user' || bashio::config.has_value 'mqtt.password')) && bashio::var.has_value "$(bashio::services 'mqtt')"; then
    if bashio::var.true "$(bashio::services 'mqtt' 'ssl')"; then
        export ZIGBEE2MQTT_CONFIG_MQTT_SERVER="mqtts://$(bashio::services 'mqtt' 'host'):$(bashio::services 'mqtt' 'port')"
    else
        export ZIGBEE2MQTT_CONFIG_MQTT_SERVER="mqtt://$(bashio::services 'mqtt' 'host'):$(bashio::services 'mqtt' 'port')"
    fi
    export ZIGBEE2MQTT_CONFIG_MQTT_USER="$(bashio::services 'mqtt' 'username')"
    export ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD="$(bashio::services 'mqtt' 'password')"
fi

# GA external converters (2.12.1-12, Odoo #1934, KB #354). Device definitions the
# pinned zigbee-herdsman-converters lacks — e.g. the on/off countdown of the TS0014
# `_TZ3000_cxw02yp3`, which ga_heating needs as its dead-man — ship in the image under
# GA_CONVERTER_SRC and are installed into <data>/external_converters/, which
# Zigbee2MQTT 2.x loads on start. A converter only matches its own fingerprint, so it
# changes nothing on a device where that hardware is not paired.
#   * Every *.mjs in GA_CONVERTER_SRC is installed; one that is already identical is
#     left untouched (idempotent: no write, no log line).
#   * A same-named file WITHOUT the GA marker is the owner's: never overwritten, and
#     said loudly.
#   * A file WITH the marker that the image no longer ships is removed, so a converter
#     dropped once upstream supports the device does not linger. Files without the
#     marker are never removed.
GA_CONVERTER_SRC="${GA_CONVERTER_SRC:-/ga-converters}"
GA_CONVERTER_MARKER='// GA-MANAGED external converter'
# The marker counts only on LINE 1. An owner's file that merely mentions the marker
# text further down (a comment, a copied snippet) is still the owner's (review #12).
ga_converter_marked() { head -n1 "$1" 2>/dev/null | grep -qF "$GA_CONVERTER_MARKER"; }
install_ga_converters() {
    local dst="$ZIGBEE2MQTT_DATA/external_converters" src name target
    if [ ! -d "$GA_CONVERTER_SRC" ]; then
        bashio::log.warning "GA converters: $GA_CONVERTER_SRC is missing from the image — none installed"
        return 0
    fi
    mkdir -p "$dst" || { bashio::log.warning "GA converters: cannot create $dst — none installed"; return 0; }
    for src in "$GA_CONVERTER_SRC"/*.mjs; do
        [ -e "$src" ] || continue
        name="$(basename "$src")"
        target="$dst/$name"
        if [ -e "$target" ] && ! ga_converter_marked "$target"; then
            bashio::log.warning "GA converter $name NOT installed: $target exists without the GA-MANAGED marker and is kept as the owner's file"
            continue
        fi
        if ! cmp -s "$src" "$target"; then
            # rm first: cp would follow a pre-existing symlink at .ga-tmp and write
            # through it to wherever it points (review #12).
            rm -f "$target.ga-tmp" && cp "$src" "$target.ga-tmp" && mv -f "$target.ga-tmp" "$target" \
                && bashio::log.info "GA converter installed: $name" \
                || bashio::log.warning "GA converter $name could not be installed into $dst"
        fi
    done
    for target in "$dst"/*.mjs; do
        [ -e "$target" ] || continue
        name="$(basename "$target")"
        if [ ! -e "$GA_CONVERTER_SRC/$name" ] && ga_converter_marked "$target"; then
            rm -f "$target" && bashio::log.info "GA converter removed (no longer shipped): $name"
        fi
    done
}
install_ga_converters

bashio::log.info "Starting Zigbee2MQTT..."
cd /app
exec node index.js
