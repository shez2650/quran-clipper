# Quran Clipper

Cut the recitations out of a video or recording and join them into one continuous recitation, without the talking in between. Export it as MP3, WAV and more, or upload it straight to your YouTube channel as a private video in a playlist.

Runs on **Android**, **macOS** and **Windows**. Each device works on its own, with no server needed.

## Install

Download from the [latest release](../../releases/latest):

| Device | File | First run |
|---|---|---|
| Android | `QuranClipper-android.apk` | Open the file. If asked, allow your browser or Files app to "install unknown apps". |
| Mac | `QuranClipper-macos.zip` | Unzip and drag **Quran Clipper** into Applications. The first time, right-click it and choose **Open**, then **Open** again. If macOS says it is damaged, run `xattr -cr "/Applications/Quran Clipper.app"` in Terminal once. |
| Windows | `QuranClipper-windows.zip` | Unzip anywhere and run `QuranClipper.exe`. If SmartScreen appears, choose **More info**, then **Run anyway**. |

The app isn't signed by Apple or Microsoft, so these first-run warnings are expected.

## Using it

1. **Start a project.** Paste a YouTube link, or open a video or audio file (voice recordings work too). On Android you can also **Share → Quran Clipper** from the YouTube app or a file manager.
2. **Mark the recitations.** Play until a recitation begins, press **Mark start**, then press **Mark end** when it stops. Repeat for each recitation.
   - Drag a part's edges on the waveform, nudge them with **− / +** (hold for 1 second steps), or tap a time to type it.
   - Reorder parts by dragging the handle. Rename them from the ⋮ menu.
   - **Preview all** plays the parts back to back.
   - On a computer: `Space` play/pause, `I`/`O` mark start/end, `←`/`→` seek, `,`/`.` fine seek, `+`/`−` zoom, `P` preview, `Ctrl/⌘ Z` undo.
3. **Export.** Choose:
   - **Audio format:** MP3 (default), M4A, Opus, WAV or FLAC.
   - **Between parts:** hard cut (default), fade, crossfade or a silent gap, with an adjustable length.
   - **Extras:** volume levelling and a fade at the start and end.
   - **Video:** none, a still image or title card, or the original footage.
   - **Make these my defaults** saves your choices.

Projects save automatically. On a computer, exports go to `Downloads/Quran Clipper`. On Android, use **Save** or **Share** after exporting.

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

Every push to `main` builds all three platforms in GitHub Actions. Pushing a tag such as `v1.0.1` also publishes a release.

The Android release signing key is *not* in the repo:
- Locally, `android/key.properties` points to it.
- In CI it comes from the `ANDROID_KEYSTORE_*` secrets.

Keep a backup of the key. Without it, future APKs can't install over an existing one.

## How it works

| Piece | Package |
|---|---|
| Cutting, joining, encoding | `ffmpeg_kit_flutter_new` (FFmpeg 8, same build on all platforms). One `-filter_complex` graph per export, built in [lib/core/render.dart](lib/core/render.dart) |
| Playback | `media_kit` (mpv) |
| YouTube download | `youtube_explode_dart`, falling back to `yt-dlp` on a computer if it's installed |
| Google sign-in | Loopback OAuth (`googleapis_auth`), the same flow on every device |
| Upload | YouTube Data API v3 (`googleapis`), resumable upload |
