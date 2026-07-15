ARG BUILD_FROM
FROM $BUILD_FROM as base

ENV LANG C.UTF-8
ARG BUILD_VERSION

RUN apk add --no-cache socat tini nodejs eudev

# Dependencies and build
FROM base as dependencies_and_build

RUN apk add --no-cache --virtual .buildtools npm make gcc g++ linux-headers udev git python3 && \
    npm install -g pnpm && \
    if [ "${BUILD_VERSION}" = "edge" ]; \
    then \
        echo "Installing Edge version" && \
        git clone -b dev --single-branch --depth 1 \
        https://github.com/Koenkk/zigbee2mqtt.git /app && \
        mkdir /app/dist && \
        jq -n --arg commit $(eval cd /app;git rev-parse --short HEAD) '$commit' > /app/dist/.hash ; \
    else \
        echo "Installing Stable version ${BUILD_VERSION%-*}" && \
        curl -sL -o "/app.tar.gz" \
        "https://github.com/Koenkk/zigbee2mqtt/archive/${BUILD_VERSION%-*}.tar.gz" && \
        tar xzvf "/app.tar.gz"  && rm "/app.tar.gz" && \
        mv -v "zigbee2mqtt-${BUILD_VERSION%-*}" app && \
        mkdir /app/dist && \
        jq -n --arg commit ${BUILD_VERSION%-*} '$commit' > /app/dist/.hash ; \
    fi; \
    echo "Installed Zigbee2MQTT @ version $(cat /app/dist/.hash)" && \
    cd /app && \
    pnpm install --frozen-lockfile --no-optional --unsafe-perm && \
    pnpm run build && \
    rm -rf node_modules && \
    pnpm install --frozen-lockfile --no-optional --unsafe-perm --prod && \
    # serialport has outdated prebuilds that appear to fail on some archs, force build on target platform
    rm -rf `find ./node_modules/.pnpm/ -wholename "*/@serialport/bindings-cpp/prebuilds" -type d` && \
    pnpm rebuild @serialport/bindings-cpp

# Release
FROM base as release

WORKDIR /app

COPY rootfs /
COPY --from=dependencies_and_build /app/node_modules ./node_modules
COPY --from=dependencies_and_build /app/dist ./dist
COPY --from=dependencies_and_build /app/package.json /app/LICENSE /app/index.js ./

ENV NODE_ENV production

# GA self-build (#480): pre-warm the Node 22 V8 compile cache at build time so
# every cold start reuses compiled bytecode instead of re-parsing ~86 MB of
# node_modules. On slow armv7 CPUs this parse is the dominant startup cost
# (zigbee-herdsman-converters ~5 s + zigbee-herdsman ~3.7 s measured on KIB-SON),
# which pushed total startup past the Supervisor watchdog window and crash-looped
# z2m 2.12. NODE_COMPILE_CACHE is Node-version + path keyed (arch-independent V8
# bytecode), so a cache baked in the QEMU-armv7 build is valid on the device.
ENV NODE_COMPILE_CACHE=/app/.node-compile-cache
RUN mkdir -p /app/.node-compile-cache; \
    ZIGBEE2MQTT_DATA=/tmp/z2mwarm timeout 180 node index.js >/dev/null 2>&1 || true; \
    rm -rf /tmp/z2mwarm; \
    echo "z2m compile cache baked: $(du -sh /app/.node-compile-cache 2>/dev/null | cut -f1)"

ENTRYPOINT [ "/sbin/tini", "--", "/docker-entrypoint.sh"]
