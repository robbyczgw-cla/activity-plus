import { loadFont } from "@remotion/google-fonts/Inter";
import { loadFont as loadMono } from "@remotion/google-fonts/JetBrainsMono";
import React from "react";
import {
  AbsoluteFill, Audio, Img, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig, Easing,
} from "remotion";
import { scenes, sceneStart, SceneID } from "./script";

const { fontFamily } = loadFont("normal", { weights: ["400", "500", "600", "700", "800"], subsets: ["latin"] });
const { fontFamily: mono } = loadMono("normal", { weights: ["400", "600"], subsets: ["latin"] });

export type TrailerProps = { voice: "none" | "xai" | "eleven"; music: boolean };

const BLUE = "#4F7DFF";
const VIOLET = "#9B5CF6";
const INK = "#F5F6FA";
const DIM = "rgba(245,246,250,0.58)";
const BG = "#06070C";
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

// ─── Shared pieces ──────────────────────────────────────────────────────────

const Backdrop: React.FC = () => {
  const frame = useCurrentFrame();
  const drift = (speed: number, range: number) => Math.sin(frame / speed) * range;
  return (
    <AbsoluteFill style={{ background: BG, overflow: "hidden" }}>
      <div style={{
        position: "absolute", width: 1300, height: 1300, borderRadius: "50%", left: -300 + drift(90, 80), top: -520 + drift(120, 60),
        background: `radial-gradient(circle, ${BLUE}55 0%, transparent 62%)`, filter: "blur(40px)",
      }} />
      <div style={{
        position: "absolute", width: 1200, height: 1200, borderRadius: "50%", right: -380 + drift(110, 70), bottom: -600 + drift(80, 50),
        background: `radial-gradient(circle, ${VIOLET}44 0%, transparent 62%)`, filter: "blur(40px)",
      }} />
      {/* Fine grid that fades toward the edges. */}
      <AbsoluteFill style={{
        backgroundImage: "linear-gradient(rgba(255,255,255,0.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.035) 1px, transparent 1px)",
        backgroundSize: "64px 64px", maskImage: "radial-gradient(ellipse at center, black 30%, transparent 75%)",
      }} />
    </AbsoluteFill>
  );
};

/** Words rise and sharpen one after another. */
const Title: React.FC<{ text: string; delay?: number; size?: number; weight?: number; color?: string; gradient?: boolean; align?: "center" | "left" }> =
  ({ text, delay = 0, size = 76, weight = 700, color = INK, gradient = false, align = "center" }) => {
    const frame = useCurrentFrame();
    const { fps } = useVideoConfig();
    const words = text.split(" ");
    return (
      <div style={{ fontFamily, fontSize: size, fontWeight: weight, letterSpacing: -size * 0.025, lineHeight: 1.08, textAlign: align,
        display: "flex", flexWrap: "wrap", justifyContent: align === "center" ? "center" : "flex-start", gap: `0 ${size * 0.26}px` }}>
        {words.map((word, i) => {
          const p = spring({ frame: frame - delay - i * 3, fps, config: { damping: 200, mass: 0.6 } });
          return (
            <span key={i} style={{
              display: "inline-block", opacity: p, transform: `translateY(${(1 - p) * size * 0.45}px)`, filter: `blur(${(1 - p) * 10}px)`,
              ...(gradient
                ? { backgroundImage: `linear-gradient(90deg, ${BLUE}, ${VIOLET})`, WebkitBackgroundClip: "text", color: "transparent" }
                : { color }),
            }}>{word}</span>
          );
        })}
      </div>
    );
  };

const MacWindow: React.FC<{ src: string; width: number; style?: React.CSSProperties }> = ({ src, width, style }) => (
  <div style={{
    width, borderRadius: 18, overflow: "hidden", background: "#1c1d22",
    boxShadow: "0 60px 140px rgba(0,0,0,0.65), 0 0 0 1px rgba(255,255,255,0.12)", ...style,
  }}>
    <div style={{ height: 34, display: "flex", alignItems: "center", gap: 9, paddingLeft: 16, background: "#2a2b31" }}>
      {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => <div key={c} style={{ width: 13, height: 13, borderRadius: 7, background: c }} />)}
    </div>
    <Img src={staticFile(src)} style={{ width: "100%", display: "block" }} />
  </div>
);

