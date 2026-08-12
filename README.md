# Prism

A web audio visualizer that paints itself with the colors of the album cover.

Open `index.html` in a browser. That's it — one self-contained file, no build step,
no dependencies, no network calls.

## Audio sources

| Source | How | Notes |
| --- | --- | --- |
| **Audio file** | Button, `O`, or drag & drop | Plays locally, reads embedded cover art and tags |
| **Tab / system audio** | Button → pick a tab, tick *Share tab audio* | Visualize Spotify, YouTube, anything playing in another tab |
| **Microphone** | Button | Live input from an instrument, a room, a turntable |

Tab and mic input are analyzed but never routed back to your speakers, so there's
no feedback loop.

## Cover colors

For local files, cover art and title/artist/album are parsed straight out of the
file — no tag library, no lookups:

- **MP3** — ID3v2.2/2.3/2.4 (`APIC`, `TIT2`, `TPE1`, `TALB`)
- **FLAC** — `PICTURE` metadata blocks and Vorbis comments, including
  base64 `METADATA_BLOCK_PICTURE`
- **M4A / MP4 / ALAC** — `moov › udta › meta › ilst › covr`

The cover is quantized into 12-bit color buckets, each bucket scored by how much
of the image it covers *and* how vivid it is, and the winners picked greedily so
they stay well separated — you get the record's actual accent colors rather than
five shades of the same brown. Those colors drive the bars, the glow, the
background, and the app's own UI.

No embedded art (or capturing a tab)? Drop any image onto the window and the
palette comes from that instead. Or switch the palette source to custom colors,
rainbow, monochrome, or heat.

## Visual modes

`Spectrum bars` · `Radial burst` · `Waveform` · `Liquid blob` · `Particle field` · `Pulse rings`

Press `V` to cycle (`Shift+V` to go back).

## Customization

Everything in the panel is live and persists to `localStorage`:

- **Mode** — bass pulse, rotation, line weight, particle count
- **Bars** — count, gap, roundness, mirror, peak caps, reflection
- **Color** — palette source, spread, hue drift, saturation, brightness
- **Glow & background** — glow, motion tail, blurred cover / palette gradient /
  solid / black, blur, dim, vignette, center art, track title
- **Analysis** — sensitivity, smoothing, FFT size, noise floor, ceiling, beat
  trigger, log frequency axis

Seven built-in presets (Neon bars, Vinyl, Oscilloscope, Lava lamp, Starfield,
Sonar, Minimal), plus save/load/delete of your own and *Copy JSON* to move
settings around. `🎲` randomizes the whole look.

## Keyboard

| Key | Action |
| --- | --- |
| `Space` | Play / pause |
| `←` `→` | Seek ±5s |
| `V` | Next visual mode (`Shift+V` previous) |
| `C` | Toggle the control panel |
| `H` | Hide all UI |
| `F` | Fullscreen |
| `R` | Randomize |
| `O` | Open a file |

The UI also fades out on its own after a few seconds of no input.

## Deploying

Prism is one static file, so hosting it is a copy. `deploy/` targets a VPS
running Caddy:

```sh
./deploy/deploy.sh --dry-run --with-caddy   # see exactly what it will do
./deploy/deploy.sh --with-caddy             # first deploy: page + site config
./deploy/deploy.sh                          # every deploy after: page only
```

It uses your existing SSH access — nothing secret lives in this repo. Defaults
are overridable:

| Variable | Default |
| --- | --- |
| `SSH_HOST` | `root@163.245.220.226` |
| `DOMAIN` | `visualmental.163-245-220-226.nip.io` |
| `WEB_ROOT` | `/var/www/visualmental` |
| `SITES_DIR` | `/etc/caddy/sites` |
| `MAIN_CADDYFILE` | `/etc/caddy/Caddyfile` |

`--with-caddy` installs `deploy/Caddyfile` as its own file under `SITES_DIR`
rather than replacing your existing config, adds the `import` line only if it's
missing (backing up the original first), and runs `caddy validate` before
reloading — a broken config won't take the server down.

The nip.io hostname resolves to the embedded IP, so Caddy gets a real Let's
Encrypt certificate over HTTP-01 with no DNS setup. Ports 80 and 443 need to be
open. HTTPS isn't just polish here: **microphone and tab capture require a
secure context**, so they won't work over plain HTTP.

The site config sets a CSP tight enough to match the app exactly
(`default-src 'none'`, inline script/style, `blob:` for audio and artwork) and a
`Permissions-Policy` that grants `microphone` and `display-capture` — a
restrictive default would silently break two of the three audio sources. Both
were verified by serving the page under those exact headers.

## Notes

- Tab audio capture needs Chrome or Edge; Firefox and Safari don't offer
  tab audio through `getDisplayMedia`. File and mic input work everywhere.
- Playable formats are whatever the browser decodes. Cover art extraction
  covers MP3, FLAC, and MP4/M4A — an OGG file will play, but its art won't be
  read, so drop an image in for colors.
- Everything stays on your machine. Files are read with `URL.createObjectURL`
  and never uploaded.
