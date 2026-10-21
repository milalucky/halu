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

Later: Integrations screen with API keys — Jira (company Atlassian, API token), Slack notifications.

## Roadmap

- **iPhone app** with the same features, **synced with the Mac app**. Keep models Codable and storage swappable so a sync backend (e.g. CloudKit) can be added later.
- Keep Awake button (`caffeinate`) — one tap, animated. Done.
- More quick-action buttons next to Keep Awake (one-tap commands). Ideas to be collected with the user.
- The animated Halu mark spins only where work is in progress (Claude tab, running tasks), never constantly in the main panel.
