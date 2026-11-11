// Tests for the GA external converters (Odoo #1934). Run by run.sh against the REAL
// zigbee-herdsman-converters version Zigbee2MQTT pins, with the LIVE converter files
// from common/ga-converters (run.sh stages them next to node_modules and proves the
// staged bytes equal the live ones). GA_SKIP_CONVERTERS=1 runs the same assertions
// WITHOUT loading the converters (red proof: must fail).
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import zhc from "zigbee-herdsman-converters";

const STAGE = process.env.GA_STAGE;
const FIX = JSON.parse(fs.readFileSync(process.env.GA_FIXTURES, "utf8"));
const SKIP = process.env.GA_SKIP_CONVERTERS === "1";
const files = fs.readdirSync(STAGE).filter((f) => f.endsWith(".mjs")).sort();

const fake = ({ modelID, manufacturerName }) => ({
    modelID, manufacturerName, type: "Router", endpoints: [], getEndpoint: () => undefined,
});
async function resolve(dev) {
    const d = await zhc.findByDevice(fake(dev));
    assert.ok(d, `no definition for ${dev.modelID}/${dev.manufacturerName}`);
    const ex = typeof d.exposes === "function" ? d.exposes(fake(dev), {}) : d.exposes;
    const props = new Set();
    const walk = (a) => a.forEach((x) => { if (x.property) props.add(x.property); if (x.features) walk(x.features); });
    walk(ex);
    return { model: d.model, props: [...props].sort() };
}

// Baseline BEFORE any external definition is added.
const baseline = new Map();
for (const c of FIX.controls) baseline.set(JSON.stringify(c), await resolve(c));
const builtin = new Map();
for (const [f, e] of Object.entries(FIX.converters)) builtin.set(f, await resolve(e.match));

if (!SKIP) {
    for (const f of files) zhc.addExternalDefinition((await import(path.join(STAGE, f))).default);
}

test("the control list is not empty (a vacuous control check proves nothing)", () => {
    assert.ok(Array.isArray(FIX.controls) && FIX.controls.length > 0, "no control devices in fixtures.json");
});

test("every shipped converter has a fixture entry (coverage, fails closed)", () => {
    assert.ok(files.length > 0, "no converter shipped — nothing inspected");
    for (const f of files) assert.ok(FIX.converters[f], `no fixture entry for ${f}`);
});

for (const [f, e] of Object.entries(FIX.converters)) {
    test(`${f}: ${e.match.modelID}/${e.match.manufacturerName} resolves to ${e.model} and adds ${e.adds.join(",")}`, async () => {
        assert.equal(builtin.get(f).model, e.builtin_model, "built-in baseline changed — re-check the converter against the new zhc");
        const got = await resolve(e.match);
        assert.equal(got.model, e.model);
        for (const p of e.adds) assert.ok(got.props.includes(p), `missing ${p}`);
        for (const p of builtin.get(f).props) assert.ok(got.props.includes(p), `built-in property ${p} was lost`);
        const extra = got.props.filter((p) => !builtin.get(f).props.includes(p)).sort();
        assert.deepEqual(extra, [...e.adds].sort(), "converter adds more than the fixture declares");
    });
}

for (const c of FIX.controls) {
    test(`control ${c.modelID}/${c.manufacturerName} unchanged (${c.why})`, async () => {
        assert.deepEqual(await resolve(c), baseline.get(JSON.stringify(c)));
    });
}
