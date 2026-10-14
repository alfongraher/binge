# binge — Public Beta 1 user guide

**Version 0.4.2 (11) · Updated October 13, 2026**

binge is a movie and series player for iPad and Mac. Browse titles, organize a watchlist, play sources supplied by add-ons, resume your viewing, and optionally synchronize your library and history between nearby devices.

The iPad app downloads and prepares video on the iPad itself. A Mac is not needed for playback. A computer may still be needed to install or refresh a sideloaded iPad app.

## Quick start

1. Install the current beta using the instructions below.
2. Open **Settings**: the gear at the top-right on iPad, or the **Settings** tab on Mac.
3. Check that the catalog, source, and subtitle add-ons you want are connected.
4. Open **Explore**, choose Movies or TV shows, and optionally select a genre or search for a title.
5. Open the title. For a series, choose a season and episode.
6. Select an available source and allow the loading cover to finish.
7. Use the player’s controls to pause, seek, select subtitles, or enter Picture in Picture.

There is no binge account to create. Device synchronization is optional.

## Requirements and beta scope

| Platform | Current build requirements | Testing status |
| --- | --- | --- |
| iPad | iPadOS 17 or later; internet access and free storage for video preparation | Tested on a physical iPad Pro running iPadOS 27.0.1. Older supported versions and other iPad models need further testing. |
| Mac | macOS 14 or later; the current supplied build is for Apple silicon | Tested on the development Mac. An Intel build is not included in this release. |

This release targets iPad, not iPhone. Source availability, startup time, subtitles, and format compatibility vary. A displayed title is not a guarantee that a working playback source is available.

## Install on iPad

### Get the current installer

Ask the beta organizer for **`binge-0.4.2-security-update.ipa`**. This includes the correction for Explore pagination. Version 0.4.2 also includes the security update.

Update both devices to 0.4.2 or later for the new secure sync protocol. Remote add-on, subtitle and direct media URLs require HTTPS; localhost HTTP is supported for explicitly configured local providers.

An `.ipa` is the iPad app package. Saving it in Files alone does not install it; a signing and installation tool is required. The organizer’s development signature is not a universal installation permission for every tester’s iPad.

### AltStore Classic setup

AltStore Classic can sign sideloaded apps using your own Apple Account. Follow its official setup guide for your computer:

- [AltStore installation using a Mac](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)
- [AltStore installation using Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)

The general process is:

1. Install AltServer on your computer using the official guide.
2. Connect and unlock your iPad, and trust the computer when prompted.
3. Use AltServer to install AltStore Classic on the iPad, using your own Apple Account.
4. If required, trust your development profile under **iPad Settings → General → VPN & Device Management**.
5. Enable **Developer Mode** under **Settings → Privacy & Security**, following the device’s restart and confirmation prompts. See [Apple’s Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).
6. Save the binge `.ipa` in the iPad’s Files app.
7. In AltStore Classic, open **My Apps**, use the add/import action, and choose the `.ipa`. Allow AltStore to finish signing and installing it.
8. Open binge from the Home Screen.

Enter account credentials only in the installation tool’s sign-in flow; the beta organizer does not need them. These instructions describe the expected sideloading route. This particular binge package has not yet been validated through a fresh AltStore installation.

### Keep the installation active

