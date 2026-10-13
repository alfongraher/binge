<div align="center">

<img src="Assets/binge.png" alt="binge app icon" width="120" />

# binge

### Pick a story. Make yourself comfortable.

A native movie and series app for **Mac and iPad**, with a simple library, thoughtful playback controls, and a place to pick up where you left off.

**[Download Public Beta 1](https://github.com/alfongraher/binge/releases/tag/v0.4.1-public-beta1)** · **[User guide](docs/USER-GUIDE.md)** · **[Report an issue](https://github.com/alfongraher/binge/issues)**

</div>

---

## Your next watch, within reach

Home brings together popular titles, recommendations inspired by your recent viewing, and **Continue Watching**. Wide cards show your progress and remaining time, while movie and series labels help you find what you’re in the mood for.

The featured banner cycles through titles. Open a title for more information, save it for later, or watch an available trailer.

## A library that feels like yours

Keep everything organized in **Plan to Watch**, **Favourites**, **Watching**, and **Watched**. Search your saved titles, filter movies and series, and choose how they’re sorted.

Mark something watched elsewhere, change its label, or remove it with Undo. Series remember watched episodes and highlight where you last left off.

## Settle into the story

- **Resume easily.** Continue Watching keeps one current entry per show.
- **Find more.** Explore movies and series by genre, search for a title, and keep browsing as more titles load while you scroll.
- **Choose your subtitles.** Select available embedded tracks or find online subtitles, with timing adjustments for online captions.
- **Watch while doing other things.** Use native Picture in Picture on iPad or the floating miniplayer on Mac.
- **Keep the next episode close.** An Up Next card offers Play Now and automatic playback after an end-of-episode countdown. The next released episode can also appear in Continue Watching once its source is ready.
- **Enjoy a quieter player.** Controls hide during viewing and return when you interact. The timeline shows playback progress and buffered sections.

On Mac, use **Space** to play or pause, **Left/Right** to seek, and **Up/Down** to adjust volume. Local video files are also supported on Mac.

## Your devices, on the same page

Optional **local network sync** shares viewing progress, watched episodes, library titles, favourites, and labels between your paired devices.

Open Settings on both devices, enable sync, compare the pairing codes, and confirm. No binge account or iCloud subscription is needed. Both apps must be open; iPad syncing runs while binge is in the foreground. Downloads and add-ons stay on each device.

**The iPad app works on its own. A Mac server is not required for playback.**

## Try the beta

| | Mac | iPad |
| --- | --- | --- |
| Download | Mac `.zip` | Corrected iPad `.ipa` |
| Requirements | Apple silicon · macOS 14+ | iPadOS 17+ |
| Installation | Extract and copy binge to Applications | Sign and install using a compatible sideloading tool |

**[Get both versions →](https://github.com/alfongraher/binge/releases/tag/v0.4.1-public-beta1)**

The Mac beta is development-signed and has not been notarized. The iPad package needs signing for your device; it is not an App Store or TestFlight installation. AltStore is an expected installation route, but this build has not yet been verified through a fresh AltStore setup. Free-account sideloading requires periodic refresh.

Our physical iPad testing used an iPad Pro on iPadOS 27.0.1. Other models and older supported versions still need testing. See the **[setup guide](docs/USER-GUIDE.md#install-on-ipad)** for installation steps and requirements.

## A little setup, then you’re ready

1. Install binge and open **Settings**—the top-right gear on iPad or the Settings tab on Mac.
2. Check your **Add-ons**. Catalogs supply title information, source providers supply playback options, and subtitle providers supply captions. Quick-connect choices include Cinemeta, Torrentio, and OpenSubtitles v3.
3. Open **Explore**, choose a title and an episode if needed, then select an available source.
4. Save your favourites, build your watchlist, and make yourself comfortable.

Availability and startup time depend on the selected provider and source. You can connect additional compatible add-ons using their manifest URLs in Settings.

## Help shape what comes next

**Public Beta 1 · version 0.4.1 (10)** includes the iPad Explore pagination fix.

Some sources or subtitle formats may still need work. Completion uses an estimated credits window rather than exact credit detection, and the featured banner uses artwork rather than background trailer autoplay.

If something feels wrong, **[tell us about it](https://github.com/alfongraher/binge/issues)**. Include your device, operating-system version, the title and source involved, and what happened. Screenshots and exact error messages help.

The **[full user guide](docs/USER-GUIDE.md)** covers every main feature, device pairing, troubleshooting, and useful things to test. Repository and download access currently require an invitation while this project is private.
