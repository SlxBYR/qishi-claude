<div align="center">

**English** | [简体中文](README.zh-CN.md)

<img src="docs/images/logo.png" width="128" alt="Qishi·Claude icon">

# Qishi·Claude（栖时·Claude）

**A Claude Code companion that lives on your desktop: Claude-chan and Clawd the crab work right alongside Claude.**

Native macOS Liquid Glass workbench · Token activity heatmap · Usage limits · Desktop pets · WebRTC leak check

[![Release](https://img.shields.io/github/v/release/SlxBYR/qishi-claude?include_prereleases&label=release&color=D97757)](https://github.com/SlxBYR/qishi-claude/releases)
[![License](https://img.shields.io/github/license/SlxBYR/qishi-claude?color=D97757)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-27%2B%20%C2%B7%20Apple%20silicon-000000?logo=apple)
![Windows](https://img.shields.io/badge/Windows-10%2F11%20x64-0078D4?logo=windows)
![Status](https://img.shields.io/badge/status-work%20in%20progress-orange)
[![Stars](https://img.shields.io/github/stars/SlxBYR/qishi-claude?style=social)](https://github.com/SlxBYR/qishi-claude/stargazers)

2.2.1 (build 31)

<img src="docs/images/workbench.png" width="820" alt="Claude workbench">

</div>

> [!WARNING]
> **Status: work in progress.** This is an unfinished project still under development, not a stable release. Features, UI and data formats may change at any time, and there may be undiscovered bugs.
> The Windows version has only been previewed in isolation on macOS and has not been fully tested on real Windows machines; the macOS version has not been fully verified against real Gmail and Claude accounts either.
> The macOS package is ad-hoc signed (not notarized by Apple). On first launch, allow it in System Settings › Privacy & Security, or right-click the app and choose Open. The Windows package is unsigned; if SmartScreen warns you, choose "Run anyway".
> You're welcome to try it and send feedback, but please don't rely on it for anything important.

> [!IMPORTANT]
> **Clawd artwork permission pending.** The Clawd animations and artwork in this project come from [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk), animated by 鹿鹿 ([@rullerzhou-afk](https://github.com/rullerzhou-afk)). They are all rights reserved and not covered by AGPL-3.0. Permission for non-commercial use, adaptation and redistribution with this project has been requested from the author; please do not redistribute or adapt them until it is granted. If the author declines, they will be replaced or removed right away. See "Assets & Sources" below.

## Download

[GitHub Releases](https://github.com/SlxBYR/qishi-claude/releases) provides packages for macOS (.dmg, Apple silicon, macOS 27+) and Windows (single-file portable .exe or .zip, x64).

A native macOS Claude workbench plus a standalone Windows desktop app, built on the original Qishi (栖时) source code. The macOS version runs on Apple silicon with macOS 27 or later and needs no Python, Node or Electron. The Windows version is a standalone portable app for Windows 10/11 x64; see [Windows/README.txt](Windows/README.txt) (Chinese).

Qishi currently works with Claude Code. Support for other agents may come in the future.

The app UI is available in Chinese and English.

## Features

### Desktop companions: Claude-chan + Clawd

<table>
<tr>
<td align="center"><img src="Resources/Claude/idle.webp" width="110"><br><sub>Idle</sub></td>
<td align="center"><img src="Resources/Claude/thinking.webp" width="110"><br><sub>Thinking</sub></td>
<td align="center"><img src="Resources/Claude/writing.webp" width="110"><br><sub>Coding</sub></td>
<td align="center"><img src="Resources/Clawd/typing.gif" width="120"><br><sub>Clawd typing</sub></td>
<td align="center"><img src="Resources/Clawd/qishi-hop.gif" width="120"><br><sub>Hop</sub></td>
<td align="center"><img src="Resources/Clawd/qishi-heart.gif" width="120"><br><sub>Heart</sub></td>
</tr>
</table>

Claude-chan and Clawd the crab share your desktop and switch animations as Claude thinks, reads, writes code, runs commands, searches, delegates to subagents, waits, compacts context, finishes, hits an error or rests.

- Clawd uses Clawd on Desk's original SVGs, renderer.js and styles, with eye tracking, clicks, dragging, idle, sleep and edge docking.
- Claude-chan is built on CrossPet's motion logic, effects.js and all 60 original images, keeping breathing sway, blinking, head pats, dizzy spins, sulking, holiday animations and multi-task performances.
- Dragging Claude-chan only moves the character. Dropped at a screen edge, she docks statically (half hidden, using the docking artwork) with no peek, retract or wave animation, and hovering doesn't make her peek out.
- Claude-chan and Clawd can be shown or hidden separately (from the menu bar, the "Companions & Integration" page, or by right-clicking a character), and each can be dragged, remembers its position, and can be resized and kept on top. Desktop labels, limit bars and floating buttons have been removed. Clicking Claude-chan shows a CrossPet-style bubble with how many days your account has been alive.
- The menu bar Clawd icon walks in place while Claude works (thinking, reading, coding, running, searching, subagents, compacting context), and returns to a static mark when idle, waiting for you, done or errored. The walking frames share the same outline grid, play at a steady pace, and are driven by a Core Animation keyframe mask in the style of RunCatNeo rather than timer redraws. It can be turned off from the menu bar menu or "Companions & Integration", and stays still when Reduce Motion is on.
- At the bottom of the sidebar, Clawd randomly plays either its original animations or one of six new ones drawn for Qishi (hop, wave, look around, crab walk, heart, hum). Click it to switch.

### Claude workbench

The screenshot at the top is the Windows workbench: the Claude logo animation on the left, a status card on the right, and usage limits plus the Token activity heatmap below.

- The left side of the workbench is a standalone Claude logo animation: the center and the roots of every ray stay fixed while the outer part of each ray slowly stretches from its root (each on its own 7–11 second cycle), so the logo always stays in one piece. It speeds up slightly while Claude works. A glass card on the right shows the status.
- The session list only shows the 5 most recent sessions that made tool calls (sessions with 0 tool calls are hidden), with tracking for parallel tools and subagents, and a button to open the project folder.
- Optional notifications for completion, errors and waiting, and an optional one-time tool approval panel: allow once, deny, or hand back to Claude.

### Usage, limits and Token activity

- **Limits**: the 5-hour, weekly and optional spend limits reported by Claude Code's official status line, plus context usage, update time and stale markers.
- **Silent Claude Desktop limit history** (merged into "Usage & limits"): only while Claude Desktop is running, Qishi checks the usage history that Claude Desktop itself writes on your Mac (`~/Library/Application Support/Claude/plan-usage-history.json`) every 20 seconds and reads it only when it changes. It keeps just the timestamps and the 5-hour and weekly percentages, stores the organization ID only as a hash, and merges everything into `desktop-usage-history.json` in its data directory (plain text, up to 400 days). The last 7 days can be expanded into a trend chart and details. No network access, no traffic capture, no Accessibility APIs, no window automation, no reading login credentials, and nothing written to any Claude file. In "Usage & limits", each limit shows whichever of the two sources is newer and labels its source. Desktop records carry no reset time, so a reset time is only reused when it falls in the same window as a Claude Code report. Claude Desktop decides when to update its records (at launch, and when its usage panel was opened in the last 24 hours), so they may lag behind. The file format is internal to Claude; if it changes, Qishi shows it as unreadable instead of guessing.
- **Token activity**: reads the usage fields of every reply in your local Claude Code transcripts (`~/.claude/projects/**/*.jsonl`, respecting `CLAUDE_CONFIG_DIR`), de-duplicates by message and sums by local date into a one-year calendar heatmap (one column per week, one row per day, four shades of the accent color split by the quartiles of days with usage). Switch between daily, weekly and cumulative totals; hover a cell for its date and value. Also shows today / this week / past-year totals and a 14-day table. It only reads usage numbers, timestamps and message IDs, never reads or stores conversation text, never goes online, and refreshes incrementally every 2 minutes.

### Pets & integration

<img src="docs/images/companion.png" width="720" alt="Pets and integration settings">

Connect Claude Code in one click, control each pet's visibility, always-on-top and size, and toggle completion notifications and one-time tool approval (the macOS version also has a toggle for the walking menu bar icon). See "How the integration works" below.

### Account guard & WebRTC check

<img src="docs/images/guard.png" width="720" alt="Account guard: registration timer and Gmail check">

- Keeps Qishi's original registration timer, read-only Gmail check, reminders and menu bar presence.
- The sidebar also shows a WebRTC leak check: an offscreen WebKit view opens https://browserleaks.com/webrtc and reads the "WebRTC Leak Test" result and WebRTC public IP. It runs at launch and every 5 minutes after that; click the status to check again. Whenever the result isn't "No Leak", Clawd keeps playing its error animation.

### Interface

- The macOS UI uses native system components for Liquid Glass: a floating NavigationSplitView sidebar, glass toolbar buttons, glassEffect cards, and glass / glassProminent buttons.
- Light / dark / system appearance and Chinese / English switching (the "Appearance & Language" toolbar menu). The accent color is Claude's logo color `#D97757`; the selected sidebar row follows the system accent color.
- A streamlined main window: decorative slogans and repeated explanations removed; sources and licenses can be expanded on demand.
- A poster (`Resources/Sidebar/poster.png`) sits below the sidebar navigation. It's decorative only; clicking it doesn't switch pages.

> The screenshots above come from the Windows version, rendered with sample data by `npm run verify-ui`. The macOS version uses a native Liquid Glass look with a slightly different layout.

## Getting started

1. Open "栖时·Claude.app". The two transparent desktop pets appear right away; the workbench doesn't pop up. Right-click a character to pat it, poke it, open Qishi's other features, or quit.
   Click Claude-chan on the desktop to see how many days your account has been alive. The bubble closes after 8 seconds, or click it to close.
2. To connect for the first time, right-click and choose "Open Qishi", go to "Companions & Integration", and click "Connect Claude Code".
3. Start a new Claude Code session. If Claude asks you to trust the hooks, confirm inside Claude.
4. Start a task and both characters will follow the events. Limits appear once Claude's status line pushes data.
5. To approve tool requests in Qishi, also turn on "Approve single tool requests in Qishi". It's off by default.
6. Account age is calculated from the registration time saved under "Connection" and goes up by 1 every full 24 hours; if it isn't set, a setup hint is shown. This number is how long the account has existed, not a live check of whether the account still works.
7. Set up Gmail under "Connection". On first launch, Qishi copies the non-password settings of the old Qishi and can still read the old Keychain password. New saves and deletions use a separate Keychain item and never delete the old password.

## How the integration works

- Updates `~/.claude/settings.json`; if `CLAUDE_CONFIG_DIR` is set in the launch environment, that directory is used instead.
- Only adds hooks marked with `--qishi-hook`, and hooks into `--qishi-statusline`.
- Existing hooks, permissions, model and other settings are kept. An existing command status line keeps running in sequence and its output is preserved (up to 3 seconds).
- A full backup of settings.json is saved before connecting. Disconnecting removes only this app's hooks and restores the original status line field if this app still manages it; later changes you made are kept.
- The bridge program is copied into a separate data directory, so moving the app doesn't break the hook paths.
- Never installs third-party plugins, never modifies the Claude app, never reads Claude login credentials, and never makes extra requests to usage APIs.

## Data & permissions

- Data directory: `~/Library/Application Support/QishiClaude`
- Backups: the `Backups` folder inside that directory.
- Work state keeps only hashed session IDs, project paths, event names, tool names, times, counts and usage. Prompts, replies and conversation text are never saved.
- When approvals are on, request arguments are temporarily stored in the `requests` folder of that directory so the whole request can be shown; they're deleted once handled, and leftovers are cleaned up at the next launch.
- The approval directory is 0700 and its files are 0600. Only explicit one-time allow / deny is supported; no permanent permission rules are added.
- If the app isn't running, approvals are off, a request times out, the session changes or the app quits, no decision is made up: control goes back to Claude's own flow.
- Questions and plan confirmations are still handled inside Claude. There is no auto-approval.

## Limits & status boundaries

- Limits depend on what Claude Code actually reports or what Claude Desktop itself records. Missing means unknown, never "100% remaining".
- Limits not updated for 15 minutes are marked as stale. After the reset time passes, Qishi waits for fresh real data instead of assuming a reset.
- A busy session with no work events for 5 minutes shows "Awaiting update", so old state isn't mistaken for live work.
- Regular Claude desktop chat doesn't provide this event protocol; this version works with Claude Code, and other agents may be supported in the future.

## Building & testing from source

```bash
bash Scripts/build.sh
bash Scripts/test.sh
```

Push to GitHub (public repository SlxBYR/qishi-claude; commits every change, then pushes the current branch):

```bash
bash Scripts/push.sh "commit message"
```

Run only the pet regression tests (WebKit static docking and native docking motion):

```bash
bash Scripts/test.sh --motion-only
```

- Windows: run `npm ci`, `npm test` and `npm run build` in `Windows/`, or run `Scripts/build-windows.ps1`.
- Builds `../栖时·Claude.app` by default, with the build cache in `.build`. Use `QISHI_BUILD_DIR` and `QISHI_OUTPUT_DIR` to change the cache and output directories.
- The test script needs Node.js and runs real WebKit and window checks in a logged-in macOS desktop session. Docking screenshots go to `.build/MotionVerification` by default; change this with `QISHI_MOTION_TEST_OUTPUT`.
- The pet tests cover static docking, no peeking on hover, dragging and hiding; the script also compiles a standalone test program to check that native docking motion can be interrupted and that stale callbacks are ignored.
- The Claude logo layers are split from the source image by `python3 Scripts/make-claude-logo.py` (one fixed core layer, plus one layer per ray's outer segment overlapping the core), into `Resources/ClaudeLogo`.
- The new Clawd animations are drawn frame by frame on Clawd's original 15×16 pixel grid by `python3 Scripts/make-clawd-animations.py` (requires Pillow), into `Resources/Clawd/qishi-*.gif`.
- `Qishi.xcodeproj` can be opened with full Xcode. The main app uses a non-sandboxed signature so it can access the Claude settings you choose to connect; the WidgetKit extension still needs your own development team and App Group.
- The command-line build doesn't embed the WidgetKit extension; the two floating characters work as-is.

### Verification modes (never touch real account settings)

```bash
栖时·Claude.app/Contents/MacOS/Qishi --demo
栖时·Claude.app/Contents/MacOS/Qishi --demo --show-workbench
栖时·Claude.app/Contents/MacOS/Qishi --render-previews /absolute/path/previews
栖时·Claude.app/Contents/MacOS/Qishi --verify-companions /absolute/path/previews
```

UI previews are labeled as sample data. A normal launch never shows sample limits. `ClaudeIntegrationTests.py` uses an isolated temporary directory and never touches your real `~/.claude`.

## Platform limitations

- On Windows, the tray, notifications, DPAPI, PowerShell, DPI scaling, multiple displays and window lifecycle haven't been confirmed on real Windows machines.
- Not verified with real Gmail or Claude accounts, and no paid model calls with a real account have been tested.

## Assets & Sources

| Source | Link | Pinned version |
| --- | --- | --- |
| Clawd on Desk | https://github.com/rullerzhou-afk/clawd-on-desk | `834f2b83eb6c9725956c5c541b59f825b48b4b9a` |
| CrossPet | https://github.com/lokicorvus/crosspet | `5c64326b6e7fc175eda0360c0bb5c4732541d138` |
| Event format | https://code.claude.com/docs/en/hooks | |
| Limit format | https://code.claude.com/docs/en/statusline | |

- Claude-chan artwork: CrossPet / lokicorvus, based on the community's Claude-chan character design. Licensed under CC BY-NC-SA 4.0; no commercial use.
- Clawd: the animations come from [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk), animated by 鹿鹿 ([@rullerzhou-afk](https://github.com/rullerzhou-afk)). See [assets/LICENSE](https://github.com/rullerzhou-afk/clawd-on-desk/blob/main/assets/LICENSE) (copy in this repository: `Resources/Clawd/LICENSE`): all rights reserved, no commercial use. clawd-on-desk's AGPL-3.0 is a source code license and doesn't cover its animations and artwork, and these assets are not part of this project's AGPL-3.0 license either. The six new Clawd animations and the walking menu bar icon drawn for Qishi are adapted from these assets and fall under the same asset license.
- The rights to the Clawd character itself belong to Anthropic; this attribution does not imply permission or endorsement from Anthropic.
- This bundle is meant for personal use on your own machine. Before publicly distributing a bundle that includes the original Clawd artwork, permission must be obtained from the rights holder.
- The full asset licenses are in `Resources/Claude/LICENSE.md` and `Resources/Clawd/LICENSE`, with file fingerprints in `manifest.json` in the same directories. The new Claude-chan dragging variants follow the original character design and asset license.
- Not an official Anthropic app.

## License

This project's source code is released under the GNU Affero General Public License v3.0 (AGPL-3.0); see [LICENSE](LICENSE).

The project includes and adapts AGPL-3.0 code from Clawd on Desk (`Resources/ClawdWeb`, `Upstream/clawd-on-desk`), so the whole distribution must stay under AGPL-3.0, which is also the most open option the upstream license allows. CrossPet's MIT code is compatible with it, and its original copyright notice is kept in `Resources/CrossPet/LICENSE`.

AGPL-3.0 covers source code only, not animations or artwork: Claude-chan's artwork is CC BY-NC-SA 4.0; the Clawd animations and artwork (including the animations and icons adapted from them for Qishi) follow clawd-on-desk's [assets/LICENSE](https://github.com/rullerzhou-afk/clawd-on-desk/blob/main/assets/LICENSE), all rights reserved and no commercial use; the sidebar poster was provided by the user and its rights belong to its original author. Each follows its own license (see "Assets & Sources" above).

## Acknowledgements

- Thanks to [CrossPet](https://github.com/lokicorvus/crosspet) (lokicorvus and CrossPet contributors): the desktop Claude-chan's motion logic, effects.js and all character artwork come from this project.
- Thanks to [clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) (animated by 鹿鹿 [@rullerzhou-afk](https://github.com/rullerzhou-afk), and the project's contributors): Clawd's animation assets, renderer.js, styles and interaction logic come from this project, and the new Clawd animations drawn for Qishi are drawn on its original pixel grid.

## Star History

<a href="https://star-history.com/#SlxBYR/qishi-claude&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=SlxBYR/qishi-claude&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=SlxBYR/qishi-claude&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=SlxBYR/qishi-claude&type=Date" />
  </picture>
</a>
