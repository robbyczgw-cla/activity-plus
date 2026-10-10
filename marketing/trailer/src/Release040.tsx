// Activity+ 0.4.0: "where did your disk space go". Explore, Biggest, Duplicates and What grew show a demo folder
// with neutral names built for the film (real files, real scans). System Data, Clean up, crashes, fan spin-ups, the
// notch and the security card are real readings from an M1 Max (10.10.2026), cropped to rows without personal names.
import React from "react";
import { AbsoluteFill, Audio, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig, Easing } from "remotion";
import { Backdrop, Title, Chip, fadeOut, BLUE, VIOLET, INK, DIM, BG, clamp, fontFamily, mono } from "./Trailer";

const ORANGE = "#FF9F0A";
const PINK = "#FF375F";
const GREEN = "#30D158";
const TEAL = "#40C8E0";
/** Card and page colours of the dark renders, for patches drawn over them. */
const CARD = "rgb(36,36,36)";
const PAGE = "rgb(50,50,50)";
const system = "-apple-system, 'SF Pro Text', system-ui, sans-serif";

export const release040Scenes = [
  { id: "hook", frames: 120 },
  { id: "explore", frames: 270 },
  { id: "systemData", frames: 210 },
  { id: "cleanup", frames: 210 },
  { id: "find", frames: 270 },
  { id: "notch", frames: 165 },
  { id: "slow", frames: 210 },
  { id: "extras", frames: 180 },
  { id: "end", frames: 165 },
] as const;
type SceneID = (typeof release040Scenes)[number]["id"];
export const release040TotalFrames = release040Scenes.reduce((sum, s) => sum + s.frames, 0);
const start = (id: SceneID) => {
  let at = 0;
  for (const s of release040Scenes) { if (s.id === id) return at; at += s.frames; }
  return at;
};

/** A render on a dark panel, rising in. `scale` maps image pixels to the panel (width / image width). */
const Shot: React.FC<{ src: string; width: number; height?: number; delay?: number; style?: React.CSSProperties; children?: React.ReactNode }> =
  ({ src, width, height, delay = 0, style, children }) => {
    const frame = useCurrentFrame();
    const { fps } = useVideoConfig();
    const p = spring({ frame: frame - delay, fps, config: { damping: 200 } });
    return (
      <div style={{ position: "absolute", width, height, borderRadius: 20, overflow: "hidden", background: PAGE, opacity: p,
        transform: `translateY(${(1 - p) * 50}px) scale(${0.96 + 0.04 * p})`,
        boxShadow: "0 60px 140px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.12)", ...style }}>
        <Img src={staticFile(src)} style={{ width: "100%", display: "block" }} />
        {children}
      </div>
    );
  };

/** A highlight ring around a box given in image pixels. */
const Ring: React.FC<{ box: [number, number, number, number]; scale: number; at: number; color?: string; pad?: number }> =
  ({ box: [x0, y0, x1, y1], scale, at, color = ORANGE, pad = 8 }) => {
    const frame = useCurrentFrame();
    const { fps } = useVideoConfig();
    const p = spring({ frame: frame - at, fps, config: { damping: 14 } });
    return (
      <div style={{ position: "absolute", left: x0 * scale - pad, top: y0 * scale - pad, width: (x1 - x0) * scale + 2 * pad,
        height: (y1 - y0) * scale + 2 * pad, borderRadius: 12, border: `3px solid ${color}`, opacity: Math.min(1, p),
        boxShadow: `0 0 36px ${color}88`, transform: `scale(${0.9 + 0.1 * p})` }} />
    );
  };

/**
 * The render shows ticked boxes. An empty box is drawn over each one and fades away at `at`, so the ticks appear
 * one after another. `box` is the checkbox in image pixels.
 */
