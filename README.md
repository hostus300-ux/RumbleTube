# RumbleTube

[**⬇︎ Download the latest IPA**](https://github.com/hostus300-ux/RumbleTube/releases/download/latest/RumbleTube.ipa) · current version 0.8.0

An unofficial iPhone client for Rumble that works like the YouTube app, with **RumbleSkip** (SponsorBlock-style skipping) built in. On your home screen it shows up as **Rumble**.

## Features

**Tabs** (turn tabs on/off and reorder them in Settings → Tabs)
- **Home:** Rumble's homepage, with a featured video, rows like Continue Watching and Live, and section buttons. Each row has "See all".
- **Shorts:** a vertical swipe feed. It never interrupts music or podcasts from other apps.
- **Discover:** swipe between **Videos** and **Live**.
  - **Trending** (the default): videos from the last 7 days, ranked by views per hour and likes/comments, with older videos sinking as the week goes on. Live streams are ranked by viewers and chat speed. Cards show why, e.g. "↑ 4.1K views/hr".
  - **For You:** picks based on the channels, topics and categories you watch, worked out on your phone. Nothing is sent anywhere.
  - **Newest:** newest first.
- **My Feed:**
  - Your Rumble subscriptions, with channel circles at the top. A red ring means the channel is live (tap to join the stream); a green ring means a recent upload.
  - Filters: All / Today / Live / Videos / Continue Watching.
  - A separate Shorts view for shorts from creators you follow.
- **Account:** profile, Your Videos, Following (live channels marked), Earnings, Watch History, Watch Later, Settings and Sign Out.

**Everywhere**
- **+**, search and the notification bell sit in the top-right, on the same line as the page title.
  - **+** lets you upload a video or **Go live**. Go live opens the Rumble Studio app if you have it, and its App Store page if you don't. You can hide **+** in Settings.
- On a cold start, a short launch animation covers loading, and the last Home page you saw appears instantly while a fresh one loads.
- All / Videos / Live filters on Home, search results and every list.
- Search shows matching channels and videos, sorted by relevance, newest or most viewed. You can also paste any rumble.com link.
- Thumbnails show how far you've watched, from this phone or from Rumble, and finished videos get a "Watched" badge.

**Rumble account** (you sign in on Rumble's own page; the app never sees your password)
- **Notifications:** tapping a reply jumps straight to that comment, already expanded, so you can answer it. Optional reply alerts.
- **Comments:** read, like, reply and delete your own.
- **Following:** Follow / Unfollow syncs with your Rumble account.
- **Live chat:**
  - Chat streams in real time.
  - **Rants:** a $1–$500 tier slider shows how long your message stays pinned. Pay with Rumble Wallet, or with Apple Pay on Rumble's checkout.
  - **Gift subs** for the channel you're watching.

**Player**
- Custom controls with YouTube-style gestures, which you can remap in Settings → Tweaks → Gestures. Defaults:
  - Double-tap the sides to rewind or skip ahead.
  - Hold for a speed boost.
  - Swipe up for fullscreen.
  - Pinch to zoom.
- Picture-in-Picture, AirPlay, background audio and lock-screen controls.
- Quality picker, playback speed, and resume where you left off.
- Mini player: swipe the player down and keep browsing.
- Live streams are supported.

**RumbleSkip**
- Auto-skips sponsor reads, self-promo and like/subscribe asks, with an Undo button.
- Shows a skip button for intros, outros and recaps.
- **Automatic YouTube matching:** finds the same video on YouTube and uses its SponsorBlock segments.
  - If the lengths match, it skips automatically.
  - If it's a different edit, it shows buttons instead of skipping on its own.
- Mark your own segments, vote on them, or keep them on your device only. Works with the RumbleSkip browser extension's community server.

**Look**
- Built for iOS 26 **Liquid Glass**: glass header buttons, filter chips, a floating mini player, and a tab bar that shrinks while you scroll. You can switch it off in Settings.
- Light/dark theme and accent colours.
- The app icon has dark and tinted versions, so it matches tinted and clear home screens.

**No Rumble ads.** The app plays the video stream directly, so Rumble's player ads never load.

## Install (sideload)

Every push to `main` builds an unsigned `RumbleTube.ipa` with Xcode 26 on GitHub's macOS build machines:

1. On your phone, tap **[Download RumbleTube.ipa](https://github.com/hostus300-ux/RumbleTube/releases/download/latest/RumbleTube.ipa)**. You can also open [Releases → RumbleTube (latest build)](https://github.com/hostus300-ux/RumbleTube/releases/tag/latest) and download it there.
2. Install it with AltStore, SideStore, Sideloadly, TrollStore or a similar tool. The tool signs it with your Apple ID.
3. If you used a free Apple ID, refresh it every 7 days.

Requires iOS 16 or later. Liquid Glass needs iOS 26.

To build by hand on a Mac with Xcode 26:

```bash
brew install xcodegen
xcodegen generate
open RumbleTube.xcodeproj   # pick your team under Signing and run on your phone
```

## How it works

| Piece | Where | Notes |
|---|---|---|
| Home, channels, categories, search | `Core/FeedParsers.swift` | Parses the JSON Rumble embeds in its pages (`rum-videos-row-provider`, `rum-videos-grid`) plus server-rendered cards. A hidden WebKit view (`PageExtractor`) is only a fallback. |
| My Feed | `Core/FeedParsers.swift` | `/-api/user/following-latest` (channels, live viewers) and `/-api/user/following-feed` (pills, shorts, watch progress). |
| Video details | `Core/RumbleParsers.swift` | Watch-page JSON-LD + `embedJS/u3/?request=video`, the endpoint yt-dlp uses. |
| Account, comments, notifications | `Core/AccountCore.swift`, `Services/AccountStore.swift` | Uses the session cookie from Rumble's own sign-in page. |
| Live chat & rants | `Core/LiveChatCore.swift`, `Player/LiveChat.swift` | Rumble's chat server-sent-event stream; messages and rants post to the same endpoints as rumble.com. |
| Shorts | `Core/ShortsCore.swift`, `Views/ShortsView.swift` | `service.php?name=shorts.feed`, with a small pool of looping players. |
| RumbleSkip | `Core/SkipCore.swift`, `Core/YouTubeMatch.swift` | Same API as the browser extension. Lookups use a hash prefix, so the server never learns exactly what you watch. |
| Discover ranking | `Core/Discovery.swift`, `Views/DiscoverScreen.swift` | Trending and For You are computed on the phone from Rumble's view, vote, comment and chat numbers. Views/hour gets more accurate the more often you open Discover. |
| Liquid Glass | `Views/Glass.swift` | `glassEffect` on iOS 26, with a blur fallback on older versions. |

## Tests

```bash
swift test                     # parsers, chat, skip engine, settings migration (Linux or macOS)
node tests/extract.test.mjs    # fallback page extractor in Chromium
```

All test data is either invented or taken from public Rumble pages.

## Limits

- Sign in with Apple can't show the native Face ID sheet inside third-party apps. Use email and password instead; you can set one with "Forgot password" on rumble.com.
- Gift-sub checkout and Apple Pay rants happen on Rumble's own page inside the app.
- Unofficial and not on the App Store. It may need fixes when Rumble changes its site.
