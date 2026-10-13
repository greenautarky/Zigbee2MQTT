#!/usr/bin/env node
"use strict";
/**
 * Applies the GA herdsman patch (Odoo #1221) to an installed zigbee-herdsman.
 *
 *   node apply-patch.js <path/to/node_modules/zigbee-herdsman>
 *
 * Fails closed: wrong herdsman version, anchor not found exactly once, or the
 * patched file not containing the call -> exit 1 (the image build stops).
 * A herdsman bump must re-review this patch; that is what the version pin forces.
 */
const fs = require("node:fs");
const path = require("node:path");

const EXPECTED_VERSION = "10.6.1";
const ANCHOR = 'logger_1.logger.info("[INIT TC] Adapter network matches config.", NS);';
const MARKER = "/* GA-PATCH #1221 */";
const CALL = `${MARKER} await require("./gaNwkCounterGuard").guardNwkFrameCounter({ ezsp: this.ezsp, backup, logger: logger_1.logger, ns: NS, slOk: enums_1.SLStatus.OK });`;

function fail(msg) {
    console.error(`apply-patch #1221: FAIL: ${msg}`);
    process.exit(1);
}

const root = process.argv[2];
if (!root) fail("usage: apply-patch.js <zigbee-herdsman dir>");
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
if (pkg.name !== "zigbee-herdsman") fail(`not zigbee-herdsman: ${pkg.name}`);
if (pkg.version !== EXPECTED_VERSION) fail(`herdsman ${pkg.version} != pinned ${EXPECTED_VERSION}; re-review the #1221 patch`);

const dir = path.join(root, "dist", "adapter", "ember", "adapter");
const target = path.join(dir, "emberAdapter.js");
let src = fs.readFileSync(target, "utf8");
if (src.includes(MARKER)) fail("already patched");
const count = src.split(ANCHOR).length - 1;
if (count !== 1) fail(`anchor found ${count} times (expected 1)`);
src = src.replace(ANCHOR, `${ANCHOR}\n                ${CALL}`);
fs.writeFileSync(target, src);
fs.copyFileSync(path.join(__dirname, "gaNwkCounterGuard.js"), path.join(dir, "gaNwkCounterGuard.js"));

const check = fs.readFileSync(target, "utf8");
if (check.split(MARKER).length - 1 !== 1) fail("marker not present exactly once after patching");
if (!fs.existsSync(path.join(dir, "gaNwkCounterGuard.js"))) fail("guard module not copied");
console.log(`apply-patch #1221: patched ${target}`);