const TickReveal: React.FC<{ box: [number, number, number, number]; scale: number; at: number; bg?: string }> =
  ({ box: [x0, y0, x1, y1], scale, at, bg = CARD }) => {
    const frame = useCurrentFrame();
    const gone = interpolate(frame, [at, at + 5], [0, 1], clamp);
    const pop = interpolate(frame, [at, at + 4, at + 9], [1, 1.25, 1], clamp);
    return (
      <>
        <div style={{ position: "absolute", left: x0 * scale - 3, top: y0 * scale - 3, width: (x1 - x0) * scale + 6, height: (y1 - y0) * scale + 6,
          background: bg, opacity: 1 - gone }}>
          <div style={{ position: "absolute", inset: 3, borderRadius: 4 * scale + 1, border: "1.5px solid rgba(255,255,255,0.28)", background: "rgba(255,255,255,0.06)" }} />
        </div>
        <div style={{ position: "absolute", left: x0 * scale - 6, top: y0 * scale - 6, width: (x1 - x0) * scale + 12, height: (y1 - y0) * scale + 12,
          borderRadius: 8, border: `2px solid ${BLUE}`, opacity: gone * interpolate(frame, [at + 6, at + 20], [1, 0], clamp), transform: `scale(${pop})` }} />
      </>
    );
  };

/** Draws a tick into an empty checkbox of the render at `at`. */
const TickAdd: React.FC<{ box: [number, number, number, number]; scale: number; at: number }> = ({ box: [x0, y0, x1, y1], scale, at }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - at, fps, config: { damping: 12, mass: 0.5 } });
  const w = (x1 - x0) * scale;
  return (
    <div style={{ position: "absolute", left: x0 * scale, top: y0 * scale, width: w, height: (y1 - y0) * scale, borderRadius: 4, background: BLUE,
      opacity: Math.min(1, p * 2), transform: `scale(${0.5 + 0.5 * p})`, display: "flex", alignItems: "center", justifyContent: "center",
      fontFamily: system, fontWeight: 800, fontSize: w * 0.8, color: "#fff", lineHeight: 1 }}>✓</div>
  );
};

const Caption: React.FC<{ text: string; at: number; style: React.CSSProperties; size?: number; color?: string }> = ({ text, at, style, size = 30, color = DIM }) => {
  const frame = useCurrentFrame();
  return (
    <div style={{ position: "absolute", fontFamily, fontSize: size, fontWeight: 500, color, lineHeight: 1.3,
      opacity: interpolate(frame, [at, at + 15], [0, 1], clamp), transform: `translateY(${interpolate(frame, [at, at + 15], [12, 0], clamp)}px)`, ...style }}>
      {text}
    </div>
  );
};

const Tag: React.FC<{ text: string }> = ({ text }) => (
  <div style={{ position: "absolute", right: 70, bottom: 50, fontFamily: mono, fontSize: 22, color: DIM }}>{text}</div>
);

const Heading: React.FC<{ text: string; top?: number; size?: number }> = ({ text, top = 58, size = 56 }) => (
  <div style={{ position: "absolute", top, width: "100%" }}><Title text={text} size={size} /></div>
);

// ─── 1: hook ────────────────────────────────────────────────────────────────

const HookScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", gap: 30, opacity: fadeOut(frame, frames) }}>
      <Title text="Where did your disk space go?" size={92} />
      <Title text="Now you can see it, and clear it safely." size={60} weight={600} gradient delay={40} />
    </AbsoluteFill>
  );
};

// ─── 2: explore ─────────────────────────────────────────────────────────────

const menuItems: { label: string; icon: string; checked?: boolean; divider?: boolean }[] = [
  { label: "Home folder", icon: "⌂", checked: true },
  { label: "Backup", icon: "◫", divider: true },
  { label: "Whole startup disk", icon: "▣", divider: true },
];

const ExploreScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const mapW = 960, mapScale = mapW / 1592;
  // The "Map of" picker sits at x 121–450, y 11–50 of explore-map.png.
  const menuOpen = interpolate(frame, [55, 62, 118, 124], [0, 1, 1, 0], clamp);
  const hover = frame < 80 ? 0 : frame < 98 ? 1 : 2;
  const grewW = 1060, grewScale = grewW / 1592;
  // The map steps back when "What grew" comes in over it.
  const back = interpolate(frame, [128, 150], [0, 1], { ...clamp, easing: Easing.inOut(Easing.cubic) });
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <Heading text="A map of every folder, by size and kind" />
      <Shot src="v040/explore-map.png" width={mapW} delay={6}
        style={{ left: 90, top: 175, filter: `brightness(${1 - 0.45 * back})`, scale: `${1 - 0.04 * back}` }}>
        <div style={{ position: "absolute", left: 121 * mapScale, top: 56 * mapScale, width: 330, borderRadius: 10, padding: "6px 0",
          background: "rgba(44,44,48,0.97)", border: "1px solid rgba(255,255,255,0.14)", boxShadow: "0 20px 50px rgba(0,0,0,0.6)",
          fontFamily: system, fontSize: 19, color: INK, opacity: menuOpen, transform: `translateY(${(1 - menuOpen) * -8}px)` }}>
          {menuItems.map((item, i) => (
            <React.Fragment key={item.label}>
              {item.divider && <div style={{ height: 1, background: "rgba(255,255,255,0.12)", margin: "5px 10px" }} />}
              <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "6px 12px", margin: "0 6px", borderRadius: 6,
                background: hover === i ? BLUE : "transparent" }}>
                <span style={{ width: 14, fontSize: 14 }}>{item.checked ? "✓" : ""}</span>
                <span style={{ width: 20, textAlign: "center", opacity: 0.8 }}>{item.icon}</span>
                {item.label}
              </div>
            </React.Fragment>
          ))}
        </div>
      </Shot>
      <Caption text="Your home folder, another drive, or the whole startup disk." at={60} style={{ left: 1110, top: 230, width: 720 }} size={32} color={INK} />
      <Shot src="v040/explore-grew.png" width={grewW} delay={135} style={{ left: 790, top: 450 }} />
      <Caption text="Scan again later and see which folders grew." at={150} style={{ left: 1100, top: 450 + 473 * grewScale + 34, width: 760 }} size={32} color={INK} />
      <Tag text="demo folder" />
    </AbsoluteFill>
  );
};

// ─── 3: System Data ─────────────────────────────────────────────────────────

// Real reading, 10.10.2026: developer data 6.88 GB, caches 10.3 GB, logs 94.9 MB, managed by macOS 2.15 GB.
const parts = [
  { label: "Developer data", gb: 6.88, color: "#7B7CF6" },
  { label: "Caches", gb: 10.3, color: "#1E9BFF" },
  { label: "Logs", gb: 0.095, color: TEAL },
  { label: "Managed by macOS", gb: 2.15, color: "#9A9AA0" },
];

const SystemDataScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const split = interpolate(frame, [25, 55], [0, 1], { ...clamp, easing: Easing.inOut(Easing.cubic) });
  const total = parts.reduce((s, p) => s + p.gb, 0);
  const barLeft = 260, barW = 1400, gap = 6 * split;
  let x = 0;
  const shotW = 1000, shotScale = shotW / 1592;
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <Heading text="The grey “System Data” bar, explained" />
      <div style={{ position: "absolute", left: barLeft, top: 170, width: barW, fontFamily: system, fontSize: 22, color: DIM,
        opacity: interpolate(frame, [5, 20], [0, 1], clamp) }}>
        System Data · {total.toFixed(1)} GB
      </div>
      {parts.map((p, i) => {
        const w = (p.gb / total) * (barW - gap * (parts.length - 1));
        const left = barLeft + x + i * gap;
        x += w;
        return (
          <React.Fragment key={p.label}>
            <div style={{ position: "absolute", left, top: 208, width: Math.max(w, 4), height: 34, borderRadius: 8,
              background: p.color, opacity: interpolate(frame, [5, 20], [0, 1], clamp) }} />
            {p.gb > 1 && (
              <div style={{ position: "absolute", left, top: 252, width: w, fontFamily: system, fontSize: 20, color: INK, opacity: split }}>
                {p.label} <span style={{ color: DIM }}>{p.gb >= 1 ? `${p.gb} GB` : ""}</span>
              </div>
            )}
          </React.Fragment>
        );
      })}
      {/* One grey bar, as macOS shows it, until it splits into its parts. */}
      <div style={{ position: "absolute", left: barLeft, top: 208, width: barW, height: 34, borderRadius: 8, background: "#8E8E93",
        opacity: interpolate(frame, [5, 20], [0, 1], clamp) * (1 - split) }} />
      <Shot src="v040/systemdata.png" width={shotW} height={660} delay={60} style={{ left: 160, top: 320 }}>
        <Ring box={[52, 808, 208, 854]} scale={shotScale} at={115} color={ORANGE} />
      </Shot>
      <div style={{ position: "absolute", left: 1220, top: 380, width: 560 }}>
        <Caption text="Each part named, with what it is and where it lives." at={75} style={{ position: "relative" }} size={32} color={INK} />
        <div style={{ height: 34 }} />
        {[["Safe to clear", GREEN, 92], ["Look first", ORANGE, 104], ["Managed by macOS", "#9A9AA0", 116]].map(([label, color, at]) => (
          <div key={label as string} style={{ display: "flex", alignItems: "center", gap: 14, marginBottom: 18,
            opacity: interpolate(frame, [at as number, (at as number) + 12], [0, 1], clamp) }}>
            <span style={{ fontFamily: system, fontSize: 24, fontWeight: 600, color: color as string, padding: "6px 14px", borderRadius: 8,
              background: `${color}26` }}>{label as string}</span>
          </div>
        ))}
        <Caption text="Activity+ only measures here and changes nothing." at={135} style={{ position: "relative", marginTop: 14 }} size={26} />
      </div>
    </AbsoluteFill>
  );
};

// ─── 4: clean up ────────────────────────────────────────────────────────────

const CleanupScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const w = 1000, s = w / 1592;
  // Checkbox tops in cleanup.png (x 60–87, 28 px high): uv, Cargo, npm, Playwright, other caches.
  const rows = [455, 593, 731, 869, 1007];
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <Heading text="Clean up, with a reason for every item" />
      <Shot src="v040/cleanup.png" width={w} delay={4} style={{ left: 110, top: 175 }}>
        {rows.map((y, i) => <TickReveal key={y} box={[60, y, 88, y + 28]} scale={s} at={40 + i * 9} />)}
        <Ring box={[104, 384, 232, 416]} scale={s} at={110} color={ORANGE} />
      </Shot>
      <div style={{ position: "absolute", left: 1190, top: 300, width: 620 }}>
        <Caption text="Each line says what it is and what happens when it goes." at={30} style={{ position: "relative" }} size={32} color={INK} />
        <div style={{ height: 50 }} />
        <Caption text="Caches of apps that are open stay locked." at={110} style={{ position: "relative" }} size={32} color={ORANGE} />
        <div style={{ height: 50 }} />
        <Caption text="Everything goes to the Trash, after you confirm." at={150} style={{ position: "relative" }} size={28} />
      </div>
    </AbsoluteFill>
  );
};

// ─── 5: biggest files and duplicates ────────────────────────────────────────

const query = "kind:video size:>100mb";

const FindScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const bw = 880, bs = bw / 1592;
  const typed = Math.round(interpolate(frame, [30, 72], [0, query.length], clamp));
  const filtered = interpolate(frame, [80, 92], [0, 1], clamp);
  // The filtered list is shorter: the panel closes up to it (biggest-video.png has content down to y ≈ 1000).
  const panelH = interpolate(frame, [92, 112], [760, 1000 * bs], { ...clamp, easing: Easing.inOut(Easing.cubic) });
  const caret = Math.floor(frame / 8) % 2 === 0 && frame < 80;
  const dw = 820, ds = dw / 1592;
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <Heading text="The biggest files, and the copies you don't need" />
      <Shot src="v040/biggest-all.png" width={bw} height={panelH} delay={4} style={{ left: 90, top: 180 }}>
        <Img src={staticFile("v040/biggest-video.png")} style={{ position: "absolute", left: 0, top: 0, width: "100%", opacity: filtered }} />
        {/* Typing over the empty search field (right of the magnifier) until the filtered render takes over. */}
        <div style={{ position: "absolute", left: 118 * bs, top: 52 * bs, width: 1340 * bs, height: 56 * bs, background: CARD,
          opacity: 1 - filtered, display: "flex", alignItems: "center", paddingLeft: 18 * bs, fontFamily: system, fontSize: 30 * bs, color: INK }}>
          {query.slice(0, typed)}
          <span style={{ width: 2, height: 30 * bs, background: INK, marginLeft: 1, opacity: caret ? 1 : 0 }} />
        </div>
      </Shot>
      <Caption text="Filter by kind, size and age." at={40} style={{ left: 110, top: 180 + panelH + 30 }} size={28} />
      <Shot src="v040/duplicates.png" width={dw} delay={110} style={{ left: 1010, top: 180 }}>
        <Ring box={[392, 653, 468, 684]} scale={ds} at={150} color={GREEN} pad={6} />
        <Ring box={[542, 1047, 618, 1078]} scale={ds} at={156} color={GREEN} pad={6} />
        {[754, 838, 1148].map((y, i) => <TickAdd key={y} box={[60, y, 88, y + 28]} scale={ds} at={185 + i * 8} />)}
        {/* With the three extra copies ticked, the button reads as the app words it (DuplicatesTab). */}
        <div style={{ position: "absolute", left: 1129 * ds, top: 455 * ds, width: 451 * ds, height: 32 * ds, borderRadius: 6 * ds,
          background: "rgb(91,91,91)", color: "#fff", fontFamily: system, fontSize: 25 * ds, display: "flex", alignItems: "center",
          justifyContent: "center", opacity: interpolate(frame, [203, 208], [0, 1], clamp) }}>
          Move 3 copies (346 MB) to Trash…
        </div>
      </Shot>
      <Caption text="One copy of each file always stays." at={170} style={{ left: 1030, top: 180 + 1255 * ds + 30 }} size={28} />
      <Tag text="demo folder" />
    </AbsoluteFill>
  );
};

// ─── 6: the notch ───────────────────────────────────────────────────────────

const NotchScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  // One after the other, so the two captions and the two panels never overlap: caption out, panel swap, caption in.
  const firstOut = interpolate(frame, [78, 88], [0, 1], clamp);
  const hint = interpolate(frame, [90, 95], [0, 1], clamp);
  const secondIn = interpolate(frame, [96, 108], [0, 1], clamp);
  const w = 1250;
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <Heading text="The notch, put to use" />
      <Shot src="v040/notch-hover.png" width={w} delay={4} style={{ left: (1920 - w) / 2, top: 290 }}>
        <Img src={staticFile("v040/notch-hint.png")} style={{ position: "absolute", left: 0, top: 0, width: "100%", opacity: hint }} />
      </Shot>
      <div style={{ position: "absolute", top: 290 + w * 330 / 1112 + 60, width: "100%", textAlign: "center", fontFamily, fontSize: 36, fontWeight: 600,
        color: INK, opacity: interpolate(frame, [20, 35], [0, 1], clamp) * (1 - firstOut) }}>
        Point at it for live values.
      </div>
      <div style={{ position: "absolute", top: 290 + w * 330 / 1112 + 60, width: "100%", textAlign: "center", fontFamily, fontSize: 36, fontWeight: 600,
        color: INK, opacity: secondIn }}>
        Short hints when something changes, like “Charging · 65 W”.
      </div>
    </AbsoluteFill>
  );
};

// ─── 7: why is it slow ──────────────────────────────────────────────────────

const SlowScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const lw = 880, rw = 780;
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <Heading text="Why is it slow? More answers." />
      <Shot src="v040/crashes.png" width={lw} delay={6} style={{ left: 100, top: 175 }} />
      <Caption text="Crashes per app, in plain words" at={20} style={{ left: 120, top: 175 + 937 * lw / 1520 + 24 }} size={28} />
      <Shot src="v040/fans.png" width={rw} delay={40} style={{ left: 1040, top: 175 }} />
      <Caption text="Fan spin-ups, and the apps behind them" at={50} style={{ left: 1060, top: 175 + 352 * rw / 1520 + 18 }} size={28} />
      <Shot src="v040/spotlight.png" width={rw} delay={80} style={{ left: 1040, top: 490 }} />
      <Caption text="Whether Spotlight is indexing" at={90} style={{ left: 1060, top: 490 + 94 * rw / 1520 + 18 }} size={28} />
      <Shot src="v040/orphans.png" width={rw} delay={115} style={{ left: 1040, top: 670 }} />
      <Caption text="Background items left behind by deleted apps" at={125} style={{ left: 1060, top: 670 + 246 * rw / 1520 + 18 }} size={28} />
    </AbsoluteFill>
  );
};

// ─── 8: also new ────────────────────────────────────────────────────────────

const ExtrasScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const w = 820;
  const chips: [string, string][] = [
    ["Backup status", ORANGE],
    ["Microphone and camera in use", GREEN],
    ["Network quality test", TEAL],
    ["Pause a process", VIOLET],
    ["Explanations behind ⓘ", BLUE],
    ["Eight languages", PINK],
  ];
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <Heading text="Also new" />
      <Shot src="v040/appearance.png" width={w} delay={8} style={{ left: 140, top: 210 }} />
      <Caption text="Text size and density" at={20} style={{ left: 160, top: 210 + 275 * w / 1262 + 18 }} size={28} />
      <Shot src="v040/security.png" width={w} delay={30} style={{ left: 140, top: 500 }} />
      <Caption text="Security at a glance" at={40} style={{ left: 160, top: 500 + 496 * w / 1520 + 18 }} size={28} />
      {chips.map(([text, color], i) => (
        <Chip key={text} text={text} delay={45 + i * 12} color={color} style={{ left: 1100, top: 230 + i * 110 }} />
      ))}
    </AbsoluteFill>
  );
};

// ─── 9: end card ────────────────────────────────────────────────────────────

const EndScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame, fps, config: { damping: 12, mass: 0.9 } });
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column" }}>
      <Img src={staticFile("icon.png")} style={{ width: 190, height: 190, transform: `scale(${icon})`, filter: "drop-shadow(0 30px 60px rgba(79,125,255,0.45))" }} />
      <div style={{ height: 24 }} />
      <Title text="Activity+ 0.4" size={112} weight={800} delay={10} />
      <div style={{ height: 12 }} />
      <Title text="See where your disk space went." size={44} weight={500} color={DIM} delay={26} />
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
    case "explore": return <ExploreScene frames={frames} />;
    case "systemData": return <SystemDataScene frames={frames} />;
    case "cleanup": return <CleanupScene frames={frames} />;
    case "find": return <FindScene frames={frames} />;
    case "notch": return <NotchScene frames={frames} />;
    case "slow": return <SlowScene frames={frames} />;
    case "extras": return <ExtrasScene frames={frames} />;
    case "end": return <EndScene />;
  }
};

export const Release040: React.FC<{ music: boolean }> = ({ music }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  const volume = interpolate(frame, [0, 20, durationInFrames - 45, durationInFrames], [0, 0.8, 0.8, 0], clamp);
  return (
    <AbsoluteFill style={{ background: BG }}>
      <Backdrop />
      {release040Scenes.map((s) => (
        <Sequence key={s.id} from={start(s.id)} durationInFrames={s.frames}>{component(s.id, s.frames)}</Sequence>
      ))}
      {music && <Audio src={staticFile("audio/music.mp3")} volume={() => volume} />}
    </AbsoluteFill>
  );
};