const Chip: React.FC<{ text: string; delay: number; style: React.CSSProperties; color?: string }> = ({ text, delay, style, color = BLUE }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = spring({ frame: frame - delay, fps, config: { damping: 14, mass: 0.7 } });
  return (
    <div style={{
      position: "absolute", fontFamily, fontSize: 30, fontWeight: 600, color: INK, padding: "14px 24px", borderRadius: 999,
      background: "rgba(20,22,32,0.78)", border: `1px solid ${color}88`, backdropFilter: "blur(14px)",
      boxShadow: `0 10px 40px ${color}33`, opacity: Math.min(1, p * 1.4), transform: `scale(${0.6 + 0.4 * p})`, ...style,
    }}>
      <span style={{ display: "inline-block", width: 12, height: 12, borderRadius: 6, background: color, marginRight: 14 }} />
      {text}
    </div>
  );
};

const fadeOut = (frame: number, total: number, length = 12) =>
  interpolate(frame, [total - length, total], [1, 0], clamp);

// ─── Scene 1: hundreds of processes ─────────────────────────────────────────

const processNames = [
  "Google Chrome Helper (Renderer)", "WindowServer", "kernel_task", "Code Helper (Plugin)", "Slack Helper (GPU)", "mds_stores",
  "Google Chrome Helper (GPU)", "node", "Safari Web Content", "Finder", "coreaudiod", "Spotify Helper", "zsh", "Dock",
  "Code Helper (Renderer)", "cloudd", "photoanalysisd", "Mail Web Content", "com.apple.WebKit.Networking", "trustd",
  "Figma Helper (Renderer)", "bird", "launchservicesd", "Docker", "postgres", "python3", "mdworker_shared", "Zoom Helper",
  "Google Chrome Helper (Renderer)", "Notion Helper (Renderer)", "backupd", "corespotlightd", "logd", "Messages", "nsurlsessiond",
];

const NoiseScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const count = Math.round(interpolate(frame, [0, 70], [0, 912], { ...clamp, easing: Easing.out(Easing.cubic) }));
  const wallOpacity = interpolate(frame, [0, 20, 90, 120], [0, 0.55, 0.55, 0.18], clamp);
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <AbsoluteFill style={{ display: "flex", flexDirection: "row", gap: 60, padding: "0 40px", opacity: wallOpacity, filter: "blur(0.4px)" }}>
        {[0, 1, 2, 3, 4].map((column) => (
          <div key={column} style={{ flex: 1, transform: `translateY(${-((frame * (1.6 + column * 0.45)) % 900)}px)` }}>
            {Array.from({ length: 60 }).map((_, i) => (
              <div key={i} style={{ fontFamily: mono, fontSize: 21, color: "rgba(255,255,255,0.75)", lineHeight: "30px", whiteSpace: "nowrap" }}>
                {processNames[(i * 7 + column * 11) % processNames.length]}
                <span style={{ color: "rgba(255,255,255,0.35)" }}>  {((i * 37 + column * 53) % 900) / 10}%</span>
              </div>
            ))}
          </div>
        ))}
      </AbsoluteFill>
      <AbsoluteFill style={{ background: `radial-gradient(ellipse at center, ${BG}f2 20%, ${BG}66 60%, transparent 90%)` }} />
      <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column", gap: 26 }}>
        <div style={{ fontFamily, fontSize: 190, fontWeight: 800, color: INK, letterSpacing: -8, fontVariantNumeric: "tabular-nums",
          opacity: interpolate(frame, [0, 10], [0, 1], clamp) }}>
          {count}
        </div>
        <div style={{ fontFamily, fontSize: 40, color: DIM, fontWeight: 500, marginTop: -30 }}>processes running on this Mac</div>
        <div style={{ height: 40 }} />
        <Title text="Which one is slowing it down?" delay={70} size={72} />
      </AbsoluteFill>
    </AbsoluteFill>
  );
};

