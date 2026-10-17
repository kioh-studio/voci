// theme.ts — tokens ported from Shared/Design/Theme.swift (dark values only; this video is dark-only).
export const theme = {
  bg: '#1C1C1E',
  surface: '#232326',
  surfaceHi: '#2C2C2E',
  border: 'rgba(255,255,255,0.10)',
  borderHi: 'rgba(255,255,255,0.18)',
  textPri: '#F2F2F7',
  textSec: '#98989D',
  textMut: '#7C7C80',
  high: '#FF9F6B',
  med: '#D9B77A',
  done: '#30D158',
  nowAccent: '#66D4CF',
  nowAccentSoft: '#8FE3DF',
  nowSurface: '#16302E',
  nowRing: 'rgba(102,212,207,0.55)',
  nowGlow: 'rgba(102,212,207,0.20)',
} as const;

import {interFontFamily, monoFontFamily} from './loadFonts';

export const font = {
  ui: interFontFamily,
  mono: monoFontFamily,
};
