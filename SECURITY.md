# Security & data handling

Kodisle reads sensitive context (AI accounts, GitHub, local processes), so its rules are strict and
enforced in code. If you contribute, please keep them.

## Rules

1. **Never persist secrets.** No tokens, keys or passwords in `UserDefaults`, files, logs or caches.
   Settings (`KodisleConfig`) must stay secret-free.
2. **Borrow credentials, don't own them.**
   - GitHub: always via the `gh` CLI (`Shell.run("gh", …)`). Kodisle never reads the GitHub token.
   - Claude Code: token read with `/usr/bin/security find-generic-password -s "Claude Code-credentials"`,
     kept in a local variable for one request.
   - Codex: `access_token` read from `~/.codex/auth.json` for one request. Other fields (e.g. API keys) are ignored.
   - **Never refresh** OAuth tokens: rotating them would invalidate the CLI's session.
3. **Minimal child environment.** `Shell` passes only `HOME`, `USER`, `PATH`, `LANG` and non-secret flags.
4. **No process arguments.** Use names, PIDs, ports and `cwd` only.
5. **Minimal transcript access.** Agent detection reads metadata (`type`, `stop_reason`, `cwd`, timestamps) and the
   session title. Only when *Show what agents did in notifications* is enabled, the text of the agent's **last reply**
   (never prompts, tool calls or tool output) is condensed to one line, kept in memory and shown in the island.
   It is never written anywhere and is hidden by Privacy mode.
6. **Redact what's displayed.** Use `Redact.url` for URLs, and `.privacySensitive()` on project names,
   repos, branches, titles and file names so Privacy mode can hide them.
7. **Ephemeral networking.** `Net.session` has no cache and no cookies.
8. **No telemetry.** No analytics SDKs, crash reporters or calls to servers we control.

## Local bridge

Integrations talk to Kodisle through `~/.kodisle/bridge.sock` (directory 0700, socket 0600 — only your user).
- The Claude Code hook sends the permission request JSON and waits for the decision. Kodisle shows the tool and its target
  (command / file / URL); nothing is stored.
- The zsh hook sends only the program + first subcommand, exit code, duration and folder. Env assignments (`TOKEN=… cmd`),
  arguments and flags are dropped before anything leaves the shell.
- Installing an integration backs up the touched file (`*.kodisle-backup`) and only adds/removes Kodisle's own entries.

## Tasks

Tasks are stored in plain text in `~/.kodisle/tasks.json` (directory 0700, file 0600) and never leave your Mac through
Kodisle. Don't keep secrets in them. Titles, notes and projects are hidden by Privacy mode.

The optional Claude Code integration runs `claude mcp add` (user scope) to register `Kodisle --mcp`, a local stdio server
with no network access that only reads and writes that file, and adds `mcp__kodisle` to `permissions.allow` in
`~/.claude/settings.json` (backup in `*.kodisle-backup`) so Claude can use it without asking. What Claude reads from the
list goes to Anthropic like any other tool result. From `~/.claude.json`, Kodisle only checks whether the server is registered.

## Clipboard history

In memory only, cleared on quit. Pasteboard items marked concealed/transient (password managers) are never read into
history. Text matching secret patterns (API keys, tokens, JWTs, private keys) is displayed masked, copied back as concealed
and dropped after two minutes.

## Network requests Kodisle makes

| Destination | When | Credential |
| --- | --- | --- |
| `api.anthropic.com/api/oauth/usage` | Claude limits enabled | Claude Code OAuth token (Keychain, read-only) |
| `chatgpt.com/backend-api/wham/usage` | Codex limits enabled | Codex access token (`~/.codex/auth.json`, read-only) |
| `api.github.com` (through `gh`) | `gh` installed and logged in | handled entirely by `gh` |
| `api.vercel.com` | Vercel CLI logged in | Vercel CLI token (`auth.json`, read-only, never refreshed) |
| `api.github.com/repos/pablorod1/kodisle/releases/latest` | Once a day if update checks are on | none (anonymous) |
| `github.com/pablorod1/kodisle/releases/download/…` | Only when you click *Update* | none — verified against the release SHA-256 |
| `*.scdn.co`, `*.spotifycdn.com` | Spotify widget, for the cover of the current track | none (anonymous) |
| URLs you add as endpoints | Endpoints widget | none |

## Local data Kodisle reads

- `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**`, `~/.codex/session_index.jsonl`: metadata, session titles and (optionally) the last agent reply.
- `~/Downloads`: listing, only after you open the Downloads widget (macOS will ask).
- `~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite`: read-only, only while the WhatsApp widget is on screen. macOS requires Full Disk Access for this and never prompts for it: you have to grant it in System Settings, and without it the widget simply stays empty. Name, last message and unread count of unread chats, kept in memory only and never sent anywhere.
- Spotify's playback notifications, plus AppleScript while the Spotify widget is on screen (macOS will ask): current track, position and playback controls.
- `lsof`, `ps`, `git status`, `docker ps` output.
- `com.apple.dock` preferences, to import pinned apps and to hide/restore the Dock.

## Local actions Kodisle takes

- **Replying on WhatsApp**: there's no API, so Kodisle drives WhatsApp's window with the Accessibility permission: it brings WhatsApp to the front, pastes through the clipboard (restored right after, and marked transient so clipboard histories skip it) and presses Send. It only presses Send after checking that the open chat has the expected name and the composer holds exactly your reply, and only when you submit a reply. Opening a group or a contact without a known number works the same way, through WhatsApp's search.
- **Starting Claude on a task**: only when you press *Claude*, Kodisle writes the task's title and notes to `~/.kodisle/prompts/<uuid>.txt` (mode 600, deleted when the tab starts), rewrites `~/.warp/tab_configs/kodisle_claude.toml` and opens it. The prompt is read from that file, never interpolated into a command, so a task's text can't run as shell code. Nothing runs until you press Enter in the tab.

## Endpoint URLs

Endpoint URLs are stored in plain preferences. Don't put tokens in them. They're shown redacted
(no credentials or query string), but they're still stored as you typed them.

## Reporting a vulnerability

Please open a private security advisory on GitHub (Security › Report a vulnerability) instead of a public issue.