// ─── Scene 2: processes fold into apps ──────────────────────────────────────

const groups = [
  { app: "Google Chrome", color: "#34A853", memory: "4.2 GB", procs: ["Google Chrome", "Google Chrome Helper (Renderer)", "Google Chrome Helper (Renderer)", "Google Chrome Helper (GPU)", "Google Chrome Helper (Renderer)"] },
  { app: "Visual Studio Code", color: "#3B8EEA", memory: "2.1 GB", procs: ["Code", "Code Helper (Renderer)", "Code Helper (Plugin)", "Code Helper (GPU)"] },
  { app: "Terminal", color: "#9AA0A6", memory: "1.3 GB", procs: ["Terminal", "zsh", "node", "node"] },
  { app: "Slack", color: "#E01E5A", memory: "940 MB", procs: ["Slack", "Slack Helper (Renderer)", "Slack Helper (GPU)"] },
];

const FoldScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const fold = spring({ frame: frame - 45, fps, config: { damping: 22, mass: 1.1 } });
  const rowH = 44;
  const appRowH = 96;
  let processIndex = 0;
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", top: 90, width: "100%" }}>
        <Title text="Every process, under the app it belongs to." size={64} delay={5} />
      </div>
      <div style={{ position: "absolute", left: 460, top: 250, width: 1000 }}>
        {groups.map((group, g) => {
          const startIndex = processIndex;
          processIndex += group.procs.length;
          const appY = g * (appRowH + 18);
          return (
            <React.Fragment key={group.app}>
              {group.procs.map((name, i) => {
                const flatY = (startIndex + i) * rowH;
                const y = interpolate(fold, [0, 1], [flatY, appY + 24]);
                return (
                  <div key={i} style={{
                    position: "absolute", top: y, left: 0, right: 0, height: rowH - 6, display: "flex", alignItems: "center",
                    fontFamily: mono, fontSize: 22, color: "rgba(255,255,255,0.8)", opacity: interpolate(fold, [0, 0.55], [1, 0], clamp),
                    padding: "0 18px", borderRadius: 8, background: "rgba(255,255,255,0.035)",
                  }}>
                    {name}
                    <span style={{ marginLeft: "auto", color: "rgba(255,255,255,0.4)" }}>{120 + ((startIndex + i) * 97) % 700} MB</span>
                  </div>
                );
              })}
              <div style={{
                position: "absolute", top: appY, left: 0, right: 0, height: appRowH, display: "flex", alignItems: "center", gap: 24,
                padding: "0 28px", borderRadius: 20, background: "rgba(22,24,34,0.9)", border: "1px solid rgba(255,255,255,0.1)",
                opacity: interpolate(fold, [0.35, 0.8], [0, 1], clamp), transform: `scale(${interpolate(fold, [0.35, 1], [0.92, 1], clamp)})`,
                boxShadow: `0 20px 60px rgba(0,0,0,0.4)`,
              }}>
                <div style={{ width: 56, height: 56, borderRadius: 14, background: `linear-gradient(135deg, ${group.color}, ${group.color}99)` }} />
                <div style={{ fontFamily }}>
                  <div style={{ fontSize: 34, fontWeight: 650, color: INK }}>{group.app}</div>
                  <div style={{ fontSize: 22, color: DIM }}>{group.procs.length} processes</div>
                </div>
                <div style={{ marginLeft: "auto", fontFamily, fontSize: 38, fontWeight: 700, color: INK, fontVariantNumeric: "tabular-nums" }}>{group.memory}</div>
              </div>
            </React.Fragment>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 3: overview ──────────────────────────────────────────────────────

const OverviewScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame, fps, config: { damping: 30, mass: 1.2 } });
  const push = interpolate(frame, [0, frames], [1, 1.06]);
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames), perspective: 2000 }}>
      <AbsoluteFill style={{ justifyContent: "center", alignItems: "center" }}>
        <MacWindow src="shots/overview.png" width={1320} style={{
          transform: `translateY(${(1 - enter) * 300 + 40}px) rotateX(${(1 - enter) * 18 + 6}deg) scale(${push})`, opacity: enter,
        }} />
      </AbsoluteFill>
      <Chip text="CPU per core" delay={35} style={{ left: 120, top: 190 }} />
      <Chip text="Memory pressure" delay={50} color={VIOLET} style={{ right: 120, top: 260 }} />
      <Chip text="GPU per app" delay={65} color="#F25C8A" style={{ left: 90, top: 560 }} />
      <Chip text="Energy in watts" delay={80} color="#3CCB7F" style={{ right: 100, top: 640 }} />
      <Chip text="30 days of history" delay={95} color="#F5A524" style={{ left: 760, top: 900 }} />
    </AbsoluteFill>
  );
};

