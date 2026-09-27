# ChatGPT MCP bridge

## Current state

The iOS app has a canonical MCP tool projection for native capability
descriptors in `NativeMCPToolCatalog`, plus a request validator in
`NativeMCPToolRouter` for incoming `tools/call` arguments. The validator
returns a capability proposal only; it does not execute it or treat ChatGPT's
confirmation as approval on the iPhone. The catalog emits JSON Schema inputs
and MCP tool annotations only when both conditions are true:

1. iOS reports the capability as available and authorized (or authorization is
   not applicable).
2. The app explicitly supplies that capability ID as an executable adapter.

Discovery by itself never makes a capability executable. The projection is a
protocol boundary, not an MCP server; it does not open a network listener or
approve actions.

## Intended architecture

```text
ChatGPT
   │ MCP over HTTPS / Secure MCP Tunnel
   ▼
ISyCode MCP relay on the user's computer
   │ authenticated, outbound mobile bridge
   ▼
iSyCode Móvil NativeCapabilityBroker
   │ on-device approval + Apple framework/system UI
   ▼
iPhone
```

The phone remains the authority for iOS permissions and native side effects.
The desktop relay transports requests and events; it must not hold or infer
Apple permissions. The app must remain foregrounded for capabilities that need
visible system UI or a fresh approval.

## Work still required

- Define the authenticated phone-to-relay protocol, reconnect behavior, and
  request/approval IDs.
- Implement an MCP server transport on the computer and connect it to the
  mobile bridge.
- Add an on-device approval queue for MCP-originated actions. ChatGPT's own
  confirmation does not replace the iPhone approval.
- Connect validated MCP proposals to registered native executors after the
  local approval queue is in place.
- Register executable adapters one at a time; keep unsupported catalog entries
  out of `tools/list`.
- Document Secure MCP Tunnel setup and ChatGPT's developer-mode connection.

ChatGPT cannot call a private iPhone listener directly. Its supported MCP
connection needs a remote endpoint or a Secure MCP Tunnel client running on a
computer that can reach the private MCP server. Tunnel credentials and IDs are
provided by the user's OpenAI Platform organization and must stay out of source
control. ChatGPT account/workspace plan permissions also determine which MCP
actions are available.
