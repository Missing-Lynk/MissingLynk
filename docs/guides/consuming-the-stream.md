# Consuming the stream

The goggle serves a live RTSP restream of the video feed while the **air unit is transmitting**:

- **URL:** `rtsp://192.168.3.100:554/venc8/stream`
- **Codec:** H.265 / HEVC by default (matches the DVR codec; see below), up to 1920x1080 60 fps

The same URL works on both stacks: the **open stack** (slot B, ml-pipeline's built-in gst-rtsp-server) and the **patched vendor firmware** (slot A, the enabled mini-RTSP server). The Android app's default URL points here.

## Open stack (slot B)

Enable **DVR > RTSP Stream** in the goggle menu (persists across reboots; the HUD re-asserts it after a pipeline restart). The restream is the DVR encoder's own output, teed before the muxer:

- It carries exactly what a recording would: the configured DVR resolution/framerate (**DVR > Resolution**) and, with **DVR > Record OSD** on, the OSD burn-in.
- It works with or without an active recording; starting/stopping a recording while streaming causes a sub-second gap while the encoder graph swaps (players resume at the next keyframe).
- The codec follows the DVR: H.265 by default, H.264 when the pipeline runs with `ML_DVR_CODEC=h264` (the Android app expects H.265 and will not play the H.264 variant; VLC/ffplay handle both).
- Timestamps are real RTP timestamps; UDP and TCP transports both work.
- Bench levers (env, on the goggle): `ML_RTSP_PORT` overrides port 554, `ML_DVR_GOP` sets the keyframe interval in frames (default 60, i.e. ~1 s; 0 = driver default).

## Quick checks / viewing

Grab a single frame as proof, or open a live low-latency view with VLC, GStreamer, or ffplay:

```sh
ffmpeg -rtsp_transport tcp -i rtsp://192.168.3.100:554/venc8/stream -frames:v 1 -update 1 frame.png

vlc --rtsp-tcp --network-caching=150 rtsp://192.168.3.100:554/venc8/stream

gst-launch-1.0 rtspsrc location=rtsp://192.168.3.100:554/venc8/stream protocols=tcp latency=50 ! rtph265depay ! h265parse ! avdec_h265 ! autovideosink sync=false

ffplay -fflags nobuffer -flags low_delay -rtsp_transport tcp rtsp://192.168.3.100:554/venc8/stream
```

## Record a clip (no transcode)

```sh
ffmpeg -rtsp_transport tcp -use_wallclock_as_timestamps 1 -i rtsp://192.168.3.100:554/venc8/stream -t 10 -c copy clip.mp4
```

## Restream to RTMP / YouTube (transcode to H.264)

RTMP/YouTube-RTMP don't accept HEVC, so transcode:

```sh
ffmpeg -rtsp_transport tcp -use_wallclock_as_timestamps 1 -i rtsp://192.168.3.100:554/venc8/stream -c:v libx264 -preset veryfast -tune zerolatency -b:v 8M -g 120 -f flv rtmp://YOUR-INGEST/key
```

If your target accepts **HEVC** (e.g. YouTube via HLS/RTMPS-HEVC), use `-c:v copy` for near-zero CPU.

## Quirks

Both stacks:

- **DESCRIBE needs a live feed.** With the air unit off (or, on the open stack, RTSP Stream disabled) there is no media to describe; players report a DESCRIBE/SDP failure. This is expected, not a regression. On the open stack a connect can also take up to one keyframe interval (~1 s) to produce the first frame.
- Keep buffering modest for low glass-to-glass latency; raise it if you see stutter (the RF link itself drops/recovers, see telemetry, that's the air side).

Patched vendor firmware (slot A) only:

- **Use TCP** (`-rtsp_transport tcp` / `protocols=tcp` / `--rtsp-tcp`). UDP is flaky there.
- **No RTP timestamps** are sent -> players warn "Timestamps unset" / "Non-monotonous DTS". Harmless for viewing. For muxing/restream add **`-use_wallclock_as_timestamps 1`** on the input (or let the encoder re-timestamp).
- **HTTP `:8081`** is RTSP-over-HTTP tunnelling (`application/x-rtsp-tunnelled`), not a separate stream.
