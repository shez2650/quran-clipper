# Windows YouTube downloader

The x64 Windows ZIP targets Windows 10 or later. Extract the **whole folder**:
`QuranClipper.exe`, Flutter data/DLLs, and `tools/` must stay together.

## Pinned dependencies

`tool/bundle_windows_downloader.ps1` downloads these official release assets,
verifies their pinned SHA256 digests, and packages them under `tools/`:

| Component | Version | Asset/source |
| --- | --- | --- |
| yt-dlp | 2026.10.26 | [yt-dlp.exe](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26), [source](https://github.com/yt-dlp/yt-dlp/tree/2026.10.26) |
| Deno | 2.9.8 | [deno-x86_64-pc-windows-msvc.zip](https://github.com/denoland/deno/releases/tag/v2.9.8), [source](https://github.com/denoland/deno/tree/v2.9.8) |

Deno runs the YouTube JavaScript challenges supported by yt-dlp. The official
yt-dlp executable includes its EJS components; no runtime code downloads,
Python installation, browser extension, or PATH configuration are required.
The app passes the bundled Deno path explicitly. It downloads separate audio
and video streams without invoking a system FFmpeg; existing FFmpegKit handles
playback preparation and exports.

Discovery uses `Platform.resolvedExecutable`, never the working directory:
`<app directory>/tools/yt-dlp.exe` first, then WinGet Links and PATH. Development
builds can use a system installation or run the packaging script against their
runner directory. macOS retains the Dart-first/system-yt-dlp fallback, and Android
retains the Dart implementation.

## Licensing

yt-dlp source is Unlicense. Its official PyInstaller executable bundles other
projects and is a **GPL-3.0-or-later combined work**, not merely an Unlicense binary.
The ZIP includes its upstream LICENSE and complete THIRD_PARTY_LICENSES.txt under
`tools/licenses/`. Those notices identify bundled projects, licenses, and source
locations. The pinned upstream release and source links above are provided so
recipients can obtain the corresponding upstream source and build instructions.
Maintain redistribution obligations for all bundled dependencies when updating;
do not remove their notices.

Deno is MIT licensed with bundled third-party components. The packaging script
captures the pinned executable's full `deno --license` output in
`tools/licenses/deno-LICENSE.txt`.

## Updating

1. Choose explicit official yt-dlp and Deno releases; review release notes,
   supported Windows versions and licensing changes.
2. Update versions and SHA256 digests in the packaging script. Verify digests
   against the official release assets (GitHub asset digest / upstream checksums).
3. Update this table and the expected versions in `tool/windows_downloader_smoke.dart`.
4. Run analysis, tests, the Windows build and extracted-ZIP smoke check. Inspect
   the live YouTube report, then manually import a permitted public video on
   a Windows machine without yt-dlp, Python, Deno or FFmpeg on PATH.
5. Verify marking/playback, saved-project reopening, audio export with reverb,
   and original footage fetched both during import and later during export.
   Publish only after review. The application does not self-update the tools.

## Verification and limitations

The branch workflow builds without publishing a release. It compiles a small
smoke executable using the **same resolver and process/download implementation**,
places it beside the extracted app, removes system downloader paths, changes
the working directory, and verifies both pinned executables. The harness is not
included in the release ZIP. The runner also attempts a real public test-video
audio/video download and saves the result as `windows-downloader-smoke.json`.
A YouTube rejection is recorded as a failure in that report, not called a passed
download; it does not invalidate the offline packaging checks.

YouTube may still refuse unavailable, private, age/region/member-restricted
videos, or flag a connection as automated. The app reports the downloader's
reason. It does not extract browser cookies or bypass access restrictions.
Metadata is optional: if lookup fails, a successful import is named
`YouTube <video ID>`.

Browser URL dragging is intentionally not implemented. The current Windows
runner has no OLE URL-drop handler and the app has no desktop drop dependency;
adding one would introduce a second platform integration for an already short
clipboard flow. Copy the browser URL, press **Paste a YouTube link**, and
**Import**. The clipboard is prefilled and the form also has a Paste button.
