# Subtitle fixture

`subtitles.mp4` is a generated 12-second black video (320×180, 10 fps) with two
`mov_text` subtitle tracks. The text is “English subtitle test” and “中文字幕测试”.
The language tags are `eng` and `zho`; neither subtitle is marked as default.
It contains no network URLs or third-party media.

Generated with FFmpeg from a `color` source and two SRT files whose cue runs from
00:00:00,000 to 00:00:11,900, using H.264 video, `mov_text`, and `+faststart`.
Tests use it to exercise actual AVFoundation and VLC track discovery/selection,
including subtitles that would otherwise remain disabled.
