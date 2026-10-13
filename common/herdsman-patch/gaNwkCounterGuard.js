"use strict";
/**
 * GA patch for zigbee-herdsman (Odoo #1221): NWK frame-counter high-water guard.
 *
 * Problem: the EmberZNet NCP persists its outgoing NWK frame counter only at
 * 4096-frame granularity. A counter raised by `setValue NWK_FRAME_COUNTER`
 * (restore from backup) lives in RAM until the next 4096 boundary, so an NCP
 * reset can resume BELOW frames that were already sent. Joined devices then drop
 * our frames as replays: writes time out while their reports still arrive.
 *
 * herdsman's "Adapter network matches config" (DONE) start path never compares
 * the NCP counter with the stored coordinator backup. This guard does: if the
 * NCP counter is below the backup counter, it raises the NCP counter to
 * backup + MARGIN and verifies the result by reading it back.
 *
 * If the NCP does not accept the raise, the guard does NOT re-form the network
 * (leave + form-from-backup drops the child table and is not proven safe for
 * joined devices). It logs at ERROR and writes a status file the GA health
 * checks can read. It never throws: a guard failure must not stop Zigbee.
 *
 * Copied into zigbee-herdsman/dist/adapter/ember/adapter/ by apply-patch.js.
 */
const fs = require("node:fs");
const path = require("node:path");

const MARGIN = 8192; // two 4096 persistence steps
const UINT32_MAX = 0xffffffff;
const DEFAULT_STATUS_FILE = "/share/ga-z2m-nwk-counter-guard.json";

function writeStatus(file, status) {
    if (!file) return;
    try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const tmp = `${file}.tmp`;
        fs.writeFileSync(tmp, `${JSON.stringify(status, null, 2)}\n`);
        fs.renameSync(tmp, file);
    } catch {
        // the status file is a secondary signal; the log line is the primary one
    }
}

async function readNcpCounter(ezsp, slOk) {
    const [status, info] = await ezsp.ezspGetNetworkKeyInfo();
    if (status !== slOk || !info) {
        throw new Error(`ezspGetNetworkKeyInfo status=${status}`);
    }
    return info.networkKeyFrameCounter >>> 0;
}

/**
 * @param {object} o
 * @param {object} o.ezsp     herdsman Ezsp instance (ezspGetNetworkKeyInfo, ezspSetNWKFrameCounter)
 * @param {object|undefined} o.backup  getStoredBackup() result (networkKeyInfo.frameCounter)
 * @param {object} o.logger   herdsman logger (info/warning/error)
 * @param {string} o.ns       log namespace
 * @param {number} o.slOk     SLStatus.OK
 * @param {string} [o.statusFile]
 * @returns {Promise<{state: string, ncp?: number, backup?: number, target?: number, after?: number}>}
 */
async function guardNwkFrameCounter(o) {
    const { ezsp, backup, logger, ns, slOk } = o;
    const statusFile = o.statusFile !== undefined ? o.statusFile : process.env.GA_NWK_GUARD_STATUS_FILE || DEFAULT_STATUS_FILE;
    const tag = "[GA NWK GUARD #1221]";
    const result = { state: "unknown", time: new Date().toISOString() };
    try {
        const backupCounter = backup?.networkKeyInfo?.frameCounter;
        if (typeof backupCounter !== "number") {
            result.state = "no-backup";
            logger.info(`${tag} No stored coordinator backup counter; nothing to compare.`, ns);
            writeStatus(statusFile, result);
            return result;
        }
        result.backup = backupCounter >>> 0;
        result.ncp = await readNcpCounter(ezsp, slOk);
        if (result.ncp >= result.backup) {
            result.state = "ok";
            logger.info(`${tag} NWK frame counter ok: ncp=${result.ncp} >= backup=${result.backup}.`, ns);
            writeStatus(statusFile, result);
            return result;
        }
        result.target = result.backup + MARGIN;
        if (result.target > UINT32_MAX) {
            result.state = "rejected";
            result.reason = "target exceeds uint32";
            logger.error(`${tag} NWK frame counter went BACKWARDS (ncp=${result.ncp} < backup=${result.backup}) and cannot be raised (target overflows uint32). Devices will drop coordinator frames as replays. Manual action needed.`, ns);
            writeStatus(statusFile, result);
            return result;
        }
        logger.warning(`${tag} NWK frame counter went BACKWARDS across an NCP reset: ncp=${result.ncp} < backup=${result.backup}. Raising NWK counter to ${result.target}.`, ns);
        const setStatus = await ezsp.ezspSetNWKFrameCounter(result.target);
        result.setStatus = setStatus;
        if (setStatus === slOk) {
            result.after = await readNcpCounter(ezsp, slOk);
        }
        if (setStatus === slOk && result.after >= result.target) {
            result.state = "raised";
            logger.warning(`${tag} raised NWK counter: ncp=${result.ncp} -> ${result.after} (backup=${result.backup}).`, ns);
        } else {
            result.state = "rejected";
            logger.error(`${tag} NCP did NOT accept the NWK counter raise (setStatus=${setStatus}, read back=${result.after}, ncp=${result.ncp}, backup=${result.backup}, target=${result.target}). Devices may drop coordinator frames as replays until the counter passes ${result.backup}. Not re-forming the network.`, ns);
        }
    } catch (error) {
        result.state = "error";
        result.reason = String(error && error.message ? error.message : error);
        logger.error(`${tag} guard failed: ${result.reason}. NWK frame counter NOT verified.`, ns);
    }
    writeStatus(statusFile, result);
    return result;
}

module.exports = { guardNwkFrameCounter, MARGIN, DEFAULT_STATUS_FILE };
