#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const cliArguments = process.argv.slice(2);
const reload = cliArguments.includes("--reload");
const [secondsArgument, outputArgument, portArgument = "9222"] = cliArguments.filter(
    (argument) => argument !== "--reload"
);
const durationSeconds = Number(secondsArgument);
const debugPort = Number(portArgument);

if (!Number.isFinite(durationSeconds) || durationSeconds <= 0 || !outputArgument || !Number.isInteger(debugPort)) {
    console.error("Usage: node workerprofile.mjs <seconds> <output-directory> [debug-port] [--reload]");
    process.exit(2);
}

class CdpClient {
    #socket;
    #nextId = 1;
    #pending = new Map();
    #listeners = new Map();

    static async connect(url) {
        const client = new CdpClient();
        await client.#open(url);
        return client;
    }

    async #open(url) {
        this.#socket = new WebSocket(url);
        await new Promise((resolveOpen, rejectOpen) => {
            this.#socket.addEventListener("open", resolveOpen, { once: true });
            this.#socket.addEventListener("error", rejectOpen, { once: true });
        });
        this.#socket.addEventListener("message", (event) => this.#receive(String(event.data)));
        this.#socket.addEventListener("close", () => this.#rejectPending(new Error("CDP socket closed")));
    }

    on(method, listener) {
        const listeners = this.#listeners.get(method) ?? new Set();
        listeners.add(listener);
        this.#listeners.set(method, listeners);
    }

    send(method, params = {}, sessionId) {
        const id = this.#nextId++;
        const message = { id, method };
        if (Object.keys(params).length > 0) message.params = params;
        if (sessionId) message.sessionId = sessionId;

        return new Promise((resolveResponse, rejectResponse) => {
            this.#pending.set(id, { resolve: resolveResponse, reject: rejectResponse });
            this.#socket.send(JSON.stringify(message));
        });
    }

    close() {
        this.#socket.close();
    }

    #receive(raw) {
        const message = JSON.parse(raw);
        if (message.id) {
            const pending = this.#pending.get(message.id);
            if (!pending) return;
            this.#pending.delete(message.id);
            if (message.error) pending.reject(new Error(`${message.error.code}: ${message.error.message}`));
            else pending.resolve(message.result ?? {});
            return;
        }
        for (const listener of this.#listeners.get(message.method) ?? []) {
            listener(message.params ?? {});
        }
    }

    #rejectPending(error) {
        for (const pending of this.#pending.values()) pending.reject(error);
        this.#pending.clear();
    }
}

const delay = (milliseconds) => new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
const targets = await fetch(`http://127.0.0.1:${debugPort}/json/list`).then((response) => {
    if (!response.ok) throw new Error(`DevTools target discovery failed: HTTP ${response.status}`);
    return response.json();
});
const page = targets.find((target) => target.type === "page" && target.webSocketDebuggerUrl);
if (!page) throw new Error("No inspectable WebView page found. Open the harness before collecting a profile.");

const outputDirectory = resolve(outputArgument);
await mkdir(outputDirectory, { recursive: true });
const cdp = await CdpClient.connect(page.webSocketDebuggerUrl);
const sessions = new Map();
let collecting = true;

async function startSession(sessionId, targetInfo) {
    if (!collecting || sessions.has(sessionId)) return;
    try {
        await cdp.send("Profiler.enable", {}, sessionId);
        await cdp.send("Profiler.start", {}, sessionId);
        sessions.set(sessionId, targetInfo);
    } catch (error) {
        console.error(`Could not profile ${targetInfo.type} ${targetInfo.url}: ${error.message}`);
    }
}

cdp.on("Target.attachedToTarget", ({ sessionId, targetInfo }) => {
    if (targetInfo.type === "worker") void startSession(sessionId, targetInfo);
});
cdp.on("Target.detachedFromTarget", ({ sessionId }) => {
    sessions.delete(sessionId);
});
await cdp.send("Target.setAutoAttach", {
    autoAttach: true,
    waitForDebuggerOnStart: false,
    flatten: true,
});
await cdp.send("Profiler.enable");
await cdp.send("Profiler.start");

if (reload) {
    await cdp.send("Runtime.evaluate", { expression: "location.reload()" });
}
console.error(
    reload
        ? `Collecting ${durationSeconds}s from ${page.url} after a CDP-triggered reload.`
        : `Collecting ${durationSeconds}s from ${page.url}. Reload the fixture now to capture a viewer open.`
);
await delay(durationSeconds * 1000);
collecting = false;

const profiles = [];
const pageProfile = await cdp.send("Profiler.stop");
profiles.push({ name: "page", target: page, profile: pageProfile.profile });
for (const [sessionId, targetInfo] of sessions) {
    try {
        const result = await cdp.send("Profiler.stop", {}, sessionId);
        profiles.push({ name: "worker", target: targetInfo, profile: result.profile });
    } catch (error) {
        console.error(`Could not stop ${targetInfo.type} ${targetInfo.url}: ${error.message}`);
    }
}

const summary = {
    collectedAt: new Date().toISOString(),
    durationSeconds,
    page: { title: page.title, url: page.url },
    profiles: [],
};
for (const [index, entry] of profiles.entries()) {
    const filename = `${entry.name}-${index + 1}.cpuprofile`;
    await writeFile(join(outputDirectory, filename), JSON.stringify(entry.profile));
    summary.profiles.push({
        file: filename,
        type: entry.target.type,
        title: entry.target.title,
        url: entry.target.url,
    });
}
await writeFile(join(outputDirectory, "summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
cdp.close();
console.error(`Wrote ${profiles.length} CPU profiles to ${outputDirectory}.`);