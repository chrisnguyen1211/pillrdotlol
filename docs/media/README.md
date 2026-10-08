# Media

Images used by the README — the film's world of pixel sky and meadow, but
each at its own hour, so none repeats the film or the landing page.

- `lockup-black.png`, `lockup-white.png` — the halftone iris beside the word
  pillr in Inter, as the film and the app icon draw it; 790 × 320, shown at 280
  wide, for light and dark GitHub themes. The film project's `Lockup`
  composition at 2× (`--props='{"color":"#FFFFFF"}'` for white), trimmed.
- `meme.gif` — the README's opening loop, 7 s: a storm over the meadow, six
  agents and no idea who's done; then noon and a rainbow, pillr and a pair of
  pixel sunglasses. Original art, the app's own
  pill and card; the film project's `ReadmeMeme` composition (`src/Meme.tsx`),
  rendered to MP4 and turned into an 800-wide, 15 fps GIF with palettegen.
- `shots/` — 1600-wide stills shown at 800: the app's own cards and settings
  panes, exported by its render tests (`EFFORT_RENDER_DIR=… swift test --filter
  Render`), cut out and laid on the meadow by the film project's
  `Readme*` compositions (`src/Readme.tsx`, sources in `public/readme/`):
  `hero` (noon, a rainbow), `sessions` (golden hour), `done` (sunset and
  fireworks), `questions` (dusk), `api-keys` (night, fireflies), `effort`
  (an aurora).

  ```bash
  npx remotion still ReadmeHero out/readme/ReadmeHero.png
  ```
