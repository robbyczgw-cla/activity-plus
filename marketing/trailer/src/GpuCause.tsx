// "Find the Cause" (Activity+ 0.2.9): a 36-second film. Every number is from real measurements on an
// M1 Max on 07.10.2026; the run itself is footage Activity+ filmed of its own window (snapshot film mode).
import React from "react";
import { AbsoluteFill, Audio, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig, Easing } from "remotion";
import { Backdrop, Title, MacWindow, Chip, fadeOut, BLUE, VIOLET, INK, DIM, BG, clamp, fontFamily, mono } from "./Trailer";

const PINK = "#FF375F";
const RUN_FRAMES = 441; // footage frames in public/gpu, f-0001.jpg … f-0441.jpg
const RUN_START = 21; // the run starts at footage frame 21 and shows its result at 416
const RUN_END = 416;

export const gpuScenes = [
  { id: "hook", frames: 120 },
  { id: "blame", frames: 150 },
  { id: "why", frames: 165 },
  { id: "run", frames: 330 },
  { id: "result", frames: 180 },
  { id: "end", frames: 150 },
] as const;
type GpuSceneID = (typeof gpuScenes)[number]["id"];
export const gpuTotalFrames = gpuScenes.reduce((sum, s) => sum + s.frames, 0);
const start = (id: GpuSceneID) => {
  let at = 0;
  for (const s of gpuScenes) { if (s.id === id) return at; at += s.frames; }
  return at;
};
const frameFile = (n: number) => `gpu/f-${String(Math.min(RUN_FRAMES, Math.max(1, n))).padStart(4, "0")}.jpg`;

// ─── 1: the GPU is busy ─────────────────────────────────────────────────────

const HookScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const value = Math.round(interpolate(frame, [0, 45], [0, 69], { ...clamp, easing: Easing.out(Easing.cubic) }));
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", opacity: fadeOut(frame, frames) }}>
      <div style={{ fontFamily, fontSize: 40, fontWeight: 600, color: PINK, letterSpacing: 1, opacity: interpolate(frame, [0, 12], [0, 1], clamp) }}>GPU</div>
      <div style={{ fontFamily, fontSize: 230, fontWeight: 800, color: INK, letterSpacing: -10, fontVariantNumeric: "tabular-nums", lineHeight: 1 }}>
        {value}%
      </div>
      <div style={{ height: 36 }} />
      <Title text="No game. No video. Just a few windows open." delay={40} size={56} weight={600} />
    </AbsoluteFill>
  );
};

// ─── 2: and all a monitor shows is WindowServer ─────────────────────────────

// GPU time per process, measured with the driver's own counters before the run.
const processes: [string, string][] = [
  ["WindowServer", "52.6%"], ["Claude Helper", "12.7%"], ["Browser Helper", "0.2%"], ["Steam Helper", "0.0%"], ["Telegram", "0.0%"], ["Finder", "0.0%"],
];

const BlameScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", gap: 54, opacity: fadeOut(frame, frames) }}>
      <Title text="So who is using it?" size={72} />
      <div style={{ width: 900, borderRadius: 20, background: "rgba(20,22,32,0.82)", border: "1px solid rgba(255,255,255,0.1)", padding: "18px 0" }}>
        <div style={{ display: "flex", justifyContent: "space-between", padding: "8px 40px 16px", fontFamily, fontSize: 24, color: DIM }}>
          <span>Process</span><span>GPU time</span>
        </div>
        {processes.map(([name, value], i) => {
          const p = spring({ frame: frame - 14 - i * 5, fps, config: { damping: 200 } });
          const top = i === 0;
          const glow = top ? interpolate(frame, [60, 80], [0, 1], clamp) : 0;
          return (
            <div key={name} style={{
              display: "flex", justifyContent: "space-between", padding: "14px 40px", fontFamily: mono, fontSize: 34,
              color: top ? INK : DIM, opacity: p, transform: `translateY(${(1 - p) * 20}px)`,
              background: `rgba(255,55,95,${0.16 * glow})`, borderLeft: `4px solid rgba(255,55,95,${glow})`,
            }}>
              <span>{name}</span><span style={{ fontVariantNumeric: "tabular-nums" }}>{value}</span>
            </div>
          );
        })}
      </div>
      <div style={{ height: 70 }}>
        <Title text="WindowServer. That's all it tells you." delay={78} size={52} weight={600} color={DIM} />
      </div>
    </AbsoluteFill>
  );
};

