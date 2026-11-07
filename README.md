# SousBar: Claude Code on your Touch Bar

**Approve, deny and answer Claude Code from your MacBook Pro Touch Bar, without switching to the terminal.** Claude does the cooking; SousBar, your sous chef, brings you only what needs you: permission requests, questions and finished replies. Approve or deny (with a spoken reason), answer questions, read replies word by word, switch sessions and models, and dictate prompts, all from the Touch Bar, whichever app is in front, without ever taking focus.

A free macOS menu bar app for Touch Bar MacBook Pros (2016–2022), macOS 12 or later.

Works with **Claude Code** today. Support for other agents (such as Cursor) is planned; see [Agents](#agents).

Free to use. If SousBar saves you a trip to the terminal, you can [buy me a coffee](https://buymeacoffee.com/hataphan) ☕

<a href="https://buymeacoffee.com/hataphan"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" height="40"></a>

<img src="docs/gifs/flow.gif" alt="SousBar on the Touch Bar: Claude works, asks to run npm run build, the approval is held to allow, and the finished reply is swiped through" width="100%">

**Contents:** [Install](#install) · [Try it](#try-it-without-claude) · [Using it](#using-it) · [Privacy](#privacy) · [How it works](#how-it-works) · [Troubleshooting](#troubleshooting) · [Support](#support)

## Install

**Disk image** (most people): download `SousBar-<version>.dmg` from [Releases](https://github.com/hatamania/sousbar-community/releases), open it, and drag SousBar to Applications, then open it. Releases are signed and notarized by Apple, so it opens like any other Mac app. A short **setup window** walks you through it: **Connect to Claude Code** (adds its hooks to `~/.claude/settings.json`, after a backup), turn on the Control Strip, allow the microphone for voice (optional), launch at login, and send a test approval to the Touch Bar. Restart running Claude Code sessions afterwards. Reopen it any time from **Setup Guide…** in the menu bar.

**Script, from a release** (no Xcode needed): download `SousBar-<version>.zip`, unzip it, then:

```bash
cd SousBar-<version>
./install.sh
```

**From source** (needs Xcode or the Command Line Tools, Swift 5.9+):

```bash
cd sousbar
./install.sh
```

Either way: macOS 12 or later on a MacBook Pro with a Touch Bar. Releases are universal (Apple silicon and Intel), signed with Developer ID and notarized. Building from source gives you an ad-hoc signed app; `install.sh` clears the download quarantine so macOS lets it run.

The installer:
- builds and installs `~/Applications/SousBar.app` (chef-hat icon, drawn at install time), a menu-bar app with no Dock icon
- puts the hook at `~/.sousbar/bin/sousbar-hook`
- adds hooks to `~/.claude/settings.json`, after backing it up to `settings.json.sousbar-backup-<time>`

Then turn on **System Settings › Keyboard › Touch Bar Settings › Show Control Strip**. A small chef-hat pill appears on the right of the Touch Bar.

### Upgrading from AgentStrip

SousBar was called AgentStrip. Running `./install.sh` upgrades it: it removes the old app, replaces the old hook entries in `~/.claude/settings.json` (after a backup), and carries your settings over. Then restart running Claude Code sessions, delete `~/.agentstrip`, and turn **Launch at login** on again if you used it.

## Try it without Claude

```bash
~/.sousbar/bin/sousbar-hook demo              # short fake session: status → approval → response
~/.sousbar/bin/sousbar-hook demo permission   # risky Bash approval (hold to allow)
~/.sousbar/bin/sousbar-hook demo always         # approval with an "always allow" rule
~/.sousbar/bin/sousbar-hook demo safe         # read-only approval (tap to allow)
~/.sousbar/bin/sousbar-hook demo question     # 2 questions, one multi-select
~/.sousbar/bin/sousbar-hook demo response     # a finished reply to swipe through
```

The demo prints the exact JSON that would go back to Claude Code.

## Using it

**The pill** (always in the Control Strip):

A chef hat whose color shows the state of all your sessions:

| Pill | Meaning |
|---|---|
| gray | idle |
| blue | Claude is working |
| green | new response you haven't read |
| orange (with a number when several are waiting) | Claude needs an answer |

Tap the pill to open the full bar.

**The bar** reads left to right: the session chip, the text, then buttons, with the hide button (crossed-out eye) always last on the right. The chip has a fixed width; long folder names wrap onto two lines. While Claude works, the text shows an animated spinner and shimmering orange text ("Cooking…", "Running Bash: npm test").

**Approvals.** These open the full bar automatically. Read-only tools (Read, Grep, WebFetch…) need one tap on **Allow**. Anything that can change things (Bash, Edit, Write, MCP tools…) needs you to **hold Allow for 0.7 s**. **Deny** is a tap. When Claude Code offers a "don't ask again" rule, **Hold · Always** allows this request and saves that exact rule (the same one the terminal would offer). It always needs a hold. Long-press the text to see what rule it would add. To tell Claude *why* you're saying no, hold the mic **Deny** button, say the reason, release, check it, and tap **Deny ➤**. **→ Term** hands the decision back to Claude Code's normal terminal prompt. If you don't answer within 60 s, the request also goes back to the terminal (you can change this in the menu bar). Long-press the text to see the full command in a floating panel.

<img src="docs/gifs/always.gif" alt="An approval on the Touch Bar: Hold · Always fills up to allow and save the rule" width="100%">

**Questions.** Options show up as buttons. For multi-select questions, toggle the options and tap **Done**. For your own answer, hold the mic **Other** button, talk, release, and tap **Answer ➤** (on multi-select it's added after any options you ticked). Long option labels get shortened so the row always fits.

<img src="docs/gifs/question.gif" alt="A two-part question on the Touch Bar: pnpm is picked, then Lint and Unit tests are ticked" width="100%">

**Responses.** Swipe left or right on the text to page through it one sentence group at a time (`3/12` shows where you are). Code blocks show as `‹code · N lines›`. Long-press the text to open the whole reply, rendered, in a floating panel. Tapping does nothing on purpose.

**Read word by word.** Tap ▶ to play the reply one word at a time (the RSVP method): each word's focus letter, a little left of center, stays on the same spot and is drawn in orange, so your eyes don't move. Commas, sentence ends and paragraphs pause longer; long words, numbers and paths stay up longer; a code block shows as one `‹code · N lines›` card. **−/+** change the speed in 50 wpm steps (150–700, starts at 300, remembered). **Tap** the word to pause or resume, **swipe** to go back or forward a sentence, **long-press** for the full reply, and the lines icon goes back to the swipeable pages. The thin orange line at the bottom shows how far through you are. The menu bar has **Play new replies word by word** (off by default) to start it by itself when you open the bar on a new reply.

<img src="docs/gifs/reader.gif" alt="The word-by-word reader on the Touch Bar, with the orange progress line" width="100%">

**Voice.** Hold the mic, talk, and release. Check the transcript, then tap **Send ➤**. **VI/EN** switches the language. Voice *prompts* work for sessions running in **tmux** (in any terminal) or **iTerm2**. Spoken deny reasons and Other answers go back through the hook, so they work in every terminal. Text goes into the session without bringing the terminal to the front. Other terminals show a message instead.

<img src="docs/gifs/voice-deny.gif" alt="Denying on the Touch Bar with a spoken reason: holding the mic, saying run the test first, then tapping Deny" width="100%">

**Jump** (the arrow-in-a-box icon). Long-press to bring that session's terminal to the front. This is the only button that switches apps.

**Active sessions.** Tap the session chip to see every Claude Code session running right now, in any folder, with a status dot: orange = needs you on the bar, red = waiting for you in the terminal, blue = working, green = new reply, gray = idle. Tap one to switch to it. Sessions that were already running when SousBar started (for example after a reinstall) show up straight away: the app finds Claude Code processes running in a terminal.

**Folder history.** Tap the list icon to see every conversation saved for the current folder (newest first), then live sessions elsewhere. Titles come from Claude Code: your own name for the conversation, its generated title, or your last prompt. **Hold** a past one to resume it: the bar types `/resume <id>` into that folder's Claude Code (tmux or iTerm2, not while it's busy). The back arrow returns. **New** starts a fresh session in that folder: a new background tmux window, a new iTerm2 tab next to that folder's session, or else a new Terminal window, running `claude` there. Nothing comes to the front, and the bar switches to the new session as soon as it starts.

**Model and effort.** Tap the chip icon to pick a model (Opus, Sonnet, Haiku, Fable), then an effort level (low to max). The bar types `/model …` and `/effort …` into the session and goes back to normal. You can tap **Effort** to skip the model step. Like voice prompts, this needs tmux or iTerm2, and it waits until Claude isn't busy.

## Privacy

SousBar sits between Claude Code and its permission prompts, so here is exactly what it does and doesn't do. The source is all in this repo if you want to check.

- **No network.** SousBar's own code never connects to the internet: no analytics, no tracking, no update checks. The app and the hook only talk to each other over a local Unix socket (see [How it works](#how-it-works)). The one exception is below: speech in a language your Mac can't recognize on its own goes to Apple.
- **What it changes:** SousBar's own hook entries in `~/.claude/settings.json` (after a backup), and its helper in `~/.sousbar`. Nothing else. **Disconnect from Claude Code…** in the menu bar removes the hooks.
- **Microphone:** only while you hold a mic button. macOS's own speech recognizer turns it into text, on your Mac when it can. If your Mac can't recognize a language on-device, Apple's recognizer sends that audio to Apple, as macOS dictation does.
- **Your terminal:** text is typed into a session (tmux or iTerm2) only when you send a voice prompt, pick a model, resume or start a session. Nothing is read from your screen.
- **What it reads:** Claude Code's hook events, its transcript files (to show replies and conversation titles) and the list of running Claude Code processes. All of it stays on your Mac.

## How it works

```
Claude Code ──hook (stdin JSON)──▶ sousbar-hook ──unix socket──▶ SousBar.app ──▶ Touch Bar
                                         ▲                                │
                                         └──── allow / deny / answers ────┘  (PermissionRequest only)
```

- Hooks used: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Notification, Stop.
- Only **PermissionRequest** waits for an answer. Every other hook sends its event and exits right away.
- The hook also sends the PID and start time of the Claude Code process that ran it. Every 30 s the app drops sessions whose process is gone (a crash, `kill -9`, a closed terminal) and hands any of their waiting approvals back. Sessions with no known process, such as the demo, are dropped after 12 h without activity.
- **If the app isn't running, the hook exits 0 instantly**, and Claude Code behaves exactly as if the hook weren't there.
- The socket is `~/.sousbar/sousbar.sock`. It's a Unix socket (not a network port), so web pages can't reach it. It's mode 600 in a 700 folder, and connections from other users are refused.
- Questions (`AskUserQuestion`) are answered by allowing the tool with `updatedInput.answers` filled in.
- The full-width bar and the Control Strip pill use the same private macOS Touch Bar API as MTMR and Pock.

## Agents

Every installed hook says which agent it's for, e.g. `'~/.sousbar/bin/sousbar-hook' --agent claude-code`, and the app records it per session. Adding another agent means teaching SousBar that agent's hook events and replies; your existing Claude Code entries don't change.

| Agent | Status |
|---|---|
| Claude Code | Supported (checked against 2.1.319) |
| Cursor | Planned |

## Settings

The menu bar chef-hat icon (tinted like the pill) has:
- **Open Touch Bar automatically for approvals** (on by default)
- **Hand approvals to the terminal after** 30 s / 1 min / 2 min / 5 min / never
- **Voice language**
- **Launch at login**
- **Setup Guide…** reopens the first-launch walkthrough

If the expanded bar shows up empty, its content is wider than your Touch Bar. Make it narrower:

```bash
defaults write local.sousbar.app barWidth -float 880 && pkill SousBar && open ~/Applications/SousBar.app
```

## Troubleshooting

- **No pill:** turn on Show Control Strip, then quit and reopen SousBar.
- **Pill vanished after closing the bar:** it should come back within 5 s or as soon as you switch apps. You can also open it from the menu bar chef hat › Show on Touch Bar.
- **Nothing happens in Claude Code:** restart the session (hooks load at start), then run `~/.sousbar/bin/sousbar-hook ping`.
- **Voice asks for permission again after reinstalling:** expected. The app is ad-hoc signed, so macOS sees each build as a new app.
- **A question shows in the terminal anyway:** use **→ Term** and tell me. Hook support for answering `AskUserQuestion` may differ by Claude Code version.

## Releases and CI

- **CI** (`.github/workflows/ci.yml`) is manual: **Actions › CI › Run workflow** runs the tests and a universal build. It doesn't run on new commits or pull requests.
- **Release** (`.github/workflows/release.yml`) is manual: **Actions › Release › Run workflow**, enter a version like `0.2.0`. It refuses a version that's malformed or already tagged, runs the tests, builds `SousBar-<version>.dmg` and `SousBar-<version>.zip` (plus SHA-256 files) with `scripts/package.sh`, and creates release `v<version>` with install notes and generated changes. It's a **draft** by default: check it, then publish.
- To build the same zip and DMG locally: `scripts/package.sh 0.2.0` → `dist/`.
- To record the Touch Bar as a GIF (for this README or a post): `scripts/record-touchbar.sh [demo-kind] [seconds]` → `docs/touchbar-<kind>.gif`. It plays a `sousbar-hook demo` while capturing; answer it on the bar as it records.

### Signing and notarization

Without signing, macOS blocks the downloaded DMG app ("Apple cannot check it for malicious software") until the user clicks **Open Anyway**. With these five repository secrets, the Release workflow signs the app and hook with your Developer ID (hardened runtime, `Resources/SousBar.entitlements`), has Apple notarize the zip and the DMG, and staples the result, so it opens like any other Mac app. Without them it still releases, ad-hoc signed, with a warning; tick **require_notarization** when running it to fail instead.

Needs a paid [Apple Developer Program](https://developer.apple.com/programs/) membership.

1. **Developer ID certificate.** In Xcode › Settings › Accounts › Manage Certificates, add a **Developer ID Application** certificate (or create it at developer.apple.com › Certificates). In Keychain Access, find it under *My Certificates*, right-click › **Export…** as `.p12` with a password.
2. **App Store Connect API key** (for notarization). At [App Store Connect › Users and Access › Integrations › App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api), create a key with the **Developer** role and download the `.p8` (you can only download it once). Note its **Key ID** and the **Issuer ID** shown above the list.
3. **Add the secrets** (repository › Settings › Secrets and variables › Actions), e.g. with the GitHub CLI:

```bash
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64
gh secret set MACOS_CERTIFICATE_PASSWORD          # the .p12 export password
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_P8_BASE64
gh secret set NOTARY_API_KEY_ID --body XXXXXXXXXX  # Key ID
gh secret set NOTARY_API_ISSUER_ID --body xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Then run **Actions › Release**: the log says "Signing as: Developer ID Application: …", each notarization is "accepted", and the release notes drop the Open Anyway steps. During the run the certificate lives in a temporary keychain that's deleted at the end, even if the run fails.

To test a release-like build locally without a certificate: `HARDENED=1 scripts/package.sh 0.2.0` (ad-hoc signed, but with the hardened runtime and entitlements).

## Connecting and disconnecting

The menu bar chef hat has **Connect to Claude Code…** / **Disconnect from Claude Code…**. Both back up `~/.claude/settings.json` first and change only SousBar's own entries. The app carries its hook inside it (`SousBar.app/Contents/MacOS/sousbar-hook`) and, once connected, keeps the installed copy in `~/.sousbar` up to date when you update the app.

## Uninstall

```bash
./uninstall.sh
rm -rf ~/Applications/SousBar.app ~/.sousbar
```

## Support

SousBar is a side project, free for everyone. If it's useful to you:

- ☕ [Buy me a coffee](https://buymeacoffee.com/hataphan). It keeps the project going.
- ⭐ Star the repo so more Touch Bar owners find it.
- 🐞 [Open an issue](https://github.com/hatamania/sousbar-community/issues) for bugs and ideas. Pull requests are welcome too.

## License

Copyright © 2026 Quan Phan. All rights reserved.

The source is public so you can see exactly what SousBar does on your Mac, and you're welcome to build it for your own use. Please don't redistribute it or publish modified versions without asking first.
