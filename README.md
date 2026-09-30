# Notch

A free, open-source, study-focused companion for the MacBook notch. Hover over the notch and it expands into a mini dashboard with a Pomodoro timer, assignment tracker, calendar, file shelf, clipboard history and notes.

Everything runs locally. There is no account, no server and no tracking, and it's a single Swift file with no dependencies.

## Features

| Tab | What it does |
| --- | --- |
| **Focus timer** | Pomodoro cycles (focus, short break, long break after 4 rounds), skip and auto-start, plus daily and weekly focus stats and a day streak |
| **Assignments** | Quick-add list with due dates, sorted by urgency, with overdue highlighting |
| **Schedule** | Today's and tomorrow's events from the macOS Calendar app (iCloud, Google and others you've added) |
| **File shelf** | Drag files onto the notch to hold them, then drag them back out anywhere |
| **Clipboard** | History of your last 20 copied text items (password-manager copies are ignored) |
| **Notes** | A scratchpad that autosaves |

**Smart closed notch:** when collapsed, the notch widens to show whatever is most urgent: a running timer, a class starting within 15 minutes, or a deadline within 48 hours.

Works on Macs without a notch too, using a virtual pill at the top of the screen.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode or the Command Line Tools: `xcode-select --install`

## Install

```bash
git clone https://github.com/dchavan2192/notch.git
cd notch
bash build.sh
```

The build takes about 10 to 30 seconds and launches the app. It runs in the background with no Dock icon. To stop it, use the power icon in the expanded notch or the menu bar icon.

### Start at login

```bash
mv Notch.app /Applications/
```

Then add **Notch** under System Settings > General > Login Items & Extensions.

## Usage

- **Open:** hover over the notch, or choose "Open Notch" from the menu bar icon.
- **Files:** drag a file toward the notch and it opens on the shelf automatically. Click a file to open it, right-click for more options.
- **Assignments:** type a title, click the calendar pill to cycle the due date, press Enter.
- **Calendar:** on first use, click "Connect Calendar" and approve the macOS prompt.

## Privacy

All data stays on your Mac, stored in `UserDefaults`. Calendar access is read-only and optional. Clipboard history is kept in memory only and is cleared when the app quits.

## Known limitations

- The shelf stores references to files, not copies. If you move or delete the original, it disappears from the shelf.
- The app is self-signed. Because you build it yourself, Gatekeeper won't block it, but macOS may ask for Calendar permission again after a rebuild.
- Due dates use a cycling button rather than a full date picker.

## How it works

A borderless, non-activating `NSPanel` sits at the top of the screen and hosts a SwiftUI view. The window ignores mouse events while collapsed, so the menu bar stays fully usable, and a mouse-position monitor handles hover-to-open and drag-to-open. The notch size is read from `NSScreen.safeAreaInsets` and the auxiliary top areas.

All code lives in `main.swift`.

## Roadmap

- [ ] Global hotkey to open the notch
- [ ] Media controls
- [ ] Flashcards
- [ ] Full date picker for assignments
- [ ] Customizable timer lengths and themes
- [ ] Multi-display support

## Contributing

Issues and pull requests are welcome. Fork the repo, make your change, run `bash build.sh` to check it builds, and open a PR.

## License

[MIT](LICENSE)