// ─── 3: why ─────────────────────────────────────────────────────────────────

const Box: React.FC<{ label: string; delay: number; color?: string; wide?: boolean }> = ({ label, delay, color = "rgba(255,255,255,0.18)", wide }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 16, mass: 0.7 } });
  return (
    <div style={{
      fontFamily, fontSize: wide ? 44 : 34, fontWeight: 600, color: INK, padding: wide ? "26px 54px" : "20px 34px", borderRadius: 18,
      background: "rgba(20,22,32,0.85)", border: `2px solid ${color}`, opacity: Math.min(1, p * 1.3), transform: `scale(${0.7 + 0.3 * p})`,
      boxShadow: wide ? `0 0 60px ${color}55` : "none", whiteSpace: "nowrap",
    }}>{label}</div>
  );
};

const Arrow: React.FC<{ delay: number }> = ({ delay }) => {
  const frame = useCurrentFrame();
  const p = interpolate(frame, [delay, delay + 14], [0, 1], clamp);
  return <div style={{ width: 4, height: 70 * p, background: `linear-gradient(${BLUE}, ${VIOLET})`, borderRadius: 2, margin: "0 auto" }} />;
};

const WhyScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", opacity: fadeOut(frame, frames) }}>
      <div style={{ display: "flex", gap: 30 }}>
        <Box label="Steam" delay={0} />
        <Box label="Browser" delay={5} />
        <Box label="Chat app" delay={10} />
        <Box label="Music player" delay={15} />
      </div>
      <div style={{ height: 14 }} />
      <Arrow delay={24} />
      <div style={{ height: 14 }} />
      <Box label="WindowServer" delay={36} color={PINK} wide />
      <div style={{ height: 14 }} />
      <Arrow delay={48} />
      <div style={{ height: 14 }} />
      <Box label="GPU" delay={58} color={BLUE} />
      <div style={{ height: 60 }} />
      <Title text="Most apps hand their windows to WindowServer." delay={70} size={50} weight={600} />
      <div style={{ height: 12 }} />
      <Title text="Their GPU work is counted there." delay={92} size={50} weight={600} color={DIM} />
    </AbsoluteFill>
  );
};

// ─── 4: the real run, sped up ───────────────────────────────────────────────

const RunScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const lead = 30; // the button, before the footage moves
  const footage = Math.round(interpolate(frame, [lead, frames - 20], [RUN_START, RUN_END], clamp));
  const shown = frame < lead ? frameFile(RUN_START - 1) : frameFile(footage);
  const enter = spring({ frame, fps, config: { damping: 200 } });
  const speed = Math.round(((RUN_END - RUN_START) / 4.3) / ((frames - 20 - lead) / fps)); // footage was ~4.3 frames per second
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames, 8) }}>
      <div style={{ position: "absolute", top: 60, width: "100%" }}>
        <Title text="Find the Cause" size={64} gradient />
      </div>
      <div style={{ position: "absolute", left: 160, top: 170, transform: `translateY(${(1 - enter) * 60}px)`, opacity: enter }}>
        <MacWindow src={shown} width={1200} />
      </div>
      <Chip text="Hides one app at a time" delay={lead + 10} style={{ right: 70, top: 330 }} color={VIOLET} />
      <Chip text="Measures WindowServer" delay={lead + 40} style={{ right: 70, top: 440 }} color={PINK} />
      <Chip text="Shows it again" delay={lead + 70} style={{ right: 70, top: 550 }} color={BLUE} />
      <div style={{ position: "absolute", right: 90, bottom: 110, fontFamily: mono, fontSize: 30, color: DIM,
        opacity: interpolate(frame, [lead, lead + 15], [0, 1], clamp) }}>
        real run · {speed}× speed
      </div>
    </AbsoluteFill>
  );
};

