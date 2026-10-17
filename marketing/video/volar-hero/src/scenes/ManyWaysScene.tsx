import React from 'react';
import {interpolate, spring, Easing} from 'remotion';
import {theme, font} from '../theme';
import {KeyBadge} from '../components/KeyBadge';
import {Waveform} from '../components/Waveform';
import {FPS, T} from '../timeline';

const TILE_W = 300;
const TILE_H = 220;
const GAP = 40;
const COUNT = 5;
const TOTAL_W = COUNT * TILE_W + (COUNT - 1) * GAP;
const START_X = (1920 - TOTAL_W) / 2;
const TOP_Y = 400;
const STAGGER = 10.5; // 0.35s @ 30fps

const LABELS = ['Voice', 'Quick type', 'Any selected text', 'Launchers', 'Shortcuts & Siri'];

const Tile: React.FC<{index: number; frame: number; label: string; children: React.ReactNode}> = ({
  index,
  frame,
  label,
  children,
}) => {
  const appearAt = T.shot6 + index * STAGGER;
  const local = frame - appearAt;
  const p = spring({frame: local, fps: FPS, config: {damping: 16, mass: 0.7}});
  const opacity = interpolate(local, [0, 1], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});

  const convergeStart = T.shot6 + 78;
  const converge = interpolate(frame, [convergeStart, convergeStart + 16], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.in(Easing.cubic),
  });

  return (
    <div
      style={{
        position: 'absolute',
        left: START_X + index * (TILE_W + GAP),
        top: TOP_Y,
        width: TILE_W,
        opacity: opacity * converge,
        transform: `scale(${interpolate(p, [0, 1], [0.85, 1]) * (0.9 + 0.1 * converge)})`,
      }}
    >
      <div
        style={{
          height: TILE_H,
          borderRadius: 14,
          background: theme.surface,
          border: `1px solid ${theme.border}`,
          padding: 20,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 14,
        }}
      >
        {children}
      </div>
      <div
        style={{
          marginTop: 12,
          textAlign: 'center',
          fontFamily: font.ui,
          fontSize: 14,
          color: theme.textSec,
        }}
      >
        {label}
      </div>
    </div>
  );
};

const TypedText: React.FC<{text: string; startFrame: number; frame: number}> = ({text, startFrame, frame}) => {
  const count = Math.floor(
    interpolate(frame, [startFrame, startFrame + text.length * 1.6], [0, text.length], {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    })
  );
  return <>{text.slice(0, count)}</>;
};

const Orb: React.FC<{frame: number}> = ({frame}) => {
  const t = frame / 30;
  return (
    <svg width={72} height={72} viewBox="0 0 72 72">
      {[26, 19, 12].map((r, i) => (
        <circle
          key={r}
          cx={36}
          cy={36}
          r={r + Math.sin(t * 2 + i) * 2}
          fill="none"
          stroke={theme.textSec}
          strokeWidth={1.4}
          opacity={0.55 - i * 0.12}
        />
      ))}
    </svg>
  );
};

