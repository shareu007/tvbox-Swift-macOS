# Third-party notices

TVBox-Swift uses third-party components that keep their own licenses:

- **VLCKitSPM / VLCKit** — GNU Lesser General Public License 2.1. The package
  source and license are available from
  <https://github.com/tylerjonesio/vlckit-spm> and the upstream VideoLAN
  project. Distributors of an App/DMG/IPA are responsible for meeting the
  LGPL requirements, including providing the applicable license and source or
  relinking materials.
- **Node.js** — the macOS packaging step embeds an official Node.js runtime.
  Its upstream `LICENSE` file is copied into the App next to the runtime by
  `scripts/prepare_embedded_gateway.sh`.
- **MPVKit / mpv / FFmpeg** — macOS uses the LGPL product of MPVKit 1.0.0,
  including mpv 0.41.0 and FFmpeg n8.1.2. Package sources and component build
  scripts: <https://github.com/mpvkit/MPVKit/tree/1.0.0>. License notices and
  rebuilding instructions are bundled in `tvbox/Resources/Licenses/`.
  The modified CoreAudio driver and required original headers are included in
  `Vendor/MPVCoreAudio/`, with upstream provenance and LGPL license notices;
  see its README before upgrading or replacing MPVKit.

This file is informational and does not replace the complete license texts
shipped by those projects.
