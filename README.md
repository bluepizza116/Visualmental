# Prism

A web audio visualizer that paints itself with the colors of the album cover.

Open `index.html` in a browser. That's it — one self-contained file, no build
step and no dependencies. Everything runs locally; the only feature that talks
to a server is the optional YouTube downloader, which you host yourself.

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
- **`＋`** on a row queues it; shift-click queues it to play next
- Re-importing the same files is a no-op — tracks are keyed by name, size and
  modified time
- **✕** on a row removes that track; **Clear all** empties the library. Neither
  touches the original files on disk
- The footer shows the track count and how much storage is in use

Prism asks for persistent storage on first import so the browser won't evict
the library under storage pressure.

Recorded tape notes are stored against the track, so they come back whenever
that track is loaded — a dot in the library marks tracks that have one.

## Queue and playlists

The library panel has three tabs: **Tracks**, **Playlists**, **Queue**.

Playing anything from Tracks makes the visible list the queue, so a search
narrows what plays as well as what is listed. `＋` on a row appends to the
queue, shift-click puts it next.

**Shuffle** (`X`) is a permutation, not a random pick: a shuffled pass visits
every track exactly once, the track playing when you enable it stays put, and
turning it off restores the original running order rather than reshuffling.
With repeat on, each lap gets a fresh permutation.

**Repeat** (`Y`) cycles off → all → one. On `one` a finished track restarts;
on `all` the queue wraps; on `off` it stops at the end.

**Playlists** are saved in IndexedDB. Name one and press *Create*, or capture
what you are listening to with *From queue*. Deleting a playlist leaves the
tracks alone.

Queue, shuffle and repeat state all survive a reload, and Prism reopens on the
track you left — paused, at the position you stopped — rather than starting
something unbidden.

Media keys, the lock screen and the OS now-playing card work through the Media
Session API, with the cover art attached.

## YouTube downloads

yt-dlp is a Python program and cannot run in a browser, so this is the one
feature that needs a server component — `server/prismd.py`, a small
authenticated API in front of yt-dlp. See [`server/README.md`](server/README.md)
to install it.

In the app: **☰ Library → Download from YouTube**, paste the token the installer
prints, then a video or playlist URL. Pasting can be skipped entirely with
`install.sh --auto-token`, but only alongside a password on the site
(`deploy.sh --protect=user:pass`) — otherwise every visitor gets working
credentials. See [`server/README.md`](server/README.md). Playlist entries are listed with
checkboxes so you can queue the whole thing or pick from it. Finished tracks are
pulled into the same IndexedDB library as local files and then deleted from the
server, so nothing is stored twice.

Two notes before you use it. Downloading from YouTube is against YouTube's Terms
of Service — content you own or that is openly licensed is the uncontroversial
case. And the service requires a bearer token and only accepts URLs on a host
allowlist (YouTube by default) because an unguarded download endpoint on a
public server is an open proxy that strangers will happily point at anything.

## Lyrics

