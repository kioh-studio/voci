import React from 'react';
import {interpolate, spring} from 'remotion';
import {theme, font} from '../theme';
import {FPS, T} from '../timeline';

// design/logo/mark.svg, ported: viewBox unchanged, stroke drawn via a normalized pathLength so we
// don't need the real geometric length.
const Mark: React.FC<{drawProgress: number; sparkProgress: number; size: number}> = ({
  drawProgress,
  sparkProgress,
  size,
}) => (
  <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
    <path
      d="M6 13.2 Q9.7 19.7 13.5 21 Q17.5 17.3 22 8.3"
      stroke={theme.nowAccent}
      strokeWidth={3}
      strokeLinecap="round"
      strokeLinejoin="round"
      pathLength={1}
      strokeDasharray={1}
      strokeDashoffset={1 - drawProgress}
    />
    <circle cx={24.7} cy={4.9} r={2.15 * sparkProgress} fill={theme.nowAccent} />
  </svg>
);

export const LockupScene: React.FC<{frame: number}> = ({frame}) => {
  const inOpacity = interpolate(frame, [T.shot7 - 4, T.shot7 + 8], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  // Hands back to the looped idle window (shot 8) — see HeroComposition.
  const outOpacity = interpolate(frame, [T.shot8, T.shot8 + 16], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const opacity = inOpacity * outOpacity;
  if (opacity <= 0) return null;

  const local = frame - T.shot7;
  const drawProgress = interpolate(local, [0, 26], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  const sparkP = spring({frame: local - 22, fps: FPS, config: {damping: 12}});

  const wordmarkP = spring({frame: local - 30, fps: FPS, config: {damping: 16, mass: 0.8}});
  const wordmarkX = interpolate(wordmarkP, [0, 1], [-24, 0]);
  const wordmarkOpacity = interpolate(local, [30, 40], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  const taglineP = spring({frame: local - 42, fps: FPS, config: {damping: 18}});
  const taglineOpacity = interpolate(local, [42, 52], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        opacity,
        background: theme.bg,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 28,
      }}
    >
      <div style={{display: 'flex', alignItems: 'center', gap: 6}}>
        <Mark drawProgress={drawProgress} sparkProgress={Math.max(0, sparkP)} size={100} />
        <div
          style={{
            fontFamily: font.ui,
            fontSize: 72,
            fontWeight: 600,
            letterSpacing: '-0.04em',
            color: theme.textPri,
            opacity: wordmarkOpacity,
            transform: `translateX(${wordmarkX}px)`,
          }}
        >
          Volar
        </div>
      </div>
      <div
        style={{
          fontFamily: font.ui,
          fontSize: 26,
          color: theme.textSec,
          opacity: taglineOpacity,
          transform: `scale(${interpolate(taglineP, [0, 1], [0.96, 1])})`,
        }}
      >
        Stop choosing. <span style={{color: theme.textPri}}>Start doing.</span>
      </div>
    </div>
  );
};
