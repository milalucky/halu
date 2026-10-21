# Halu — notch workspace for macOS

Native SwiftUI + AppKit app that lives in the MacBook notch and in a virtual notch at the top centre of external displays. Swift Package, no dependencies, built into an .app by `scripts/build.sh --install` (installs to `~/Applications`).

## Language

- Talk to the user in Russian.
- Code, comments and all UI text are English only.

## Product rules

- Minimal, beautiful, clearly better than the reference project (akalikbergenov/cyclop). Do not copy it; Halu has its own design.
- The repo is public on GitHub (milalucky/halu).

## Tabs (priority order)

1. Tasks — one to-do list, check off → archive ("Done"), voice input.
2. Calendar — Google Calendar via EventKit, Join button, reminder pops out of the notch 10 min before.
3. Claude — Claude Code sessions via hooks (`halu-hook`), progress bar, states, pop-out notices.
4. Shelf — files, screenshots and screen recordings (watches the system screenshot folder).
5. Clipboard + Snippets (one tab).
6. Translate — Google Translate EN↔RU, dictate by voice, copy the translation.
7. Accounts — test accounts table (Service · Login · Password · Notes), stored in Keychain.
8. Notes.
9. Media — now playing, music and any video, last.

Next, after Media:

10. Jira — done: Mine / Sprint / status queue (any assignee), projects auto-discovered (no hardcoded keys — the app must suit anyone), Start + any transition.
11. Messages — done. Sources: open browser tabs of Slack/Gmail/Telegram Web read via AppleScript JS every 20 s (WebInbox): Slack keeps only DMs and channels with a mention badge (incl. @channel/@here), Gmail rows labelled with their inbox address (from the tab title), Telegram only the chosen chat folder (menu in the tab; only the open folder's list is rendered, otherwise the folder badge count). Message text comes from matching notifications. Other apps: macOS notification database (Full Disk Access), read = its app was in front after the message. No IMAP/passwords: the user doesn't want logins for mail. Rows carry a thin source colour, no app icons.
12. Integrations screen in settings: Jira token (Keychain); Slack, Gmail, Telegram show "Connected" when their tab is open.

Collapsed notch indicator: one small glowing circle with the icon of the app that is waiting (Claude first), no counts.
13. Quick actions next to Keep Awake: VPN on/off first.

Tabs are configurable in Settings (gear): all on by default; a disabled tab hides from the sidebar, pauses its store's background work (`isActive`), and drops its notch indicators.

## Roadmap

- **iPhone app** with the same features, **synced with the Mac app**. Keep models Codable and storage swappable so a sync backend (e.g. CloudKit) can be added later.
- Keep Awake button (`caffeinate`) — one tap, animated. Done.
- More quick-action buttons next to Keep Awake (one-tap commands). Ideas so far: VPN on/off. More to be collected with the user.
- Notes tab = Apple Notes (all notes, search; plain-text notes editable in Halu, rich notes read-only with "Open in Notes"; new notes go to the Notes folder).
- Media tab: any source. Core Audio process list (public API) finds the app playing audio, its window title comes from Accessibility, control via system media keys. The tab shows only while something plays or was paused in the last 30 min. Browsers (Chromium family, Safari): page player driven via AppleScript "execute javascript" (needs "Allow JavaScript from Apple Events"); never media keys there — they wake Apple Music when the video is paused. Browser tabs are scanned only while the Media tab is visible. The perl-hosted MediaRemote helper (Cyclop's approach) was rejected as a security bypass — don't reintroduce it.
- The animated Halu mark spins only where work is in progress (Claude tab, running tasks), never constantly in the main panel.
