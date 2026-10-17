import React from 'react';
import {theme, font} from '../theme';
import {NowChip} from './Chips';

// A checkmark that draws via strokeDashoffset (spec: "checkmark draws"), not a static icon swap.
const DrawnCheck: React.FC<{progress: number}> = ({progress}) => {
  const len = 16;
  return (
    <svg width={18} height={18} viewBox="0 0 18 18">
      <path
        d="M4 9.5 L7.5 13 L14 5.5"
        fill="none"
        stroke={theme.done}
        strokeWidth={2.4}
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeDasharray={len}
        strokeDashoffset={len * (1 - progress)}
      />
    </svg>
  );
};

// The one task that gets to be NOW at a given moment (shots 4–5). `highlight` 0..1 crossfades
// between a quiet "PAUSED — «title»" label (only rendered when `note` is given) and the full
// nowSurface hero pill. Without a `note`, `highlight` just fades/scales the pill itself in or out.
export const HeroTaskRow: React.FC<{
  top: number;
  title: string;
  note?: string;
  highlight: number; // 0..1
  checked?: number; // 0..1 draw progress
}> = ({top, title, note, highlight, checked = 0}) => {
  const showPaused = note !== undefined;

  return (
    <div style={{position: 'absolute', left: 0, right: 0, top}}>
      {showPaused && (
        <div
          style={{
            position: 'absolute',
            inset: 0,
            opacity: 1 - highlight,
            display: 'flex',
            flexDirection: 'column',
            gap: 3,
            padding: '10px 20px',
          }}
        >
          <span
            style={{
              fontFamily: font.ui,
              fontSize: 12,
              fontWeight: 600,
              letterSpacing: '0.08em',
              textTransform: 'uppercase',
              color: theme.textSec,
            }}
          >
            Paused — «{title}»
          </span>
          <span style={{fontFamily: font.ui, fontSize: 12.5, color: theme.textMut}}>{note}</span>
        </div>
      )}

      <div
        style={{
          position: 'relative',
          display: 'flex',
          alignItems: 'center',
          gap: 14,
          height: 52,
          padding: '0 18px 0 20px',
          borderRadius: 10,
          background: theme.nowSurface,
          overflow: 'hidden',
          opacity: highlight,
          transform: `scale(${0.97 + 0.03 * highlight})`,
        }}
      >
        <div style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: 3, background: theme.nowAccent}} />
        <div
          style={{
            width: 18,
            height: 18,
            borderRadius: '50%',
            border: `1.6px solid ${checked > 0 ? theme.done : theme.nowAccent}`,
            background: checked > 0.9 ? theme.done : 'transparent',
            flexShrink: 0,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          {checked > 0 && <DrawnCheck progress={checked} />}
        </div>
        <div style={{flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 2}}>
          <span
            style={{
              fontFamily: font.ui,
              fontSize: 16,
              fontWeight: 600,
              color: theme.textPri,
              whiteSpace: 'nowrap',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              textDecoration: checked > 0.5 ? 'line-through' : 'none',
              textDecorationColor: theme.textMut,
            }}
          >
            {title}
          </span>
          {note && highlight > 0.5 && (
            <span style={{fontFamily: font.ui, fontSize: 12.5, color: theme.textSec}}>{note}</span>
          )}
        </div>
        <NowChip />
      </div>
    </div>
  );
};
