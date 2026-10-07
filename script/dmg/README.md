# The dressed disk image

`script/package.sh --styled` (or `STYLED=1 script/release.sh`) builds the
disk image with a background: a pastel wash, two frosted plates where Finder
puts pillr and the Applications link, and an arrow between them. Without the
flag the image is the plain Finder window it has always been.

- `style.sh` — lays the window out through Finder (macOS asks once whether
  the terminal may control Finder) and seals the image.
- `background.tiff` — 720 × 405 points, 1× and 2× in one file. Drawn by the
  film project's `DmgBackground` composition:

  ```bash
  npx remotion still DmgBackground out/dmg@2x.png --frame=0 --scale=0.75
  npx remotion still DmgBackground out/dmg.png --frame=0 --scale=0.375
  tiffutil -cathidpicheck out/dmg.png out/dmg@2x.png -out background.tiff
  ```

  Its icon positions (`DMG_ICONS`) and `style.sh`'s must stay the same.
