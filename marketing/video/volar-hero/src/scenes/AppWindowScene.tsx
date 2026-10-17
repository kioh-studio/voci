import React from 'react';
import {interpolate, Easing} from 'remotion';
import {theme, font} from '../theme';
import {AppWindow} from '../components/Window';
import {FillerRow} from '../components/TaskRow';
import {HeroTaskRow} from '../components/HeroTaskRow';
import {PopoverCapture} from './PopoverCapture';
import {fillerTasks, taskA, taskB, parkedNote} from '../data';
import {T} from '../timeline';

const HEADER_Y = 84;
const ROW_STEP = 34;
const HERO_STEP = 66; // vertical room the NOW pill needs
const PAUSED_STEP = 50; // vertical room the "PAUSED — «…»" label needs, reserved below the NOW slot
const FILLER_TOP = HEADER_Y + HERO_STEP + PAUSED_STEP;

// Per-filler-row style: barely-visible before the reveal, a staggered pop-in at shot 4, then a
// settle to a dim backdrop for the rest of the video. Index 0 sits right under the NOW slot.
function fillerStyle(index: number, frame: number): {opacity: number; translateY: number; scale: number} {
  const revealStart = T.shot4 + index * 0.8;
  const reveal = interpolate(frame, [revealStart, revealStart + 10], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });
  const recedeStart = T.shot4 + 26;
  const recede = interpolate(frame, [recedeStart, recedeStart + 22], [1, 0.25], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const preReveal = interpolate(frame, [0, T.shot4], [0.08, 0.08], {extrapolateRight: 'clamp'});
  const opacity = frame < revealStart ? preReveal : reveal < 1 ? reveal : recede;
  return {opacity, translateY: (1 - reveal) * -8, scale: 0.97 + 0.03 * reveal};
}

export const AppWindowScene: React.FC<{frame: number}> = ({frame}) => {
  // Whole-scene fade out once the window hands off to the "many ways in" grid (shot 6).
  const sceneOpacity = interpolate(frame, [T.shot5 + 64, T.shot5 + 76], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  if (sceneOpacity <= 0) return null;

  // Camera: zoom into the popover for the capture beats, then pull back to reveal the window.
  const zoom = interpolate(
    frame,
    [0, 20, T.shot3 + 10, T.shot4 + 50],
    [1, 1.32, 1.32, 1],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp', easing: Easing.bezier(0.22, 0.8, 0.2, 1)}
  );

  const windowDim = frame < T.shot4;

  // Task A's journey: list row 11 → rises into NOW (shot 4) → bumped to "paused" (shot 5) → resumes.
  const LIST_Y = FILLER_TOP + 11 * ROW_STEP;
  const PAUSED_Y = HEADER_Y + HERO_STEP;
  const riseStart = T.shot4 + 26;
  const resumeStart = T.shot5 + 52;
  let aHighlight: number;
  let aTopResolved: number;
  if (frame < riseStart) {
    aHighlight = 0;
    aTopResolved = LIST_Y;
  } else if (frame < T.shot5) {
    const rise = interpolate(frame, [riseStart, riseStart + 22], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
    aHighlight = rise;
    aTopResolved = interpolate(rise, [0, 1], [LIST_Y, HEADER_Y]);
  } else if (frame < resumeStart) {
    aHighlight = 0;
    aTopResolved = PAUSED_Y;
  } else {
    const resume = interpolate(frame, [resumeStart, resumeStart + 12], [0, 1], {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'});
    aHighlight = resume;
    aTopResolved = interpolate(resume, [0, 1], [PAUSED_Y, HEADER_Y]);
  }
  const aNote = frame >= T.shot5 ? parkedNote : undefined;

  // Task B: cuts in as NOW right at shot 5, gets checked, then exits.
  const bIn = interpolate(frame, [T.shot5, T.shot5 + 10], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const bChecked = interpolate(frame, [T.shot5 + 40, T.shot5 + 48], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const bOut = interpolate(frame, [T.shot5 + 48, T.shot5 + 58], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const bVisible = frame >= T.shot5 && frame < T.shot5 + 58;
  const bHighlight = Math.min(bIn, bOut);

  const showNowGlow = frame >= T.shot4 + 26;
  const glowOpacity = interpolate(frame, [T.shot4 + 26, T.shot4 + 40], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <div style={{position: 'absolute', inset: 0, opacity: sceneOpacity}}>
      <div
        style={{
          position: 'absolute',
          inset: 0,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          transform: `scale(${zoom})`,
          transformOrigin: '50% 300px',
        }}
      >
        <AppWindow dim={windowDim}>
          <div style={{padding: '20px 24px 0'}}>
            <div style={{fontFamily: font.ui, fontSize: 24, fontWeight: 600, color: theme.textPri}}>
              Today
            </div>
          </div>
          <div style={{position: 'relative', flex: 1, margin: '0 24px', overflow: 'hidden'}}>
            {showNowGlow && (
              <div
                style={{
                  position: 'absolute',
                  left: -60,
                  top: HEADER_Y - 40,
                  width: 400,
                  height: 200,
                  opacity: glowOpacity,
                  background: `radial-gradient(circle, ${theme.nowGlow}, transparent 70%)`,
                }}
              />
            )}

            {fillerTasks.map((title, i) => {
              const {opacity, translateY, scale} = fillerStyle(i, frame);
              return (
                <div
                  key={title}
                  style={{
                    position: 'absolute',
                    left: 0,
                    right: 0,
                    top: FILLER_TOP + i * ROW_STEP,
                    opacity,
                    transform: `translateY(${translateY}px) scale(${scale})`,
                  }}
                >
                  <FillerRow title={title} />
                </div>
              );
            })}

            <HeroTaskRow top={aTopResolved} title={taskA.title} highlight={aHighlight} note={aNote} />
            {bVisible && (
              <HeroTaskRow top={HEADER_Y} title={taskB.title} highlight={bHighlight} checked={bChecked} />
            )}
          </div>
        </AppWindow>
      </div>

      <PopoverCapture frame={frame} />
    </div>
  );
};
