import { readFileSync, writeFileSync } from "node:fs";

const [inputPath, outputPath] = process.argv.slice(2);
if (!inputPath || !outputPath) {
  throw new Error("Usage: node make-icns.mjs INPUT.png OUTPUT.icns");
}

const png = readFileSync(inputPath);
const chunkLength = 8 + png.length;
const result = Buffer.alloc(8 + chunkLength);
result.write("icns", 0, "ascii");
result.writeUInt32BE(result.length, 4);
result.write("ic10", 8, "ascii");
result.writeUInt32BE(chunkLength, 12);
png.copy(result, 16);
writeFileSync(outputPath, result);
