import React from 'react';
import {theme, font} from '../theme';
import {NowChip} from './Chips';

// Plain filler row — dimmed background list (shot 4). No chips, just a title + a priority dot,
// matching design/volar-mac.jsx's TaskRow at a glance without porting every prop.
export const FillerRow: React.FC<{title: string; style?: React.CSSProperties}> = ({title, style}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 12,
      height: 40,
      padding: '0 16px',
      borderRadius: 9,
      ...style,
    }}
  >
    <div
      style={{
        width: 16,
        height: 16,
        borderRadius: '50%',
        border: `1.5px solid ${theme.borderHi}`,
        flexShrink: 0,
      }}
    />
    <span
      style={{
        fontFamily: font.ui,
        fontSize: 15,
        fontWeight: 500,
        color: theme.textPri,
        whiteSpace: 'nowrap',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
      }}
    >
      {title}
    </span>
  </div>
);

// The hero NOW row — nowSurface fill, 3px left accent bar, NOW chip. `barOpacity`/`fillOpacity`
// let a caller cross-fade this in without a hard cut.
export const NowRow: React.FC<{
  title: string;
  subtitle?: string;
  style?: React.CSSProperties;
}> = ({title, subtitle, style}) => (
  <div
    style={{
      position: 'relative',
      display: 'flex',
      alignItems: 'center',
      gap: 14,
      height: subtitle ? 58 : 48,
      padding: '0 18px 0 20px',
      borderRadius: 10,
      background: theme.nowSurface,
      overflow: 'hidden',
      ...style,
    }}
  >
    <div style={{position: 'absolute', left: 0, top: 0, bottom: 0, width: 3, background: theme.nowAccent}} />
    <div
      style={{
        width: 18,
        height: 18,
        borderRadius: '50%',
        border: `1.6px solid ${theme.nowAccent}`,
        flexShrink: 0,
      }}
    />
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
        }}
      >
        {title}
      </span>
      {subtitle && (
        <span style={{fontFamily: font.ui, fontSize: 12.5, color: theme.textSec}}>{subtitle}</span>
      )}
    </div>
    <NowChip />
  </div>
);

// "PAUSED — «title»" label row (design/volar-mac.jsx's ParkedNoteRow, per storyboard shot 5).
export const ParkedRow: React.FC<{title: string; note: string; style?: React.CSSProperties}> = ({
  title,
  note,
  style,
}) => (
  <div
    style={{
      display: 'flex',
      flexDirection: 'column',
      gap: 3,
      padding: '10px 20px',
      ...style,
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
);
