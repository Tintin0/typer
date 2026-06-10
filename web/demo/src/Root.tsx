import React from "react";
import { Composition } from "remotion";
import { Demo, DEMO_DURATION_S } from "./Demo";

const FPS = 30;

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="typer-demo-dark"
      component={Demo}
      durationInFrames={Math.round(DEMO_DURATION_S * FPS)}
      fps={FPS}
      width={1280}
      height={800}
      defaultProps={{ theme: "dark" as const }}
    />
    <Composition
      id="typer-demo-light"
      component={Demo}
      durationInFrames={Math.round(DEMO_DURATION_S * FPS)}
      fps={FPS}
      width={1280}
      height={800}
      defaultProps={{ theme: "light" as const }}
    />
  </>
);
