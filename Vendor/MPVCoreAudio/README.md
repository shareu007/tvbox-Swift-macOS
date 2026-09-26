# mpv CoreAudio initialization cleanup backport

This directory contains the CoreAudio output driver and its required internal
headers from [mpv v0.41.0](https://github.com/mpv-player/mpv/tree/v0.41.0).
`upstream-sha256.json` records the original file hashes, before local changes.
The original license notices remain in each file; `LICENSE.LGPL` is included.

## Why this is built separately

MPVKit 1.0.0 statically links mpv 0.41.0, which leaves a CoreAudio property
listener registered when audio initialization fails. A later audio device change
calls `hotplug_cb` with a freed `ao` context, crashing the entire host app.

The macOS target compiles only `audio/out/ao_coreaudio.c` from this directory.
Its `audio_out_coreaudio` definition satisfies libmpv's reference before the
linker extracts the original archive member. All other mpv objects and supporting
libraries still come from the pinned MPVKit package. No runtime symbol patching
or modification of the downloaded dependency cache is used. The iOS target does
not compile this driver.

## Changes from v0.41.0

- Backport [mpv PR #18383](https://github.com/mpv-player/mpv/pull/18383): register
  hotplug listeners after AudioUnit initialization succeeds; clean up resources
  on failure; tolerate partially initialized queue and AudioUnit state.
- Clear the AudioUnit pointer after the v0.41.0 helper disposes it on failure,
  so the backported cleanup does not dispose it twice.
- Avoid decrementing a zero listener-registration count on early failure.
- Import `Libavutil/mathematics.h` using MPVKit's framework header spelling.
- `config.h` supplies only the macOS feature definitions required by this driver
  and its headers. The structures and helper declarations match mpv 0.41.0.
- The Xcode source entry maps build paths to relative paths for privacy.

## Upgrade and verification

This is coupled to **MPVKit 1.0.0 / mpv 0.41.0's internal ABI**. Do not update the
package without updating/removing this backport and running the audio tests.
Once MPVKit ships the upstream fix, remove the source entry and header search
path from `project.yml`, regenerate Xcode, and run the same regression tests.

`MPVPlayerTests.testAudioDeviceNotificationAfterPlayerTeardown` reproduces the
reported crash with generated mono PCM on the affected macOS audio driver. It
creates and removes a private, empty aggregate device to deliver real CoreAudio
notifications, without changing the system's default audio output. The old
binary crashes in `mp_msg_va → mp_msg → hotplug_cb`; the backport survives.
The mono initialization failure depends on the host audio driver, so a passing
run on another OS alone is insufficient to prove this failure path is covered.

The stereo regression covers actual playback, notifications during playback and
after teardown, and pause/resume beyond CoreAudio's seven-second idle shutdown.
Existing real-video tests still require `hwdec-current == videotoolbox` and
exercise subtitles, seek, and software decoding. Universal Release builds must
also pass bundle privacy auditing and code-signature verification.
