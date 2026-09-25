// Generates the voice-over with xAI TTS, one file per scene.
// Usage: XAI_TOKEN=$(pi auth print-bearer-token --model grok-4.7) node voices/xai.mjs [voice] [outDir]
import { writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";

const voice = process.argv[2] ?? "eve";
const outDir = process.argv[3] ?? "public/audio/xai";
const source = readFileSync(new URL("../src/script.ts", import.meta.url), "utf8");
const scenes = [...source.matchAll(/id: "(\w+)",.*?voice: "([^"]+)"/g)].map((m) => ({ id: m[1], text: m[2] }));

for (const scene of scenes) {
  const response = await fetch("https://api.x.ai/v1/tts", {
    method: "POST",
    headers: { Authorization: `Bearer ${process.env.XAI_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ text: scene.text, voice_id: voice, language: "en",
      output_format: { codec: "mp3", sample_rate: 44100, bit_rate: 128000 } }),
  });
  if (!response.ok) { console.error(scene.id, response.status, await response.text()); process.exit(1); }
  await writeFile(`${outDir}/${scene.id}.mp3`, Buffer.from(await response.arrayBuffer()));
  console.log("ok", scene.id);
}
