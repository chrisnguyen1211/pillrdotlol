# Media

Images used by the README — drawn for it alone, so it shows what the film and
the landing page do not.

- `lockup-black.png`, `lockup-white.png` — the halftone iris beside the word
  pillr in Inter, as the film and the app icon draw it; 790 × 320, shown at 280
  wide, for light and dark GitHub themes. The film project's `Lockup`
  composition at 2× (`--props='{"color":"#FFFFFF"}'` for white), trimmed.
- `shots/` — 1600-wide stills shown at 800: the app's own cards and settings
  panes, exported by its render tests (`EFFORT_RENDER_DIR=… swift test --filter
  Render`), cut out and laid on a graphite studio by the film project's
  `Readme*` compositions (`src/Readme.tsx`, sources in `public/readme/`):
  `hero`, `sessions`, `done`, `questions`, `api-keys`, `effort`.

  ```bash
  npx remotion still ReadmeHero out/readme/ReadmeHero.png
  ```
