# Nearby Transfer

An opt-in native module for two Macs running a compatible macos-x version.
Add it from the module pool, enable it on both Macs, and allow Local Network
access when macOS asks. Single-click the existing menu-bar apple to open the
drawer. Hover still belongs to menu-bar storage; double-click opens the client.
The drawer remains open while selecting files in Finder; click the apple again
or press Esc in the drawer to dismiss it. Closing the drawer does not disconnect.

Choose a device, accept its connection request, compare the six-digit pairing
codes on the two screens, and confirm on both Macs. Names are labels, not trust.
There is no saved trust, account, automatic reconnection or cloud relay. Each
connection has new ephemeral keys and needs confirmation again. Sleep,
disabling/removing the module, and quitting revoke the connection. Turning off
the module stops browsing/advertising and releases its panels and input monitor.

Drop regular files into the drawer, click the drop area to choose files, or
press Command-V while the drawer has keyboard focus. Clipboard file URLs take
priority, followed by PNG/TIFF images, then plain text. Folders, symlinks and
formatted mixed text/image documents are not packaged by this version.

- One peer; one outgoing file and one incoming file at a time.
- Up to 16 queued files, 2 GiB per regular file, 32 MiB per clipboard image.
- Clipboard text is limited to 48 KiB UTF-8; larger text can be sent as a file.
- Image decoding is bounded to 32 million pixels; thumbnails are at most 96 px.
- The in-memory recent list holds at most 30 records. Received files remain in
  `~/Downloads/macos-x/Nearby`; no received file is opened or executed implicitly.
- File contents are transferred in 48 KiB chunks, acknowledged after disk write,
  verified by total byte count and incremental SHA-256, and renamed atomically.
  Existing files are never overwritten; cancelled/failed partials are removed.
- Text/files have explicit receipt acknowledgements; progress is not completion.
- Auto-copy is off initially and resets on every disconnect. It covers incoming
  text/images only, not files, and requires the receiver to opt in. New clipboard
  changes cancel a pending asynchronous image-copy result.
- Received images can be pinned if the screenshot module is added and enabled.

The nearby-discovery/session foundation follows the same Apple
MultipeerConnectivity approach explored in BitBun. This module uses a distinct
`macosx-nearby` Bonjour service and its own v1 protocol; BitBun v0.0.1 is not a
compatible peer. The protocol requires an encrypted MCSession plus ephemeral
Curve25519 key agreement. HKDF derives a transcript-bound session key and human
comparison code. Both people confirm before any application content is accepted.
All subsequent control messages, text and file chunks use AES-GCM with ordered,
authenticated sequence numbers; tampering, replay or protocol errors disconnect.
The human comparison authenticates the session and must actually be performed.

Automated checks use two injected in-memory links, real protocol crypto, real
temporary-file IO and isolated named pasteboards. They exercise paired text,
multi-chunk files, images, cancellation and teardown. Native views are rendered
offscreen in both languages. They never start discovery, show windows, write the
general clipboard or establish evidence of a physical two-Mac transfer. Real
network visibility, permission prompts, drag/drop and throughput are user tests.
