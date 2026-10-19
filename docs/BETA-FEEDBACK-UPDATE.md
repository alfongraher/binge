# Beta feedback update

## Playback and recommendations · 0.4.3 (12) · October 19, 2026

Back navigation now retires torrent sessions and removes playback cache data away from the main thread. Source lists use lazy rows and compute their ranking in the background.

A warm-yellow Recommended label highlights the first suggested source in the selected resolution filter. Ranking considers recent observed transfer speed and variability, provider-reported peers, file size and runtime, resolution, audio format, and previous startup results on this device. All sources remain selectable. Cold starts use a conservative estimate; this is not an internet speed test or a live probe of every torrent. iPad recommendations respect its existing 2 GiB limit. Known zero-peer torrents and AV1 sources are not recommended. Network estimates expire after an hour; recent source results remain local and expire after seven days.

Home banner artwork now fits without cropping, blending into the text area.

Validation: focused recommendation/runtime tests, cache cleanup race checks, and history/library regressions passed. Three generated native playback/start/exit cycles on the physical iPad measured 7–9 ms for synchronous stop cleanup. This does not measure external torrent shutdown or guarantee every navigation stall is resolved. A populated Mac episode source list displayed the recommendation and returned normally. Real-world source startup still depends on the swarm and media format.

A built-in VPN and a broader custom settings theme are separate work and are not included in this update.
