// The trailer's words: on-screen titles and the voice-over, one entry per scene.
// Scene lengths are in frames at 30 fps; the voice-over for a scene starts `voiceAt` frames in.
export const FPS = 30;

export type SceneID = "noise" | "fold" | "overview" | "diagnosis" | "menubar" | "features" | "agents" | "privacy" | "logo";

export const scenes: { id: SceneID; frames: number; voice: string; voiceAt: number }[] = [
  { id: "noise", frames: 165, voiceAt: 20, voice: "Your Mac runs hundreds of processes. Which one is slowing it down?" },
  { id: "fold", frames: 180, voiceAt: 10, voice: "Activity Plus groups every process under the app it belongs to." },
  { id: "overview", frames: 270, voiceAt: 10, voice: "CPU, memory, GPU, disk, network and energy, per app, live, with thirty days of history." },
  { id: "diagnosis", frames: 180, voiceAt: 10, voice: "Ask why your Mac is slow, and get an answer in plain words, with a fix." },
  { id: "menubar", frames: 225, voiceAt: 10, voice: "Build the menu bar you want. As many items as you like, in eleven styles." },
  { id: "features", frames: 285, voiceAt: 10, voice: "Alerts that learn what is normal. Dev servers by project. Drive health, every sensor, and automations that ask first." },
  { id: "agents", frames: 180, voiceAt: 10, voice: "Your AI agents can ask, too." },
  { id: "privacy", frames: 165, voiceAt: 10, voice: "No account. No analytics. Everything stays on your Mac." },
  { id: "logo", frames: 195, voiceAt: 15, voice: "Activity Plus. Free, for macOS." },
];

export const totalFrames = scenes.reduce((sum, scene) => sum + scene.frames, 0);

export function sceneStart(id: SceneID): number {
  let start = 0;
  for (const scene of scenes) {
    if (scene.id === id) return start;
    start += scene.frames;
  }
  return start;
}