export const ManyWaysScene: React.FC<{frame: number}> = ({frame}) => {
  const sceneOpacity = interpolate(
    frame,
    [T.shot6 - 4, T.shot6 + 8, T.shot7 - 24, T.shot7 - 4],
    [0, 1, 1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}
  );
  if (sceneOpacity <= 0) return null;

  const t1 = T.shot6;
  const t2 = T.shot6 + STAGGER;
  const t3 = T.shot6 + STAGGER * 2;

  // Convergence: tiles collapse into a single compact list, centered.
  const convergeStart = T.shot6 + 78;
  const listP = spring({frame: frame - (convergeStart + 6), fps: FPS, config: {damping: 15}});
  const listOpacity = interpolate(frame, [convergeStart + 4, convergeStart + 16], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <div style={{position: 'absolute', inset: 0, opacity: sceneOpacity}}>
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 260,
          textAlign: 'center',
          fontFamily: font.ui,
          fontSize: 44,
          fontWeight: 600,
          letterSpacing: '-0.02em',
          color: theme.textPri,
        }}
      >
        Many ways in.
      </div>

      <Tile index={0} frame={frame} label={LABELS[0]}>
        <div style={{display: 'flex', gap: 6}}>
          <KeyBadge>⌃</KeyBadge>
          <KeyBadge>⌥</KeyBadge>
          <KeyBadge>M</KeyBadge>
        </div>
        <div style={{width: '100%'}}>
          <Waveform frame={frame - t1} bars={14} height={26} />
        </div>
      </Tile>

      <Tile index={1} frame={frame} label={LABELS[1]}>
        <div style={{display: 'flex', gap: 6}}>
          <KeyBadge>⌃</KeyBadge>
          <KeyBadge>⌥</KeyBadge>
          <KeyBadge>T</KeyBadge>
        </div>
        <div
          style={{
            width: '100%',
            height: 34,
            borderRadius: 8,
            background: theme.surfaceHi,
            border: `1px solid ${theme.border}`,
            display: 'flex',
            alignItems: 'center',
            padding: '0 10px',
            fontFamily: font.ui,
            fontSize: 13,
            color: theme.textPri,
          }}
        >
          <TypedText text="Pay invoice Friday" startFrame={t2 + 6} frame={frame} />
        </div>
      </Tile>

      <Tile index={2} frame={frame} label={LABELS[2]}>
        <div style={{width: '100%', display: 'flex', flexDirection: 'column', gap: 5}}>
          <div style={{height: 6, width: '80%', background: theme.border, borderRadius: 3}} />
          <div
            style={{
              height: 14,
              width: '95%',
              borderRadius: 3,
              background: `rgba(102,212,207,${
                0.3 *
                interpolate(frame, [t3 + 10, t3 + 16], [0, 1], {
                  extrapolateLeft: 'clamp',
                  extrapolateRight: 'clamp',
                })
              })`,
              fontFamily: font.ui,
              fontSize: 10.5,
              color: theme.textSec,
              display: 'flex',
              alignItems: 'center',
              padding: '0 4px',
            }}
          >
            Send the deck before 5
          </div>
          <div style={{height: 6, width: '60%', background: theme.border, borderRadius: 3}} />
        </div>
        <div
          style={{
            width: '100%',
            opacity: interpolate(frame, [t3 + 20, t3 + 28], [0, 1], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            }),
            borderRadius: 8,
            background: theme.nowSurface,
            border: `1px solid ${theme.nowRing}`,
            padding: '8px 10px',
            fontFamily: font.ui,
            fontSize: 12,
            color: theme.nowAccent,
            fontWeight: 500,
          }}
        >
          New Task in Volar
        </div>
      </Tile>

      <Tile index={3} frame={frame} label={LABELS[3]}>
        <div
          style={{
            width: '100%',
            height: 38,
            borderRadius: 9,
            background: theme.surfaceHi,
            border: `1px solid ${theme.borderHi}`,
            display: 'flex',
            alignItems: 'center',
            padding: '0 12px',
            fontFamily: font.mono,
            fontSize: 13,
            color: theme.textPri,
          }}
        >
          <TypedText text="volar Renew passport" startFrame={t1 + STAGGER * 3 + 6} frame={frame} />
        </div>
      </Tile>

      <Tile index={4} frame={frame} label={LABELS[4]}>
        <Orb frame={frame} />
        <div style={{fontFamily: font.ui, fontSize: 13, color: theme.textSec}}>Shortcuts</div>
      </Tile>

      {/* Convergence: one compact task list forms at center. */}
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: TOP_Y + TILE_H / 2 - 90,
          width: 380,
          marginLeft: -190,
          opacity: listOpacity,
          transform: `scale(${interpolate(listP, [0, 1], [0.7, 1])})`,
        }}
      >
        <div
          style={{
            borderRadius: 14,
            background: theme.surface,
            border: `1px solid ${theme.border}`,
            padding: 16,
            display: 'flex',
            flexDirection: 'column',
            gap: 8,
          }}
        >
          {['Send the deck to Nam', 'Pay invoice Friday', 'Renew passport'].map((title) => (
            <div
              key={title}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 10,
                fontFamily: font.ui,
                fontSize: 14,
                color: theme.textPri,
              }}
            >
              <span style={{width: 5, height: 5, borderRadius: '50%', background: theme.nowAccent}} />
              {title}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};
