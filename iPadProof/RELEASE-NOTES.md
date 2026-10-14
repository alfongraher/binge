## Security update · 0.4.2 (11) · October 13, 2026

Patched FFmpeg 8.0.3 on both platforms; limited and protected add-on/subtitle downloads; hardened encrypted sync with fresh key agreement, direction binding and replay protection; bounded loopback server connections and protected local saved data. Detailed production playback diagnostic files are no longer written. See docs/SECURITY-REVIEW.md for findings, tests and limits.

Update both devices together for sync. Existing pairings remain stored. Remote HTTP-only providers/direct sources must use HTTPS; explicit localhost providers remain supported.

## Public Beta 1 correction · October 13, 2026

Mac Continue Watching and Library cards hide the native menu indicator, leaving only the ellipsis. iPad Explore page requests are no longer tied to the loading indicator's view task, which cancelled its own request when busy changed. Cancellation is ignored rather than displayed as a network failure; generation checks still discard obsolete results after filters change. Corrected installer: `releases/binge-0.4.1-public-beta1-pagination-fix.ipa` (original installer retained).

## Public Beta 1 · 0.4.1 (10) · October 13, 2026

Movies and episodes are marked watched during an estimated credits window: the last five percent, capped at three minutes for movies and one minute for episodes. Unknown duration does not trigger early completion. Catalogs currently supply no exact credit-start timestamps; this is an estimate, not visual credits detection. Playback continues normally. For series, the next released episode is queued in Continue Watching when its playable source has been resolved; its own saved progress is retained. Final episodes retain the completed title. Existing end-of-episode autoplay timing remains unchanged.

Explore uses a vertical lazy grid and requests subsequent catalog pages as the bottom enters view. Filters are carried into subsequent pages, duplicate titles are removed, and paging stops when the provider supplies no new titles. Search keeps its existing ranking. Add-on connection is enabled while idle; an empty URL gives a prompt rather than disabling the action.

Optimized Mac and iPad Release builds and signatures passed. The iPad build was installed and launched. Focused completion/next-episode checks and both library regression suites passed. Live Cinemeta default and genre pages returned distinct additional titles; Mac UI scrolling loaded more titles, and the Connect Add-on URL prompt was checked. Broad torrent playback was not rerun for these UI/history changes. Existing LAN pairing reconnected and the Mac reports Up to date with iPad.

---

# binge for iPad · Beta 4

Version **0.4.0 · build 9 · October 13, 2026**

Adds Settings through the top-right gear, with Add-ons and optional local network syncing with Mac. Pair once using matching codes on both screens; history, progress, watched status, favourites and library updates reconnect automatically on the same network. Automatic sync and the history/library categories can be controlled separately; Sync Now and Forget Device are available. iPad sync requires the app in the foreground. No account or paid Apple Developer membership is needed. Videos, local files and installed add-ons stay local.

Optimized Release builds, signature verification, physical installation and model/transport regression checks passed. The user confirmed pairing and “Up to date” on the real devices; the iPad diagnostic independently reports “Up to date with Mac.” This release does not alter video preparation or startup buffering.

Package: `releases/binge-0.4.0-beta4.ipa`; checksum metadata: `releases/beta4-manifest.json`. Earlier installers remain preserved.

---

# binge for iPad · Beta 3 poster-loading update

Version **0.3.1 · build 8 · October 13, 2026**

Startup now shows the title cover gradually filling into colour, with a subtle glow and one Getting Your Video Ready message. Technical startup stages, peer counts and preparation bars are hidden. The cover stays until the native player has a frame ready. Back and error/Retry actions remain available. Reduced Motion is respected.

Optimized Release compilation and signature verification passed. Installed and launched on the iPad; visual startup review remains with the user. Package: `releases/binge-0.3.1-beta3.ipa`; checksum: `releases/beta3-0.3.1-manifest.json`. Previous packages are preserved.

---

# binge for iPad · Beta 3 Library update

Version **0.3.0 · build 7 · October 13, 2026**

Library now has Plan to Watch, Favourites, Watching, Watched and All Titles sections. Search, movie/show filters, sorting and remembered filter choices make saved titles easier to find. Cards include a heart, status and options with resume, manual labels, removal and Undo. Title detail pages also support favourites and status changes.

Existing saved titles migrate without losing their order. Default status follows viewing progress; finishing one episode does not label the whole series Watched. Manual labels can be reset to viewing progress. Removal affects library membership only.

Focused model checks passed migration, favourites, status derivation/overrides, filters/sorting, Undo and persistence. Optimized Release compilation and signature verification passed. Installed and launched on the iPad; visual review remains with the user.

Package: `releases/binge-0.3.0-beta3.ipa`; checksum: `releases/beta3-manifest.json`. Previous packages are preserved.

---

# binge for iPad · Beta 2 image-banner update

Version **0.2.3 · build 6 · October 13, 2026**

