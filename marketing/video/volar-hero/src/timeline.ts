// timeline.ts — frame boundaries for each shot, computed from the storyboard's second marks at 30fps.
export const FPS = 30;
const s = (sec: number) => Math.round(sec * FPS);

export const T = {
  shot1: s(0), // idle → keycap → popover drops (0.0s)
  shot2: s(1.0), // transcript types
  shot3: s(2.8), // transcript collapses into chips
  shot4: s(4.0), // pull back to full window, list populates, NOW row rises
  shot5: s(6.6), // park / resume
  shot6: s(8.8), // many ways in
  shot7: s(12.4), // lockup
  shot8: s(15.2), // loop crossfade back to frame 0
  end: s(16.0),
} as const;
