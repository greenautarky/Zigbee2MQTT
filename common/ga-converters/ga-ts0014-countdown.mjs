// GA-MANAGED external converter — installed by the GreenAutarky Zigbee2MQTT add-on
// (common/rootfs/docker-entrypoint.sh). The add-on refreshes this file on every start
// as long as this marker line is present; delete the marker to keep a local edit.
//
// Why (Odoo #1934, KB #354): the Tuya TS0014 `_TZ3000_cxw02yp3` ("4CH Zigbee Switch
// Module-L") implements the Tuya on/off countdown (genOnOff onWithTimedOff, time in
// SECONDS, toggles on expiry) — measured on a GA bench device on 2026-11-11: armed 900 s,
// the relay switched itself OFF 900 s later with no command in between. The built-in
// zigbee-herdsman-converters definition (generic "TS0014") does not enable
// `onOffCountdown`, so Zigbee2MQTT exposes no `countdown_l1..l4` and ga_heating cannot
// arm its dead-man on this relay.
//
// This definition is the built-in TS0014 one (zhc 26.76.0, devices/tuya.js) with ONE
// change: `onOffCountdown: true`. It matches ONLY `_TZ3000_cxw02yp3`; every other TS0014
// keeps the built-in definition.
import * as reporting from "zigbee-herdsman-converters/lib/reporting";
import * as tuya from "zigbee-herdsman-converters/lib/tuya";

export default {
    fingerprint: tuya.fingerprint("TS0014", ["_TZ3000_cxw02yp3"]),
    model: "TS0014_countdown",
    vendor: "Tuya",
    description: "4 gang switch module without neutral (Module-L), with on/off countdown (GA)",
    extend: [
        tuya.modernExtend.tuyaBase(),
        tuya.modernExtend.tuyaOnOff({
            backlightModeLowMediumHigh: true,
            onOffCountdown: true,
            endpoints: ["l1", "l2", "l3", "l4"],
        }),
    ],
    endpoint: () => ({ l1: 1, l2: 2, l3: 3, l4: 4 }),
    meta: { multiEndpoint: true },
    configure: async (device, coordinatorEndpoint) => {
        await tuya.configureMagicPacket(device, coordinatorEndpoint);
        try {
            for (const ID of [1, 2, 3, 4]) {
                await reporting.bind(device.getEndpoint(ID), coordinatorEndpoint, ["genOnOff"]);
            }
        } catch {
            // Fails for some: https://github.com/Koenkk/zigbee2mqtt/issues/4872
        }
        device.powerSource = "Mains (single phase)";
        device.save();
    },
};