// ─── Scene 4: diagnosis ─────────────────────────────────────────────────────

const DiagnosisScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const slide = spring({ frame: frame - 5, fps, config: { damping: 26 } });
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", left: 110, top: 300, width: 700 }}>
        <Title text="Why is my Mac slow?" size={88} align="left" delay={4} />
        <div style={{ height: 34 }} />
        <Title text="One click. Plain words. A fix." size={46} weight={500} color={DIM} align="left" delay={30} />
      </div>
      <div style={{ position: "absolute", right: -40, top: 150, transform: `translateX(${(1 - slide) * 500}px) rotateY(-8deg)`, opacity: slide }}>
        <MacWindow src="shots/diagnosis.png" width={1080} />
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 5: menu bar ──────────────────────────────────────────────────────

const Ring: React.FC<{ value: number; color: string }> = ({ value, color }) => (
  <svg width="30" height="30" viewBox="0 0 30 30">
    <circle cx="15" cy="15" r="11" stroke="rgba(255,255,255,0.22)" strokeWidth="4" fill="none" />
    <circle cx="15" cy="15" r="11" stroke={color} strokeWidth="4" fill="none" strokeLinecap="round"
      strokeDasharray={`${value * 69} 69`} transform="rotate(-90 15 15)" />
  </svg>
);

const Spark: React.FC<{ frame: number; color: string }> = ({ frame, color }) => {
  const points = Array.from({ length: 22 }, (_, i) => {
    const v = 0.5 + 0.32 * Math.sin((i + frame / 4) / 2.3) + 0.14 * Math.sin((i + frame / 3) * 1.7);
    return `${i * 3.6},${26 - v * 22}`;
  }).join(" ");
  return (
    <svg width="78" height="28" viewBox="0 0 78 28">
      <polyline points={`0,28 ${points} 75.6,28`} fill={`${color}44`} stroke="none" />
      <polyline points={points} fill="none" stroke={color} strokeWidth="2" />
    </svg>
  );
};

const CoreBars: React.FC<{ frame: number }> = ({ frame }) => (
  <div style={{ display: "flex", gap: 2, alignItems: "flex-end", height: 28 }}>
    {Array.from({ length: 10 }, (_, i) => {
      const v = 0.25 + 0.7 * Math.abs(Math.sin((frame / 9) + i * 1.3));
      return <div key={i} style={{ width: 5, height: 28 * v, background: v > 0.8 ? "#F59E0B" : "#3CCB7F", borderRadius: 1 }} />;
    })}
  </div>
);