// ─── 5: the answer ──────────────────────────────────────────────────────────

const ResultScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame, fps, config: { damping: 200 } });
  const ring = spring({ frame: frame - 30, fps, config: { damping: 14 } });
  // The result card of the last footage frame at full size: footage rows 540–890 (Steam's row is 680–765).
  const top = 540;
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", top: 70, width: "100%" }}>
        <Title text="The answer" size={60} gradient />
      </div>
      <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
        <div style={{ width: 1680, height: 333, overflow: "hidden", borderRadius: 18, position: "relative", background: "#f5f5f7",
          boxShadow: "0 60px 140px rgba(0,0,0,0.65), 0 0 0 1px rgba(255,255,255,0.12)",
          opacity: enter, transform: `translateY(${-40 + (1 - enter) * 50}px) scale(${0.94 + 0.06 * enter})` }}>
          <Img src={staticFile(frameFile(RUN_FRAMES))} style={{ position: "absolute", width: 1700, left: -4, top: -top }} />
          <div style={{ position: "absolute", left: 14, right: 14, top: 680 - top - 10, height: 105, borderRadius: 14,
            border: `4px solid ${PINK}`, opacity: ring, transform: `scale(${0.94 + 0.06 * ring})`, boxShadow: `0 0 50px ${PINK}88` }} />
        </div>
      </AbsoluteFill>
      <div style={{ position: "absolute", bottom: 150, width: "100%" }}>
        <Title text="Steam. Its window is a built-in browser that never stops redrawing." delay={45} size={46} weight={600} />
      </div>
      <div style={{ position: "absolute", bottom: 90, width: "100%" }}>
        <Title text="Hidden for a moment, WindowServer drops from 52% to 21%." delay={75} size={34} weight={500} color={DIM} />
      </div>
    </AbsoluteFill>
  );
};

// ─── 6: end card ────────────────────────────────────────────────────────────

const EndScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame, fps, config: { damping: 12, mass: 0.9 } });
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column" }}>
      <Img src={staticFile("icon.png")} style={{ width: 200, height: 200, transform: `scale(${icon})`, filter: "drop-shadow(0 30px 60px rgba(79,125,255,0.45))" }} />
      <div style={{ height: 26 }} />
      <Title text="Activity+ 0.2.9" size={110} weight={800} delay={10} />
      <div style={{ height: 14 }} />
      <Title text="Find the Cause, on the GPU page." size={44} weight={500} color={DIM} delay={26} />
      <div style={{ height: 54 }} />
      <div style={{ fontFamily, fontSize: 44, fontWeight: 700, opacity: interpolate(frame, [45, 65], [0, 1], clamp),
        backgroundImage: `linear-gradient(90deg, ${BLUE}, ${VIOLET})`, WebkitBackgroundClip: "text", color: "transparent" }}>
        activityplus.xyz
      </div>
      <div style={{ fontFamily, fontSize: 26, color: DIM, marginTop: 14, opacity: interpolate(frame, [55, 75], [0, 1], clamp) }}>
        Free and open source · macOS 15 or later · Apple silicon
      </div>
    </AbsoluteFill>
  );
};

const component = (id: GpuSceneID, frames: number): React.ReactNode => {
  switch (id) {
    case "hook": return <HookScene frames={frames} />;
    case "blame": return <BlameScene frames={frames} />;
    case "why": return <WhyScene frames={frames} />;
    case "run": return <RunScene frames={frames} />;
    case "result": return <ResultScene frames={frames} />;
    case "end": return <EndScene />;
  }
};

export const GpuCause: React.FC<{ music: boolean }> = ({ music }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const volume = interpolate(frame, [0, 20, durationInFrames - 45, durationInFrames], [0, 0.8, 0.8, 0], clamp);
  return (
    <AbsoluteFill style={{ background: BG }}>
      <Backdrop />
      {gpuScenes.map((s) => (
        <Sequence key={s.id} from={start(s.id)} durationInFrames={s.frames}>{component(s.id, s.frames)}</Sequence>
      ))}
      {music && <Audio src={staticFile("audio/music.mp3")} volume={() => volume} />}
    </AbsoluteFill>
  );
};
