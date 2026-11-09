#!/usr/bin/env node
// Adds the exact deploy block and transaction hash to contracts/deployments/<chainId>.json,
// reading Foundry's broadcast log. Run after `forge script script/Deploy.s.sol --broadcast`.
// Usage: node scripts/record-deployment.mjs [chainId]
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "contracts");
const chainId = process.argv[2] ?? "4663";
const runPath = join(root, "broadcast", "Deploy.s.sol", chainId, "run-latest.json");
const outPath = join(root, "deployments", `${chainId}.json`);

const run = JSON.parse(readFileSync(runPath, "utf8"));
const tx = run.transactions.find((t) => t.contractName === "FlatCircleFactory" && t.transactionType === "CREATE");
if (!tx) throw new Error("No FlatCircleFactory CREATE transaction in the broadcast log");
const receipt = run.receipts.find((r) => r.transactionHash === tx.hash);
if (!receipt) throw new Error("No receipt for the deploy transaction yet");
if (receipt.status !== "0x1") throw new Error(`Deploy transaction failed: ${tx.hash}`);

const out = JSON.parse(readFileSync(outPath, "utf8"));
if (out.factory.toLowerCase() !== tx.contractAddress.toLowerCase()) {
  throw new Error(`Address mismatch: deployments says ${out.factory}, broadcast says ${tx.contractAddress}`);
}
out.deployBlock = Number(BigInt(receipt.blockNumber));
out.deployTxHash = tx.hash;
out.deployer = tx.transaction.from;
writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
console.log(JSON.stringify(out, null, 2));
