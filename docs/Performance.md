Receiver Performance Switches
=============================

The Receiver's menu bar icon has a **Performance** submenu for comparing latency changes on real hardware. Each switch is stored and applies immediately unless noted.

- **Draw only the newest frame** (on by default): every frame is still decoded, because later frames depend on it, but only the latest decoded frame is drawn when several arrive in one loop. This avoids drawing frames that are already out of date.
- **Wake on incoming data** (on by default): while waiting, the Receiver wakes as soon as data arrives instead of always sleeping 1 ms.
- **Show performance stats**: an overlay with frames per second, skipped frames, draw time per frame (average and maximum), received data rate and the renderer. The same line is written to the Receiver log once per second.
- **Renderer (Expert Settings)**, for developers:
  - **Renderer** (applies after restarting the Receiver):
    - **TargetBridge Metal** (default, recommended): the Receiver draws all video, H.264/HEVC and every uncompressed mode, with its own Metal code, like DisplayBridge. SDL, the library the Receiver uses for its window, still draws the waiting screen, cursor and overlays. Changed rows of the uncompressed modes are copied by the GPU straight from the Receiver's memory, and full 10-bit colour is shown in 10 bits.
    - **SDL Metal** and **SDL OpenGL**: SDL draws everything, as in earlier versions (OpenGL was the default before 4.0). SDL's Metal mode can flash on some systems, and neither shows full 10-bit colour, so the Sender then uses 10-bit dithered instead.
    - The `TB_RECEIVER_RENDER_DRIVER` environment variable still overrides SDL's choice of driver.
  - **Wait for display refresh in uncompressed modes** (off by default, TargetBridge Metal only): presents in step with the iMac's refresh, which avoids tearing. The Receiver then waits for each refresh, which can lower the frame rate.

"Draw time" covers uploading a frame to the GPU and presenting it. With display refresh waiting on, it includes that wait.

Uncompressed Video: Changed Rows Only
=====================================

With any of the **Uncompressed** options as the video compression, the Sender no longer sends every frame in full. ScreenCaptureKit reports which areas of the screen changed in each frame, and the Sender sends only those rows of the 4:2:0 picture. The Receiver keeps the whole picture in memory, patches the received rows into it and uploads only those rows to the GPU.

- **Bandwidth**: a still desktop costs almost nothing; typing or a moving window costs a fraction of a full frame. Full-screen video and scrolling still need up to about 10.6 Gb/s at 5K and 60 Hz.
- **LZ4 (lossless)**: the changed rows are compressed with LZ4 before sending, in parallel chunks of 64 rows on both Macs. The picture stays bit-identical. Chunks that LZ4 can't shrink are sent as they are.
- **Rows from skipped frames**: when the frame rate limit or a saturated link skips a frame, its changed rows are kept and sent with the next frame, so nothing is lost.
- **Safety net**: the first frame, a size change, a frame without dirty-rect information and one frame every 5 seconds are sent in full.
- **Compatibility**: the Receiver advertises `supportsRawRegions` and `supportsRawLZ4`. Older Receivers keep getting full frames (packet type 0x22), and LZ4 is only used when the Receiver supports it. The wire format of packet type 0x24 is described in `TargetBridge-Receiver/TBReceiverC/src/raw_regions.h`.
- **Comparing**: start the Sender with the environment variable `RAW_REGIONS=0` to send full frames again. With **Show performance stats** on, the Receiver's overlay shows `changed N%`, the share of the screen's rows that had to be sent.

Uncompressed, 10-bit Modes (Experimental)
=========================================

Two further options build on **Uncompressed, LZ4, lossless (8-bit)**: both capture the screen in 10-bit and send raw frames. Like all uncompressed modes, they use up to 4 parallel data connections while *Parallel connections* is on.

| Option | Captured | Sent and shown | Data at 5K | Frame rate at 5K |
|---|---|---|---|---|
| **Uncompressed (8-bit)** | 8-bit 4:2:0 | 8-bit 4:2:0 | up to ~10.6 Gb/s | 60 Hz |
| **Uncompressed, LZ4, lossless (8-bit)** | 8-bit 4:2:0 | 8-bit 4:2:0, LZ4 | less, depends on content | 60 Hz |
| **Uncompressed, enhanced (10-bit dithered)** | 10-bit RGB | 8-bit 4:2:0, dithered, LZ4, parallel | like the 8-bit modes | 60 Hz |
| **Lossless 10-bit · changed rows** (formerly *Uncompressed, full colour*) | 10-bit RGB | 10-bit RGB 4:4:4, parallel, LZ4 while it pays off | ~2.7 times as much | ~30 fps for video and scrolling |

