# Hangar

Start, stop and open the Claude Code sessions on your Mac from your iPhone, and see your
subscription limits. Hangar runs a Claude Code
[Remote Control](https://code.claude.com/docs/en/remote-control) session per project; you work in
them in the Claude app or at claude.ai/code as usual.

- **iPhone app**: running sessions (tap to open in Claude), all projects with one-line
  descriptions, start/stop, new project, rename, limits; widgets for the limits.
- **`hangar`** on the Mac: the same as a terminal UI and commands, plus the background service the
  app talks to.

Not made by or affiliated with Anthropic.

## Setup

```sh
brew install semenov/tap/hangar
hangar setup
```

`hangar setup`:

1. checks that Claude Code is installed and signed in with claude.ai (Remote Control needs a Pro,
   Max, Team or Enterprise plan);
2. asks for the projects folder (one subfolder per project), whether to trust the projects in it
   (nobody is at the terminal to answer Claude Code's folder-trust and `.mcp.json` dialogs when you
   start a session from the phone), and, if you haven't yet, for Remote Control's one-time consent.
   Your answers go into `~/.claude.json` (trust in the projects folder covers every project in it),
   so Claude Code doesn't ask; hangar still answers the dialogs if they show up anyway;
3. starts `hangar serve` in the background (`brew services`), plus a login item that brings
   sessions back after a reboot and, if you want, a daily job that describes new projects;
4. shows a QR code: scan it with the iPhone camera, and the Hangar app is paired.

`hangar pair` shows a new code for another phone, `hangar devices` lists paired phones and
`hangar devices revoke <name>` removes one. Settings go to `~/.config/hangar/config.toml`.

## How the app reaches the Mac

```
iPhone ──wss──▶ hangar.semenov.ai (relay) ◀──wss── Mac (hangar serve)
        └──────── end-to-end encrypted ────────┘
```

The Mac keeps one outgoing WebSocket to the relay, so it opens no ports; each phone gets a channel
on it. The relay only forwards frames (`relay/`, on thor behind Caddy, deployed with homebase):

- The Mac proves its ID to the relay by signing a challenge with Ed25519 (the ID is the start of
  SHA-256 of its public key), so nobody else can take it.
- Phone and Mac run a handshake over the relay: static X25519 keys exchanged at pairing plus fresh
  ephemeral ones; HKDF-SHA256 over DH(static, static) ‖ DH(eph, eph) ‖ DH(Mac static, phone eph)
  gives a ChaCha20-Poly1305 key per direction. Nonces are counters, so replayed frames are
  refused. Details in `backend/e2e.go`; the phone's side is `ios/Shared/Relay.swift` (CryptoKit).
- Pairing: `hangar pair` makes a one-time secret, valid 10 minutes, and shows
  `hangar://pair?relay&mac&key&secret&name`. The phone proves it saw the code with
  HMAC(secret, its keys); the Mac then remembers the phone's public key. Removing the Mac in the
  app tells the Mac to forget the phone (`/api/unpair`).
- API calls are tunnelled as `{id, method, path, body}` → `{id, status, body, etag}`. A GET that
  sends the ETag it already has (`if_none_match`) gets `304` and no body; the app refreshes every few
  seconds, so this is most of the traffic saved. If both sides offer `"compress": ["deflate"]` in the
  handshake, messages start with a flag byte (0 as is, 1 raw DEFLATE) and big ones are compressed
  before encryption.
- The relay runs on nbio (an event loop, not a goroutine per connection): ~5–10 KB per Mac+phone
  pair in the relay itself, down from ~75 KB. On its own server it can also terminate TLS itself
  (`TLS_DOMAINS`, autocert), with no proxy in front: measured ~17 KB per connection including TLS.

This is the only way in: `hangar serve` has no HTTP listener and no tokens, and the app has no
built-in server address.

## hangar (command line)

```
hangar                  interactive list: enter open/start · space QR · x stop · n new · / filter
hangar setup | pair | devices [revoke <name>]
hangar ls [--json]      running sessions
hangar projects         projects, with descriptions
hangar new <name>       create <projects>/<name> and start a session in it
hangar start <name>     start a session in <projects>/<name>
hangar stop <name>      stop a session
hangar restart <name>   stop it and start it again with --continue (same conversation)
hangar rename <name> <new-name>   rename the folder and its session together
hangar url|open|qr <name>
hangar describe [-f] [name...]          one-line descriptions, written by Claude
hangar describe --set <name> <text>     or by hand
hangar describe --install               run it daily at 04:00 (LaunchAgent), for new projects
hangar restore          start the sessions that were running before a reboot
hangar restore --install | --list
hangar limits           subscription limits (claude -p /usage)
hangar serve            the background service the app talks to
```

### How sessions are run

- Each session is `claude --remote-control <name>` in its folder, under a detached keeper
  (`hangar keep`, its own process session, so restarting `hangar serve` doesn't kill it). The keeper
  gives it a TTY, answers the startup dialogs you agreed to in setup, records the session's link,
  caps `~/Library/Logs/claude-rc-<name>.log` at 20 MB, and drops the `CLAUDE_CODE_*` markers it may
  inherit (with `CLAUDE_CODE_CHILD_SESSION` set, sessions don't save transcripts). A session stuck
  on a prompt shows up as `waiting`, with the screen text.
- Sessions survive a reboot: every session started through hangar is recorded in
  `~/Library/Application Support/claude-manager/desired.json` until it's stopped (hangar, the app)
  or exits on its own (`/exit`; at shutdown the keeper itself gets SIGTERM and keeps the entry). At
  login `hangar restore` waits for claude.ai and starts each with `--continue`.
- Descriptions: `hangar describe` sends each project's file list and the start of its
  README/CLAUDE.md/manifests to `claude -p --model haiku` (no tools, run outside the project,
  nothing saved) and keeps the answers in `descriptions.json`, not in the projects. Empty projects
  are labelled live.
- Renaming moves the folder, its description, its restore entry and Claude's transcripts
  (`~/.claude/projects/<encoded path>`), and restarts a running session with `--continue`.
- Limits are fetched only when asked for (`claude -p /usage`, cached for a minute).

### API

`GET /api/version`, `GET /api/overview` (sessions and projects), `POST /api/sessions
{name, dir?, create?}`, `DELETE /api/sessions/{pid}`, `GET /api/usage[?refresh=1]`,
`POST /api/describe/{project}`, `PUT /api/projects/{project} {description}`,
`POST /api/rename/{project} {to}`; through the relay also `POST /api/unpair`.

## Development

- `backend/`: the `hangar` command (Go). `make install` builds it into `~/.local/bin/hangar`
  (renaming over the old binary, so running keepers keep theirs). End-to-end test against a running
  relay and `hangar serve`: `HANGAR_E2E_LINK="$(hangar pair --no-wait | grep -o 'hangar://[^ ]*')"
  go test -run TestPhoneE2E -v`.
- `relay/`: the relay, also serving the landing page, `/privacy` and `/pair`. `homebase deploy`
  from that folder puts it on thor (https://hangar.semenov.ai), as plain HTTP on `$PORT` behind
  Caddy. With `TLS_DOMAINS=host1,host2` (and ports 80/443 free) it serves HTTPS itself instead.
- `ios/`: the SwiftUI app and widget (XcodeGen). `swift tools/Icon.swift <out.png>` renders the
  icon.

  ```sh
  cd ios
  cp Local.xcconfig.example Local.xcconfig   # your Team ID
  xcodegen generate
  xcodebuild -scheme ClaudeManager -configuration Release -destination 'id=<device-udid>' \
    -derivedDataPath build/device -allowProvisioningUpdates build
  xcrun devicectl device install app --device <device-udid> build/device/Build/Products/Release-iphoneos/Hangar.app
  ```

  Debug builds pair from a launch argument (`simctl launch … -pairLink 'hangar://pair?…'`), since
  opening the URL asks for confirmation. There is no App Group yet (it needs an explicit
  provisioning profile), so the widget can't see the app's paired Macs and shows no data.
- Homebrew formula: `Formula/hangar.rb` in [semenov/homebrew-tap](https://github.com/semenov/homebrew-tap),
  built from the release tarball.

## License

MIT, see [LICENSE](LICENSE).
