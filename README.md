# claude-manager

Hangar is an iOS app that shows which Claude Code Remote Control sessions are running on the Mac, opens them
in the Claude app, stops them, starts sessions in existing projects in `~/Dev` and creates new ones.

- `backend/`: Go server (runs under homebase).
  - `GET /api/overview`: running sessions (found with `ps`/`lsof`, so hand-started ones show too)
    and the projects in `~/Dev`.
  - `POST /api/sessions {"name", "dir"?, "create"?}`: starts `claude --remote-control <name>` and
    waits until it registers, returning the `claude.ai/code/session_…` URL.
  - `DELETE /api/sessions/{pid}`: SIGTERM, then SIGKILL after 5 s. For the "Dev Projects" server
    this is a restart (launchd's KeepAlive brings it back).
- Each started session gets a detached keeper (`claude-manager keep <name> <dir>`, own process
  session, so restarting the server doesn't kill it). It answers the startup dialogs (RC consent,
  folder trust → "Yes", `.mcp.json` → "use this and all future MCP servers"), records the URL in
  `~/Library/Application Support/claude-manager/<name>.json`, caps
  `~/Library/Logs/claude-rc-<name>.log` at 20 MB and drops the `CLAUDE_CODE_*` markers it may
  inherit (with `CLAUDE_CODE_CHILD_SESSION` set, sessions don't save transcripts).
  A session stuck on an unknown prompt shows up as `waiting` with the screen text.
  - `GET /api/usage`: subscription limits, proxied from claude-monitor's backend (`USAGE_URL`,
    default `http://127.0.0.1:4001/api/usage`).
- `ios/`: SwiftUI app (XcodeGen). `ios/Widget/`: the limits widgets, copied from claude-monitor
  (home screen small/medium, lock screen circular/rectangular/inline). `ios/Shared/`: models,
  API client, theme. There is no App Group (it needs an explicit provisioning profile, i.e. an
  Apple ID signed in to Xcode), so the widget uses the server and tokens from `Secrets.swift`,
  not ones changed in the app's Settings. `swift tools/Icon.swift <out.png>` renders the icon (SwiftUI).

## hangar (command line)

`make install` puts the same binary in `~/.local/bin/hangar`:

```
hangar                  interactive list: enter open/start · space QR · x stop · n new · / filter
hangar ls [--json]      running sessions
hangar projects         projects in ~/Dev
hangar new <name>       create ~/Dev/<name> and start a session in it
hangar start <name>     start a session in ~/Dev/<name>
hangar stop <name>      stop a session
hangar url|open|qr <name>
hangar describe [-f] [name...]          one-line descriptions, written by Claude
hangar describe --set <name> <text>     or by hand
hangar limits           subscription limits (from claude-monitor)
hangar serve            HTTP API for the iOS app (what homebase runs)
```

Sessions it starts get the same detached keeper as ones started from the app.

`hangar describe` sends each project's file list and the start of its README/CLAUDE.md/manifests to
`claude -p --model haiku` (no tools, run outside the project, nothing saved) and keeps the answers in
`~/Library/Application Support/claude-manager/descriptions.json`, not in the projects. Without
names it does the projects that have none yet; `-f` redoes them, except ones set by hand. The app,
`hangar` and `hangar projects` show them.

## Auth

Two tokens. homebase's private share checks `X-Homebase-Token` on the public URL, but its proxy
also serves `http://claude-manager.local` to the LAN without one, so the backend checks its own
`X-Manager-Token` (generated on first run in `~/Library/Application Support/claude-manager/token`).
The backend listens on 127.0.0.1 only.

## Backend

```sh
homebase                     # reads homebase.toml
homebase share --private     # https://claude-manager.dev.<domain>; token in `homebase status`
```

## iOS app

```sh
cd ios
cp Local.xcconfig.example Local.xcconfig                       # your Team ID
cp Shared/Secrets.swift.example Shared/Secrets.swift   # URL and both tokens
xcodegen generate
xcodebuild -scheme ClaudeManager -configuration Release -destination 'id=<device-udid>' \
  -derivedDataPath build/device -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> "build/device/Build/Products/Release-iphoneos/Claude Sessions.app"
```

## License

MIT, see [LICENSE](LICENSE).
