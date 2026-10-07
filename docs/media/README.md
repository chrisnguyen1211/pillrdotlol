# Media

Images used by the README.

- `lockup-black.png`, `lockup-white.png` — the halftone iris beside the word
  pillr in Inter, as the film and the app icon draw it; 790 × 320, shown at 280
  wide, for light and dark GitHub themes. Rendered by the film project's
  `Lockup` composition at 2× (`--props='{"color":"#FFFFFF"}'` for white), then
  trimmed.
- `hero.gif` — the top of the README: 6.4 s of the intro film (the pill fills
  and turns to glass), 760 wide, 10 fps, under 3 MB. Cut from
  `~/pillr-video/out/pillr-intro-final.mp4` with ffmpeg's palettegen /
  paletteuse.
- `hero.png` — the pill on a MacBook screen with a done card. 2400 × 1350,
  under 1 MB. Rendered from the film project's `Hero` composition
  (`npx remotion still Hero out/hero.png --frame=300 --scale=1.25`).
- `ui/` — the app's own cards as the film shows them (exported by the render
  tests): usage, sessions, a done card, an approval, the API keys card and the
  lid's effort card.
