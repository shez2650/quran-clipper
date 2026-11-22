# Windows YouTube import verification — 22 November 2026

Branch: `codex/windows-youtube-bundle`. No release published; main was not changed.

## Passed locally on Windows

- `tool/bundle_windows_downloader.ps1 -Destination .verification/app`:
  official yt-dlp 2026.10.26 and Deno 2.9.8 downloads passed pinned SHA256
  verification; executables started and upstream license files were packaged.
- PowerShell parser validation of the packaging script; `git diff --check`.
- With PATH reduced to Windows System32, the bundled yt-dlp and explicit bundled
  Deno path fetched metadata for the existing live-test video `dzLTlrwvuKs`
  (199 seconds), audio (3,222,777 bytes), and 360p video (7,041,227 bytes).
  Download progress reached 100% for both. No system Python, yt-dlp, Deno or
  FFmpeg was used by those commands.
- The old upstream test video `BaW_jenozKc` returned “This video is unavailable”;
  the smoke harness therefore uses the repository's existing live-test video.
  Its ID can be overridden with `LIVE_YOUTUBE_ID`.

These were direct packaged-tool checks, **not** a compiled Flutter-app test.
yt-dlp warned that the M4A was DASH media without standalone FFmpeg; playback
and export through the application's existing media_kit/FFmpegKit remain to be
verified in the full application.

## Blocked, not passed

[Actions run 45038065706](https://github.com/shez2650/quran-clipper/actions/runs/45038065706)
and its retry failed before any steps started. The follow-up
[run 45038641284](https://github.com/shez2650/quran-clipper/actions/runs/45038641284)
was also blocked. GitHub's annotation:

> The job was not started because recent account payments have failed or your
> spending limit needs to be increased. Please check the 'Billing & plans'
> section in your settings.

Consequently, **Flutter analysis, all Dart/widget/integration tests, the Windows
release build, extracted-ZIP smoke harness, and packaged-app startup have not
run**. No local Flutter installation was available. The new tests are committed,
not claimed to be passing.

After the repository owner resolves billing, rerun the latest branch workflow.
It runs analysis and tests, then Windows integration tests, builds and packages
the release, checks the extracted ZIP from a different working directory with
system downloader paths removed, and uploads both the ZIP and a live-download
JSON report. A live YouTube rejection is recorded separately and must not be
mistaken for a passed live download.

Before publishing, also verify playback/marking, saved-project reopening,
stitched/reverb exports, optional initial footage, later footage fetch during
export, cancellation, and restricted-video errors in the packaged app.
