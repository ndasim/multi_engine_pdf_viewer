#!/usr/bin/env node
import { access, copyFile } from "node:fs/promises";
import { basename, resolve } from "node:path";

const sourceFile = resolve(process.argv[2] ?? "../../../6474643.pdf");
const destinationFile = resolve("assets/6474643.pdf");

if (basename(sourceFile) !== "6474643.pdf") {
    throw new Error(`Expected a file named 6474643.pdf, received: ${sourceFile}`);
}

await access(sourceFile);
await copyFile(sourceFile, destinationFile);
console.log(`Copied fixture to ${destinationFile}`);