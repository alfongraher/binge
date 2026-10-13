# Add-on based source listing

Reference inspected: https://torrentio.strem.fun/manifest.json (2026-10-12).
Protocol: https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md
Stream schema: https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/stream.md

## What Torrentio exposes

The manifest identifies `com.stremio.torrentio.addon`, version `0.0.15`. It has no catalogs and advertises a stream resource for movie, series, and anime with `tt` and `kitsu` ID prefixes. Configuration is supported but not mandatory. These declarations describe capabilities, not guaranteed availability of every provider named in its description.

Torrentio resolves sources for an identified title or episode. It does not provide title-text search through this manifest. Its manifest also does not disclose its scraper implementation.

## Drift flow

1. Install an add-on by pasting a manifest URL. Fetch and validate its capabilities. Preserve any configuration path before `manifest.json`; configured URLs may include credentials and must not appear in diagnostic logs.
2. Search titles using a separate metadata/catalog provider. Retain the provider's stable movie or episode ID rather than using a display title to request streams.
3. On title/episode selection, request matching add-ons at `{base}/stream/{type}/{videoID}.json`, respecting each resource's supported types and ID prefixes. Use metadata-provided episode IDs, not guessed naming conventions.
4. List returned streams with provider name, name, description (or legacy title), and available structured details. Seed counts and quality may occur only in provider-specific display text; do not pretend they are standard protocol fields.
5. Handle direct HTTP(S) URLs separately from torrent `infoHash` sources. Preserve `fileIdx`, `sources`, and relevant behavior hints. Selecting the largest file is a fallback only when no file index is supplied; discarding a supplied index can play the wrong episode in a season pack.
6. Pass a selected torrent to the future engine; listing support does not make torrent playback available. Explain unsupported source types explicitly.

## Implementation boundaries

Replace the text-only torrent provider abstraction with two interfaces: catalog search and streams for a content ID. Keep custom non-Stremio adapters possible. Support mixed string/object resource declarations, configuration paths, multiple independent add-ons, cancellable requests, timeouts, and partial success when one add-on fails. Do not create a torrent session during catalog browsing.

Add fixture tests for manifest filtering, configured base URL preservation, stream decoding, file-index preservation, episode IDs, unsupported stream variants, empty results, and cancellation before claiming compatibility. Use a user-selected add-on for a live smoke check; protocol fixtures should not depend on remote provider uptime.

Implemented: manifest installation and persistence, catalog search, episode selection, stream listing, capability filtering, cancellation, and source persistence. Requests currently run sequentially within each search/list operation, so results appear when the operation finishes. The first H.264/HEVC torrent player is connected through a development libtorrent/FFmpeg helper; broad source compatibility and full-range seeking remain pending.
