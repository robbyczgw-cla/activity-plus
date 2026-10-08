// Activity+ 0.3.0: "why was it slow". Storage, SSD, Wi-Fi and the menu bar capture are real readings from an M1 Max
// (08.10.2026); the history day and the call stack are labeled as examples on screen.
import React from "react";
import { AbsoluteFill, Audio, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig, Easing } from "remotion";
import { Backdrop, Title, Chip, fadeOut, BLUE, VIOLET, INK, DIM, BG, clamp, fontFamily, mono } from "./Trailer";

const ORANGE = "#FF9F0A";
const PINK = "#FF375F";

export const releaseScenes = [
  { id: "hook", frames: 120 },
  { id: "conditions", frames: 240 },
  { id: "freeze", frames: 180 },
  { id: "storage", frames: 150 },
  { id: "ssd", frames: 150 },
  { id: "menubar", frames: 240 },
  { id: "extras", frames: 150 },
  { id: "end", frames: 165 },
] as const;
type SceneID = (typeof releaseScenes)[number]["id"];
export const releaseTotalFrames = releaseScenes.reduce((sum, s) => sum + s.frames, 0);
const start = (id: SceneID) => {
  let at = 0;
  for (const s of releaseScenes) { if (s.id === id) return at; at += s.frames; }
  return at;
};

/** A card screenshot on a soft panel, rising in. */
const Shot: React.FC<{ src: string; width: number; delay?: number; style?: React.CSSProperties }> = ({ src, width, delay = 0, style }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 200 } });
  return (
    <div style={{ width, borderRadius: 22, overflow: "hidden", background: "#f5f5f7", opacity: p,
      transform: `translateY(${(1 - p) * 50}px) scale(${0.96 + 0.04 * p})`,
      boxShadow: "0 60px 140px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.12)", ...style }}>
      <Img src={staticFile(src)} style={{ width: "100%", display: "block" }} />
    </div>
  );
};

const Tag: React.FC<{ text: string }> = ({ text }) => (
  <div style={{ position: "absolute", right: 70, bottom: 60, fontFamily: mono, fontSize: 24, color: DIM }}>{text}</div>
);

// ─── 1 ──────────────────────────────────────────────────────────────────────

const HookScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", gap: 30, opacity: fadeOut(frame, frames) }}>
      <Title text="Your Mac was slow at 3 PM." size={92} />
      <Title text="Now you can find out why." size={64} weight={600} gradient delay={40} />
    </AbsoluteFill>
  );
};

// ─── 2 ──────────────────────────────────────────────────────────────────────

const ConditionsScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const ring = spring({ frame: frame - 70, fps, config: { damping: 14 } });
  // Image 1660×1180 shown at 1180 wide: scale 0.711. The spike and the hot stretch sit at x≈265–390 of the image.
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", top: 56, width: "100%" }}>
        <Title text="Heat, memory pressure and Wi-Fi, minute by minute" size={52} />
      </div>
      <div style={{ position: "absolute", left: 370, top: 170 }}>
        <Shot src="v030/history.png" width={1180} />
        <div style={{ position: "absolute", left: 180, top: 70, width: 120, height: 720, borderRadius: 14,
          border: `4px solid ${PINK}`, opacity: ring, boxShadow: `0 0 50px ${PINK}88`, transform: `scale(${0.95 + 0.05 * ring})` }} />
      </div>
      <div style={{ position: "absolute", left: 70, top: 470, width: 280 }}>
        <Title text="The spike lines up with heat and tight memory." size={40} weight={600} align="left" delay={95} />
      </div>
      <Tag text="sample day" />
    </AbsoluteFill>
  );
};

// ─── 3 ──────────────────────────────────────────────────────────────────────

const stack = ["-[NoteController save:]", "-[NSData initWithContentsOfFile:]", "read"];

const FreezeScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", gap: 50, opacity: fadeOut(frame, frames) }}>
      <Title text="When an app freezes, you see where it was stuck." size={60} />
      <div style={{ width: 1100, borderRadius: 20, background: "rgba(20,22,32,0.85)", border: "1px solid rgba(255,255,255,0.1)", padding: "30px 40px" }}>
        <div style={{ fontFamily, fontSize: 30, fontWeight: 600, color: INK, marginBottom: 18 }}>
          Notes stopped responding <span style={{ color: DIM, fontWeight: 500 }}>· froze for 9 seconds</span>
        </div>
        {stack.map((line, i) => {
          const p = spring({ frame: frame - 30 - i * 14, fps, config: { damping: 200 } });
          const last = i === stack.length - 1;
          return (
            <div key={line} style={{ fontFamily: mono, fontSize: 32, color: last ? ORANGE : DIM, opacity: p,
              transform: `translateX(${(1 - p) * 30}px)`, padding: "6px 0", paddingLeft: i * 36 }}>
              {i > 0 ? "↳ " : ""}{line}
            </div>
          );
        })}
      </div>
      <div style={{ fontFamily, fontSize: 30, color: DIM, opacity: interpolate(frame, [80, 100], [0, 1], clamp) }}>
        Three seconds of call stacks, recorded while it hangs. Stored on your Mac.
      </div>
      <Tag text="example" />
    </AbsoluteFill>
  );
};

