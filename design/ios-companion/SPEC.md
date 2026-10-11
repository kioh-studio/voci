# Volar iOS — artboard spec v2 (matches Volar landing page v4)

You write Design Component artboards (`.dc.html`) for a design canvas. Each artboard = one iPhone
screen, **390×844 px, fixed size**, written to
`C:\Users\PC\AppData\Local\Temp\claude\C--projects-voci\1a612f0a-645a-481c-943f-007e4b3af73b\scratchpad\volar-design\project\<Name>.dc.html`.
If the file already exists, Read it first (the Write tool requires it), then REPLACE it entirely with
the new design — do not patch the old one, the design language changed. Use your Write tool (no
shell, no generator scripts). Do NOT publish, do NOT touch canvas.json, do NOT render/screenshot.

## Product context
Volar = voice-first task app for people with ADHD. Core idea: **one task at a time**. The main screen
is called **Now** and shows exactly ONE task (never a list) plus a quiet "NEXT" hint. Everything else
is optional **views** the user adds from "Customize › Add a view": **Goal rewards** (pick today's
goals, attach a reward you chose yourself, finish, then enjoy it on a timer), **Task board**, **Daily
wins**, **Soundscape**. The iPhone app is the companion of the Mac app: capture anytime by voice
(even offline), get reminded, finish, edit, earn your reward. Rules: no points, no streaks, no coins,
no guilt copy. AI suggests, user confirms. Copy: **English**, short, calm.

## File skeleton — copy EXACTLY (change only <title>, content, data-props)
```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Now</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&amp;family=Geist+Mono:wght@400;500;600&amp;display=swap">
<style>
body{margin:0}
a{color:#66D4CF}a:hover{color:#8FE3DF}
</style>
</helmet>
<div style="width: 390px; height: 844px; box-sizing: border-box; position: relative; overflow: hidden; background: #0E0F11; color: #F2F2F7; font-family: 'Geist', -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased">
  ... screen ...
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":390,"height":844}}'>
class Component extends DCLogic {
renderVals() { return {}; }
}
</script>
</body>
</html>
```
Hard rules: keep the support.js line exactly; close every non-void element; quote every attribute;
all styling inline `style="…"`; flex/grid + gap; no `<iframe>`, **no emoji anywhere** (use inline
stroke `<svg>` icons: viewBox 0 0 24 24, stroke="currentColor", stroke-width 1.8, round caps/joins,
fill none); real `<button>` for every tappable thing; `aria-label` on icon-only buttons. Apostrophes:
write a plain ' character in text (never `&#39;`). No fake status bar (no clock/battery) on app
screens: leave the top **59px** empty. Home indicator on every artboard: 134×5 pill, rgba(255,255,255,0.6),
radius 3, centered, bottom 8px.

## Tokens (taken from the landing page `:root`)
| token | value | use |
|---|---|---|
| bg | #0E0F11 | screen background |
| bg2 | #131417 | small chips / inset fields |
| surface | #232326 | sheets, cards, grouped lists |
| surfaceHi | #2C2C2E | secondary buttons, inputs |
| border | rgba(255,255,255,0.10) | 1px hairlines |
| borderHi | rgba(255,255,255,0.18) | secondary button border |
| fg | #F2F2F7 | titles/body |
| fg2 | #A0A4AA | meta, descriptions |
| fg3 | #74787E | tertiary labels (≥13px only) |
| mint | #66D4CF | the ONLY accent: NOW chip, primary buttons, FAB, active tab, earned rewards |
| mintSoft | #8FE3DF | top of primary button gradient |
| mintSur | rgba(102,212,207,0.14) | selected rows / earned highlight bg |
| mintGlow | rgba(102,212,207,0.30) | text-shadow glow on the NOW title |
| onMint | #06201F | text/icons on mint |
| high | #FF9F6B | High priority dot |
| med | #D9B77A | time/deadline value text (e.g. "17:00") — NOT a reward color |
| done | #30D158 | completed check fill |
| destruct | #FF453A | delete only |

Type: **Geist** for UI; **Geist Mono** (`font-family: 'Geist Mono', ui-monospace, monospace`) for
chips, times, durations, small uppercase labels, the NOW chip.
- Screen header: "Now" etc. 30px / 600 / letter-spacing -0.02em, with a mono meta beside it on the
  same baseline: 13px Geist Mono fg3 ("Sat, Oct 4").
