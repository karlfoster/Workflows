# Workflows

A macOS menu-bar app that runs a sequence of steps from one global hotkey or a click in the menu. A workflow is a named list of steps. Steps can open an app, run a shell command, open a URL in a chosen browser, quit every running app except the ones you keep, join a Wi-Fi network, turn Wi-Fi on or off, toggle dark mode, send a keystroke, type a text snippet into the focused field, or run an Apple Shortcut. Steps run in order, and command steps wait for their process to exit before the next step starts.

## Features

- Lives in the menu bar only. There is no Dock icon or app switcher entry.
- Each workflow can have a global keyboard shortcut, recorded in the editor and handled by the [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) package. Workflows can also be run from the menu.
- Ten step types:
  - Open App: launches and activates an app chosen from a file picker.
  - Run Command: runs the text through `/bin/zsh -lc` and waits for it to finish. Output is discarded.
  - Open URL: opens the URL in the default browser or a browser picked from those installed.
  - Quit All Apps: quits every regular app except those on a keep list. Finder and Workflows itself are always kept. Optionally clears the Dock's recent applications section afterwards.
  - Join Wi-Fi Network: runs `networksetup -setairportnetwork` for the named SSID on the Wi-Fi interface.
  - Wi-Fi On/Off: runs `networksetup -setairportpower`.
  - Toggle Dark Mode: uses an AppleScript against System Events to flip the appearance.
  - Send Keystroke: posts a recorded key combination to the frontmost app.
  - Type Text: types a string into the focused field of the frontmost app as unicode key events, without using the clipboard. It waits for hotkey modifiers to be released first.
  - Run Apple Shortcut: runs `shortcuts run <name>`. The editor lists the shortcuts installed on the Mac.
- An editor window to add, rename and delete workflows, record their shortcuts, and add, reorder and remove steps.
- A launch at login toggle, backed by `SMAppService`.
- On first launch the app seeds a "Quit All Apps" workflow bound to Option-Command-K (importing the keep list from a previous QuitAll install if one exists), a "Connect VPN" workflow if NetBird is installed in `/Applications`, and a "Google Calendar" workflow that opens the calendar in Safari.

Send Keystroke and Type Text need Accessibility access, which macOS prompts for on first use. Toggle Dark Mode needs Automation permission to control System Events.

## Requirements

- macOS 14.0 or later (deployment target in `project.yml`).
- Xcode with Swift 5 tools (`SWIFT_VERSION: "5.0"`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`.
- The KeyboardShortcuts package (2.0.0 or later) is fetched by Swift Package Manager when the project resolves.

## Building

```sh
xcodegen generate
open Workflows.xcodeproj
```

Then build and run the `Workflows` scheme in Xcode. To build from the command line instead:

```sh
xcodegen generate
xcodebuild -project Workflows.xcodeproj -scheme Workflows -configuration Release build
```

The project is set to manual, ad hoc code signing (`CODE_SIGN_IDENTITY: "-"`), so no developer certificate is needed to build it for your own machine. The bundle identifier is `com.karlfoster.Workflows`.

## Where data is stored

Workflows and their steps are saved as JSON in the app's `UserDefaults` under the key `workflows`, so they live in `~/Library/Preferences/com.karlfoster.Workflows.plist`. Keyboard shortcuts are stored by the KeyboardShortcuts package, keyed by each workflow's UUID.

## Licence

MIT. See [LICENSE](LICENSE).
