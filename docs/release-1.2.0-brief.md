# pillr 1.2.0: what is new (brief for the landing page, the film and the tour)

Product: pillr, a macOS app that lives on a screen edge as a notch-like pill showing usage
rings for coding agents (Claude Code, Codex, Cursor, Grok, Kimi, Copilot, Gemini CLI,
Antigravity, OpenCode, Droid, Hermes, ...), answers their permission prompts and questions
from the notch, and sets "effort" by moving the MacBook lid while holding ⌘.
Everything is worked out on the Mac; nothing is sent to a server.

## 1. A dashboard at the head of Settings
- Widgets in the iOS / macOS widget style, frosted over a pixel-art sky.
- Folded (default): Agents at work (time agents were busy), Commits shipped, API spent.
- Unfold with the down arrow at its foot: it slides down over the settings; the up arrow
  slides it away to one line ("Hide dashboard", "Show all metrics" on hover).
- Period picker: Today / This week / This month (default This month, remembered).
- Commits shipped: your own commits in the repos your agents worked in, from git on the Mac.
  Today = a column per hour, This week = a column per day, This month = a GitHub-style
  grid of squares. Hover any column or square for the count.
- Productivity section: Waiting on you, Lines changed, Streak, Achievements, Time at work by
  agent, Work by hour, Coding plans, Agent models, Recent sessions.
- API usage section: pay-as-you-go spend chart (Today / 3 days / 7 days), Spent by key, Keys.
  Only what was paid by use; plans belong to Productivity.
- Every chart and row lights up under the pointer with a tooltip.

## 2. A sky that is the real sky
- Pixel-art sky behind the dashboard, drawn at the Mac's own time: dawn, blue noon,
  golden afternoon, pink sunset, dusk, night with stars, a shooting star now and then,
  fireflies, drifting clouds, two mountain ranges with snow on the peaks by day.
- Real sunrise and sunset for where the Mac is (from its time zone, NOAA's equation, no
  location permission, nothing fetched): the sun sinks behind the mountains at the real time.
- The real moon: its phase (new, crescent, half, full; lit right when waxing, left when
  waning) and its hours (full rises at sunset; new keeps the sun's hours, faint by day).

## 3. Records, nudges, badges, a streak on fire
- The coach says on the notch when you beat your own best day, week or month (agent time,
  commits) and nudges on a slow week. Only ever against your own past.
- 48 badges: 16 families × bronze / silver / gold (e.g. Token Maxxer, Night Owl, Ship
  Machine, Hurricane, Unstoppable). Each family its own shape and enamel colour; the tier is
  the metal; gold has rays; one to three stars on the rim. Only earned badges are shown.
- A newly earned badge arrives on the notch on its own card: it flips in and lands with a
  bounce, rays turn behind it, confetti bursts, sparkles, and a shine crosses it. Several
  earned together take turns on one card (1/3, 2/3...). Each badge is told once.
- Streak card catches fire at 10, 50, 100, 150 and 365 days: pixel flames along its foot
  that grow at each milestone, sparks from 100 days, a glowing frame, "Full blaze" at a year.

## 4. Coding plans priced for you
- The plan each agent reports (Claude Max, ChatGPT Pro, Cursor Pro+, Copilot Pro, Kimi,
  GLM, MiniMax, Kiro, Kilo, Command Code, Amp, OpenCode...) is priced from the vendor's list.

## 5. Answered elsewhere, gone from the notch
- A question or approval held on the notch that you answer in the terminal or the Claude app
  instead now leaves the notch, and its reminder stops.

## 6. Easier to read, one glass
- Cards beside the notch wear the pill's own Liquid Glass; over the desktop the text colour is
  chosen by contrast against the wallpaper under the card (WCAG, at least 4.5:1).

## 7. Fixes
- Replies to the Claude app work whatever language the Claude app is in.
- An Antigravity done card brings Antigravity forward when clicked.

## Words
- No em dashes in anything people read.
- The app ships in English, French, Japanese, Portuguese (Brazil), Russian, Chinese (Simplified).
