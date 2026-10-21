<p align="center">
  <img src="docs/icon.png" width="160" alt="Halu icon">
</p>

<h1 align="center">Halu</h1>

<p align="center">A calm workspace that lives in your MacBook's notch.</p>

---

Halu stays invisible until you point at the notch, then unfolds into a small panel with the things you reach for all day. It works on external displays too: there, the top centre of the screen acts as a virtual notch.

## Features

- **Tasks.** A single to-do list for the day. Check a task off and it moves to the Done archive, where you can search and restore it. Add tasks by typing or by voice (English or Russian).
- **Calendar.** Today's and tomorrow's meetings from any calendar on your Mac, including Google. One-click **Join** for Zoom, Google Meet, Teams and Webex. A reminder drops out of the notch 10 minutes before a meeting and again when it starts.
- **Claude.** Live status of your Claude Code sessions: working, waiting for you, your turn, done, with a progress bar built from each session's plan. When Claude needs an answer, the notch lights up and a notice pops out.
- **Shelf.** New screenshots and screen recordings appear here automatically, along with images you copy. Drag them out wherever you need them, or drop any file onto the notch to keep it for later.
- **Clipboard.** Recent text you copied plus saved snippets, one click to copy again. Anything a password manager marks as secret is never recorded.
- **Translate.** English ↔ Russian with automatic direction. Type or dictate, then copy the translation.
- **Accounts.** A searchable vault for test accounts: service, login, password and notes, grouped by service. Encrypted on disk with a key kept in your Keychain; copied passwords clear from the clipboard after a minute. Paste rows from a table to import them.
- **Notes.** A quick scratch pad; empty notes clean themselves up.
- **Keep Awake.** One tap keeps your Mac from sleeping while long work runs, for an hour, three hours or until you turn it off.

On the roadmap: media controls, Jira and Slack integrations, and an iPhone companion app with sync.

## Requirements

- macOS 15 or later
- Swift 6 toolchain (the Xcode Command Line Tools are enough)

## Build and run

```bash
./scripts/build.sh --install
```

This builds `Halu.app`, copies it to `~/Applications` and launches it. Halu runs from the menu bar; it has no Dock icon.

## Permissions

Halu asks only when a feature needs it:

| Feature | Permission |
|---|---|
| Calendar | Calendars (add your Google account in System Settings → Internet Accounts first) |
| Shelf | Access to your screenshot folder |
| Voice input | Microphone and Speech Recognition |

## Connecting Claude Code

Open the Claude tab and press **Connect**. Halu installs a small hook, `~/.claude/hooks/halu-hook`, and registers it in `~/.claude/settings.json`; a backup of your settings is saved next to it, and your existing hooks are left in place. The hook only records each session's status locally under `~/Library/Application Support/Halu`; it never changes what Claude does.

## License

[MIT](LICENSE)
