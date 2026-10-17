import React from 'react';
import {theme, font} from '../theme';

export const WINDOW_W = 1440;
export const WINDOW_H = 860;

const TrafficLights: React.FC = () => (
  <div style={{display: 'flex', gap: 8}}>
    {['#FF5F57', '#FEBC2E', '#28C840'].map((c) => (
      <div key={c} style={{width: 12, height: 12, borderRadius: '50%', background: c, opacity: 0.9}} />
    ))}
  </div>
);

const SidebarItem: React.FC<{label: string; active?: boolean; count?: number}> = ({
  label,
  active,
  count,
}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      height: 32,
      padding: '0 10px',
      borderRadius: 7,
      background: active ? 'rgba(102,212,207,0.12)' : 'transparent',
      color: active ? theme.nowAccent : theme.textSec,
    }}
  >
    <span
      style={{
        flex: 1,
        fontFamily: font.ui,
        fontSize: 14,
        fontWeight: active ? 600 : 500,
      }}
    >
      {label}
    </span>
    {count != null && (
      <span style={{fontFamily: font.ui, fontSize: 12, color: theme.textMut}}>{count}</span>
    )}
  </div>
);

// The macOS-style app window chrome: traffic lights, title bar, sidebar. `children` is the main
// list area content — everything shot-specific lives there.
export const AppWindow: React.FC<{dim?: boolean; children: React.ReactNode}> = ({dim, children}) => (
  <div
    style={{
      width: WINDOW_W,
      height: WINDOW_H,
      borderRadius: 14,
      background: theme.surface,
      border: `1px solid ${theme.border}`,
      boxShadow: '0 40px 100px rgba(0,0,0,0.55)',
      overflow: 'hidden',
      display: 'flex',
      flexDirection: 'column',
      opacity: dim ? 0.55 : 1,
    }}
  >
    <div
      style={{
        height: 52,
        flexShrink: 0,
        display: 'flex',
        alignItems: 'center',
        padding: '0 18px',
        borderBottom: `1px solid ${theme.border}`,
      }}
    >
      <TrafficLights />
    </div>
    <div style={{flex: 1, display: 'flex', minHeight: 0}}>
      <div
        style={{
          width: 220,
          flexShrink: 0,
          borderRight: `1px solid ${theme.border}`,
          padding: '18px 12px',
          display: 'flex',
          flexDirection: 'column',
          gap: 2,
        }}
      >
        <SidebarItem label="Today" active count={dim ? undefined : 30} />
        <SidebarItem label="Upcoming" count={12} />
        <SidebarItem label="Inbox" count={3} />
      </div>
      <div style={{flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column'}}>{children}</div>
    </div>
  </div>
);
