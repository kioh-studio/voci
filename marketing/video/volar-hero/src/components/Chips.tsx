import React from 'react';
import {theme, font} from '../theme';

const chipBase: React.CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: 6,
  height: 26,
  padding: '0 12px',
  borderRadius: 20,
  fontFamily: font.ui,
  fontSize: 13,
  fontWeight: 500,
  whiteSpace: 'nowrap',
};

export const TimeChip: React.FC<{label: string; style?: React.CSSProperties}> = ({label, style}) => (
  <span style={{...chipBase, background: 'rgba(102,212,207,0.14)', color: theme.nowAccent, ...style}}>
    {label}
  </span>
);

export const PriorityChip: React.FC<{level: 'high' | 'med' | 'low'; style?: React.CSSProperties}> = ({
  level,
  style,
}) => {
  const color = level === 'high' ? theme.high : level === 'med' ? theme.med : theme.textSec;
  const label = level === 'high' ? 'High' : level === 'med' ? 'Medium' : 'Low';
  return (
    <span
      style={{
        ...chipBase,
        background: 'rgba(255,255,255,0.06)',
        color,
        ...style,
      }}
    >
      <span style={{width: 6, height: 6, borderRadius: '50%', background: color, flexShrink: 0}} />
      {label}
    </span>
  );
};

export const DurationChip: React.FC<{label: string; style?: React.CSSProperties}> = ({label, style}) => (
  <span style={{...chipBase, background: 'rgba(255,255,255,0.06)', color: theme.textSec, ...style}}>
    {label}
  </span>
);

export const NowChip: React.FC<{style?: React.CSSProperties}> = ({style}) => (
  <span
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      height: 22,
      padding: '0 9px',
      borderRadius: 6,
      background: theme.nowAccent,
      color: '#0B1F1D',
      fontFamily: font.ui,
      fontSize: 11,
      fontWeight: 600,
      letterSpacing: '0.06em',
      textTransform: 'uppercase',
      ...style,
    }}
  >
    Now
  </span>
);
