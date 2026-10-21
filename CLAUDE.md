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
11. Messages — done. Sources: open browser tabs read via AppleScript JS every 20 s (WebInbox; two passes: the first starts async work in the page, the second collects it): Slack through the page's own session (`client.counts`, `conversations.history`, names cached in the page) — every unread channel, DMs/mentions flagged, menu "All unread / Mentions & DMs"; Telegram Web K from the page's IndexedDB (`tweb-account-N`, dialogs carry `index_<folder localId>`), any folder via the menu; Gmail unread rows of the open list, labelled with the inbox (from the tab title), menu per inbox. A tab that misses a read keeps its list for 2 min. Scripts are sent as one line: never use `//` comments in them. Other apps: macOS notification database (Full Disk Access). No IMAP/passwords. Rows carry a thin source colour, no app icons.
12. Integrations screen in settings: Jira token (Keychain); Slack, Gmail, Telegram show "Connected" when their tab is open.

Collapsed notch indicator: just the Halu mark in orange with a soft glow, no backing, no counts.

Secrets live in ONE Keychain item (`com.milana.halu.secrets`), read once per launch: every local rebuild changes the code identity, so macOS asks once per item.
13. Quick actions next to Keep Awake. VPN switcher done (Features/VPN): click lists every server grouped by app, picking one switches to it. Sources: `scutil --nc` (Outline and other system VPNs), Pritunl via its own `pritunl-client` CLI (system profiles only: GUI-only profiles keep their keys encrypted by the Pritunl app — never decrypt them), AmneziaVPN has no outside control (Open app).

14. Compare — two inputs (drop, paste, open): text/Markdown/any text file line diff (Swift `difference(from:)`, Myers, with changed words lit), JSON and PDF form fields by path (key order and formatting ignored; `true` ≠ `1`), PDF text via PDFKit, Word/RTF/ODT/HTML via NSAttributedString, images pixel by pixel. No dependencies, nothing leaves the Mac. A file drop on the panel or notch fills Compare while it's open.

Header right wing is narrow: VPN and Keep Awake are icon-only (details in tooltips). Keep Awake runs `caffeinate -dims` and is restored after Halu restarts.

Tabs are configurable in Settings (gear): all on by default; a disabled tab hides from the sidebar, pauses its store's background work (`isActive`), and drops its notch indicators.

## Roadmap

- **iPhone app** with the same features, **synced with the Mac app**. Keep models Codable and storage swappable so a sync backend (e.g. CloudKit) can be added later.
- Keep Awake button (`caffeinate`) — one tap, animated. Done.
- More quick-action buttons next to Keep Awake (one-tap commands). Ideas so far: VPN on/off. More to be collected with the user.
- Notes tab = Apple Notes (all notes, search; plain-text notes editable in Halu, rich notes read-only with "Open in Notes"; new notes go to the Notes folder).
- Media tab: any source. Core Audio process list (public API) finds the app playing audio, its window title comes from Accessibility, control via system media keys. The tab shows only while something plays or was paused in the last 30 min. Browsers (Chromium family, Safari): page player driven via AppleScript "execute javascript" (needs "Allow JavaScript from Apple Events"); never media keys there — they wake Apple Music when the video is paused. Browser tabs are scanned only while the Media tab is visible. The perl-hosted MediaRemote helper (Cyclop's approach) was rejected as a security bypass — don't reintroduce it.
- The animated Halu mark spins only where work is in progress (Claude tab, running tasks), never constantly in the main panel.
