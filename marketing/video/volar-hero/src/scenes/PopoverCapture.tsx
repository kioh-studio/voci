import React from 'react';
import {interpolate, spring} from 'remotion';
import {theme, font} from '../theme';
import {Waveform} from '../components/Waveform';
import {PriorityChip, TimeChip, DurationChip} from '../components/Chips';
import {KeyBadge} from '../components/KeyBadge';
import {transcriptSentence} from '../data';
import {FPS, T} from '../timeline';

const POPOVER_W = 620;
// Keycap press starts at 0.2s (storyboard shot 1) — frame 0 itself must stay pure idle so it's
// pixel-identical to the loop-back frame at the end.
const POPOVER_START = 6;

export const PopoverCapture: React.FC<{frame: number}> = ({frame}) => {
  // frame is absolute (0 = video start).
  const dropLocal = frame - POPOVER_START;
  if (dropLocal < 0) return null;

  const dropP = spring({frame: dropLocal, fps: FPS, config: {damping: 14, mass: 0.85}});
  const translateY = interpolate(dropP, [0, 1], [-400, 0]);

  const fadeOutStart = T.shot4 - 12;
  const fadeOutEnd = T.shot4 + 4;
  const outOpacity = interpolate(frame, [fadeOutStart, fadeOutEnd], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  if (outOpacity <= 0) return null;

  const isRecording = frame < T.shot3;
  const isParsed = frame >= T.shot3;

  // Typewriter (shot 2) — the one linear animation allowed, per the brief.
  const typedCount = Math.floor(
    interpolate(frame, [T.shot2, T.shot3 - 6], [0, transcriptSentence.length], {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
    })
  );
  const typed = transcriptSentence.slice(0, typedCount);
  const caretOn = Math.floor(frame / 6) % 2 === 0;

  // Waveform envelope: pulses from 0.3s in, decays once the sentence finishes typing.
  const waveIn = interpolate(frame, [T.shot1 + 9, T.shot1 + 15], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const waveDecay = interpolate(frame, [T.shot3 - 10, T.shot3], [1, 0.08], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const waveEnvelope = waveIn * waveDecay;

  const cardIn = spring({frame: frame - T.shot3, fps: FPS, config: {damping: 15}});

  // Keycap hint (⌃ ⌥ M): the "trigger" beat, visible just before the popover covers it.
  const keycapIn = interpolate(dropLocal, [0, 5], [0, 1], {extrapolateRight: 'clamp'});
  const keycapOut = interpolate(dropLocal, [12, 20], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const keycapPressed = dropLocal >= 6 && dropLocal < 16;

  return (
    <>
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: 70,
          transform: 'translateX(-50%)',
          display: 'flex',
          gap: 8,
          opacity: keycapIn * keycapOut,
        }}
      >
        <KeyBadge pressed={keycapPressed}>⌃</KeyBadge>
        <KeyBadge pressed={keycapPressed}>⌥</KeyBadge>
        <KeyBadge pressed={keycapPressed}>M</KeyBadge>
      </div>
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: 150,
          width: POPOVER_W,
          marginLeft: -POPOVER_W / 2,
          transform: `translateY(${translateY}px)`,
          opacity: outOpacity,
        }}
      >
        <div
        style={{
          borderRadius: 18,
          background: 'rgba(35,35,38,0.97)',
          border: `1px solid ${theme.borderHi}`,
          boxShadow: '0 30px 70px rgba(0,0,0,0.6)',
          padding: '18px 20px 20px',
        }}
      >
        {/* hint row */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            fontFamily: font.ui,
            fontSize: 13,
            color: theme.textMut,
          }}
        >
          <span style={{display: 'inline-flex', alignItems: 'center', gap: 8}}>
            {isRecording ? (
              <>
                <span style={{width: 7, height: 7, borderRadius: '50%', background: theme.high}} />
                <span>Listening…</span>
              </>
            ) : (
              <span style={{color: theme.textSec}}>Looks right? Hit return.</span>
            )}
          </span>
          <span>Esc to cancel</span>
        </div>

        {/* waveform / settled dot */}
        <div style={{marginTop: 10, marginBottom: 6, height: 44}}>
          {isRecording && <Waveform frame={frame - T.shot1} envelope={waveEnvelope} />}
        </div>

        {/* transcript */}
        {isRecording && (
          <div
            style={{
              minHeight: 40,
              padding: '6px 4px 2px',
              fontFamily: font.ui,
              fontSize: 20,
              lineHeight: 1.4,
              color: theme.textPri,
              position: 'relative',
            }}
          >
            {typed}
            <span
              style={{
                display: 'inline-block',
                width: 3,
                height: 20,
                marginLeft: 3,
                verticalAlign: '-3px',
                background: theme.nowAccent,
                opacity: caretOn ? 1 : 0,
              }}
            />
          </div>
        )}

        {/* parsed card */}
        {isParsed && (
          <div
            style={{
              marginTop: 8,
              padding: '16px 16px',
              background: 'rgba(255,255,255,0.04)',
              border: `1px solid ${theme.border}`,
              borderRadius: 12,
              opacity: cardIn,
              transform: `translateY(${interpolate(cardIn, [0, 1], [10, 0])}px)`,
            }}
          >
            <div
              style={{
                fontFamily: font.ui,
                fontSize: 18,
                fontWeight: 600,
                color: theme.textPri,
                marginBottom: 12,
              }}
            >
              Send the deck to Nam
            </div>
            <div style={{display: 'flex', gap: 8, flexWrap: 'wrap', position: 'relative', minHeight: 26}}>
              <ChipSlot frame={frame} delay={4}>
                <TimeChip label="Today 5 PM" />
              </ChipSlot>
              <ChipSlot frame={frame} delay={10}>
                <PriorityChip level="high" />
              </ChipSlot>
              <ChipSlot frame={frame} delay={16}>
                <DurationChip label="15m" />
              </ChipSlot>
            </div>
          </div>
        )}
        </div>
      </div>
    </>
  );
};

// A chip that pops into its resting slot with a small spring — the "chip travels from the
// matching word" beat, simplified to a short flight-in-place rather than a literal cross-DOM
// measured path.
const ChipSlot: React.FC<{frame: number; delay: number; children: React.ReactNode}> = ({
  frame,
  delay,
  children,
}) => {
  const local = frame - T.shot3 - delay;
  const p = spring({frame: local, fps: FPS, config: {damping: 14, mass: 0.5}});
  const opacity = interpolate(local, [0, 6], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
  return (
    <div
      style={{
        opacity,
        transform: `translateY(${interpolate(p, [0, 1], [-14, 0])}px) scale(${interpolate(p, [0, 1], [0.7, 1])})`,
      }}
    >
      {children}
    </div>
  );
};
