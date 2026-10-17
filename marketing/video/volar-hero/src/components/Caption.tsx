import React from 'react';
import {interpolate, Easing} from 'remotion';
import {theme, font} from '../theme';

// Left-bottom caption with a mask-wipe entrance (clip-path, not a fade-up) per the brief.
// `accentWord` (if present and matching a trailing word) renders in nowAccent.
export const Caption: React.FC<{
  frame: number;
  start: number;
  end: number;
  text: string;
  accentWord?: string;
}> = ({frame, start, end, text, accentWord}) => {
  const local = frame - start;
  if (local < -1 || frame > end) return null;
  const wipe = interpolate(local, [0, 14], [0, 100], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.bezier(0.2, 0.8, 0.2, 1),
  });
  const fadeOut = interpolate(frame, [end - 10, end], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const opacity = (local < 0 ? 0 : 1) * fadeOut;

  const parts = accentWord && text.includes(accentWord) ? text.split(accentWord) : null;

  return (
    <div
      style={{
        position: 'absolute',
        left: 96,
        bottom: 90,
        clipPath: `inset(0 ${100 - wipe}% 0 0)`,
        opacity,
      }}
    >
      <div
        style={{
          fontFamily: font.ui,
          fontSize: 56,
          fontWeight: 600,
          letterSpacing: '-0.02em',
          color: theme.textPri,
          whiteSpace: 'nowrap',
        }}
      >
        {parts ? (
          <>
            {parts[0]}
            <span style={{color: theme.nowAccent}}>{accentWord}</span>
            {parts[1]}
          </>
        ) : (
          text
        )}
      </div>
    </div>
  );
};
