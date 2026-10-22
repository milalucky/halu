# Halu — notch workspace for macOS

Native SwiftUI + AppKit app that lives in the MacBook notch and in a virtual notch at the top centre of external displays. Swift Package, no dependencies, built into an .app by `scripts/build.sh --install` (installs to `~/Applications`).

## Language

- Talk to the user in Russian.
- Code, comments and all UI text are English only.

## Product rules

- Minimal, beautiful, clearly better than the reference project (akalikbergenov/cyclop). Do not copy it; Halu has its own design.
- The repo is on GitHub (milalucky/halu), private for now; the user will open it later.

## Tabs (priority order)

1. Tasks — one to-do list, check off → archive ("Done"), voice input.
2. Calendar — Google Calendar via EventKit, Join button, reminder pops out of the notch 10 min before.
3. Claude — Claude Code sessions via hooks (`halu-hook`), progress bar, states, pop-out notices.
4. Shelf — files, screenshots and screen recordings (watches the system screenshot folder). Now a mode of the Clipboard tab (Clipboard | Shelf).
5. Clipboard + Snippets (one tab).
6. Translate — Google Translate EN↔RU, dictate by voice, copy the translation.
7. Accounts — test accounts table (Service · Login · Password · Notes) in an AES-GCM vault file, key in Keychain. Import: Markdown lists/tables, CSV/TSV, clipboard rows (AccountImport), or `Halu --import-accounts <file>`. A service dropdown next to search filters by service; combined services ("losolo, losolo3", "StarSteer — losolo2") count for each part, URLs/hosts left out. Never commit account files.
8. Notes.
9. Media — now playing, music and any video, last.

Next, after Media:

10. Jira — done: Mine / Sprint / status queue (any assignee), projects auto-discovered (no hardcoded keys — the app must suit anyone), Start + any transition.
11. Messages — done. Sources: open browser tabs read via AppleScript JS every 20 s (WebInbox; two passes: the first starts async work in the page, the second collects it): Slack through the page's own session (`client.counts`, `conversations.history`, names cached in the page) — every unread channel, DMs/mentions flagged, menu "All unread / Mentions & DMs"; Telegram Web K from the page's IndexedDB (`tweb-account-N`, dialogs carry `index_<folder localId>`), any folder via the menu; Gmail unread rows of the open list, labelled with the inbox (from the tab title), menu per inbox. A tab that misses a read keeps its list for 2 min. Scripts are sent as one line: never use `//` comments in them. Other apps: macOS notification database (Full Disk Access). No IMAP/passwords. Rows carry a thin source colour, no app icons.
12. Integrations screen in settings: Jira token (Keychain); Slack, Gmail, Telegram show "Connected" when their tab is open.

Collapsed notch indicator: just the Halu mark in orange with a soft glow, no backing, no counts.

Secrets live in ONE Keychain item (`com.milana.halu.secrets`), read once per launch: every local rebuild changes the code identity, so macOS asks once per item.
13. Quick actions next to Keep Awake. VPN switcher done (Features/VPN): click lists every server grouped by app, picking one switches to it. Sources: `scutil --nc` (Outline and other system VPNs), Pritunl via its own `pritunl-client` CLI (system profiles only: GUI-only profiles keep their keys encrypted by the Pritunl app — never decrypt them), AmneziaVPN has no outside control (Open app).

14. Compare (inside Tools, third mode) — two inputs (drop, paste, open): text/Markdown/any text file line diff (Swift `difference(from:)`, Myers, with changed words lit), JSON and PDF form fields by path (key order and formatting ignored; `true` ≠ `1`), PDF text via PDFKit, Word/RTF/ODT/HTML via NSAttributedString, images pixel by pixel. No dependencies, nothing leaves the Mac. A file drop on the panel or notch fills Compare while Tools → Compare is open.