Time-synced lyrics come from [LRCLIB](https://lrclib.net) — keyless, free, and
CORS-enabled, so the browser asks it directly and this works with **no server
at all**. They are fetched automatically when a track loads, cached in
IndexedDB (misses too, so a track without lyrics isn't re-queried), and drawn
karaoke-style with the current line held in the palette's accent color.

**Click any line to jump to it.** Position (lower third or centred), text size,
and auto-fetch are in the panel, along with a manual *Look up lyrics now*.

Where only unsynced lyrics exist, the block is shown scrolling linearly with
playback and labelled *unsynced* — there are no timings to follow, so it is an
approximation rather than a pretence.

## Cover art lookup

Missing artwork can be found automatically from the iTunes Search API. Unlike
lyrics this **needs the download service**, for a specific reason: the art CDNs
send no `Access-Control-Allow-Origin` header, so an image loaded straight from
them taints the canvas and `getImageData` throws — which would silently drop
the whole palette back to defaults and stop covers driving the visuals. The
daemon refetches the image server-side and hands it back same-origin, keeping
the canvas clean. Found art is saved to the library record, so it survives a
reload.

The lookup takes search terms only, never a URL — accepting a URL there would
turn the box into an open image proxy.

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

### Reel-to-reel

An open deck: two reels with a visible tape path threaded past guide rollers,
a head block, a capstan and pinch roller, a mechanical counter, and VU meters
with real ballistics reading each channel. Because a reel deck pulls tape at a
constant linear speed, **the emptier reel turns faster** — angular speed goes
as 1/radius.

**Drag either reel to shuttle the tape** — a hand on the flange, exactly like
scratching the vinyl. The transport buttons under the deck work: play, stop,
and hold-to-wind ⏪/⏩ that shuttle the actual playhead at 6×, audibly.

### MiniDisc

A portable player: the disc sits in a bay behind a lid with a circular window,
over an LCD showing the track title (scrolling when long), queue position,
time, and the locked BPM. The buttons work — play/pause, **track skip driven
by the real queue**, stop, and eject, which lifts the lid, pauses, and resumes
when closed. Drag the disc through the window to jog it.

### Boombox

Twin woofers pulse on their own channel behind ring grilles, kicked by the
tempo grid so they move on the beat. Between them: a cassette door (click it —
it pops open), a spectrum LED strip, working transport buttons with
hold-to-wind, and **three real knobs**. VOL, BASS and TREBLE drive an actual
tone stack — lowshelf and highshelf filters that sit *before* the analyser, so
cranking the bass changes the sound, the bars, and how hard the woofers move,
all at once. The tone stack is scoped to the boombox and eases flat when you
leave the skin.

### CD

A spinning disc with the album art in the data area, fine track rings, a clear
plastic hub, and a diffraction sheen that sweeps across it as it turns. Spin
speed, sheen strength and art on/off are all adjustable.

The artwork turns with the disc, as a real CD does. **Spin the art** turns that
off if you would rather keep the cover upright and readable — the sheen and
rings keep rotating either way, so the disc still reads as spinning.

## Beat sync

Prism estimates the actual tempo rather than just reacting to loud moments.
Spectral flux over an unsmoothed spectrum gives an onset envelope,
autocorrelation over that envelope finds the period, and a phase search locks
the grid — so beats are **predicted**, and pulses land *on* the beat instead of
just after it. The detected BPM is shown top-right with a dot that blinks on
the predicted beat, so a bad lock is obvious at a glance.

*Amount* sets how hard it drives the visuals; it feeds the same pulse the bass
already drives, so bars, radial, blob and rings all breathe with the tempo and
particles and rings fire on the grid.

**Half and double time are genuinely ambiguous** — a track at 174 with a
two-beat pattern really does contain an 87 BPM periodicity, and no estimator
gets that right every time. A perceptual preference curve centred near 120
resolves the common cases; **÷2** and **×2** fix the rest, and hold until the
track changes. **Auto** hands it back.

Tempo state is cleared when the track changes, since the ten-second envelope
would otherwise still be full of the previous song.

## Capture

`⏺` in the toolbar, `G`, or **Capture** in the panel records the canvas with
the audio, and *Save this frame* writes a PNG. Frame rate and bitrate are
adjustable.

Audio is tapped from the analyser — the one node every source passes through —
so files, tab audio and the mic all record, and the vinyl and tape wear DSP is
baked in because it sits upstream. What you hear is what lands in the file.

Format is MP4 where the browser names a concrete codec for it, otherwise WebM.
Chrome answers "supported" for a bare `video/mp4` and then writes a file that
will not parse, so that path is deliberately skipped. The WebM that
MediaRecorder produces carries no duration in its header, so some players show
an unknown length and seek poorly; it plays through correctly, and remuxing
fixes it if you need to edit:

```sh
ffmpeg -i clip.webm -c copy clip-fixed.webm
```

## Phone and TV

The layout adapts from a `data-ui` mode on the document — driven by pointer
type and viewport, not width alone, because TV browsers report odd viewports
and forcing a mode is useful for testing. **Display → Layout** overrides the
automatic choice.

**Touch.** The control panel and library become bottom sheets that stop above
the player rather than under it, so the transport stays reachable while you
browse. Hit targets go to 44px minimum, row actions drop their hover
dependency, the backing store is capped at 1.5x since phones lose more to
overdraw than they gain from it, and the chrome no longer auto-hides — tap
empty stage to toggle it instead.

**TV.** Everything scales up about 1.75x with 44px overscan margins, since many
sets crop the outer few percent of the picture. Arrow keys move focus
geometrically to the nearest control, so a remote works without any hard-coded
tab order; Enter activates, Escape or Back closes the open panel. With the
chrome hidden, left and right go back to scrubbing rather than moving focus.
Focus rings are deliberately loud enough to read from across a room.

The transport row's height is measured rather than assumed, and the lyrics and
track-title overlays key off it, so nothing is drawn underneath it at any size.

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

Built-ins can be deleted too. They live in the source so they cannot literally
be erased — the removal is remembered instead, and **Restore built-ins** brings
them all back.

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
| `X` | Shuffle on/off |
| `Y` | Repeat off / all / one |

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