- **Enhanced (10-bit dithered)**: captured in 10-bit, displayed in 8-bit. Before sending, a GPU shader converts only the changed rows to 8-bit 4:2:0 (BT.709, video range) with an ordered 4×4 (Bayer) dither. Gradients stay smooth without visible steps. The pattern depends only on the pixel position and repeats every 4 pixels and rows, so a still picture stays bit-identical from frame to frame and flat areas still compress well with LZ4. Without a usable Metal GPU the Sender captures 8-bit directly.
- **Full colour (10-bit)**: the captured pixels are sent unchanged, 4 bytes per pixel, compressed with LZ4 while that pays off. Desktop content (moving windows, text, scrolling pages) shrinks several times. Video barely does, so after a frame that LZ4 shrank by less than 20 %, the next 30 frames go out raw before LZ4 is tried again, much like DisplayBridge sends video raw.
  - **Shown in 10 bits by the TargetBridge Metal renderer** (the default): the window switches to a 10-bit (BGR10A2) drawable, and the GPU copies only the changed rows from the Receiver's memory into a 10-bit texture without any CPU conversion. The stats overlay shows `10-bit RGB`.
  - With an SDL renderer the Receiver doesn't offer full colour, and the Sender uses Enhanced instead.
- **Receive buffers**: the parallel data connections of the uncompressed modes ask for receive buffers of up to 16 MiB each (macOS allows 8 MiB by default), so a whole 5K frame keeps arriving while the previous one is drawn. The main connection, which carries H.264/HEVC, keeps upstream's 4 MiB (3.6.2), so stale video can't pile up there.
- **Read budget**: the Receiver reads each connection for at most 8 ms per pass (upstream 3.6.1) and keeps any packet it has started; no data is dropped.
- **Complete frames only**: each part of a frame carries the number of parts, and the Receiver draws a frame only once all of its parts have arrived (or after 100 ms, if one never does). A frame that is replaced by a newer one before it was drawn counts as skipped in the stats.
- **Display refresh**: frames are presented as soon as they are complete. Waiting for the iMac's refresh (no tearing) is in Renderer (Expert Settings), off by default; hardware-decoded H.264/HEVC never waits.
- **Stream profiles**: *5K 60 Uncompressed (8-bit)*, *5K 60 LZ4, lossless (8-bit)*, *5K 60 10-bit dithered* and *5K 60 Full 10-bit* select 5K at 60 Hz and the matching mode in one step. While one is selected, the video compression setting offers only the four uncompressed modes, so you can switch between them within the profile; the profile remembers the choice until you pick another profile.
- **Parallel data streams** (session setting *Parallel connections*, on by default, for all uncompressed modes; choosing a 10-bit profile or mode turns it on): one TCP connection over Thunderbolt Bridge tends to hit a CPU-core limit before the cable is full. The Receiver advertises up to 4 extra connections and a per-session token; the Sender opens them, splits each frame's changed rows into parts of similar size and sends one part per connection (packet type 0x26, with the part count in byte 12 of the header). Parts can arrive out of order, so the Receiver remembers for every pair of rows which frame wrote it last, and an older part never overwrites newer rows. If no extra connection comes up, frames go over the session connection as before.

Lossless 10-bit · Full Frames (DPCM, Experimental)
==================================================

From upstream pull request #201 (Aykut Alpgiray Ates, Biao), as a second lossless 10-bit option next to *Lossless 10-bit · changed rows*.

- **Format**: TBD2 tile-DPCM, described in `TargetBridge-Shared/codec/tb_dpcm.h`. Each 8×8 tile is independent: a seed pixel, per-channel bit widths and residuals against the left neighbour (first column: the pixel above), zigzag-coded and bit-packed. 64 tiles share one byte-aligned base offset, so a GPU threadgroup per tile can find its data. Lossless at 8 and 10 bits; a tile never grows beyond raw size. The optional adaptive colour extension codes a tile as (B−G, G, R−G) when that is smaller.
- **Sender**: captures packed 10-bit RGB (`l10r`), encodes each whole frame on the GPU (`tb_dpcm_gpu_encode`, or the adaptive variant when the Receiver supports it) and sends it as packet type 0x27 over the session connection. If the GPU encoder fails, the CPU reference encoder takes over. Frames are dropped, not queued, while three packets are still in flight.
- **Receiver**: validates the blob (`tb_dpcm_parse` re-derives every offset, since it is network data), copies it into a GPU buffer, decodes it with #201's kernel (one threadgroup per tile, one thread per pixel) and copies the pixels into the 10-bit texture of the TargetBridge Metal renderer, which draws it like the changed-rows mode.
- **Capabilities**: `supportsDPCM` and `supportsDPCMAdaptiveColor` in the display profile, only with the TargetBridge Metal renderer and a GPU that runs the kernel. Without them the Sender uses *Lossless 10-bit · changed rows*.
- **Differences from #201**: packet type 0x27 instead of 0x25; decoding in this version's renderer instead of #201's own Metal layer; synchronous encoding per frame (#201 also has band-wise and asynchronous encoder calls, which are included in the codec but not used yet); no 4.5K presets.
- **Stats overlay**: `DPCM lossless`.

