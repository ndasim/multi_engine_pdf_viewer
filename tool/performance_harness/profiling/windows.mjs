#!/usr/bin/env node
import { readFile } from "node:fs/promises";

const [profilePath, startArgument = "0", endArgument] = process.argv.slice(2);
const startMilliseconds = Number(startArgument);
if (!profilePath || !Number.isFinite(startMilliseconds) || startMilliseconds < 0) {
    console.error("Usage: node windows.mjs <profile.cpuprofile> [start-ms] [end-ms]");
    process.exit(2);
}

const profile = JSON.parse(await readFile(profilePath, "utf8"));
if (!Array.isArray(profile.nodes) || !Array.isArray(profile.samples) || !Array.isArray(profile.timeDeltas)) {
    throw new Error("The input is not a sampled Chrome CPU profile.");
}

const endMilliseconds = endArgument === undefined ? (profile.endTime - profile.startTime) / 1000 : Number(endArgument);
if (!Number.isFinite(endMilliseconds) || endMilliseconds <= startMilliseconds) {
    throw new Error("The end of the window must be greater than its start.");
}

const nodeById = new Map(profile.nodes.map((node) => [node.id, node]));
const parentById = new Map();
for (const node of profile.nodes) {
    for (const childId of node.children ?? []) parentById.set(childId, node.id);
}

const startUs = profile.startTime + startMilliseconds * 1000;
const endUs = profile.startTime + endMilliseconds * 1000;
let sampleTimeUs = profile.startTime;
let selectedUs = 0;
const inclusiveUs = new Map();

for (let index = 0; index < profile.samples.length; index++) {
    const deltaUs = profile.timeDeltas[index] ?? 0;
    const nextSampleTimeUs = sampleTimeUs + deltaUs;
    const overlapUs = Math.max(0, Math.min(nextSampleTimeUs, endUs) - Math.max(sampleTimeUs, startUs));
    if (overlapUs > 0) {
        selectedUs += overlapUs;
        let nodeId = profile.samples[index];
        while (nodeId !== undefined) {
            inclusiveUs.set(nodeId, (inclusiveUs.get(nodeId) ?? 0) + overlapUs);
            nodeId = parentById.get(nodeId);
        }
    }
    sampleTimeUs = nextSampleTimeUs;
}

const labelFor = (node) => {
    const frame = node.callFrame ?? {};
    const name = frame.functionName || "(anonymous)";
    const location = frame.url ? ` ${frame.url}:${(frame.lineNumber ?? -1) + 1}` : "";
    return `${name}${location}`;
};
const rows = [...inclusiveUs.entries()]
    .map(([nodeId, timeUs]) => ({
        function: labelFor(nodeById.get(nodeId)),
        milliseconds: Number((timeUs / 1000).toFixed(1)),
        percent: Number((selectedUs === 0 ? 0 : (timeUs * 100 / selectedUs)).toFixed(1)),
    }))
    .sort((left, right) => right.milliseconds - left.milliseconds)
    .slice(0, 25);

console.log(`Window ${startMilliseconds}ms to ${endMilliseconds}ms, sampled ${Math.round(selectedUs / 1000)}ms.`);
console.table(rows);