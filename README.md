# Workflows

A macOS menu-bar app that runs a sequence of steps from one global hotkey or a click in the menu. A workflow is a named list of steps. Steps can open an app, run a shell command, open a URL in a chosen browser, quit every running app except the ones you keep, join a Wi-Fi network, turn Wi-Fi on or off, toggle dark mode, send a keystroke, type a text snippet into the focused field, run an Apple Shortcut, send the Slack conversation on screen to Claude, or send a screenshot to Claude. Steps run in order, and command steps wait for their process to exit before the next step starts.

## Features

- Lives in the menu bar only. There is no Dock icon or app switcher entry.
- Each workflow can have a global keyboard shortcut, recorded in the editor and handled by the [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) package. Workflows can also be run from the menu.
- Twelve step types:
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
  - Send Slack to Claude: sends the Slack channel or chat on screen to a new Claude Code session. See below.
  - Send Screenshot to Claude: takes a screenshot of the part of the screen you pick and pastes it into a new Claude Code session. See below.
- An editor window to add, rename and delete workflows, record their shortcuts, and add, reorder and remove steps.
- A launch at login toggle, backed by `SMAppService`.
- On first launch the app seeds a "Quit All Apps" workflow bound to Option-Command-K (importing the keep list from a previous QuitAll install if one exists), a "Connect VPN" workflow if NetBird is installed in `/Applications`, and a "Google Calendar" workflow that opens the calendar in Safari.

Send Keystroke, Type Text, Send Slack to Claude and Send Screenshot to Claude need Accessibility access, which macOS prompts for on first use. Send Screenshot to Claude also needs Screen Recording. Toggle Dark Mode needs Automation permission to control System Events.

## Send Slack to Claude

With a channel, chat or thread open in Slack's desktop app, press the workflow's shortcut (for example Option-Command-A). A panel opens with the conversation's name and, a moment later, a line saying how much of it will go: "Launch date: 9 messages, Tue 17 Nov 14:10 to now". Say what you'd like Claude to do or leave it blank, and press Return (it can be pressed before the line appears). Workflows reads those messages and every thread under them, then opens a new Claude Code session in Claude's desktop app with the conversation and the ask filled in. Nothing is sent until you send it in Claude.