Colour Management and Zero-Copy Video (Experimental)
====================================================

- **Colour space** (Sender session setting *Colour space (experimental)*: Automatic, sRGB, Display P3). The chosen colour space is used end to end:
  - the virtual display's primaries (`CGVirtualDisplayDescriptor`), so macOS renders in it;
  - ScreenCaptureKit's `colorSpaceName` with the BT.709 `colorMatrix` (and `kCGDisplayStreamColorSpace` for the direct display stream);
  - the encoder's colour tags (primaries, BT.709 transfer function and matrix);
  - the session ack (`TB_PKT_CREATE_SESSION_ACK`, field `colorSpace`: `srgb` or `displayP3`), sent before the first frame. The Receiver sets its Metal layer's `colorspace` from it, so macOS converts the picture for the panel. The ack also covers the uncompressed modes, which have no container for colour tags.
  - **Automatic** picks Display P3 when the Receiver's display profile reports `panelColorSpace: displayP3`, otherwise sRGB.
  - **Compatibility**: only when the Receiver reports `supportsColorSpaceTags: true` (TargetBridge Metal renderer). Otherwise the session runs as before: the virtual display keeps the iMac's wide-gamut SDR primaries and the Receiver's layer stays untagged, so the values go to the panel unchanged. The Receiver never guesses: an unknown or missing colour space leaves the layer untagged.
  - The colour space changes only with a new session; the setting is locked while streaming.
- **Zero-copy H.264/HEVC frames** (Receiver menu bar > Performance > Renderer (Expert Settings), off by default). Instead of copying each decoded frame's two planes into Metal textures (`replaceRegion`, about 22 MB per frame at 5K, 1.3 GB/s at 60 Hz), the Receiver wraps the decoder's IOSurface-backed `CVPixelBuffer` as textures through a `CVMetalTextureCache`. The last 4 frames stay referenced, so the decoder cannot reuse a picture the GPU may still be drawing. Only 8-bit NV12 in video range is shown this way; software-decoded frames and anything else are copied as before, frame by frame.
- **Stats overlay**: with *Show performance stats* on, the Receiver shows `zero-copy`, `copy` or `zero-copy + copy` for decoded video, and the colour space (`sRGB`, `Display P3` or `unmanaged`).
- **Latency (Sender, experimental: Standard / Balanced / Low, default Standard)**, below the compression. What happens when a large change (scrolling, a window switch) would take long to reach the Receiver; the text under the menu explains each setting for the chosen compression.
  - *H.264 / HEVC*: Balanced adds a short-window `DataRateLimits` cap (at most 1.5× the average over about 3 frames, besides any one-second ceiling); Low creates the encoder with Apple's low-latency rate control (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`). Where the encoder refuses, Standard applies and the Sender says so.
  - *Uncompressed and LZ4 changed rows*: the Sender measures the link speed (large frames sent onto an idle link) and how much LZ4 shrinks rows, and estimates how long a change takes. Balanced sends a change that would take more than about two frames at half resolution; Low sends one that would take more than about one frame at half, or quarter, resolution. Rows sent smaller are owed and go out again losslessly with the next frames while there is room, at the latest 50 ms (Balanced) / 100 ms (Low) after the last reduced frame, from the newest captured frame. Wire format: band encoding bits 4-5 carry a scale shift (`raw_regions.h`); only sent to Receivers that announce `supportsScaledRows`. The Receiver repeats the pixels into its frame.
  - *DPCM* sends whole frames; the setting changes nothing.
  - The session ack carries `"latency": "balanced"/"low"` when applied; the Receiver's stats overlay shows `latency low` and `(simplified)` in seconds with reduced rows.
- **Decoder output without delay (Receiver)**: FFmpeg's `AV_CODEC_FLAG_LOW_DELAY` is always set, so a decoded frame is handed over at once instead of being held for a possible reorder (the Sender never reorders frames).
- **Queue one frame less (Receiver menu bar > Performance > Expert Settings, experimental, off by default)**: with *Wait for display refresh* on, the Metal layer keeps two drawables instead of three, about one frame less delay at the cost of stuttering sooner under load. No effect without display sync.
- **What to compare** on real hardware: draw time and skipped frames in the overlay and the Receiver's CPU load in Activity Monitor, with zero-copy on and off, at 5K60 HEVC with moving content; and a colourful image on the Mac and on the iMac with Automatic, sRGB and Display P3.