Header right wing is narrow: VPN and Keep Awake are icon-only (details in tooltips). Keep Awake runs `caffeinate -dims` and is restored after Halu restarts.

15. Chat — chatgpt.com only, in a WKWebView, opened from a header button (not in the sidebar); the user signs in on the site, no tokens, no scraping or private APIs. One long-lived web view per site.
16. Tools — Test data / Convert / Compare. Test data generator (click copies and regenerates; +alias emails from the user's own address) and Convert (paste anything: JWT, Base64, URL, JSON, timestamps, hashes).
17. GitLab — your open MRs and MRs where you're a reviewer, new comments since you last opened each (comments fetched only when `user_notes_count` changes), read_api token in Keychain.

Tasks have tags (#tag while typing, picker, filter; new tasks get the active filter's tag). Header shows live download speed (en* byte counters). VPN menu shows ping latency (pinged past the tunnel via `ping -b <Wi-Fi/Ethernet port>`; silence isn't failure) and switches to the next server when one doesn't connect in 25 s.

The panel reopens on the last tab (hovering the notch mark doesn't jump to Messages/Claude). Clicking the Halu logo opens Halu as a normal resizable window (WindowRootView, same Sidebar + TabContent). Claude's sidebar icon is a monochrome burst (ClaudeMark). Header speed = busier of physical ports vs utun tunnels. The clipboard keeps everything, tokens included — the user chose that; don't filter.

Live notch (LiveCenter / LiveView, Display.live): a meeting within 15 min (or started and not joined, up to 10 min) or the Pomodoro timer shows on the collapsed notch with a glow tracing the notch outline that shrinks with time; tapping joins the meeting / pauses the timer. Meeting reminders at 5 min, 1 min, start, +2 min until joined (Join anywhere marks it joined). Pomodoro button in the header (right-click for lengths). Tools has a colour picker (NSColorSampler) and a pixel ruler overlay. Global shortcuts (Carbon hot keys): ⌃⌥Space opens Halu, ⌃⌥T translates the selected text (sends ⌘C, needs Accessibility, restores the clipboard). The header clock shows time only; the date is in its tooltip.

Answering Claude from the notch: halu-hook writes PermissionRequest / AskUserQuestion requests to Application Support/Halu/claude-requests and waits (≤110 s, hook timeout 120) for Halu's answer file; it only waits while Halu's heartbeat file is fresh; "Answer in terminal" or no answer = silent exit (normal prompt). Plan usage comes from the status line (`halu-hook statusline`, rate_limits) into claude-usage.json, shown as a pill in the header's left wing with the weather (Open-Meteo, CoreLocation or a city in Settings). GitLab shows MR pipeline status and your own pipelines of the last day, with a notice when one finishes. Weekly recap (Tasks → chart button; a notice on Monday from 9:00) uses a local Stats log (focus, Claude sessions, meetings joined, pipelines) plus tasks and EventKit. Liquid Glass via `.glass(...)` (macOS 26, falls back to a card fill). The live notch is 9 pt taller than the camera housing so its bottom line shows.

Header: left = Halu, tab title (truncates), weather pill (click opens the hidden Weather tab: hourly + 7-day forecast, Apple-Weather look; WeatherKit would need a paid developer account, so data is Open-Meteo) and the time; right = Claude usage, speed, Chat, Pomodoro, VPN, Keep Awake. The live line continues through the notch's top flares to the screen edge. Settings lets you reorder tabs (drag or arrows; AppModel.order, "tabOrder").

Appearance (Settings): Black (default, melts into the notch), Dark Glass, Light Glass — glass modes draw the open panel with Liquid Glass (macOS 26 glassEffect, material fallback) and keep a black band behind the header; the header is always dark, the body follows the mode. Theme.primary/secondary/tertiary/card/hairline are adaptive (dark/light); use Theme.onPrimary for text on a primary fill. Header buttons share `.headerButton(active:tint:hovering:)` (26 pt circles). Claude session titles are cleaned of app markup (`ClaudeSession.cleanPrompt`).

Settings → Appearance also has Colours (Style: Minimal / Playful / Neon — per-tab colour drives Theme.accent, Neon glows), Panel size (Compact 680×404 / Comfortable 780×440 default / Wide 880×480; Layout.expandedWidth/contentHeight are set by AppModel) and hover delay. Tools modes: Test data, Decode, Compare, Calculator (own safe parser — never NSExpression, it throws ObjC exceptions; units via Measurement; currencies from open.er-api.com), Emoji (Unicode names), Stocks (Yahoo Finance chart endpoint); plus Colour picker, Mirror (camera only while open) and Ruler. Clipboard entries can be pinned. Shelf images are OCR'd (Vision, ru+en) and searchable.

18. Money (Tab.finance) — must-have, and the one feature that will go to iPhone and Apple Watch. Models (MoneyBook, MoneyTransaction, MoneyCategory with keywords and budgets) and StatementParser live in HaluCore so the phone and watch apps can share them; storage is money.json for now (CloudKit later). Quick entry "350 coffee" guesses the category from keywords; changing a category teaches the shop (MoneyBook.learn/merchantKey). Import: CSV (UTF-8 / Windows-1251, ; , or tab) and .xlsx (first sheet via /usr/bin/unzip + XMLParser); header row found by Russian/English column names; failed rows skipped; fingerprints stop duplicates. Overview (spent/income/left, donut, by-day bars), Transactions (search, recategorize), Budget (monthly + per-category limits).

Themes (Style): Minimal, Playful (default), Neon, Glass — each changes the panel backdrop (PanelBackground), card tint (Theme.card follows the theme), sidebar icon colours, and Neon adds a travelling gradient rim (NeonRim). Light Glass was dropped. Tools sections (modes and utilities) can be hidden in Settings (ToolsStore.hidden). Converter is its own Tools mode (ConverterKind: money via open.er-api rates, units via Measurement); the Calculator line is for sums. Money: Spending/Income switch, currency words in the entry line ($100, 20 евро) counted in roubles via market rates, income words flip to income, category chips; Plan (expected income, regular payments, savings goal, limits) and Categories (edit/hide/delete/add).

Recordly (dev.recordly.app, Electron, no URL scheme/AppleScript): the header record button folds the panel and presses the user's shortcut (default ⌥3, Settings → Recordly) via CGEvent; "Show controls" sends the reopen Apple event. Recording state = Recordly's menu bar icon exists (AX extras menu bar); stop presses its "Stop Recording" item.

Tabs are configurable in Settings (gear): all on by default; a disabled tab hides from the sidebar, pauses its store's background work (`isActive`), and drops its notch indicators.

## Roadmap

- **iPhone app** with the same features, **synced with the Mac app**. Keep models Codable and storage swappable so a sync backend (e.g. CloudKit) can be added later.
- Keep Awake button (`caffeinate`) — one tap, animated. Done.
- More quick-action buttons next to Keep Awake (one-tap commands). Ideas so far: VPN on/off. More to be collected with the user.
- Notes tab = Apple Notes (all notes, search; plain-text notes editable in Halu, rich notes read-only with "Open in Notes"; new notes go to the Notes folder).
- Media tab: any source. Core Audio process list (public API) finds the app playing audio, its window title comes from Accessibility, control via system media keys. The tab shows only while something plays or was paused in the last 30 min. Browsers (Chromium family, Safari): page player driven via AppleScript "execute javascript" (needs "Allow JavaScript from Apple Events"); never media keys there — they wake Apple Music when the video is paused. Browser tabs are scanned only while the Media tab is visible. The perl-hosted MediaRemote helper (Cyclop's approach) was rejected as a security bypass — don't reintroduce it.
- The animated Halu mark spins only where work is in progress (Claude tab, running tasks), never constantly in the main panel.
