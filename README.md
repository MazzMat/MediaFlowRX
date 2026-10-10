# MediaFlowRX

Native macOS app that receives one live stream published by an encoder, previews it, and records it to MP4 without re-encoding.

The encoder pushes to the Mac. MediaFlowRX does not pull from a camera.

<p align="center">
  <img src="docs/screenshots/on-air.png" width="780" alt="MediaFlowRX on air, recording an RTMP stream">
</p>
<p align="center">
  <img src="docs/screenshots/waiting.png" width="780" alt="Waiting for the encoder">
</p>
<p align="center">
  <img src="docs/screenshots/preferences.png" width="480" alt="Settings: protocol, port, and the URL to paste into the encoder">
</p>

## Features

- One listener at a time: RTMP, SRT, or RTSP
- Preview that keeps the source aspect ratio, with mute as the only audio control
- MP4 remux of the incoming H.264 or HEVC and AAC (no transcode)
- Record button, or automatic recording when the stream connects
- If the encoder drops, the same file continues when it returns within the grace period
- Final file name: `{slug}_yyyy-MM-dd_HH-mm-ss.mp4`
- Interface in English and Italian

Default ports, all editable in Settings: RTMP `1935`, SRT `9000`, RTSP `8554`. Slug and stream key are required. A second publisher is rejected while the first one is on air. The same slug and key may reconnect during the grace period.

## Language

The app ships in English and Italian. On first launch it follows the Mac language. In Settings → General you can choose System, English, or Italian. The new language applies the next time the app opens.

## Requirements

- macOS 14 or later
- Intel or Apple silicon
- An encoder that can publish RTMP or SRT (OBS, Epiphan Pearl, or equivalent). RTSP publish is for devices that push RTSP (OBS does not)

The app is not sandboxed: it has to accept incoming connections on the chosen port.

## Use

1. Copy MediaFlowRX to Applications, then clear the download quarantine so macOS will open it:

   ```sh
   xattr -dr com.apple.quarantine /Applications/MediaFlowRX.app
   ```

2. Open Settings and choose the protocol, port, slug, and key.
3. Copy the publish URL shown in the main window into the encoder.
4. Start the stream. The window goes on air, and Record becomes available.

RTMP, for OBS: server `rtmp://<mac>:1935/live`, stream key `stream`.

SRT, for OBS: server `srt://<mac>:9000`, stream id `#!::r=live/stream,m=publish`. SRT is not encrypted.

RTSP: `rtsp://<mac>:8554/live/stream`.

Username and password are optional. When set in Settings, the encoder must send them: after the stream key on RTMP (`stream?user=…&pass=…`), in the URL query on RTSP (`?user=…&pass=…`), in the stream id on SRT (`,user=…,pass=…`). With both empty, slug and key are enough.

`live` and `stream` are the defaults. The window always shows the URL that matches the current settings.

Recordings are fragmented MP4: the file is written as the stream comes in, so a crash or power loss costs only the last seconds.

## Build

```sh
./scripts/build-zlm.sh
```

The script clones ZLMediaKit into `third_party/` (not part of this repository) at the commit pinned in the script, and builds `libmk_api.dylib`. To try another version: `ZLM_COMMIT=<sha> ./scripts/build-zlm.sh`. Then open `MediaFlowRX.xcodeproj` and run the MediaFlowRX scheme.

A disk image:

```sh
./scripts/make-dmg.sh
```

The image is written to `dist/MediaFlowRX.dmg`.
