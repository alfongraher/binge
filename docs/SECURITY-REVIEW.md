# Security review — October 13, 2026

Scope: Mac and standalone iPad source, bundled media dependencies, add-on/subtitle requests, loopback playback servers, torrent file reads, production diagnostics and local-network sync. This is a focused engineering review with regression and abuse tests, not an independent penetration test or a certification that the application has no vulnerabilities.

## Findings and changes in 0.4.2 (11)

| Area | Finding | Resolution |
| --- | --- | --- |
| Media dependencies | Mac shipped FFmpeg 6.0; iPad used FFmpeg 8.0. Both predate published security fixes. This creates exposure when processing untrusted media; exploitability depends on the codec and enabled components. | Rebuilt both from official FFmpeg 8.0.3 source. Mac uses a reduced set of required formats/codecs rather than the previous broadly enabled binary. iPad retains its existing enabled codecs with the patch release. |
| Add-on downloads | JSON responses had no byte limit. Subtitle limits were checked after the entire response had been buffered. A malicious provider could exhaust memory. | Stream responses with an eight-MiB limit, check declared lengths, cancel oversized transfers, and retain request/resource timeouts. Tested with an oversized response that omits Content-Length. |
| Transport protection | Mac accepted remote cleartext HTTP add-on/subtitle/direct-source URLs. Redirects lacked an application-level downgrade check. | Require HTTPS for remote add-on/subtitle/direct-source URLs. Explicit localhost HTTP remains for development/local providers. Reject credentials in URL userinfo, file URLs and HTTPS-to-HTTP redirects. Default shared networking does not retain cookies or cache responses. |
| Sync protocol | Encrypted frames lacked explicit direction binding and replay sequence validation; keys came from static agreement plus session nonces. | Protocol v2 mixes static and fresh ephemeral Curve25519 agreement into HKDF. AES-GCM authenticates sender, recipient and monotonically increasing sequence. Reflected approvals and exact replayed frames were rejected by tests against the real TCP listener. Both devices must update; existing paired identity pins remain usable. |
| Sync input limits | Initial messages could consume the full four-MiB frame budget, and arbitrary field names could grow stored state. | Limit unauthenticated frames to sixteen KiB, allow only known field names and cap total journal records at 20,000. Existing per-value, record and session limits remain. |
| Loopback HTTP | Playback server connections had no explicit global cap or header deadline. | Limit both servers to 32 connections. iPad closes incomplete headers after ten seconds; Mac sockets have a ten-second I/O timeout. Both bind only to 127.0.0.1 and require unguessable URL tokens; iPad also bounds header size. |
| Torrent file reads | iPad relied on libtorrent's path handling when opening selected files. | Resolve symlinks and require selected paths to remain inside the torrent cache. This is defense in depth, not a demonstrated libtorrent traversal exploit. Mac already checks resolved containment. |
| Mac FFmpeg input | A broadly enabled parser could probe unexpected nested formats/protocols from media. | Restrict torrent input to expected media demuxers and HTTP/TCP. Input cannot invoke FFmpeg's local-file protocol. Output files still use the app-owned scratch directory. |
| Local data permissions | Saved Mac JSON files could inherit permissions allowing other local OS users to read viewing or provider details. | Atomic writes explicitly set owner-only 0600 permissions for history, library, add-on configuration and sync journals. This does not encrypt files against the logged-in user, administrator or a compromised app. |
| Diagnostics | iPad release builds could persist detailed native playback errors containing URLs or internal playback tokens. | Detailed startup/failure/HTTP traces are now Debug-only. Normal user-facing failure messages remain. Old diagnostic files from previous builds are not automatically erased. |

Official upstream references: [FFmpeg security fixes](https://ffmpeg.org/security.html) and [libtorrent releases](https://github.com/arvidn/libtorrent/releases). The FFmpeg release checksum used here is `6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818`. Libtorrent remains 2.0.15 and Boost remains 1.86.0. No claim is made that every advisory affects the reduced codec configuration, or that every dependency is vulnerability-free.

## Validation

- Mac/iPad Release compilation and signature verification.
- Both updated physical apps reconnected using the saved pairing; Mac Settings reported Up to date with iPad.
- Existing real-TCP sync regression: mutual code confirmation, encryption, manual sync, category controls, saved-pair reconnect and state persistence.
- New raw-peer transport tests: reflected encrypted approval and replayed authenticated data both close the connection.
- Network tests: unsupported/insecure/credential-bearing URLs, oversized unknown-length responses and unknown sync fields.
- Live Cinemeta default and genre pagination through the bounded request path.
- Patched Mac runtime: MKV, MP4 and AC3 fixtures streamed over local HTTP and converted into HLS.
- Physical iPad fixture: twelve-second AC3 surround clip converted to AAC stereo, video packet-copied, four caption packets converted, and native playback clock advanced beyond five seconds. Visual lip-sync and caption appearance were not measured by this automated check.
- Credits and saved-library regressions on both models.

The iPad media library was rebuilt with the established codec configuration. Compilation alone does not prove visual A/V sync, captions and seeking for every real torrent; those still need user testing on this exact update. This review did not fuzz native codecs, exhaustively test adversarial torrent metadata, audit every upstream dependency, or perform a separate-device network penetration test.

## Privacy and remaining work

No binge login is required, but the app is not anonymous. Catalog/subtitle/source providers receive network requests and can see the requester's IP address and requested content. BitTorrent peers and trackers can also see network addresses. Local history, library entries and saved source/subtitle URLs can contain viewing preferences or provider-specific tokens. Pair only devices you trust.

Sync transfers history/library records, including source details needed for resume, to explicitly paired devices. It is encrypted in transit; local databases rely on operating-system filesystem and device protections rather than separate database encryption. The private sync identity is stored in Keychain. Artwork and direct media playback still use the native platform networking paths; they have not received the same application-level streaming byte budget as add-on JSON/subtitles.

**Remaining dependency priority:** Mac playback launches a separately installed Python 3.12 framework. The audited machine has Python 3.12.0; it was not upgraded by this app update. Later 3.12 releases include security fixes ([Python 3.12.15](https://www.python.org/downloads/release/python-31215/)). Bundling and validating a maintained interpreter, or upgrading that dependency, is outstanding before calling the Mac distribution self-contained or fully maintained. This review has not established that any particular Python advisory is exploitable through binge.

The Mac app is not App Sandbox-isolated. It remains development-signed and non-notarized. Moving toward least-privilege sandboxing and a signed/notarized distribution should be evaluated separately against torrent/network/runtime requirements. Do not describe this engineering update as a full security certification.

Protocol v2 deliberately rejects older sync clients. Upgrade both devices together. Remote HTTP-only providers/direct streams are intentionally rejected; migrate those providers to HTTPS. A reachable local provider remains an explicit trust choice, and this review does not promise comprehensive DNS-rebinding or private-network request isolation.
