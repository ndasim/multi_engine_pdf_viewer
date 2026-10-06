import { parentPort, workerData } from 'node:worker_threads';

globalThis.self = {
    location: { href: workerData.location },
    postMessage: (value, transfer) => parentPort.postMessage(value, transfer),
    close: () => parentPort.close(),
};
await import('../assets/embedpdf_viewer/worker.mjs');
parentPort.on('message', data => self.onmessage({ data }));