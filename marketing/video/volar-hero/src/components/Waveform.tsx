import React from 'react';
import {theme} from '../theme';

// Deterministic per-bar amplitude — ported from design/volar-popover.jsx's rAF sine stack, but
// driven by `frame` instead of performance.now() so every render (still or video) is identical.
function barHeight(bar: number, bars: number, t: number, envelope: number, maxH: number): number {
  const phase = bar * 0.35;
  const v =
    Math.sin(t * 6 + phase) * 0.55 +
    Math.sin(t * 10 + phase * 1.7) * 0.35 +
    Math.cos(t * 3 + phase * 0.5) * 0.2;
  const norm = (v + 1.1) / 2.2;
  const edgeFalloff = 0.4 + 0.6 * Math.exp(-Math.pow((bar - bars / 2) / (bars / 2.6), 2));
  return Math.max(2, norm * edgeFalloff * envelope * (maxH - 4));
}

export const Waveform: React.FC<{
  frame: number;
  bars?: number;
  height?: number;
  envelope?: number; // 0..1 overall amplitude (for decay)
  color?: string;
}> = ({frame, bars = 32, height = 42, envelope = 1, color = theme.nowAccent}) => {
  const t = frame / 30;
  return (
    <div
      style={{
        height,
        width: '100%',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 4,
      }}
    >
      {Array.from({length: bars}).map((_, i) => {
        const h = barHeight(i, bars, t, envelope, height);
        return (
          <div
            key={i}
            style={{
              width: 3.5,
              height: h,
              background: color,
              borderRadius: 2,
              opacity: 0.55 + 0.45 * envelope,
            }}
          />
        );
      })}
    </div>
  );
};