- NOW task title: 30px / 600 / letter-spacing -0.025em / line-height 1.14 / `text-shadow: 0 0 30px rgba(102,212,207,0.30)`
- Section label: 12px Geist Mono / 600 / uppercase / letter-spacing 0.06em / fg2 (e.g. "TODAY'S GOALS")
- Row title: 16px / 500. Body/desc: 15px / 1.55 / fg2. Meta: 13px fg2. Buttons: 16px / 600.

Spacing 4pt grid, screen side padding **22px**. Radii: cards 14, sheets 28 (top), buttons 14,
chips 999. Touch targets ≥ 44px.

## Shared components (copy exactly where they appear)

**NOW chip**: `<span>` Geist Mono 11px/600, letter-spacing .1em, color #06201F, background #66D4CF,
radius 999, padding 4px 11px, text "NOW", align-self flex-start.

**Meta chips row** (under the NOW title): flex, gap 8, wrap; each chip Geist Mono 13px, padding 5px
10px, radius 8, background #131417, border 1px rgba(255,255,255,0.10), color fg2. Time chip text in
med #D9B77A or mint where specified. High priority chip has a 6px #FF9F6B dot before "High".

**Primary button**: height 52, radius 14, `background: linear-gradient(180deg,#8FE3DF,#66D4CF)`
(the only gradient allowed), color #06201F, 16px/600, full width.
**Secondary button**: height 48, radius 14, background #2C2C2E, border 1px rgba(255,255,255,0.18),
color fg, 16px/500.

**NEXT hint**: label "NEXT" Geist Mono 11px letter-spacing .06em fg3; below it a row: 14px empty
circle (1.2px border fg3) + task title 15px fg2 + right-aligned Geist Mono 12px med "after this one".

**Tab bar** (on Now, Goals, Views, Settings screens): absolute bottom 0, height 83, background
rgba(14,15,17,0.92), border-top 1px rgba(255,255,255,0.10), 3 equal `<button>` columns, content in
top 49px; icon 24px above label 10px/500; active mint, inactive #74787E. Tabs:
**Now** (icon: target — circle with inner circle), **Goals** (icon: flag), **Views** (icon: 2×2
squares grid). Settings is NOT a tab — it's opened from the Views tab.

**Mic FAB** (Now and Goals screens only): 64×64 circle, background #66D4CF, mic icon 28px #06201F,
`box-shadow: 0 8px 24px rgba(102,212,207,0.30)`, centered, bottom 96px. aria-label "Add task by voice".

**Sheet**: dim layer rgba(0,0,0,0.55) over a simplified copy of the screen behind; sheet bg #232326,
radius 28 28 0 0, grabber 36×5 #5A5A5E radius 3 centered 8px from top; header row: "Cancel" (mint,
left) · title (17/600, centered) · confirm action (mint 600, right).

**Reward chip**: pill (radius 999), Geist Mono 12px, padding 5px 11px, background #2C2C2E, border
1px rgba(255,255,255,0.10), color fg2, with a 14px stroke icon before the text. Reward icons: Game =
gamepad, One episode = tv/screen, An album = headphones, Walk & coffee = cup.

## Shared sample data (keep consistent — taken from the landing page)
Date **Sat, Oct 4**.
- NOW task: **Fix the auth token refresh** — High · 17:00 · 45m · desc "Push it to staging as soon as
  it builds — QA wants a pass before five." · NEXT: **Write the 0.4.2 changelog** (after this one)
- Today's goals (Goal rewards view): **Gym — push day** (done → reward Game · 30m EARNED),
  **Send the deck to Nam** (One episode · 45m), **Draft the Q4 proposal** (Walk & coffee · 20m)
- Your rewards: Game · 30m, One episode · 45m, An album · 40m, Walk & coffee · 20m
- Other tasks that exist: Book dentist (reminder 17:30), Renew the SSL cert (before Friday)
- Voice capture example: "Remind me to book the dentist tomorrow at 10, and renew the SSL cert before Friday"

## Quality bar
Native iOS feel (sheets, grouped lists, safe areas) wearing the landing page's look (dark #0E0F11,
Geist, mono chips, one mint accent). Primary actions in the bottom third. Lots of air: the Now
screen is ONE task, calm, nothing competing with it. No left-border accent cards, no gradient washes
(except the primary button), no emoji. Contrast ≥ 4.5:1 for text that matters.