// ─── 4 & 5 ──────────────────────────────────────────────────────────────────

const CardScene: React.FC<{ frames: number; title: string; sub: string; src: string; width: number }> = ({ frames, title, sub, src, width }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", gap: 46, opacity: fadeOut(frame, frames) }}>
      <Title text={title} size={70} />
      <Shot src={src} width={width} delay={10} />
      <Title text={sub} size={34} weight={500} color={DIM} delay={40} />
    </AbsoluteFill>
  );
};

// ─── 6: menu bar and the notch ──────────────────────────────────────────────

const values: [string, string][] = [["CPU", "43%"], ["MEM", "74%"], ["GPU", "82%"], ["SSD", "125 GB"], ["NET", "16 kB/s"], ["TEMP", "54°"], ["FAN", "2310"], ["PWR", "18 W"]];

const Item: React.FC<{ label: string; value: string }> = ({ label, value }) => (
  <div style={{ display: "flex", flexDirection: "column", alignItems: "flex-start", lineHeight: 1 }}>
    <span style={{ fontFamily, fontSize: 15, fontWeight: 600, color: "rgba(255,255,255,0.75)" }}>{label}</span>
    <span style={{ fontFamily, fontSize: 25, fontWeight: 600, color: "#fff", fontVariantNumeric: "tabular-nums" }}>{value}</span>
  </div>
);

// Rough rendered width of a label/value stack at these font sizes.
const itemWidth = ([label, value]: [string, string]) => Math.max(label.length * 11, value.length * 15.5) + 6;

const MenuBarScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  // Phase 1 (0–95): items arrive one by one and pile up at the notch. Phase 2 (105–140): five merge into one.
  const merge = interpolate(frame, [105, 140], [0, 1], { ...clamp, easing: Easing.inOut(Easing.cubic) });
  const barY = 330, notchX = 760, notchW = 400, gap = 34, combinedGap = 16;
  // Separate layout: right to left from the bar's right edge.
  const separate: number[] = [];
  let cursor = 1740;
  for (const v of values) { cursor -= itemWidth(v); separate.push(cursor); cursor -= gap; }
  // Combined layout: the first five side by side, just right of the notch.
  const combined: number[] = [];
  let left = notchX + notchW + 40;
  for (const v of values.slice(0, 5)) { combined.push(left); left += itemWidth(v) + combinedGap; }
  const combinedWidth = left - combinedGap - (notchX + notchW + 40);
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", top: 100, width: "100%" }}>
        <Title text={merge < 0.5 ? "Too many items for the notch?" : "They become one."} size={62} />
      </div>
      <div style={{ position: "absolute", left: 160, right: 160, top: barY, height: 64, borderRadius: 16, background: "#111318",
        boxShadow: "0 40px 100px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.1)" }} />
      <div style={{ position: "absolute", left: notchX, top: barY - 2, width: notchW, height: 74, borderRadius: "0 0 26px 26px", background: "#000", zIndex: 3 }} />
      {values.map((v, i) => {
        const [label, value] = v;
        const arrive = interpolate(frame, [i * 10, i * 10 + 14], [0, 1], { ...clamp, easing: Easing.out(Easing.cubic) });
        const piled = separate[i] < notchX + notchW + 10;
        // macOS piles items that don't fit at one spot by the notch, where they can't be seen.
        const separateX = piled ? notchX + notchW - 60 : separate[i];
        const x = interpolate(arrive, [0, 1], [1800, separateX]) * (1 - merge) + (i < 5 ? combined[i] : separateX) * merge;
        const dim = piled ? interpolate(frame, [i * 10 + 14, i * 10 + 24], [1, 0.2], clamp) : 1;
        const opacity = i < 5 ? arrive * (dim + (1 - dim) * merge) : arrive * dim * (1 - merge);
        return (
          <div key={label} style={{ position: "absolute", left: x, top: barY + 12, opacity, zIndex: piled && merge < 0.3 ? 2 : 4 }}>
            <Item label={label} value={value} />
          </div>
        );
      })}
      <div style={{ position: "absolute", left: notchX + notchW + 28, top: barY + 6, width: combinedWidth + 24, height: 52, borderRadius: 12,
        border: `2px solid ${BLUE}`, opacity: interpolate(merge, [0.6, 1], [0, 1], clamp), boxShadow: `0 0 40px ${BLUE}66`, zIndex: 1 }} />
      <div style={{ position: "absolute", top: 470, width: "100%", textAlign: "center", fontFamily, fontSize: 34, color: DIM,
        opacity: interpolate(frame, [150, 170], [0, 1], clamp) }}>
        Activity+ notices hidden items and combines them. A click on a value opens its tab.
      </div>
      <div style={{ position: "absolute", top: 540, width: "100%", textAlign: "center", fontFamily, fontSize: 28, color: DIM,
        opacity: interpolate(frame, [175, 195], [0, 1], clamp) }}>
        Separate, combined, or combined only when they don't fit: your choice.
      </div>
    </AbsoluteFill>
  );
};