const Gauge: React.FC<{ value: number }> = ({ value }) => {
  const angle = Math.PI * (1 - value);
  return (
    <svg width="40" height="24" viewBox="0 0 40 24">
      <path d="M4 22 A16 16 0 0 1 36 22" stroke="rgba(255,255,255,0.22)" strokeWidth="4" fill="none" strokeLinecap="round" />
      <path d={`M4 22 A16 16 0 0 1 ${20 - 16 * Math.cos(Math.PI * value)} ${22 - 16 * Math.sin(Math.PI * value)}`} stroke="#F59E0B" strokeWidth="4" fill="none" strokeLinecap="round" />
      <line x1="20" y1="22" x2={20 + 11 * Math.cos(angle)} y2={22 - 11 * Math.sin(angle)} stroke={INK} strokeWidth="2" strokeLinecap="round" />
    </svg>
  );
};

const MenuBarScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const cpu = 0.38 + 0.2 * Math.sin(frame / 14);
  const items: { key: string; node: React.ReactNode }[] = [
    { key: "clock", node: <span style={{ fontSize: 26 }}>Fri 09:41</span> },
    { key: "bat", node: <span style={{ display: "flex", alignItems: "center", gap: 8 }}><span style={{ display: "inline-block", width: 38, height: 18, borderRadius: 5, border: "2px solid rgba(255,255,255,0.7)", padding: 2 }}><span style={{ display: "block", width: "82%", height: "100%", background: "#3CCB7F", borderRadius: 2 }} /></span><span style={{ fontSize: 22 }}>82%</span></span> },
    { key: "temp", node: <span style={{ fontSize: 26 }}>57°</span> },
    { key: "net", node: <span style={{ fontFamily: mono, fontSize: 15, lineHeight: "17px", textAlign: "right" }}>↑ 1.2 MB/s<br />↓ 18.4 MB/s</span> },
    { key: "mem", node: <span style={{ display: "flex", alignItems: "center", gap: 8 }}><Gauge value={0.72} /><span style={{ fontSize: 22 }}>MEM</span></span> },
    { key: "cores", node: <CoreBars frame={frame} /> },
    { key: "spark", node: <Spark frame={frame} color={BLUE} /> },
    { key: "cpu", node: <span style={{ display: "flex", alignItems: "center", gap: 8 }}><Ring value={cpu} color={cpu > 0.5 ? "#F59E0B" : "#3CCB7F"} /><span style={{ fontSize: 24, fontVariantNumeric: "tabular-nums" }}>{Math.round(cpu * 100)}%</span></span> },
  ];
  const panel = spring({ frame: frame - 120, fps, config: { damping: 20 } });
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      {/* A macOS menu bar, drawn large. */}
      <div style={{ position: "absolute", top: 110, left: 60, right: 60, height: 64, borderRadius: 16, display: "flex", alignItems: "center",
        padding: "0 28px", gap: 34, background: "rgba(30,32,44,0.72)", border: "1px solid rgba(255,255,255,0.1)", backdropFilter: "blur(20px)",
        fontFamily, color: INK, fontWeight: 500 }}>
        <span style={{ fontSize: 28, fontWeight: 700 }}></span>
        <span style={{ fontSize: 24, fontWeight: 700 }}>Activity+</span>
        {["File", "View", "Window"].map((m) => <span key={m} style={{ fontSize: 22, color: DIM }}>{m}</span>)}
        <div style={{ marginLeft: "auto", display: "flex", flexDirection: "row-reverse", alignItems: "center", gap: 30 }}>
          {items.map((item, i) => {
            const p = spring({ frame: frame - 12 - i * 9, fps, config: { damping: 15, mass: 0.6 } });
            return <div key={item.key} style={{ opacity: p, transform: `translateY(${(1 - p) * -40}px)`, display: "flex", alignItems: "center" }}>{item.node}</div>;
          })}
        </div>
      </div>
      <div style={{ position: "absolute", right: 250, top: 190, opacity: panel, transform: `translateY(${(1 - panel) * -30}px) scale(${0.9 + 0.1 * panel})`, transformOrigin: "top right" }}>
        <Img src={staticFile("shots/menubar-panel.png")} style={{ width: 430, borderRadius: 16, boxShadow: "0 40px 100px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.12)" }} />
      </div>
      <div style={{ position: "absolute", left: 120, top: 470, width: 860 }}>
        <Title text="Your menu bar." size={96} align="left" delay={20} />
        <Title text="Your way." size={96} align="left" delay={32} gradient />
        <div style={{ height: 30 }} />
        <Title text="As many items as you like · eleven styles · your colors" size={36} weight={500} color={DIM} align="left" delay={55} />
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 6: features ──────────────────────────────────────────────────────

