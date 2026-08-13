# Prism download service

A small authenticated HTTP API in front of [yt-dlp](https://github.com/yt-dlp/yt-dlp).
yt-dlp is a Python program, so it cannot run in the browser — this is the only
part of Prism that needs a server.

## Before you install

Downloading from YouTube is **against YouTube's Terms of Service**. Whether that
matters is your call and depends on what you download and where you are; content
you own, Creative Commons material, and public-domain recordings are the
uncontroversial cases. This service is a tool, not permission.

It is also worth being clear about what an unguarded download endpoint on a
public server would be: an open proxy that strangers can point at arbitrary
URLs, using your bandwidth and your IP until the host blocks you. Two things
prevent that here, and you should not remove either:

- **Every request needs a bearer token**, generated on first start and readable
  only by root and the service user.
- **URLs must be on an allowlist** (`PRISM_ALLOW_HOSTS`), which defaults to
  YouTube. Setting it to `*` turns this into a general-purpose downloader for
  every site yt-dlp supports.

The daemon binds to `127.0.0.1` and is reached only through Caddy.

## Install

On the server, as root:

```sh
cd /opt/visualmental
./server/install.sh
```

That installs `ffmpeg` (yt-dlp needs it to extract and tag audio), creates a
`prism` system user, builds a venv at `/opt/prism-venv`, installs the systemd
unit, starts it, and prints the token.

Then redeploy so Caddy routes `/api` to it:

```sh
./deploy/deploy.sh --local --with-caddy
```

Finally, open the app → **☰ Library → Download from YouTube**, paste the token,
and press **Connect**. The token is kept in that browser's `localStorage`.

## Using it

Paste a video or playlist URL and press **Fetch**. Playlist entries are listed
with checkboxes; **Queue** starts them. Two download at a time by default.

Finished tracks are pulled into the browser's IndexedDB library — the same place
local files live — and then deleted from the server, so audio is not stored
twice. They behave like any other track: skins, lyrics, notes, search.

## Operating

```sh
systemctl status prism-downloader
journalctl -u prism-downloader -f
curl -s localhost:8770/api/health

# yt-dlp breaks whenever YouTube changes; update it when downloads start failing
/opt/prism-venv/bin/pip install -U yt-dlp && systemctl restart prism-downloader
```

Settings live in the unit file (`/etc/systemd/system/prism-downloader.service`):

| Variable | Default | |
| --- | --- | --- |
| `PRISM_MEDIA` | `/var/lib/prism/media` | scratch space; files are deleted once the browser has them |
| `PRISM_TOKEN_FILE` | `/etc/prism/token` | shared secret |
| `PRISM_HOST` / `PRISM_PORT` | `127.0.0.1:8770` | bind address |
| `PRISM_WORKERS` | `2` | concurrent downloads |
| `PRISM_MAX_ITEMS` | `200` | cap on one playlist request |
| `PRISM_MAX_QUEUE` | `500` | cap on pending jobs |
| `PRISM_ALLOW_HOSTS` | YouTube hosts | comma-separated suffixes, or `*` |

To rotate the token: `rm /etc/prism/token && systemctl restart prism-downloader`,
then reconnect in the app.

## API

All routes except `/api/health` require `Authorization: Bearer <token>`.

| Method | Path | |
| --- | --- | --- |
| `GET` | `/api/health` | liveness, allowlist, worker count |
| `POST` | `/api/resolve` | `{url}` → `{items:[{id,url,title,uploader,duration}]}` |
| `POST` | `/api/jobs` | `{urls:[…]}` → queued jobs |
| `GET` | `/api/jobs` | all jobs with state and percentage |
| `GET` | `/api/media/<file>` | the audio, supports Range |
| `GET` | `/api/art/<file>` | the thumbnail |
| `POST` | `/api/forget` | `{id}` → drop a job and delete its files |
| `POST` | `/api/clear` | forget all finished jobs |

Media paths are resolved inside `PRISM_MEDIA` and rejected if they escape it.
