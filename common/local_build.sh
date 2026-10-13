cd ..
cp common/Dockerfile zigbee2mqtt-edge/
cp -R common/rootfs zigbee2mqtt-edge/
cp -R common/herdsman-patch zigbee2mqtt-edge/
docker run --rm --privileged \
-v $(pwd)/zigbee2mqtt-edge:/data homeassistant/amd64-builder --amd64 -t /data \
--no-cache
rm -rf zigbee2mqtt-edge/rootfs zigbee2mqtt-edge/herdsman-patch
rm zigbee2mqtt-edge/Dockerfile