// ─── 7 ──────────────────────────────────────────────────────────────────────

const ExtrasScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", top: 110, width: "100%" }}>
        <Title text="And a few more things" size={64} />
      </div>
      <div style={{ position: "absolute", left: 220, top: 330 }}>
        <Shot src="v030/wifi.png" width={620} delay={10} />
        <div style={{ fontFamily, fontSize: 28, color: DIM, marginTop: 20 }}>Wi-Fi noise next to the signal</div>
      </div>
      <Chip text="An alert when your VPN drops" delay={40} style={{ left: 1000, top: 320 }} color={VIOLET} />
      <Chip text="A warning when a USB cable slows your drive" delay={65} style={{ left: 1000, top: 430 }} color={ORANGE} />
      <Chip text="Freezes caught after 6 s, not 20" delay={90} style={{ left: 1000, top: 540 }} color={PINK} />
    </AbsoluteFill>
  );
};

// ─── 8 ──────────────────────────────────────────────────────────────────────

const EndScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame, fps, config: { damping: 12, mass: 0.9 } });
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column" }}>
      <Img src={staticFile("icon.png")} style={{ width: 190, height: 190, transform: `scale(${icon})`, filter: "drop-shadow(0 30px 60px rgba(79,125,255,0.45))" }} />
      <div style={{ height: 24 }} />
      <Title text="Activity+ 0.3" size={112} weight={800} delay={10} />
      <div style={{ height: 12 }} />
      <Title text="Find out why your Mac was slow." size={44} weight={500} color={DIM} delay={26} />
      <div style={{ height: 50 }} />
      <div style={{ fontFamily, fontSize: 44, fontWeight: 700, opacity: interpolate(frame, [45, 65], [0, 1], clamp),
        backgroundImage: `linear-gradient(90deg, ${BLUE}, ${VIOLET})`, WebkitBackgroundClip: "text", color: "transparent" }}>
        activityplus.xyz
      </div>
      <div style={{ fontFamily: mono, fontSize: 26, color: INK, marginTop: 18, padding: "10px 20px", borderRadius: 10,
        background: "rgba(255,255,255,0.08)", opacity: interpolate(frame, [60, 80], [0, 1], clamp) }}>
        brew install robbyczgw-cla/tap/activity-plus
      </div>
      <div style={{ fontFamily, fontSize: 24, color: DIM, marginTop: 18, opacity: interpolate(frame, [70, 90], [0, 1], clamp) }}>
        Free and open source · macOS 15 or later · Apple silicon
      </div>
    </AbsoluteFill>
  );
};

const component = (id: SceneID, frames: number): React.ReactNode => {
  switch (id) {
    case "hook": return <HookScene frames={frames} />;
    case "conditions": return <ConditionsScene frames={frames} />;
    case "freeze": return <FreezeScene frames={frames} />;
    case "storage": return <CardScene frames={frames} title="Space Finder doesn't show" sub="Purgeable space and snapshots, like a macOS update waiting to install." src="v030/storage.png" width={1300} />;
    case "ssd": return <CardScene frames={frames} title="What wears your SSD" sub="Bytes written per day, and how long the drive lasts at that pace." src="v030/ssd.png" width={1300} />;
    case "menubar": return <MenuBarScene frames={frames} />;
    case "extras": return <ExtrasScene frames={frames} />;
    case "end": return <EndScene />;
  }
};

export const Release030: React.FC<{ music: boolean }> = ({ music }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const volume = interpolate(frame, [0, 20, durationInFrames - 45, durationInFrames], [0, 0.8, 0.8, 0], clamp);
  return (
    <AbsoluteFill style={{ background: BG }}>
      <Backdrop />
      {releaseScenes.map((s) => (
        <Sequence key={s.id} from={start(s.id)} durationInFrames={s.frames}>{component(s.id, s.frames)}</Sequence>
      ))}
      {music && <Audio src={staticFile("audio/music.mp3")} volume={() => volume} />}
    </AbsoluteFill>
  );
};
