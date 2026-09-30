ARG BUILD_FROM
FROM $BUILD_FROM as base

ENV LANG C.UTF-8
ARG BUILD_VERSION
ARG BUILD_ARCH
ARG TEMPIO_VERSION=2026.07.0

# GA self-build: refresh the base layer. The Home Assistant armv7 base images
# stopped being rebuilt in 2025-11, so their Alpine packages and the tempio
# helper binary they carry are frozen at that date. `apk upgrade` moves every
# package to the current release of the same Alpine branch; tempio is replaced
# by a current upstream release, verified against a pinned sha256 per arch.
RUN apk upgrade --no-cache && \
    apk add --no-cache socat tini nodejs eudev && \
    # Validation to confirm that curl is installed in the base image.
    (curl --version || (echo "curl missing" && exit 1)) && \
    case "${BUILD_ARCH}" in \
      armv7)   sha=1887c4721317ee166de703ddb30f906c9f98f01f08a6b2da295c10946a0c8110 ;; \
      aarch64) sha=dd846861a6829bdf1267b09d4735fc6ebd0cc748c73542eb9e721c9c4d833209 ;; \
      amd64)   sha=c03682e407110fa89475c0231cde5c4b5fd59660c7fc68e5ce5d2e703ed8c002 ;; \
      *) echo "unsupported BUILD_ARCH '${BUILD_ARCH}'" && exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/tempio \
      "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VERSION}/tempio_${BUILD_ARCH}" && \
    echo "${sha}  /tmp/tempio" | sha256sum -c - && \
    install -m 0755 /tmp/tempio /usr/bin/tempio && \
    rm -f /tmp/tempio

# Dependencies and build
FROM base as dependencies_and_build

RUN apk add --no-cache --virtual .buildtools npm make gcc g++ linux-headers udev git python3 && \
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
    npm install -g $(jq -r '.packageManager' package.json) && \
    pnpm install --frozen-lockfile --no-optional --unsafe-perm && \
    pnpm run build && \
    rm -rf node_modules && \
    pnpm install --frozen-lockfile --no-optional --unsafe-perm --prod && \
    # force serialport to rebuild on current platform instead of using prebuilds
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

# GA self-build (#480): the NODE_COMPILE_CACHE warm-up bake (present in 2.12.1-2)
# was REMOVED in 2.12.1-3 — it was unproven on armv7 and the prime suspect for a
# regression vs the known-good 2.12.1-1 (which ran on K0 2026-07-07 without it).
# We ship the clean build first and prove 2.12 on armv7 via the Supervisor path;
# a compile-cache optimisation can be re-added later once it is measured to help
# and not hurt. See GA-ARMV7-MAINTENANCE.md.

# GA self-build (#480): raise the container health-check start-period. z2m 2.12
# cold-start on armv7 (module load + coordinator + web UI) exceeds the upstream
# 30s grace, so the Supervisor watchdog marked it unhealthy and crash-looped it
# before its web server on :8099 came up. 180s gives a slow armv7 enough headroom.
HEALTHCHECK --interval=1m --timeout=5s --start-period=180s --start-interval=5s \
  CMD curl -f http://localhost:8099/

ENTRYPOINT [ "/sbin/tini", "--", "/docker-entrypoint.sh"]
