# Quran Clipper

Cut the recitations out of a video or recording and join them into one continuous recitation, without the talking in between. Export it as MP3, WAV and more, or upload it straight to your YouTube channel as a private video in a playlist.

Runs on **Android**, **macOS** and **Windows**. Each device works on its own, with no server needed.

## Install

Download from the [latest release](../../releases/latest):

| Device | File | First run |
|---|---|---|
| Android | `QuranClipper-android.apk` | Open the file. If asked, allow your browser or Files app to "install unknown apps". |
| Mac | `QuranClipper-macos.zip` | Unzip and drag **Quran Clipper** into Applications. The first time, right-click it and choose **Open**, then **Open** again. If macOS says it is damaged, run `xattr -cr "/Applications/Quran Clipper.app"` in Terminal once. |
| Windows | `QuranClipper-windows.zip` | Extract the whole ZIP and run `QuranClipper.exe`. Keep its `tools` folder and DLLs beside it. Windows 10+ (x64); yt-dlp and its JavaScript runtime are included. If SmartScreen appears, choose **More info**, then **Run anyway**. |

The app isn't signed by Apple or Microsoft, so these first-run warnings are expected. On a Mac, the first export after installing a new version may also ask to use your Downloads folder: choose **Allow**.

## Using it

1. **Start a project.** Paste a YouTube link, or open a video or audio file (voice recordings work too). On Android you can also **Share → Quran Clipper** from the YouTube app or a file manager. Then choose **Mark and clip**, or [**Just add reverb**](#just-add-reverb) to skip the next two steps.
   - **On Windows:** copy the video URL from your browser, click **Paste a YouTube link**, check the prefilled URL and click **Import**. No separate yt-dlp installation, PATH setup or browser extension is needed. **Also download the video** enables footage while marking; otherwise you can fetch it later by choosing **Original footage** on export.
   - YouTube can refuse private, unavailable, restricted or bot-blocked videos. The app shows the reason; try later or open a local file. Android uses the Dart downloader, which YouTube may block; macOS can fall back to a separately installed [yt-dlp](https://github.com/yt-dlp/yt-dlp).
2. **Mark the recitations.** Play until a recitation begins, press **Mark start**, then press **Mark end** when it stops. Repeat for each recitation.
   - Drag a part's edges on the waveform, nudge them with **− / +** (hold for 1 second steps), or tap a time to type it.
   - Reorder parts by dragging the handle. Rename them from the ⋮ menu.
   - **Preview all** plays the parts back to back.
   - On a computer: `Space` play/pause, `I`/`O` mark start/end, `←`/`→` seek, `,`/`.` fine seek, `+`/`−` zoom, `P` preview, `Ctrl/⌘ Z` undo.
3. **Export.** Choose:
   - **Audio format:** MP3 (default), M4A, Opus, WAV or FLAC.
   - **Between parts:** hard cut (default), fade, crossfade or a silent gap, with an adjustable length.
   - **Extras:** volume levelling, a fade at the start and end, and [masjid reverb](#masjid-reverb).
   - **Video:** none, a still image or title card, or the original footage.
   - **Make these my defaults** saves your choices.

Projects save automatically. On a computer, exports go to `Downloads/Quran Clipper`. On Android, use **Save** or **Share** after exporting: exports stay inside the app until you do, and deleting the project deletes them too.

## Masjid reverb

Turn on **Masjid reverb** under Extras on the Export screen for a long, dark, wide echo with a faint shimmer, and a light clean-up of the voice before it. It adds 9 seconds at the end for the echo to ring out; a video holds its last frame for those seconds.

- **Amount** makes the echo quieter or louder (Light, Normal, Strong).
- **Sparkle** turns the shimmer on or off.
- **Hear a 20-second preview** plays a short stretch ending where a part ends, so you can hear the tail. Switch between **With reverb** and **Original** to compare, and change Amount while it plays.

Exports with it on are named `Title (masjid reverb).mp3`, so they don't get mixed up with plain ones.

### Just add reverb

To put a whole file through the reverb with no cutting, choose **Just add reverb** after picking the file or link. You get the same Amount, Sparkle and preview, the preview being the last 20 seconds of the file, along with the audio format, volume, video and YouTube options. **Clip instead** at the top switches to marking parts by hand. The project stays in your list and reopens on this screen.

## YouTube upload (one-time setup)

Uploading uses your own free Google API project, so the app never sees your password.

1. In [Google Cloud Console](https://console.cloud.google.com/projectcreate), create a project called "Quran Clipper".
2. Enable the [YouTube Data API v3](https://console.cloud.google.com/apis/library/youtube.googleapis.com).
3. Set up the [Google Auth Platform](https://console.cloud.google.com/auth/overview):
   - App name: Quran Clipper
   - Audience: External
   - Use your own Gmail for the contact details
4. Under [Audience → Test users](https://console.cloud.google.com/auth/audience), add your Gmail (the one that owns your channel).
5. Under [Clients](https://console.cloud.google.com/auth/clients), create a client:
   - Application type: **Desktop app**
   - Press **Create**, then **Download JSON**
6. In the app, go to **Settings → Import client_secret JSON file**, then **Sign in with Google**. Repeat this on each device; the same JSON works everywhere.

These steps are also shown inside the app's Settings. Two things to know:
- While the Google project is in Testing mode, Google may ask you to sign in again about once a week.
- Uploads from unreviewed personal projects are always **Private**, which suits a private playlist.

## Building from source

Requires Flutter 3.47+.

```bash
flutter pub get
flutter test          # includes real ffmpeg renders if ffmpeg is installed
flutter run           # macOS / Windows / connected Android phone
flutter build apk --release --target-platform android-arm64
```

Every push to `main` runs the tests and builds Android in GitHub Actions. Pushing a tag such as `v1.0.5` also builds macOS and Windows and attaches all three to a GitHub release.

The Android release signing key is *not* in the repo:
- Locally, `android/key.properties` points to it.
- In CI it comes from the `ANDROID_KEYSTORE_*` secrets.

Keep a backup of the key. Without it, future APKs can't install over an existing one.

## How it works

| Piece | Package |
|---|---|
| Cutting, joining, encoding | `ffmpeg_kit_flutter_new` (FFmpeg 8, same build on all platforms). One `-filter_complex` graph per export, built in [lib/core/render.dart](lib/core/render.dart) |
| Playback | `media_kit` (mpv) |
| YouTube download | Bundled yt-dlp + Deno on Windows; `youtube_explode_dart` on Android/macOS with a system yt-dlp fallback on desktop |
| Google sign-in | Loopback OAuth (`googleapis_auth`), the same flow on every device |
| Upload | YouTube Data API v3 (`googleapis`), resumable upload |

Windows downloader versions, source, licenses, update steps and clean-runner verification are documented in [Windows downloader packaging](docs/windows-downloader.md). Browser URL drag-and-drop is not supported; use the clipboard-prefilled link form.
