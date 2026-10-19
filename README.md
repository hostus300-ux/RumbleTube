# RumbleTube

An unofficial iPhone/iPad client for Rumble that works like the YouTube app, with **RumbleSkip** (SponsorBlock-style skipping) built in.

## Features

**Browsing**
- **Home:** a feed of your followed channels, newest first. There's no Rumble account involved; follows are stored on your phone.
- **Explore:** Live, Editor Picks and Latest.
- **Search:** sort by relevance, newest or most viewed. You can also paste any rumble.com video or channel link.
- **Channel pages:** banner, follower count, Follow button, and an endless video list.
- **Library:** History, Watch Later (long-press any video) and Following.

**Player**
- Native iOS player with Picture-in-Picture, AirPlay, speed control and fullscreen.
- Keeps playing in the background, with lock-screen and Control Center controls.
- Quality picker (Auto/HLS or fixed 1080/720/480/360p), and your choice is remembered.
- Resume where you left off, with progress bars on thumbnails.
- Mini player: swipe the player down and keep browsing.
- Live streams supported.

**RumbleSkip**
- Auto-skips sponsor reads, self-promo and like/subscribe asks, with an Undo button.
- Shows a skip button for intros, outros and recaps.
- Coloured segment markers under the video.
- Mark segments yourself (Start = Now / End = Now), vote on them, or keep them on your device only.
- Link the YouTube upload of a video to use its SponsorBlock data.
- Uses the same community server as the RumbleSkip browser extension, so skips you mark on your computer show up on your phone.

**No Rumble ads.** The app plays the video stream directly, so Rumble's player ads never load.

## Install (sideload)

Every push to `main` builds an unsigned `RumbleTube.ipa` on GitHub's free macOS build machines:

1. Open this repo's **Releases** → **RumbleTube (latest build)** on your phone and download `RumbleTube.ipa`.
2. Install it with your sideloading tool (AltStore, SideStore, Sideloadly, TrollStore, or similar). The tool signs it with your Apple ID.
3. If you used a free Apple ID, refresh it every 7 days in your sideloading tool.

To build by hand on a Mac:

```bash
brew install xcodegen
xcodegen generate
open RumbleTube.xcodeproj   # pick your team under Signing and run on your phone
```

## How it works

| Piece | Where | Notes |
|---|---|---|
| Listing pages (search, channels, explore) | `Services/PageExtractor.swift` + `Resources/extract.js` | Loads the page in a hidden WebKit view with images, media and fonts blocked, then reads every `/v….html` link and its card, including Rumble's client-rendered grids inside shadow DOM. It doesn't depend on Rumble's class names. |
| Video details | `Core/RumbleParsers.swift` | Uses the watch page's JSON-LD and `rumble.com/embedJS/u3/?request=video&v=<embedId>`, the same endpoint yt-dlp uses. Falls back to the rendered page, then oEmbed. |
| Playback | `Player/PlayerModel.swift` | AVPlayer + AVPlayerViewController. HLS is preferred, with MP4 as the fixed-quality choice. |
| RumbleSkip | `Core/SkipCore.swift`, `Player/SkipPanel.swift` | Same API and logic as the browser extension. Lookups use a 4-character hash prefix, so the server never learns exactly what you watch. |

**When Rumble changes its site:** listing pages are handled by `extract.js`, which you can test in a browser. Run `node tests/extract.test.mjs` (Playwright). For watch pages, update the patterns in `WatchPageParser`.

## Tests

```bash
swift test                     # core logic: parsers, skip engine, library (runs on Linux or macOS)
node tests/extract.test.mjs    # page extractor in Chromium against captured Rumble markup
```

## Limits

- No Rumble login, so comments, likes and live chat aren't available yet. Follows are stored locally.
- The skip notice and button don't show in native fullscreen. Auto-skip still works there.
- Unofficial and not on the App Store. Scraping is against Rumble's terms, so it may stop working when Rumble changes things.