type IconName = "clock" | "bell" | "code" | "drive" | "thermo" | "wand" | "moon" | "calendar";

/** Line icons drawn on a 24-unit grid, white on the colored tile. */
const Icon: React.FC<{ name: IconName }> = ({ name }) => {
  const stroke = { fill: "none", stroke: "white", strokeWidth: 1.9, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  const shapes: Record<IconName, React.ReactNode> = {
    clock: <><circle cx="12" cy="12" r="8.5" {...stroke} /><path d="M12 7.5V12l3 2" {...stroke} /></>,
    bell: <><path d="M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 1.5h-14z" {...stroke} /><path d="M10 20.5a2.2 2.2 0 0 0 4 0" {...stroke} /></>,
    code: <><path d="M8.5 7 4 12l4.5 5M15.5 7 20 12l-4.5 5" {...stroke} /><path d="M13.5 5.5l-3 13" {...stroke} /></>,
    drive: <><rect x="3.5" y="7" width="17" height="10" rx="2.5" {...stroke} /><path d="M7 14h6" {...stroke} /><circle cx="16.8" cy="14" r="0.9" fill="white" /></>,
    thermo: <><path d="M10 13.5V5.5a2 2 0 0 1 4 0v8a4 4 0 1 1-4 0z" {...stroke} /><path d="M12 9v6.5" {...stroke} /></>,
    wand: <><path d="M5 19 16 8" {...stroke} /><path d="M15 4v2.5M17.5 3.5 16.2 5.8M20.5 9H18M19.5 5.5 17.7 7" {...stroke} /></>,
    moon: <path d="M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z" {...stroke} />,
    calendar: <><rect x="4" y="5.5" width="16" height="14.5" rx="2.5" {...stroke} /><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4" {...stroke} /><circle cx="9" cy="14.5" r="0.9" fill="white" /><circle cx="15" cy="14.5" r="0.9" fill="white" /></>,
  };
  return <svg width="34" height="34" viewBox="0 0 24 24">{shapes[name]}</svg>;
};

const features: { title: string; detail: string; color: string; icon: IconName }[] = [
  { title: "30 days of history", detail: "Which app used the most, when", color: "#F5A524", icon: "clock" },
  { title: "Alerts that learn", detail: "Warns when an app is far from its normal", color: "#9B5CF6", icon: "bell" },
  { title: "Dev servers by project", detail: "Ports, idle time, one-click stop", color: "#4F7DFF", icon: "code" },
  { title: "Drive & SSD health", detail: "SMART, wear, data written", color: "#F25C8A", icon: "drive" },
  { title: "Every sensor", detail: "Hundreds of temperatures, volts and watts", color: "#EF4444", icon: "thermo" },
  { title: "Automations", detail: "Rules that ask before they act", color: "#3CCB7F", icon: "wand" },
  { title: "Sleep & battery drain", detail: "What kept it awake, what drained it", color: "#22C1C3", icon: "moon" },
  { title: "Weekly report", detail: "Your Mac's week, every Monday", color: "#A3E635", icon: "calendar" },
];

const FeaturesScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", top: 110, width: "100%" }}>
        <Title text="And a lot more." size={72} delay={3} />
      </div>
      <div style={{ position: "absolute", left: 130, right: 130, top: 290, display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 28 }}>
        {features.map((feature, i) => {
          const p = spring({ frame: frame - 15 - i * 7, fps, config: { damping: 18, mass: 0.7 } });
          return (
            <div key={feature.title} style={{
              height: 290, borderRadius: 26, padding: 34, background: "rgba(20,22,32,0.82)", border: "1px solid rgba(255,255,255,0.09)",
              opacity: p, transform: `translateY(${(1 - p) * 70}px) scale(${0.94 + 0.06 * p})`, fontFamily,
              boxShadow: `inset 0 1px 0 rgba(255,255,255,0.06), 0 30px 80px rgba(0,0,0,0.35)`,
            }}>
              <div style={{ width: 58, height: 58, borderRadius: 16, background: `linear-gradient(135deg, ${feature.color}, ${feature.color}66)`,
                boxShadow: `0 10px 30px ${feature.color}55`, display: "flex", alignItems: "center", justifyContent: "center" }}>
                <Icon name={feature.icon} />
              </div>
              <div style={{ fontSize: 34, fontWeight: 700, color: INK, marginTop: 40, letterSpacing: -0.8 }}>{feature.title}</div>
              <div style={{ fontSize: 23, color: DIM, marginTop: 10, lineHeight: 1.3 }}>{feature.detail}</div>
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 7: agents ────────────────────────────────────────────────────────

const typed = (text: string, frame: number, start: number, speed = 1.6) =>
  text.slice(0, Math.max(0, Math.floor((frame - start) * speed)));

const AgentsScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame, fps, config: { damping: 24 } });
  const lines = [
    { text: "$ claude mcp add activity-plus -- aplus mcp", start: 8, color: "rgba(255,255,255,0.55)" },
    { text: "> why is my Mac slow?", start: 45, color: INK },
    { text: "● Not enough memory: 8.6 GB in swap. Arc uses the most (7.6 GB).", start: 80, color: "#F5A524", speed: 2.6 },
    { text: "● The disk is almost full: 37 GB free of 494 GB.", start: 108, color: "#F5A524", speed: 2.6 },
    { text: "● 4 dev servers have been idle for hours and hold 300 MB.", start: 132, color: DIM, speed: 2.6 },
  ];
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames) }}>
      <div style={{ position: "absolute", top: 110, width: "100%" }}>
        <Title text="Your AI agents can ask, too." size={72} delay={3} />
      </div>
      <div style={{ position: "absolute", left: 260, right: 260, top: 300, height: 520, borderRadius: 20, overflow: "hidden",
        background: "rgba(12,13,18,0.94)", border: "1px solid rgba(255,255,255,0.12)", boxShadow: "0 60px 140px rgba(0,0,0,0.6)",
        opacity: enter, transform: `translateY(${(1 - enter) * 80}px)` }}>
        <div style={{ height: 38, display: "flex", alignItems: "center", gap: 9, paddingLeft: 18, background: "#1b1c22" }}>
          {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => <div key={c} style={{ width: 13, height: 13, borderRadius: 7, background: c }} />)}
        </div>
        <div style={{ padding: "34px 44px", fontFamily: mono, fontSize: 28, lineHeight: "54px" }}>
          {lines.map((line, i) => (
            <div key={i} style={{ color: line.color, whiteSpace: "pre" }}>
              {typed(line.text, frame, line.start, line.speed)}
              {frame >= line.start && typed(line.text, frame, line.start, line.speed).length < line.text.length &&
                <span style={{ background: INK, opacity: Math.floor(frame / 8) % 2 ? 1 : 0 }}>&nbsp;</span>}
            </div>
          ))}
        </div>
      </div>
      <div style={{ position: "absolute", bottom: 110, width: "100%", textAlign: "center", fontFamily, fontSize: 30, color: DIM,
        opacity: interpolate(frame, [60, 80], [0, 1], clamp) }}>
        aplus mcp · a read-only MCP server with seven tools
      </div>
    </AbsoluteFill>
  );
};

