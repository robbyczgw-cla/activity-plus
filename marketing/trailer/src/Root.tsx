import React from "react";
import { Composition } from "remotion";
import { FPS, totalFrames } from "./script";
import { Trailer, TrailerProps } from "./Trailer";
import { GpuCause, gpuTotalFrames } from "./GpuCause";

export const Root: React.FC = () => (
  <>
    <Composition id="Trailer" component={Trailer} durationInFrames={totalFrames} fps={FPS} width={1920} height={1080}
      defaultProps={{ voice: "none", music: false } satisfies TrailerProps} />
    <Composition id="GpuCause" component={GpuCause} durationInFrames={gpuTotalFrames} fps={FPS} width={1920} height={1080}
      defaultProps={{ music: true }} />
  </>
);