- **How much goes:** worked out, not chosen.
  - A thread open beside the list: the whole thread.
  - Otherwise the discussion on screen. Slack's window says which messages are in view (each row of its list carries the message's timestamp). The newest 100 messages are read (300 with the panel's switch on Long; each press starts on Short), further back when the screen is scrolled further, and Claude's API (`claude-haiku-5-5`) is asked where the discussion those messages belong to starts and ends. What's on screen always goes.
  - Without a Claude API key, or when Claude doesn't answer in time, the messages on screen are joined by their neighbours each way until a two-hour silence.
  - The line is a menu: the fixed ranges (Today, Last 7 days, Last 50, Since I last wrote, Full history) are in it for when the guess is wrong.
- **What Claude's API sees:** for that one question, the start of each of those messages (300 characters), its author, its time and how many replies it has. Its answer is two line numbers and a topic of a few words, so text in a message can't make it do anything else.

- **Which conversation:** read through Accessibility from Slack's window. Its page address carries the workspace and conversation IDs. In the Direct messages view the address has no ID (`…/client/T…/dms`), so the window title's names ("Ana Silva, Ben Okafor (DM)") are matched to people and then to your DM or group chat with exactly them. Channel names in the title are the fallback for channels.
- **Read-only:** `SlackAPI.get` refuses any Slack method outside `SlackAPI.readMethods`, so the step can't post, react or change anything, whatever the token allows.
- **Limits:** what was worked out comes with the replies of its newest 60 threads; older threads are marked with how many replies weren't read. Of the fixed ranges, Full history reads the newest 100 messages and every thread under them, so a small channel comes in whole and a busy one stays quick, and the others read up to 500 messages and the replies of the newest 60 threads. If Slack asks it to slow down, the panel says it's waiting.
- **Several workspaces:** one token per workspace. The step reads with the token whose workspace Slack is showing (the address's team ID, else the window title's workspace name). A workspace with no token gets a message, not a read.
- **Long conversations:** Claude's link takes about 14,000 characters, so the prompt holds the newest messages that fit under 12,000. The whole conversation is then saved to `~/Library/Application Support/Workflows/Slack/` and the prompt asks Claude to read that file (past 150,000 characters, to search it). Saved conversations are cleared after three days.
- **Token:** a Slack user token (`xoxp-…`) with `channels:history`, `groups:history`, `im:history`, `mpim:history`, the matching `:read` scopes and `users:read`. Each is kept only in the login Keychain (`com.karlfoster.Workflows.slack`, one item per workspace, its account the team ID; a token saved by an older version stays under `token`). Add or remove workspaces on the step in the editor, or pipe a token in so it never shows in a command line; it's checked with Slack and saved for its workspace:

  ```sh
  /Applications/Workflows.app/Contents/MacOS/Workflows --store-slack-token < token.txt
  ```
- **Claude API key:** optional, for finding where the discussion starts. Kept only in the login Keychain (`com.karlfoster.Workflows.claude`). Add or remove it on the step in the editor, or pipe it in; it's checked with Claude and saved:

  ```sh
  /Applications/Workflows.app/Contents/MacOS/Workflows --store-claude-key < key.txt
  ```

The code is in `Sources/Slack/`. The text, prompt, chat matching, parsing and the working out of how much to send are tested in `Tests/`.

## Send Screenshot to Claude

Press the workflow's shortcut and pick what to capture as with Shift-Command-4: drag an area, or press Space and click a window. Escape cancels. Workflows opens a new Claude Code session in Claude's desktop app and pastes the picture into its prompt box, so you only type what you want and send it.

- Claude's new-session link (`claude://code/new`) carries text only, so the picture goes on the clipboard and the step presses Command-V once the new session's empty prompt box has the cursor, which it watches through Accessibility (a fixed wait missed it when Claude was already in front). The picture stays on the clipboard, so if it doesn't show up, press Command-V yourself.
- It uses macOS's own `screencapture -i`, with no window shadow and no shutter sound. The file it writes is deleted once the picture is on the clipboard.
- Its workflow is on Shift-Command-2, next to macOS's own Shift-Command-3, 4 and 5, which it leaves alone.

The code is in `Sources/ScreenshotToClaude.swift`.

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

Then build and run the `Workflows` scheme in Xcode. To build and test from the command line instead:

```sh
xcodegen generate
xcodebuild -project Workflows.xcodeproj -scheme Workflows -configuration Release build
xcodebuild -project Workflows.xcodeproj -scheme Workflows -destination 'platform=macOS' test
```

The app is signed with a Developer ID Application certificate (team UPYX9DMV5Z in `project.yml`), not ad hoc, so every build is the same app to macOS and Accessibility access and the Keychain token survive updates. To build without that certificate, set `CODE_SIGN_IDENTITY` to `"-"` and remove `DEVELOPMENT_TEAM` in `project.yml`; macOS will then ask for Accessibility again after each build. The bundle identifier is `com.karlfoster.Workflows`. Install by quitting Workflows and replacing `/Applications/Workflows.app` with the built app.

## Where data is stored

Workflows and their steps are saved as JSON in the app's `UserDefaults` under the key `workflows`, so they live in `~/Library/Preferences/com.karlfoster.Workflows.plist`. Keyboard shortcuts are stored by the KeyboardShortcuts package, keyed by each workflow's UUID. The Slack tokens and the Claude API key are in the login Keychain, and the range last picked by hand in `UserDefaults` under `slackToClaudeRange`.

## Licence

MIT. See [LICENSE](LICENSE).
