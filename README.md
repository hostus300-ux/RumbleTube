# RumbleTube

[**⬇︎ Download the latest IPA**](https://github.com/hostus300-ux/RumbleTube/releases/download/latest/RumbleTube.ipa) · current version 0.14.3

An unofficial iPhone client for Rumble that works like the YouTube app, with **RumbleSkip** (SponsorBlock-style skipping) built in. On your home screen it shows up as **Rumble**.

## Features

**Tabs** (turn tabs on/off and reorder them in Settings → Tabs)
- **Home:** Rumble's homepage, with a featured video, rows like Continue Watching and Live, and section buttons. Each row has "See all".
- **Shorts:** a TikTok-style vertical feed. It never interrupts music or podcasts from other apps.
  - **Following | For You** at the top when you're signed in; each keeps its place when you flip.
  - Tap to pause, double-tap anywhere to like, and hold for 2× speed.
  - Drag the progress bar to scrub, with a time readout.
  - A right-hand rail with the creator (tap **+** to follow), like, dislike, comments, save to Watch Later, share, and ⋯ (Not interested, Mute channel, Open in full player).
  - Tap a caption to expand it.
- **Discover:** swipe between **Videos** and **Live**.
  - **Trending**, **Editor Picks** and **Latest** come straight from rumble.com, with uploads on the Videos page and streams on the Live page. The Live page also has **Browse** (all categories) and **Featured** channels.
  - **Popular** is ranked on your phone: videos from the last 7 days by views per hour and likes/comments, and live streams by viewers and chat speed. Cards show why, e.g. "↑ 4.1K views/hr".
  - **For You** picks videos based on the channels, topics and categories you watch, worked out on your phone. Nothing is sent anywhere.
- **My Feed:**
  - Your Rumble subscriptions, with channel circles at the top. A red ring means the channel is live (tap to join the stream); a green ring means a recent upload.
  - Filters: All / Today / Live / Videos / Continue Watching.
  - A separate Shorts view for shorts from creators you follow.
- **Me:** your profile picture is the tab icon. Profile, Your Videos, Following (live channels marked), Earnings, Watch History, Watch Later, Downloads, Shop, Settings and Sign Out.

**Everywhere**
- **+**, the notification bell and search sit in the top-right, on the same line as the page title. The header slides away while you scroll down and comes back as soon as you scroll up, like YouTube.
  - **+** lets you upload a video or **Go live**. Go live opens the Rumble Studio app if you have it, and its App Store page if you don't. You can hide **+** in Settings.
- On a cold start, a short launch animation covers loading, and the last Home page you saw appears instantly while a fresh one loads.
- All / Videos / Live filters on Home, search results and every list.
- Search shows matching channels and videos, sorted by relevance, newest or most viewed. You can also paste any rumble.com link.
- Thumbnails show how far you've watched, from this phone or from Rumble, and finished videos get a "Watched" badge.

**Rumble account** (you sign in on Rumble's own page; the app never sees your password). After your first sign-in the app asks once to turn on reply and went-live alerts.
- **Notifications:** tapping a reply jumps straight to that comment, already expanded, so you can answer it. Optional reply alerts.
- **Comments:** read, like, reply and delete your own.
- **Following:** Follow / Unfollow syncs with your Rumble account.
- **Live chat:**
  - Chat streams in real time, with Rumble's emotes shown as images (animated ones play). This includes channel and subscriber emotes your account can use.
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
- Mini player: swipe the player down and keep browsing. On iOS 26.1+ it docks in the tab bar like Apple Music: above the tabs normally, then beside the shrunken tab bar as you scroll.
- **Live streams:** you can rewind live streams. Drag the red bar or double-tap to go back. While you're behind, it shows how far back you are, e.g. "-2:15". Tap **LIVE** to jump back to the live edge.

**RumbleSkip**
- Auto-skips sponsor reads, self-promo and like/subscribe asks, with an Undo button.
- Shows a skip button for intros, outros and recaps.
- **Automatic YouTube matching:** finds the same video on YouTube and uses its SponsorBlock segments.
  - If the lengths match, it skips automatically.
  - If it's a different edit, it shows buttons instead of skipping on its own.
- Mark your own segments, vote on them, or keep them on your device only. Save just the start, keep watching, then tap **Mark end** on the video when the segment is over. Works with the RumbleSkip browser extension's community server.

**Offline, alerts and extras**
- **Downloads:** save videos as MP4 to watch offline. Use the Download button under a video, or long-press any video. You can manage them, and pick the quality, in Account → Downloads.
- **Went-live alerts:** get notified when a channel you follow goes live. Turn it on in Settings → Rumble account.
- **Timestamps:** tap times like 12:34 in descriptions and comments to jump there. When a description lists 3 or more timestamped lines, they become chapters, with marks on the progress bar and the current chapter name shown.
- **Audio only:** no video is drawn and picture-in-picture is off. You get artwork plus a Lock Screen / Dynamic Island card with ±10 s and play/pause buttons. It applies to the current video only, unless you turn on "carries over" in Settings.
- **Autoplay:** when a video ends, the next recommendation plays after an 8-second countdown with Cancel and Play now. "Up next" is always shown under the video. Toggle it there or in Settings.
- **Player layout:** live streams show the chat under the video, with a slim title strip you can tap for details. Videos (and finished streams) show details; the Comments button swaps in the comments until you close them.
- **Start pages:** in Settings, choose what Home, Discover and My Feed open on.
- **Watch history** is a single list, synced from your Rumble Watch History and Continue Watching, including how far you got in each video.
- **Widgets:** "Live now" from channels you follow, and "Continue watching". While you watch a live stream, a Lock Screen and Dynamic Island card shows the viewer count and how far behind live you are.
- **Mute channels and users:** long-press a video (or use ⋯ on a channel page or comment) and add an optional short tag like "Content spam". Their videos still appear, shrunk with a blurred thumbnail and your tag as a badge; their comments are collapsed the same way. Tap **Show anyway** to see one. Replies from muted users don't show in Notifications or trigger alerts. Manage the list in Settings → Muted channels & users.
- **Channel tags:** tag any channel ("Politics", "Gaming") with a colour. Its videos get a coloured badge, and each tag becomes a tab in My Feed listing the channels you follow that have it.
- **Creators:** verified checks next to names, and **Join** and **Tip** (the Rumble Wallet QR code) when the creator has them set up. Public dislike counts sit next to likes.
- **Comments:** a clock button in the comment box inserts the video's current time; tap any timestamp in a comment to jump there.
- **Mini player:** shows the live video and "1:23 / 10:05". Hold it for picture-in-picture, and swipe it right to slide it away.
- **App icon:** pick from built-in icons in Settings → RumbleTube → Look → App icon.
- **Search history and suggestions,** including matching channels you follow.
- **iPad:** a grid layout, with the video and live chat side by side.
- **Rumble Watch Later:** your Rumble Watch Later list appears next to the phone's own list.
- **Backup:** in Settings, export your RumbleTube settings to a file and import them after a reinstall. The file covers RumbleSkip and your own skip segments, muted channels and their tags, phone follows and Watch Later. Importing replaces settings and merges lists; watch history and your sign-in are never included.
- **Report a problem:** in Settings. It shares a log of what failed, without passwords, cookies or what you searched for.

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
