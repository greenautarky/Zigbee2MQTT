"use strict";
// Tests for the GA herdsman patch (Odoo #1221). They run against a REAL
// zigbee-herdsman install that run.sh patched with the live apply-patch.js —
// the subject is the patched herdsman, never a copy of the guard.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const HM = process.env.HERDSMAN_DIR;
if (!HM) throw new Error("HERDSMAN_DIR not set (use run.sh)");
const ADAPTER_DIR = path.join(HM, "dist", "adapter", "ember", "adapter");

const OK = 0;
const REJECT = 0x0c; // any non-OK SLStatus

function fakeEzsp({ ncp, acceptSet = true, applySet = true }) {
    const e = {
        counter: ncp,
        sets: [],
        async ezspGetNetworkKeyInfo() {
            return [OK, { networkKeySet: true, networkKeyFrameCounter: e.counter }];
        },
        async ezspSetNWKFrameCounter(v) {
            e.sets.push(v);
            if (!acceptSet) return REJECT;
            if (applySet) e.counter = v;
            return OK;
        },
    };
    return e;
}

function fakeLogger() {
    const lines = { info: [], warning: [], error: [], debug: [] };
    const l = {};
    for (const k of Object.keys(lines)) l[k] = (m) => lines[k].push(typeof m === "function" ? m() : m);
    return { l, lines };
}

const tmpStatus = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), "nwkguard-")), "status.json");
const backupWith = (fc) => ({ networkKeyInfo: { frameCounter: fc, sequenceNumber: 0 } });

// ---- unit: the guard module as deployed into herdsman -------------------------------
function guard() {
    return require(path.join(ADAPTER_DIR, "gaNwkCounterGuard.js"));
}

test("NCP below backup -> raises to backup+8192, WARNING with both values", async () => {
    const { guardNwkFrameCounter, MARGIN } = guard();
    assert.equal(MARGIN, 8192);
    const ezsp = fakeEzsp({ ncp: 1000060 });
    const { l, lines } = fakeLogger();
    const sf = tmpStatus();
    const r = await guardNwkFrameCounter({ ezsp, backup: backupWith(1001933), logger: l, ns: "t", slOk: OK, statusFile: sf });
    assert.equal(r.state, "raised");
    assert.deepEqual(ezsp.sets, [1001933 + 8192]);
    assert.equal(ezsp.counter, 1010125);
    assert.ok(lines.warning.some((m) => m.includes("1000060") && m.includes("1001933")));
    assert.ok(lines.warning.some((m) => m.includes("raised NWK counter")));
    assert.equal(lines.error.length, 0);
    assert.equal(JSON.parse(fs.readFileSync(sf, "utf8")).state, "raised");
});

for (const ncp of [1001933, 1004109]) {
    test(`NCP ${ncp === 1001933 ? "equal to" : "above"} backup -> quiet, no set`, async () => {
        const { guardNwkFrameCounter } = guard();
        const ezsp = fakeEzsp({ ncp });
        const { l, lines } = fakeLogger();
        const r = await guardNwkFrameCounter({ ezsp, backup: backupWith(1001933), logger: l, ns: "t", slOk: OK, statusFile: tmpStatus() });
        assert.equal(r.state, "ok");
        assert.deepEqual(ezsp.sets, []);
        assert.equal(lines.warning.length, 0);
        assert.equal(lines.error.length, 0);
    });
}

test("set rejected -> loud ERROR, status file says rejected, no throw", async () => {
    const { guardNwkFrameCounter } = guard();
    const ezsp = fakeEzsp({ ncp: 100, acceptSet: false });
    const { l, lines } = fakeLogger();
    const sf = tmpStatus();
    const r = await guardNwkFrameCounter({ ezsp, backup: backupWith(5000), logger: l, ns: "t", slOk: OK, statusFile: sf });
    assert.equal(r.state, "rejected");
    assert.ok(lines.error.some((m) => m.includes("did NOT accept") && m.includes("ncp=100") && m.includes("backup=5000")));
    const s = JSON.parse(fs.readFileSync(sf, "utf8"));
    assert.equal(s.state, "rejected");
    assert.equal(s.ncp, 100);
    assert.equal(s.backup, 5000);
});

test("set returns OK but counter unchanged on read-back -> rejected (success line is not proof)", async () => {
    const { guardNwkFrameCounter } = guard();
    const ezsp = fakeEzsp({ ncp: 100, applySet: false });
    const { l, lines } = fakeLogger();
    const r = await guardNwkFrameCounter({ ezsp, backup: backupWith(5000), logger: l, ns: "t", slOk: OK, statusFile: tmpStatus() });
    assert.equal(r.state, "rejected");
    assert.equal(lines.error.length, 1);
});

