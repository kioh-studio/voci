import React from 'react';
import {Composition} from 'remotion';
import {HeroComposition} from './HeroComposition';
import {T} from './timeline';

export const Root: React.FC = () => {
  return (
    <Composition
      id="VolarHero"
      component={HeroComposition}
      width={1920}
      height={1080}
      fps={30}
      durationInFrames={T.end}
    />
  );
};
