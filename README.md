<p align="center"><img src="docs/logo.png" alt="SACD ISO Player for Lyrion Media Server" width="320"></p>

# SACDPlayer

A Lyrion Music Server plugin that exposes SACD ISO images in the library (the stereo area as an album, the multichannel area optionally) and serves DSF extracted by `sacd_extract` from a local LRU cache, keeping the player's native `dsf dsf * *` (DoP) passthrough intact.

Design spec: `docs/superpowers/specs/2026-09-06-sacdplayer-design.md`.

## What it does

- Scans SACD `.iso` files placed in the music folder and registers the stereo area as the virtual album `<Title> (2ch)`. The multichannel area only becomes `<Title> (mch)` when the `show_mch` option is on.
- When a virtual track (`file://<iso>#<area>-NN`) is played, extracts the whole area (every track) to DSF on demand with `sacd_extract`, stores it in a local cache with a configurable size cap (LRU eviction) and serves the extracted file to the player. Native DoP passthrough (`dsf dsf * *`) is preserved, with no transcoding.
- Multichannel: the Apple Squeezer engine only accepts 2-channel DSD (`unsupported DSD format: channels=5`), so mch areas are hidden by default. Turning `show_mch` on requires a full rescan and a player that handles 5/6-channel DSD.
- The first play of an album waits for extraction to finish (the player shows "Preparing SACD track N / M"); later plays of the same album start immediately as long as the cache has not been evicted.
- A single extraction worker runs at a time; further requests are queued.

## Installation

Add this repository under Server Settings > Plugins > Additional repositories and install SACDPlayer from the list:

```
https://raw.githubusercontent.com/fdfreitas88/SACDPlayer/main/repo.xml
```

The release zip bundles `sacd_extract` for macOS x86_64. For other hosts, build the binary and deploy by hand as described below.

### Manual install from source

1. Build the `sacd_extract` binary for the target host:
   ```bash
   tools/build-sacd-extract.sh
   ```
   This produces `Bin/darwin/sacd_extract` (gitignored, specific to the server architecture).

2. Push the plugin to the LMS server with rsync:
   ```bash
   tools/deploy.sh
   ```
   Defaults to `SACD_HOST=musicplayer@10.73.254.20`; override with the environment variable if needed. The script copies `install.xml`, `custom-types.conf`, `strings.txt`, the `.pm` modules, `Bin/darwin/sacd_extract` and `HTML/` to `~/Library/Application Support/Squeezebox/Plugins/SACDPlayer` on the host (the manual plugins folder; `InstalledPlugins` is wiped by the extension manager on restart), sets permissions (755 dirs / 644 files, 755 on the binary) and **does not restart LMS**.

3. Restart Lyrion Music Server yourself (the deploy script only reminds you):
   ```bash
   open -a "Lyrion Music Server"
   ```
   (after quitting the previous instance).

4. Trigger a rescan so the importer registers the ISOs:
   ```bash
   curl -s -X POST -H 'Content-Type: application/json' \
     http://<host>:9000/jsonrpc.js \
     -d '{"id":1,"method":"slim.request","params":["",["rescan"]]}'
   ```

## Settings (Settings → SACDPlayer)

| Field | Description |
|---|---|
| `cache_dir` | Local directory where the extracted DSF files are stored. |
| `cache_cap_gb` | Cache size cap in GB; above it, the oldest albums (LRU) are evicted. |
| `extract_timeout_s` | Extraction timeout per area, in seconds. |
| `min_free_gb` | Free disk space floor; extraction pauses when it drops below this. |
| `show_mch` | Also expose multichannel areas as `(mch)` albums (needs a full rescan). |

The settings page also lists cached albums with per-album **Prepare** / **Evict** buttons.

## JSON-RPC verbs

All under the `sacdplayer` command (`Slim::Control::Request`), endpoint `http://<host>:9000/jsonrpc.js`.

### `cachestats` — cache usage, queue and worker state
```bash
curl -s -X POST -H 'Content-Type: application/json' http://10.73.254.20:9000/jsonrpc.js \
  -d '{"id":1,"method":"slim.request","params":["",["sacdplayer","cachestats"]]}'
```
Returns `usage_bytes`, `cap_bytes`, `free_bytes`, `binary` (1 when `sacd_extract` is present), `busy`, `queued`, `low_disk` and the `albums` list (key/area/bytes/last_access/iso/title).

### `status <key>/<area>` — track states of one album
```bash
curl -s -X POST -H 'Content-Type: application/json' http://10.73.254.20:9000/jsonrpc.js \
  -d '{"id":1,"method":"slim.request","params":["",["sacdplayer","status","abcdef0123456789/2ch"]]}'
```
Also accepts the virtual track URL (`file:///Volumes/.../Album.iso#2ch-01`) in place of `<key>/<area>`:
```bash
curl -s -X POST -H 'Content-Type: application/json' http://10.73.254.20:9000/jsonrpc.js \
  -d '{"id":1,"method":"slim.request","params":["",["sacdplayer","status","file:///Volumes/Disk8TB/Musik/Lossless/SACD-ISO/Album.iso#2ch-01"]]}'
```
Returns `key`, `area`, `title` and the `tracks` list (number/state/bytes/error). States: `absent`, `pending`, `extracting`, `ready`, `failed`.

### `prepare <key>/<area>` — extract the whole album ahead of time
```bash
curl -s -X POST -H 'Content-Type: application/json' http://10.73.254.20:9000/jsonrpc.js \
  -d '{"id":1,"method":"slim.request","params":["",["sacdplayer","prepare","abcdef0123456789/2ch"]]}'
```
Fails with `error: sacd_extract missing` when the binary is not installed.

### `evict <key>/<area>` — remove the area from the cache and cancel any running extraction
```bash
curl -s -X POST -H 'Content-Type: application/json' http://10.73.254.20:9000/jsonrpc.js \
  -d '{"id":1,"method":"slim.request","params":["",["sacdplayer","evict","abcdef0123456789/2ch"]]}'
```
After an evict, `status` for that area reports every track as `absent`.

## Echo Classic

Echo Classic 3.5.6 and later detects the `sacdplayer` verbs and shows the cache state of SACD albums with Prepare / Remove actions, plus an "SACD cache" row in its settings. Nothing needs to be configured on either side.

## Known limitations

- **Multichannel does not play on Apple Squeezer**: the engine rejects DSD with more than 2 channels; the `mch` area stays hidden unless `show_mch` is on.
- **First play waits for extraction**: the player shows "Preparing SACD track N / M" until `sacd_extract` finishes the whole area; later tracks of the same album start instantly while the cache exists.
- **Single extraction worker**: concurrent requests (another album, or a manual `prepare`) are queued; there is no parallelism.
- **No automatic retry**: when extraction fails (missing binary, non-zero exit, timeout, low disk) the track is marked `failed` and a new play request or `prepare` is needed to try again.

## Release

```bash
tools/release.sh X.Y.Z
```
Builds `dist/SACDPlayer-X.Y.Z.zip` in the layout LMS expects and writes its SHA-1 into `repo.xml`. `install.xml` must already carry version `X.Y.Z`.

## License

GPL-3.0 (see `LICENSE`). The bundled `sacd_extract` binary comes from the Sound-Linux-More/sacd-extract fork (GPL-2) and runs as a separate process.