// ─── Scene 8: privacy ───────────────────────────────────────────────────────

const PrivacyScene: React.FC<{ frames: number }> = ({ frames }) => {
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ opacity: fadeOut(frame, frames), justifyContent: "center", alignItems: "center", flexDirection: "column", gap: 18 }}>
      <Title text="No account." size={110} delay={5} />
      <Title text="No analytics." size={110} delay={25} />
      <Title text="Everything stays on your Mac." size={110} delay={45} gradient />
    </AbsoluteFill>
  );
};

// ─── Scene 9: logo ──────────────────────────────────────────────────────────

const LogoScene: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const icon = spring({ frame, fps, config: { damping: 12, mass: 0.9 } });
  const glow = 0.5 + 0.5 * Math.sin(frame / 12);
  return (
    <AbsoluteFill style={{ justifyContent: "center", alignItems: "center", flexDirection: "column" }}>
      <div style={{ position: "absolute", width: 700, height: 700, borderRadius: "50%",
        background: `radial-gradient(circle, ${BLUE}${Math.round(40 + glow * 30).toString(16)} 0%, transparent 60%)`, top: 40 }} />
      <Img src={staticFile("icon.png")} style={{ width: 260, height: 260, transform: `scale(${icon}) rotate(${(1 - icon) * -20}deg)`,
        filter: "drop-shadow(0 30px 60px rgba(79,125,255,0.45))" }} />
      <div style={{ height: 30 }} />
      <Title text="Activity+" size={130} weight={800} delay={12} />
      <div style={{ height: 16 }} />
      <Title text="The system monitor that tells you which app is responsible." size={40} weight={500} color={DIM} delay={30} />
      <div style={{ height: 60 }} />
      <div style={{ fontFamily, fontSize: 44, fontWeight: 700, opacity: interpolate(frame, [55, 75], [0, 1], clamp),
        backgroundImage: `linear-gradient(90deg, ${BLUE}, ${VIOLET})`, WebkitBackgroundClip: "text", color: "transparent" }}>
        activityplus.xyz
      </div>
      <div style={{ fontFamily, fontSize: 26, color: DIM, marginTop: 14, opacity: interpolate(frame, [65, 85], [0, 1], clamp) }}>
        Free · macOS 15 or later · Apple silicon
      </div>
    </AbsoluteFill>
  );
};

