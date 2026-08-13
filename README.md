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

## Stereo

**Stereo split** (panel, or `S`) shows the left and right channels separately in
every mode, mirrored about the centre:

| Mode | Left channel | Right channel |
| --- | --- | --- |
| Spectrum bars | spreads left from centre | spreads right from centre |
| Radial burst | sweeps down the left side | sweeps down the right side |
| Waveform | trace above centre | trace below centre |
| Liquid blob | left half of the outline | right half |
| Particle field | particles left of centre | particles right of centre |
| Pulse rings | left half of each ring | right half |

In bars and radial the low frequencies meet in the middle and climb outward, so
bass sits at the centre and treble at the edges. Mono sources are up-mixed, so
both sides stay identical rather than the right half going dark. Note that if
Rotation is non-zero the whole figure spins, which carries the left/right split
around with it — set Rotation to 0 to keep the channels fixed in place.

Analysis runs on a parallel branch of the audio graph that never reaches the
output, so it costs nothing audible.

## Library

Press `L` or **☰ Library**. Drop a folder of music onto the window, or use
**＋ Files** / **＋ Folder** — folder drops are walked recursively, so a whole
collection can go in at once.

Tracks are stored in IndexedDB and survive a reload. Metadata and audio live in
separate stores: listing the library reads only the small records (title,
artist, album, duration, and a 160px cover thumbnail), while the audio blob is
fetched only for the track actually being played — otherwise opening the panel
would pull hundreds of MB into memory.

- **Search** filters on title, artist and album, and narrows the play queue too
- **`[` / `]`** step to the previous / next track; a finished track auto-advances
- Re-importing the same files is a no-op — tracks are keyed by name, size and
  modified time
- **✕** on a row removes that track; **Clear all** empties the library. Neither
  touches the original files on disk
- The footer shows the track count and how much storage is in use

Prism asks for persistent storage on first import so the browser won't evict
the library under storage pressure.

Recorded tape notes are stored against the track, so they come back whenever
that track is loaded — a dot in the library marks tracks that have one.

## Player skins

A skin is an independent layer drawn over whichever spectrum mode is running —
pick a surface and a visual mode separately, so you can have the turntable with
bars reacting behind it. `Size`, `Opacity` and `Dim viz` control how much of the
stage it takes.

### Vinyl turntable

A record on a plinth with a tracking tonearm, grooves, and a centre label that
takes the album art — or, without art, the colors extracted from it.

**Drag the record to scratch it.** The rate follows your pointer's angular
velocity, so dragging backwards plays backwards and flicking sends it spinning
before it settles back to speed. This is why the vinyl and tape skins swap the
playback engine: an `<audio>` element cannot play in reverse (`playbackRate` is
positive-only), so the decoded samples are run through an `AudioWorklet` that
walks a playhead at a signed, fractional rate. Switching skins hands the engine
over in place and keeps the playhead where it was.

**Condition** is audible, not just cosmetic. As it falls you get surface
crackle and hiss, the bandwidth closes in (19 kHz → 3.6 kHz) with the low end
thinning out, soft-clip saturation builds, and wow/flutter set in — the rate is
an a-rate `AudioParam`, so two LFOs are simply connected to it. Visually the
disc gains dust, scuffs, an off-centre warp wobble, and a grain veil.

`33⅓ / 45 / 78 RPM` changes how fast the platter turns and therefore how much
audio one revolution covers when you scratch.

### Cassette

A shell with a palette-tinted label carrying the track title, a window, and two
reels whose tape packs shift from the left hub to the right as the track plays.
**Tape quality** drives the same DSP chain tuned differently — more even hiss,
heavier saturation, faster wow — plus visible grain.

**Record note** captures a spoken annotation over the tape via `MediaRecorder`
— what the song is about, who it's for. Notes are stored against the track in
the library and reload with it.

### CD

A spinning disc with the album art in the data area, fine track rings, a clear
plastic hub, and a diffraction sheen of tight rainbow lobes that sweep as it
turns. Spin speed, sheen strength and art on/off are all adjustable.

## Customization

Everything in the panel is live and persists to `localStorage`:

- **Mode** — stereo split, bass pulse, rotation, line weight, particle count and speed
- **Player skin** — surface, size, opacity, viz dimming, plus the per-skin
  controls (vinyl condition/RPM/tonearm, CD spin/sheen, tape quality/reels)
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
| `S` | Toggle stereo split |
| `C` | Toggle the control panel |
| `H` | Hide all UI |
| `F` | Fullscreen |
| `R` | Randomize |
| `O` | Open a file |
| `L` | Toggle the library |
| `[` `]` | Previous / next track |

The UI also fades out on its own after a few seconds of no input.

## Deploying

Prism is one static file, so hosting it is a copy. `deploy/` targets a server
running Caddy, and works either from your machine over SSH or directly on the
server itself.

**On the server** (you're already logged in — no SSH needed):

```sh
apt-get install -y git
git clone https://github.com/bluepizza116/Visualmental.git /opt/visualmental
cd /opt/visualmental
./deploy/deploy.sh --local --with-caddy
```

Updating later:

```sh
cd /opt/visualmental && git pull && ./deploy/deploy.sh --local
```

**From your own machine**, over SSH:

```sh
./deploy/deploy.sh --dry-run --with-caddy   # see exactly what it will do
./deploy/deploy.sh --with-caddy             # first deploy: page + site config
./deploy/deploy.sh                          # every deploy after: page only
```

`--dry-run` prints every command without running any of them, and works with
either mode. SSH mode uses your existing access — nothing secret lives in this
repo. Defaults are overridable:

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
reloading — a broken config won't take the server down. It refuses up front if
Caddy isn't installed, so a failure can't leave your config half-edited.
Re-running it is safe: the import line and backup are only made once.

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
- The vinyl and tape skins decode the whole track into memory to allow
  scratching, so a long track costs a few hundred MB while it is loaded. The CD
  skin and plain visualizer modes stream as before.
- Scratching needs `AudioWorklet`. Where it is unavailable the skins still draw
  and playback continues on the normal engine.
