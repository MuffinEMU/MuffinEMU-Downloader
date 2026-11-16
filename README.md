# Muffin Downloader

From [MuffinEMU](https://github.com/MuffinEMU/Muffin-EMU), the Wii U emulator for iPhone and iPad. Created by Void.

Muffin Downloader is a native SwiftUI iOS port of [WiiUDownloader](https://github.com/Xpl0itU/WiiUDownloader) (originally Go + GTK3), informed by the mobile groundwork in [WiiUDownloader-Mobile](https://github.com/EinTim23/WiiUDownloader-Mobile) (Flutter, Android/iOS). Licensed GPLv3, same as upstream.

Downloads title metadata/content from Nintendo's public NUS/CCS servers, the same unauthenticated endpoints any HTTP client (including a browser) can reach. Browsing, searching, and downloading raw (still-encrypted) content works with **no keys of any kind**.

## Features

- Browse/search the full NUS title list with category pills and region filters (USA, Europe, Japan, China, Korea, Taiwan).
- Box art and game summaries (synopsis, developer, publisher, release year, genre) from [GameTDB](https://www.gametdb.com/WiiU).
- Pick a version: latest, any version WiiUBrew has recorded, or a custom version code. Download size is shown before queueing.
- Choose where downloads go: the app's own folder or any folder in Files (iCloud Drive, USB drive, another app). Each title gets a `Name [Kind] [Title ID]` folder, as in upstream.
- Queue with pause/resume, per-title cancel, continue-on-error, keep-screen-on, a Live Activity, and resumable downloads.
- Related update/DLC suggestions, add-by-title-ID, optional decryption to a Cemu-ready layout.

## Title database

The list comes from `napi.v10lator.de`, which upstream also uses. That server is unreliable (it resets HTTP/2 streams, which iOS reports as "The network connection was lost"), so the app never depends on it: a snapshot ships in `Sources/WUDCore/Resources/title_db.json`, the last good download is cached, and a live fetch only upgrades the list. Refresh the snapshot with `scripts/extract_title_db.py` (reads it out of an upstream release build) or from the live server when it's up. `scripts/build_metadata.py` regenerates `title_metadata.json` (GameTDB + WiiUBrew).

## Decryption keys

This app ships with **zero decryption keys built in**: not Nintendo's Wii U common key, not the Wii common/Korean keys. Decryption is off until you import your own `keys.txt` or `otp.bin` (Settings → Import). Any layout works (`commonKey = …`, `… # Wii U common key`, spaced or `0x`-prefixed bytes, a raw OTP dump), because keys are recognized by SHA-256 fingerprint rather than by label.

Keys are stored in the iOS Keychain, or in a file-protected app file when the keychain is unavailable (common on sideloaded builds), and never leave the device. Where to get them is up to you; they have to come from a console you own.

## Project layout

- `Sources/WUDCore/` — pure Swift package: binary format parsers (TMD/FST/U8), NUS networking, resumable download state, title-key derivation, content decryption/extraction, title database + search. No UI, no platform-specific keys. Builds and tests with plain `swift build` / `swift test`.
- `App/WiiUDownloaderiOS/` — the SwiftUI app: browse/search, download queue, settings (including the key importer), first-run assistant.
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; run `xcodegen generate` to produce `WiiUDownloaderiOS.xcodeproj`.
- `.github/workflows/ios-build.yml` — CI: runs `swift test`, then builds an unsigned `.ipa` for sideloading (AltStore/SideStore/LiveContainer), like MuffinEMU's own builds.

## Building

Requires full Xcode (not just Command Line Tools) for the iOS app target — the `WUDCore` package alone builds/tests with just the Swift toolchain.

```sh
swift build              # WUDCore only
swift test                # WUDCore tests
xcodegen generate         # produces WiiUDownloaderiOS.xcodeproj
```
