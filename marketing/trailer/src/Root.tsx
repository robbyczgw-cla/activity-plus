import React from "react";
import { Composition } from "remotion";
import { FPS, totalFrames } from "./script";
import { Trailer, TrailerProps } from "./Trailer";

export const Root: React.FC = () => (
  <>
    <Composition id="Trailer" component={Trailer} durationInFrames={totalFrames} fps={FPS} width={1920} height={1080}
      defaultProps={{ voice: "none", music: false } satisfies TrailerProps} />
  </>
);
