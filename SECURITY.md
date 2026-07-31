# Security model

This is a local automation bridge, not a multi-user service. Its trust boundary
is the current macOS user account and the MCP clients that user configures.

## Safeguards

- No TCP listener and no application telemetry.
- Per-launch random broker token, user-specific socket, and mode-`0600`
  connection files.
- No shell interpolation for tool arguments.
- Strict tool schemas plus server-side ranges, enums, target validation,
  regular-file checks, and attachment-size limits.
- Write access has explicit Read Only, Ask Before Writes, and Allow Without
  Asking modes. Per-message and per-tapback confirmation remain independently
  configurable in Settings.
- Confirmed sends and reactions show the resolved target, exact preview, and
  expiry countdown, and time out denied.
- Optional approval notifications contain only a generic pending count, never
  message contents or recipient details.
- Optional reaction GUID freshness prevents reacting after the target changes.
- Advanced SIP-disabled bridge functionality is neither bundled nor exposed.
- Activity logs omit message bodies.
- Distribution archives omit extended attributes, AppleDouble files, Finder
  metadata, and quarantine metadata.

## Trust assumptions

A configured MCP client can read message history and attachment images without
an additional prompt. macOS Full Disk Access is therefore a meaningful grant:
configure only MCP clients and models you trust with that data.

The socket token prevents accidental or opportunistic cross-process attachment;
it is not intended to defend against malware already running as the same user
with permission to read that user's application-support files.

The app delegates delivery to Messages and imsg. A successful automation call
does not prove human receipt. Use returned GUIDs and `get_send_status`, while
recognizing that carrier, device, and recipient read-receipt settings remain
outside this app's control.

Current distribution archives are local/private development artifacts. Their
ad-hoc signatures are suitable for local verification only; they must not be
published as trusted macOS software before stable Developer ID signing and
notarization are implemented.

Report security issues privately to the repository owner. Do not include real
message bodies, addresses, phone numbers, attachment contents, or connection
tokens in reports.
