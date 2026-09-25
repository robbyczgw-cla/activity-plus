// Generates the voice-over with ElevenLabs, one file per scene.
// Usage: ELEVENLABS_API_KEY=$(cat ~/.config/activityplus/elevenlabs.key) node voices/eleven.mjs [voiceId] [outDir]
import { writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";

const voice = process.argv[2] ?? "cjVigY5qzO86Huf0OWal"; // Eric – smooth, trustworthy
const outDir = process.argv[3] ?? "public/audio/eleven";
const source = readFileSync(new URL("../src/script.ts", import.meta.url), "utf8");
const scenes = [...source.matchAll(/id: "(\w+)",.*?voice: "([^"]+)"/g)].map((m) => ({ id: m[1], text: m[2] }));

let previous = "";
for (const scene of scenes) {
  const response = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voice}?output_format=mp3_44100_128`, {
    method: "POST",
    headers: { "xi-api-key": process.env.ELEVENLABS_API_KEY, "Content-Type": "application/json" },
    // previous_text keeps the delivery consistent from line to line.
    body: JSON.stringify({ text: scene.text, model_id: "eleven_multilingual_v2", previous_text: previous,
      voice_settings: { stability: 0.55, similarity_boost: 0.8, style: 0.15, use_speaker_boost: true } }),
  });
  if (!response.ok) { console.error(scene.id, response.status, await response.text()); process.exit(1); }
  await writeFile(`${outDir}/${scene.id}.mp3`, Buffer.from(await response.arrayBuffer()));
  previous = scene.text;
  console.log("ok", scene.id);
}