test("EZSP read throws -> ERROR + status error, no throw", async () => {
    const { guardNwkFrameCounter } = guard();
    const ezsp = { async ezspGetNetworkKeyInfo() { throw new Error("boom"); } };
    const { l, lines } = fakeLogger();
    const r = await guardNwkFrameCounter({ ezsp, backup: backupWith(5000), logger: l, ns: "t", slOk: OK, statusFile: tmpStatus() });
    assert.equal(r.state, "error");
    assert.equal(lines.error.length, 1);
});

test("no backup -> quiet, no set", async () => {
    const { guardNwkFrameCounter } = guard();
    const ezsp = fakeEzsp({ ncp: 1 });
    const { l, lines } = fakeLogger();
    const r = await guardNwkFrameCounter({ ezsp, backup: undefined, logger: l, ns: "t", slOk: OK, statusFile: tmpStatus() });
    assert.equal(r.state, "no-backup");
    assert.deepEqual(ezsp.sets, []);
    assert.equal(lines.warning.length + lines.error.length, 0);
});

// ---- seam: the REAL patched EmberAdapter.initTrustCenter on the DONE path -----------
const NETWORK_KEY = Array.from({ length: 16 }, (_, i) => i + 1);
const EXT_PAN = [1, 2, 3, 4, 5, 6, 7, 8];

function adapterOnDonePath(ezspFake, backupCounter) {
    const { EmberAdapter } = require(path.join(ADAPTER_DIR, "emberAdapter.js"));
    const { SLStatus, EmberNodeType } = require(path.join(HM, "dist", "adapter", "ember", "enums.js"));
    assert.equal(SLStatus.OK, OK);
    const a = Object.create(EmberAdapter.prototype);
    a.networkOptions = { panID: 0x1a62, extendedPanID: EXT_PAN, networkKey: NETWORK_KEY, channelList: [11] };
    a.emberSetEzspPolicy = async () => OK;
    a.emberSetJoinPolicy = async () => OK;
    a.oneWaitress = { startWaitingForEvent: async () => {} };
    a.getStoredBackup = () => (backupCounter === undefined ? undefined : backupWith(backupCounter));
    a.ezsp = Object.assign(ezspFake, {
        async ezspNetworkInit() { return OK; },
        async ezspGetNetworkParameters() {
            return [OK, EmberNodeType.COORDINATOR, { panId: 0x1a62, extendedPanId: EXT_PAN }];
        },
        async ezspExportKey() { return [OK, { contents: Buffer.from(NETWORK_KEY) }]; },
        async ezspLeaveNetwork() { throw new Error("must not leave on the DONE path"); },
    });
    return a;
}

test("seam: patched initTrustCenter (DONE) raises a counter that went backwards", async () => {
    process.env.GA_NWK_GUARD_STATUS_FILE = tmpStatus();
    const ezsp = fakeEzsp({ ncp: 1000060 });
    const a = adapterOnDonePath(ezsp, 1001933);
    const res = await a.initTrustCenter();
    assert.equal(res, "resumed");
    assert.deepEqual(ezsp.sets, [1010125]);
    assert.equal(JSON.parse(fs.readFileSync(process.env.GA_NWK_GUARD_STATUS_FILE, "utf8")).state, "raised");
});

test("seam: patched initTrustCenter (DONE) stays quiet when the counter is ahead", async () => {
    process.env.GA_NWK_GUARD_STATUS_FILE = tmpStatus();
    const ezsp = fakeEzsp({ ncp: 1004109 });
    const a = adapterOnDonePath(ezsp, 1001933);
    assert.equal(await a.initTrustCenter(), "resumed");
    assert.deepEqual(ezsp.sets, []);
    assert.equal(JSON.parse(fs.readFileSync(process.env.GA_NWK_GUARD_STATUS_FILE, "utf8")).state, "ok");
});

test("seam: patched initTrustCenter (DONE) does not crash when the raise is rejected", async () => {
    process.env.GA_NWK_GUARD_STATUS_FILE = tmpStatus();
    const ezsp = fakeEzsp({ ncp: 10, acceptSet: false });
    const a = adapterOnDonePath(ezsp, 5000);
    assert.equal(await a.initTrustCenter(), "resumed");
    assert.equal(JSON.parse(fs.readFileSync(process.env.GA_NWK_GUARD_STATUS_FILE, "utf8")).state, "rejected");
});
