import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {theme} from './theme';
import {AppWindowScene} from './scenes/AppWindowScene';
import {ManyWaysScene} from './scenes/ManyWaysScene';
import {LockupScene} from './scenes/LockupScene';
import {Caption} from './components/Caption';
import {captions} from './data';
import {T} from './timeline';

export const HeroComposition: React.FC = () => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill style={{background: theme.bg}}>
      <AppWindowScene frame={frame} />
      <ManyWaysScene frame={frame} />

      {/* Shot 8: loop back to the exact frame-0 idle window; Lockup fades out on top of it. */}
      {frame >= T.shot7 && <AppWindowScene frame={0} />}
      <LockupScene frame={frame} />

      <Caption frame={frame} start={T.shot3} end={T.shot4} text={captions.sayItOnce} />
      <Caption
        frame={frame}
        start={T.shot4 + 4}
        end={T.shot5}
        text={captions.picksNext}
        accentWord="next"
      />
      <Caption
        frame={frame}
        start={T.shot5 + 4}
        end={T.shot6}
        text={captions.parkResume}
        accentWord="Park"
      />
      <Caption
        frame={frame}
        start={T.shot6 + 4}
        end={T.shot7}
        text={captions.manyWays}
        accentWord="One"
      />
    </AbsoluteFill>
  );
};
