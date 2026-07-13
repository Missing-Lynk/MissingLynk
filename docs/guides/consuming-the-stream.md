# Consuming the stream

Once the patched binary is running and the **air unit is transmitting**:

- **URL:** `rtsp://192.168.3.100:554/venc8/stream`
- **Codec:** H.265 / HEVC, **1920x1080, ~60 fps**
- **HTTP `:8081`** is RTSP-over-HTTP tunnelling (`application/x-rtsp-tunnelled`), not a separate stream.

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

## Important quirks of this mini-RTSP server

- **Use TCP** (`-rtsp_transport tcp` / `protocols=tcp` / `--rtsp-tcp`). UDP is flaky here.
- **No RTP timestamps** are sent -> players warn "Timestamps unset" / "Non-monotonous DTS". Harmless for viewing. For muxing/restream add **`-use_wallclock_as_timestamps 1`** on the input (or let the encoder re-timestamp).
- **DESCRIBE needs a live feed.** With the air unit off, the server still listens and OPTIONS returns 200, but DESCRIBE has no media to describe (`make sdp description failed`). This is expected, not a regression.
- Keep buffering modest for low glass-to-glass latency; raise it if you see stutter (the RF link itself drops/recovers, see telemetry, that's the air side).
