import React from 'react';
import {theme, font} from '../theme';

// Ported from design/volar-mac.jsx KeyBadge. `pressed` drives the 2px lunge from storyboard shot 1.
export const KeyBadge: React.FC<{children: React.ReactNode; pressed?: boolean; accent?: boolean}> = ({
  children,
  pressed = false,
  accent = false,
}) => (
  <span
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      minWidth: 34,
      height: 34,
      padding: '0 10px',
      borderRadius: 8,
      background: accent ? 'rgba(102,212,207,0.14)' : 'rgba(255,255,255,0.08)',
      border: `1px solid ${accent ? theme.nowRing : theme.borderHi}`,
      color: accent ? theme.nowAccent : theme.textPri,
      fontFamily: font.mono,
      fontSize: 16,
      fontWeight: 600,
      transform: `translateY(${pressed ? 2 : 0}px)`,
      boxShadow: pressed ? 'none' : '0 1px 0 rgba(255,255,255,0.06)',
    }}
  >
    {children}
  </span>
);
