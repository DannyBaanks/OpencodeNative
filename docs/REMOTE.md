# Remote OpenCode mode

OpencodeNative can use the real OpenCode runtime running on another machine. It does **not** embed Bun, PTY, or the OpenTUI renderer in iOS. Instead, the iOS app is a native client of OpenCode's official headless HTTP server.

## Link a computer with official OpenCode

Requirements on the computer:

- OpenCode installed and available as `opencode`
- Node.js 18+
- iPhone and computer on the same trusted network

From the project you want OpenCode to control:

```bash
npx --yes github:DannyBaanks/OpencodeNative link
```

The command:

1. generates an ephemeral random password;
2. starts `opencode serve --hostname 0.0.0.0 --port 4096 --mdns`;
3. protects the server with `OPENCODE_SERVER_PASSWORD`;
4. prints an `opencodenative://pair?...` link containing the LAN address, password, and current project directory.

Paste the pairing link into the iOS app and tap **connect**.

## Link a computer with OpenISy

OpenISy keeps the OpenCode headless HTTP/SSE contract consumed by the iOS app.
Point the bridge at the private OpenISy checkout explicitly:

```bash
npx --yes github:DannyBaanks/OpencodeNative link --runtime openisy --openisy-root "/path/to/OpenISy"
```

On Windows:

```powershell
npx --yes github:DannyBaanks/OpencodeNative link --runtime openisy --openisy-root "C:\path with spaces\OpenISy"
```

You can set `OPENISY_ROOT` instead of passing `--openisy-root`:

```powershell
$env:OPENISY_ROOT="C:\path\to\OpenISy"
npx --yes github:DannyBaanks/OpencodeNative link --runtime openisy
```

The bridge validates `packages/opencode/src/index.ts` and launches OpenISy with Bun. The pairing URL and iOS behavior remain unchanged: the selected project travels in the `x-opencode-directory` header, and session IDs come directly from OpenISy's `/session` API.

## Security model

- The generated credential is only printed in the local terminal and held in memory by the iOS process.
- The bridge exposes OpenCode only while the command is running.
- Traffic on the local network is HTTP with Basic Auth; use only a trusted LAN. For access across the internet, put the OpenCode server behind a TLS VPN/tunnel rather than forwarding port 4096 directly.
- Stopping the link process invalidates that generated password because the server exits.

## What is real

Remote mode talks to OpenCode's own `/session`, `/session/:id/prompt_async`, `/session/:id/abort`, `/session/:id/permissions/:permissionID`, and `/event` endpoints. OpenCode performs the actual model calls, tool execution, file edits, permission checks, and session persistence on the linked computer.

The iOS screen is a SwiftUI rendering of the OpenCode workbench semantics. The actual OpenTUI renderer itself cannot run on iOS because iOS does not expose the required PTY/TTY/Bun execution environment.
