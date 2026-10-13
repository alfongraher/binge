# binge

Native movie and series apps for Mac and iPad. Public Beta 1: version 0.4.1 (10), including the iPad Explore pagination correction.

Start with the [user guide](docs/USER-GUIDE.md) for installation, features, add-ons, subtitles, local-network sync and beta limitations. Downloadable Mac and iPad builds belong in GitHub Releases.

## Source layout

- `Sources/Drift`: Mac app and shared catalog, settings and synchronization code.
- `iPadProof/App`: standalone native iPad app, torrent engine bridge and media preparation.
- `Engine`: Mac playback engine.
- `Tests` and `scripts`: focused checks.
- `iPadProof/Fixture`: generated playback fixtures and dependency notices.

## Development

Mac requires Xcode and macOS 14 or later. `zsh build.sh` builds an optimized app at `build/binge.app`. The development workspace packages Python and FFmpeg from `.runtime`; those downloaded runtime binaries are excluded from source control and must be prepared separately for a complete distributable Mac bundle.

iPad requires Xcode and an ARM64 device. The deployment target is iPadOS 17. Third-party sources/tools are excluded from source control: libtorrent 2.0.15, Boost 1.86.0, FFmpeg 8.0 and CMake must be available at the paths used by `iPadProof/build-engine.sh` and `build-media.sh`. Pinned dependency hashes are in `iPadProof/dependency-sha256.json`. Build the engine and media libraries, run `create_project.py` (optionally set `BINGE_DEVELOPMENT_TEAM`), then open the generated BingeProof project and choose your own signing team. The historical iPadProof directory name does not indicate a Mac server dependency.

## Beta status

This is a development-signed beta, not an App Store/TestFlight release. Exact credits detection and background banner trailers are not included. AltStore installation still needs validation on a fresh tester device. See the user guide for platform requirements and current behavior.