// ─── Assembly ───────────────────────────────────────────────────────────────

const sceneComponent = (id: SceneID, frames: number): React.ReactNode => {
  switch (id) {
    case "noise": return <NoiseScene frames={frames} />;
    case "fold": return <FoldScene frames={frames} />;
    case "overview": return <OverviewScene frames={frames} />;
    case "diagnosis": return <DiagnosisScene frames={frames} />;
    case "menubar": return <MenuBarScene frames={frames} />;
    case "features": return <FeaturesScene frames={frames} />;
    case "agents": return <AgentsScene frames={frames} />;
    case "privacy": return <PrivacyScene frames={frames} />;
    case "logo": return <LogoScene />;
  }
};

export const Trailer: React.FC<TrailerProps> = ({ voice, music }) => {
  const frame = useCurrentFrame();
  const { durationInFrames } = useVideoConfig();
  // Music sits lower under a voice, and fades in and out.
  const musicLevel = voice === "none" ? 0.8 : 0.32;
  const musicVolume = interpolate(frame, [0, 30, durationInFrames - 60, durationInFrames], [0, musicLevel, musicLevel, 0], clamp);
  return (
    <AbsoluteFill style={{ background: BG }}>
      <Backdrop />
      {scenes.map((scene) => (
        <Sequence key={scene.id} from={sceneStart(scene.id)} durationInFrames={scene.frames}>
          {sceneComponent(scene.id, scene.frames)}
        </Sequence>
      ))}
      {music && <Audio src={staticFile("audio/music.mp3")} volume={() => musicVolume} />}
      {voice !== "none" && scenes.map((scene) => (
        <Sequence key={`vo-${scene.id}`} from={sceneStart(scene.id) + scene.voiceAt}>
          <Audio src={staticFile(`audio/${voice}/${scene.id}.mp3`)} volume={1} />
        </Sequence>
      ))}
    </AbsoluteFill>
  );
};
