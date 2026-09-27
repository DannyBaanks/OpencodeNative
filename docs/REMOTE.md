# Remote OpenCode mode

IysCode Movil can use the real OpenCode runtime running on another machine. It does **not** embed Bun, PTY, or the OpenTUI renderer in iOS. Instead, the iOS app is a native client of OpenCode's official headless HTTP server.

## Link a computer with official OpenCode

Requirements on the computer:

- OpenCode installed and available as `opencode`
- Node.js 18+
- iPhone and computer on the same trusted network

From the project you want OpenCode to control:

```bash
npx --yes github:DannyBaanks/IysCodeMovil#main link
```

The command:

1. generates an ephemeral random password;
2. starts `opencode serve --hostname 0.0.0.0 --port 4096 --mdns`;
3. protects the server with `OPENCODE_SERVER_PASSWORD`;
4. prints an `iyscodemovil://pair?...` link containing the LAN address, password, and current project directory.

Paste the pairing link into the iOS app and tap **connect**.

## Link a computer with OpenISy

OpenISy keeps the OpenCode headless HTTP/SSE contract consumed by the iOS app.
Point the bridge at the private OpenISy checkout explicitly:

```bash
npx --yes github:DannyBaanks/IysCodeMovil#main link --runtime openisy --openisy-root "/path/to/OpenISy"
```

On Windows:

```powershell
npx --yes github:DannyBaanks/IysCodeMovil#main link --runtime openisy --openisy-root "C:\path with spaces\OpenISy"
```

You can set `OPENISY_ROOT` instead of passing `--openisy-root`:

```powershell
$env:OPENISY_ROOT="C:\path\to\OpenISy"
npx --yes github:DannyBaanks/IysCodeMovil#main link --runtime openisy
```

The bridge validates `packages/opencode/src/index.ts` and launches OpenISy with Bun. The pairing URL and iOS behavior remain unchanged: the selected project travels in the `x-opencode-directory` header, and session IDs come directly from OpenISy's `/session` API.

## Security model

- The generated credential is only printed in the local terminal and held in memory by the iOS process.
- The bridge exposes OpenCode only while the command is running.
- Traffic is HTTP with Basic Auth and is not encrypted end to end; use only on a trusted LAN or through an encrypted VPN/tunnel. Never forward port 4096 directly to the internet. The bridge prints this warning at startup.
- Stopping the link process invalidates that generated password because the server exits.

## What is real

Remote mode talks to OpenCode's own `/session`, `/session/:id/prompt_async`, `/session/:id/abort`, `/session/:id/permissions/:permissionID`, and `/event` endpoints. OpenCode performs the actual model calls, tool execution, file edits, permission checks, and session persistence on the linked computer.

The iOS screen is a SwiftUI rendering of the OpenCode workbench semantics. The actual OpenTUI renderer itself cannot run on iOS because iOS does not expose the required PTY/TTY/Bun execution environment.

## Experimental Codex App Server

Codex uses its own JSON-RPC WebSocket protocol; it does not use OpenCode HTTP
routes or Basic Auth. The current adapter was discovered against Codex CLI
0.155.1 and is version/profile checked during initialize. Other versions must
generate a compatible local schema before the Bridge will advertise support.

On the computer, install Codex CLI and Tailscale, sign in to Codex, move to the
workspace, and start the Bridge:

```bash
npx --yes github:DannyBaanks/IysCodeMovil#main link --runtime codex --host tailscale --directory "$PWD"
```

Paste the printed `codex://pair?...` link into ISyCodeMovil. The link contains a
temporary capability token and is shown only during onboarding; treat it as a
secret. iOS stores the token in Keychain and keeps non-secret endpoint,
workspace, schema profile, and version metadata separately. Forgetting the
connection removes the stored token. Stopping the Bridge stops that App Server
process; start it again and pair again to establish a new token.

The Bridge binds to the selected Tailscale IPv4 address and passes the SHA-256
verifier, rather than the raw token, to Codex. The iPhone must be on the same
Tailscale network. The installed App Server offers `ws://` without TLS, so the
adapter is restricted to the encrypted Tailscale VPN. Do not use flat LAN,
port-forwarding, or public Internet access. This WebSocket transport is
experimental.

The current iOS profile supports listing, starting and resuming threads,
reading text history, sending text turns, streaming assistant text, interrupting
turns, and responding to command/file approvals when their choices fit the
controls shown. Approvals with extra policy amendments or unrecognized choices
remain unanswered and display an incompatibility message. The app uses the
Codex server-default model. File browsing, direct file reads, diffs, shell,
provider/model selection, agent selection, rename/delete, and Codex settings are
not available in this adapter. If the local CLI schema or initialize version
does not match the pairing profile, reconnecting fails closed; check that Codex
and the Bridge are running, then create a fresh pairing.