Restores the wide landscape image banner with title and buttons over the artwork. Inline trailer previews are removed; the Trailer button remains for on-demand playback. Automatic slide rotation, looping, Home Movie/Series tags and the removed greeting are retained.

Release compilation and signature verification passed. Installed and launched on the iPad. Package: `releases/binge-0.2.3-beta2.ipa`; checksum: `releases/beta2-0.2.3-manifest.json`. Previous packages are preserved.

---

# binge for iPad · Beta 2 automatic banner update

Version **0.2.2 · build 5 · October 13, 2026**

Removed the Home greeting. Movie/Series tags now appear on Home posters and Continue Watching cards.

The featured banner plays available trailers automatically, muted, and advances every 20 seconds. Both automatic advancement and manual end swipes wrap around. Details sit beside the video, or below it in narrower layouts. Previews pause when the banner leaves view or the app becomes inactive; unsupported or unavailable trailers fall back to artwork.

Release build, signature, installation and launch passed. Automatic playback and advancement were confirmed by successive playing events for different trailers on the physical iPad. Full carousel-cycle and visual review remain for hands-on confirmation.

Package: `releases/binge-0.2.2-beta2.ipa`; checksum: `releases/beta2-0.2.2-manifest.json`. Earlier packages are preserved.

---

# binge for iPad · Beta 2 design update

Version **0.2.1 · build 4 · October 13, 2026**

Continue Watching now uses wide image cards with overlaid title, episode, remaining time and progress. Tap to resume, or use the ellipsis menu for More Info and removal. Older watch history gains landscape artwork without resetting progress.

A swipeable Home banner features popular movies and shows, with More Info, save and an available-trailer button. Trailers open on tap in an in-app browser; background autoplay is not included in this version.

Release compilation, signature, legacy-history compatibility, artwork persistence and trailer metadata checks passed. Installed and launched on the iPad; visual and trailer playback confirmation remain pending.

Package: `releases/binge-0.2.1-beta2.ipa`; checksum: `releases/beta2-0.2.1-manifest.json`. Previous packages are preserved.

---

# binge for iPad · Beta 2

Version **0.2.0 · build 3 · October 13, 2026**

Home is now a separate default tab with a time-of-day greeting, Continue Watching, and movie/show recommendations based on recent viewing genres. New users see popular titles. Existing progress, watched episodes, More Info, resume and removal actions are retained.

Explore has movie/show selection and genre filters from the catalog. Search remains available; submitting a search clears the browse genre filter because the provider does not reliably combine them.

Debug and Release compilation, signature verification, history migration/persistence checks and live genre catalogs passed. The optimized build was installed on the iPad; visual review remains with the user. The previous playback compatibility fix is included.

Package: `releases/binge-0.2.0-beta2.ipa`; checksum: `releases/beta2-manifest.json`. This remains a local development-signed beta. Previous installers are preserved.

---

# binge for iPad · Beta 1

Version 0.1.0 · build 1 · October 13, 2026

First standalone iPad beta, installed as **binge** with the existing brand mark adapted to an opaque, full-bleed iPad icon. The release uses optimized Swift compilation and excludes development proof screens and bundled test media. Browse and Library are the only tabs. The existing bundle identifier is retained to preserve installed watch history and saved titles.

This baseline includes movie/series browsing, season and episode selection, MP4/MKV torrent preparation, full-duration seeking with buffered-range shading, native captions and online subtitle selection, Picture in Picture, saved progress, latest episode per show, next-episode countdown/source reuse and deferred cache cleanup. Real HEVC/AC3 and HEVC/AAC releases were tested on the physical iPad, including user-confirmed synced dialogue and visible picture.

The current 2 GiB selected-source limit remains. Broader Mac feature parity and other codec/subtitle cases remain for later builds.

The signed local installation package is `releases/binge-0.1.0-beta1.ipa`; its metadata and SHA-256 are in `releases/beta1-manifest.json`. This is a local development-signed beta, not a TestFlight publication.

Rebuild with the **binge** scheme, **Release** configuration in `BingeProof.xcodeproj`. Debug retains the isolated command-line playback proofs; Release opens only the app. Internal project and bundle names remain unchanged for continuity.

## Post-beta compatibility fix · October 13

The previously failing Project Hail Mary AVC/PQ MP4 now uses native verified-range MP4 playback after startup preparation. Other sources retain prepared HLS. The user built the Debug app in Xcode and confirmed the source plays. The optimized Release hotfix **0.1.1 (2)** was built, signed, and installed on the connected iPad. The icon is included, and development proof screens and test fixtures are excluded. The package is `releases/binge-0.1.1-beta1-hotfix.ipa`, with checksum metadata in `releases/beta1-hotfix-manifest.json`. The original Beta 1 package is preserved. Source playback was user-confirmed in Debug; Release launch is checked separately.