With a free Apple Account, AltStore-installed apps expire after seven days unless refreshed. Apple also limits active sideloaded apps to three. Check the remaining days under **My Apps** and use **Refresh All** before expiration. [AltStore account and refresh information](https://faq.altstore.io/altstore-classic/your-altstore)

AltStore’s documented setup uses AltServer on a computer for installation and refresh, over the same Wi-Fi network or USB. This computer connection is for app signing; binge’s playback remains independent. [AltServer instructions](https://faq.altstore.io/altstore-classic/altserver)

Other signing tools may be usable, but have not been tested with this beta. This package is not an App Store or TestFlight release.

## Install on Mac

Obtain the current **binge.app** from the beta organizer, copy it to **Applications**, and open it. Share the entire app bundle rather than just its executable. The supplied bundle includes its torrent module and FFmpeg. The current Mac beta additionally requires a Python 3.12 framework installation for torrent playback; the interpreter is not yet bundled. Use a maintained patch version.

This beta uses a development signature rather than a notarized public installer. If macOS refuses to open it, send the organizer the exact message and your macOS version. Do not alter the bundle or disable system protections to troubleshoot it.

## Home

Home brings together:

- **Featured titles:** a wide artwork banner with More Info, a save action, and a Trailer action when one is available. Slides advance automatically and loop. Mac hovering pauses advancement.
- **Continue Watching:** landscape cards with progress, episode information, and remaining time. Select a card to resume. The dots menu provides title information and removal from Continue Watching; Mac also offers Keep Watching in this menu.
- **Recommendations:** suggestions based on recent viewing genres, with popular titles available for new users.
- **Movie/Series tags:** Home artwork is labelled to help distinguish the two.

Banner trailers open on request. Background trailer autoplay is not part of this beta.

Removing a Continue Watching card dismisses it from that section; it does not erase the title’s watched history. There is one current Continue Watching entry per show rather than separate cards for every previously played episode.

## Explore and title pages

Use the type filter to select movies or series. Genre choices come from the connected catalog. Search finds titles by name; submitting a search clears the browse genre filter.

Scroll down to request more browse results. Additional pages retain the type and genre selection. Loading stops when the catalog has no new titles to return. Search results use the existing search behavior rather than browse pagination.

A movie page provides title information and available playback sources. A series page also provides season and episode selection. Watched episodes have an indicator, and the last watched episode is highlighted. The app selects its season and brings that episode into view when available.

To record something watched elsewhere, **right-click an episode on Mac** or **touch and hold it on iPad**, then choose the watched/unwatched action. This updates its watched status without pretending that it was the episode most recently played in binge.

## Add-ons and source selection

Open **Settings → Add-ons → Catalogs, sources and subtitles**. The quick-connect choices are:

| Add-on | Role |
| --- | --- |
| Cinemeta | Title catalogs, artwork, metadata and episode lists |
| Torrentio | Playback source lists |
| OpenSubtitles v3 | Online subtitles |

If an expected add-on is absent, use its quick-connect button. To connect another compatible add-on, paste its **manifest URL** into the URL field and select **Connect add-on**. A web page address or provider name alone is not necessarily a manifest URL. Remove an installed add-on with its Remove action.

Add-ons are configured separately on each device. They are not copied by device sync. Support depends on the resources exposed by the add-on; not every third-party add-on has been tested.

For playback, choose from the supplied sources and resolution choices. Resolution labels come from providers. A higher-resolution or larger source can need more startup time and storage; a smaller source can be a useful alternative when startup is slow. Sources with few available peers may fail to become ready even when other sources for the same title work.

The loading cover fills into colour while the app prepares playback. Technical preparation stages are intentionally hidden. Keep the app open while starting a source. An actionable error is shown if preparation fails.

## Player, subtitles and Picture in Picture

The player hides navigation and controls during viewing. Move the mouse on Mac or interact with the player on iPad to reveal them. The main navigation tabs are hidden in the player.

The timeline shows the full known video duration and buffered ranges. You can seek outside the currently buffered range, but playback may need time to download and prepare the destination. The skip buttons move backward or forward fifteen seconds.

**Mac keyboard controls, while the player is active:**

| Key | Action |
| --- | --- |
| Space | Play/pause |
| Left / Right arrow | Seek backward / forward ten seconds |
| Down / Up arrow | Decrease / increase volume by five percent |

### Subtitles

Use the subtitle icon in the controls. Available embedded tracks can be selected; online subtitle search depends on a connected subtitle add-on. Choose a language and a track suited to the source release.

Online subtitles have a timing adjustment. On iPad, positive delay displays online captions later; embedded tracks retain their native timing. Caption availability and synchronization depend on the selected source and subtitle track. Some embedded subtitle formats are not supported by every playback path.

### Watch while using other apps

On iPad, use native **Picture in Picture** and return to the Home Screen. Video and audio should continue in the floating window, and you can return to binge from it. PiP and captions were confirmed on the physical test iPad; behavior can vary with the subtitle path.

Mac has a floating miniplayer with simplified seeking, hover playback controls, and Back to App. Move it to a convenient location while working in other windows.

## Completion and the next episode

binge marks a title watched during an **estimated credits window**: the last five percent of its duration, capped at three minutes for movies and one minute for episodes. Exact credit-start timestamps are not supplied by the current catalog. Playback continues after the watched indicator changes.

For a series, the next released episode is placed in Continue Watching once its playable source has been resolved. Existing progress for that episode is preserved. If no next episode or working source is available, the completed episode remains accessible.

Near the end, an Up Next card offers **Play now**. After the episode ends, a ten-second countdown starts automatic next-episode playback when the next source is available. Dismiss the card to cancel automatic advancement. The app tries to reuse a compatible source, including the same season-pack torrent when possible; it cannot guarantee a transition without buffering.

Prepared video may be retained for unfinished viewing to help resuming. Completed playback caches are cleared when leaving the player; downloaded video is not a permanent offline library. Device sync does not transfer these caches.

## Library

Save a title with **Plan to watch**, without first selecting a playback source. Library includes:

- **All titles:** everything saved.
- **Plan to watch:** saved titles planned for later.
- **Favourites:** titles marked with a heart.
- **Watching:** saved titles with viewing progress.
- **Watched:** completed or manually labelled titles.

Search within the library, filter by movie/series, and sort by recently added, title, or recently watched. Use the dots menu for available information/resume actions, favourites, status labels, and removal. Choose **Use viewing progress** to reset a manual status label. Removing a library item offers Undo while the removal notice is available.

Finishing one episode does not mark the entire series Watched. Mac additionally supports local video files and manually added sources; these stay local.

## Optional synchronization between devices

Sync exchanges history and library information directly on the local network. It does not require an account, iCloud subscription, or Mac server.

1. Connect both devices to the same network and open binge on each.
2. Open Settings and enable **Local network sync** on both devices.
3. Allow Local Network access if the operating system asks.
4. Select **Pair** beside the other device.
5. Compare the six-digit code displayed on both screens.
6. Select **Codes match** on both devices only when the codes agree.
7. Wait for **Up to date**.

Saved pairing reconnects automatically. The Mac app must be running, and the iPad app must be in the foreground for iPad synchronization.

You can toggle automatic updates, history/progress, and library/favourites/labels separately. Use **Sync now** for a manual exchange or **Forget** to remove a pairing. Both devices can make changes while apart and exchange them after reconnecting.

Sync covers catalog-linked titles, playback positions, watched state, favourites and library membership. Video files, caches, local-only sources and installed add-ons stay on their original device. Subtitle settings are not included in the current sync categories. Trusted devices exchange encrypted state after pairing.

## Troubleshooting

| Symptom | What to try |
| --- | --- |
| App will not open after several days | Check the sideloading tool’s expiry and refresh the app. This is separate from playback. |
| No titles or sources | Check the catalog/source add-ons in Settings and your connection. Try another title. |
| Startup takes a long time | Keep binge open, allow preparation time, then try a smaller or different source. Peer availability and format preparation affect startup. |
| Black video, freezing or an error | Record the source label and exact error, then try another source. Report whether audio or the timeline continued. |
| Seek pauses playback | Allow the destination to buffer. Report it if playback never resumes. |
| Subtitles missing or mistimed | Check the track/language and subtitle add-on; try another matching release or adjust online timing. |
| Explore cannot load more | Confirm you have the pagination-fix installer. Check connectivity and retry. Report the selected type and genre if it repeats. |
| Other device is not discovered | Keep binge open on both, keep the iPad foregrounded, and check Local Network permission. Guest Wi-Fi can prevent devices from reaching each other. |
| Changes do not sync | Check the relevant category and automatic-sync switches, then use Sync now. Confirm both devices show the saved pairing. |

Updating through the same signing identity and app identifier should preserve data. Avoid deleting the app as a first troubleshooting step: removal can delete local history, library and pairing information. Sync is not a full backup service.

## Sending useful beta feedback

Send the beta organizer:

- Device model, operating-system version, and binge version.
- The steps that produced the problem and whether it repeats.
- Title, season/episode, source resolution and source label; include codec or file-size labels if shown.
- Exact error text and a screenshot or short recording when useful.
- For playback: whether picture, audio, timeline, seeking and captions continued working.
- For audio timing: whether audio is early or late and roughly by how much.
- For sync: both devices’ statuses, network setup and enabled categories.

Useful checks include starting a movie and episode, seeking to an unbuffered position, resuming after a long pause, online and embedded subtitles, PiP, next-episode behavior, several Explore pages, library favourites/Undo, and optional device sync. You do not need to test every feature to give helpful feedback.

This is an early beta. MP4 and MKV playback paths have been exercised, but not every codec, torrent, provider, device or signing tool has been verified. Background banner video and automatic availability of more add-ons remain future work.
