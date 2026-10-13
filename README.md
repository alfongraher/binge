# binge

Native movie and series apps for Mac and iPad. Public Beta 1: version 0.4.1 (10), including the iPad Explore pagination correction.

Start with the [user guide](docs/USER-GUIDE.md) for installation, features, add-ons, subtitles, local-network sync and beta limitations. Downloadable Mac and iPad builds belong in GitHub Releases.

## Source layout

- `Sources/Drift`: Mac app and shared catalog, settings and synchronization code.
- `iPadProof/App`: standalone native iPad app, torrent engine bridge and media preparation.
- `Engine`: Mac playback engine.
- `Tests` and `scripts`: focused checks.
- `iPadProof/Fixture`: generated playback fixtures and dependency notices.

## Beta status

This is a development-signed beta, not an App Store/TestFlight release. Exact credits detection and background banner trailers are not included. AltStore installation still needs validation on a fresh tester device. See the user guide for platform requirements and current behavior.
