# Lumen

A native macOS presentation and show-control app for church services, built in Swift, SwiftUI and Core Image/Metal.

## Install

Download `Lumen-<version>.dmg` from the GitHub release, open it, and drag Lumen to Applications. The app is signed with the Hope Church Developer ID but not yet notarized. The first time, right-click Lumen.app and choose **Open**, then confirm (or go to System Settings → Privacy & Security → Open Anyway).

To build a DMG yourself, run `Scripts/make_dmg.sh`. It writes `dist/Lumen-<version>.dmg`, and notarizes it automatically if a `lumen-notary` notarytool profile is saved on the Mac (see the comment at the top of the script).

## Sunday-morning checklist

Do this once on the show Mac (Setup), then glance at the pre-service list each week.

**One-time setup**
1. **Setup → Screens:** assign each screen to its real output (Mac display, DeckLink connector + video mode, NDI). Lumen refuses to put an output on the display its own control window is on, so you can't lock yourself out.
2. **System Settings → Notifications → Focus:** turn on *Do Not Disturb* for the show Mac so banners never appear on a projector. Lumen keeps the Mac awake on its own (Setup → General → Show safety).
3. **Setup → Remote & MIDI:** note the phone-remote PIN (Lumen makes one on first launch). **Setup → General:** note the volunteer-mode PIN (also generated); change both if you like.
4. **Setup → Planning Center:** connect, pick the service type that has *upcoming* plans, then press **Preview Next Service**. It lists every item, what Lumen will do with it, and flags songs with no lyrics, without changing anything.
5. Install the **Blackmagic Desktop Video** driver (and NDI Tools if you use NDI) and build with the SDKs (see the DeckLink and NDI sections), then check the green status line under each screen.

**Before each service (about two minutes)**
- Output boxes in the right-hand panel each show a measured fps in green (red means that output is struggling). Hover for render time.
- Press **Sync** once, glance at the playlist (🔒 = locked from Planning Center changes, ⟳ = synced), and lock it once it's final.
- Click through the countdown video, the first song's first slide, and the scripture or sermon slide.
- Confirm the stage display shows the next slide, key and timers.
- Switch on **Volunteer Mode** for whoever is running slides.

**If something goes wrong**
- *Lumen crashed or was force-quit:* relaunch; a banner offers **Put It Back on Screen** with the last slide and look.
- *A song's lyrics look wrong:* edit it (the change shows on screen when you save, and the screen never blanks while you edit); tick *Keep my edits* so Planning Center sync doesn't overwrite it.
- *An output froze or went dark:* Setup → Screens → **Apply Output Changes** rebuilds the outputs without quitting. DeckLink and NDI feeds are not interrupted by a display being plugged or unplugged.
- *Your library file was damaged:* Lumen comes back on the newest automatic backup (`Application Support/Lumen/Backups`, one per day plus one per version) and tells you.

## What Lumen does to protect a live service

- **Never blank on a bad edit.** If the live song is edited, shortened or deleted, the outputs keep showing what they showed until you choose something else.
- **Never change a live service under you.** Planning Center sync, auto-sync and updates don't run while something is on the outputs, and a sync that fails (offline, bad token) changes nothing.
- **Never lose your arrangement.** Hand-added playlist items stay where you put them across syncs; a playlist can be locked; delete asks first and refuses while the item is live.
- **Never stop the show by accident.** Closing the control window doesn't quit; quitting or turning outputs off while live asks first (default: cancel); held-down keys don't race through slides; shortcut keys only work in the main window; Volunteer Mode locks Settings, the Show menu and editing.
- **Keeps the Mac awake** and out of App Nap while it's open.
- **Phone remote is locked down:** a PIN is required (random, generated on first launch), wrong guesses are rate-limited, malformed or oversized requests are rejected, idle connections are dropped, and the pages never insert show text as HTML.
- **Dead sources don't freeze on screen:** an unplugged capture card or lost NDI source disappears instead of leaving its last frame; a missing media file is reported instead of leaving a stale frame.
- **Updates can't strand you:** they check they can replace the app before quitting, verify the signature and version, keep the old copy until the new one has run for 12 seconds, and roll back if it won't stay up.

## Updates

Lumen updates itself from this GitHub repository, so nobody downloads DMGs after the first install.

- **Where it shows up:** an orange **Update** button appears in the toolbar when a newer version exists (checked at launch). You can also use **Lumen ▸ Check for Updates…** or **Setup → General → Updates**.
- **It never installs by itself.** You click Update, confirm, and Lumen downloads the release, checks its checksum and that it's signed by Hope Church's Developer ID, swaps itself in place and reopens. If something is on screen it warns you and defaults to *Not Now*, because updating blanks the outputs for several seconds.
- **Private repo:** the check needs a GitHub login. If `gh auth login` is set up on the Mac, that's used automatically. Otherwise paste a fine-grained token (read-only *Contents* access to this repo) into Setup → General → Updates. It's stored in the Keychain.
- **Mac with DeckLink/NDI SDKs:** a downloaded release is built without those SDKs, so it can't drive DeckLink or NDI. On that Mac, clone the repo and run `./Scripts/update.sh` once (it builds with the local SDKs and installs to /Applications). From then on Lumen sees the git checkout it was built from and updates by **pulling and rebuilding** (in a Terminal window) instead of downloading, so DeckLink and NDI keep working.
- **Your songs are safe:** the first time a new version opens your library, Lumen copies the old one to `~/Library/Application Support/Lumen/Backups/`. `LibraryCompatibilityTests` guards the saved format. When adding fields to the data model, make them `Optional`.

### Publishing a new version

```bash
./Scripts/release.sh 0.3.0 "What changed"
```

That bumps the version, builds the signed DMG, commits, tags, pushes, and creates the GitHub release with the DMG attached. Every Mac then offers the update.

## Build

```bash
brew install xcodegen          # once
xcodegen generate
open Lumen.xcodeproj           # or: xcodebuild -scheme Lumen -derivedDataPath build build
```

The app targets macOS 26 or later. The library lives in `~/Library/Application Support/Lumen/` as `library.json` plus a `Media/` folder.

## How it's put together

| Area | Where | Notes |
|---|---|---|
| Show state: live slide, looks, layers, timers, macros, slideshow | `Core/Engine/LiveEngine.swift` | Every action from the UI, remote, MIDI, schedule or AI goes through here |
| Compositor | `Core/Rendering/ScreenRenderer.swift` | One renderer per screen. Layers: theme background, media/live video, slide (with dissolve), props/messages. Output is BGRA with alpha |
| Looks | `Model/Models.swift` (`Look`, `ScreenLookConfig`) | Per screen: which layers show and how slides render (full slide, transparent text, lower third, hidden). Can be set **per slide type**, e.g. scripture becomes the Bible lower third on the stream |
| Outputs | `Core/Outputs/` | Mac displays (borderless full screen), DeckLink (fill+key), NDI (with alpha), floating test window |
| Planning Center | `Integrations/PlanningCenter/` | Plans become playlists. Songs pull CCLI lyrics and the sequence from arrangements. The service template maps items to presentations. Auto-syncs every N minutes |
| Bible | `Integrations/Bible/` | bible-api.com (public domain, no key), API.Bible (thousands of translations), ESV API, or any Zefania/OSIS XML you're licensed for |
| AI listening | `Integrations/Speech/` | On-device speech recognition. `LyricFollower` (arrangement-aware, fuzzy, confidence, off-script hold) and `ScriptureDetector` (understands spoken references) |
| Remote and web stage display | `Integrations/Remote/` | `http://<mac-ip>:8090` for the remote, `/stage` for the stage display. Optional PIN |
| MIDI | `Integrations/MIDI/` | Virtual "Lumen" source and destination for Lightkey, plus incoming-MIDI → action mappings |
| Schedules and calendar | `Integrations/Schedule/` | One-off or weekly triggers, and calendar events with `lumen: …` lines in their notes |
| Import | `Integrations/Import/` | Images, video, audio, PDF, PowerPoint and Keynote (through Keynote's exporter), SongSelect `.usr`/`.txt`, OpenLyrics XML |

## Blackmagic DeckLink (e.g. DeckLink 8K Pro)

DeckLink output needs Blackmagic's SDK headers at build time and the Desktop Video driver at run time.

1. Install **Blackmagic Desktop Video** on the show Mac.
2. Download the **Desktop Video SDK** from blackmagicdesign.com/developer. Copy its `Mac/include` folder to `Vendor/DeckLinkSDK/Mac/include`.
3. Rebuild. `LMDeckLink.mm` detects the headers and compiles the real implementation. Without them it builds a stub that reports "built without DeckLink SDK".
4. In Desktop Video Setup, pick the 8K Pro's connector profile. For fill+key, use a profile that pairs connectors. Then in Lumen go to **Setup → Screens → Livestream → Add Output → DeckLink**, choose the video mode, and turn on **Fill + Key**. The alpha channel comes out as the key on the paired SDI connector for your switcher's downstream keyer.

DeckLink **inputs** (for example an Apple TV into the card's HDMI or SDI) show up as ordinary capture devices once Desktop Video is installed. They're listed under **Media → Live inputs**.

**SDK versions:** `LMDeckLink.mm` has been compiled (with warnings on, zero errors) against the real Desktop Video SDK headers for **12.0, 14.1 and 14.4**, and the whole app has been built and linked against 14.4. SDK 14.3 and later hand out frame memory through `IDeckLinkVideoBuffer`; earlier ones use `GetBytes` on the frame. `LMDeckLink.mm` picks the right one from `BLACKMAGIC_DECKLINK_API_VERSION` (switch at 14.3). If a future SDK changes the API again, that's the one place to adjust. Frames have **not** been pushed to a physical card from this development Mac, so do a test output before the first service.

## NDI

1. Install the **NDI SDK for Apple** (headers go to `/Library/NDI SDK for Apple/include`, which is already on the header search path). You can instead copy the headers to `Vendor/NDISDK/include`.
2. Install **NDI Tools** on the show Mac (it provides `libndi.dylib`). Lumen loads the library at run time, so the app still launches on Macs without NDI.
3. The NDI bridge has been compiled against the real NDI 6 headers. Add an **NDI** output to any screen. It's sent as BGRA with alpha, so vMix, OBS and TriCaster get keyed lower thirds without a separate key feed. NDI **inputs** are under **Media → NDI sources**.

## Looks: lower thirds vs. stream takeover

The seeded setup has three looks:

- **Service:** the audience gets full slides. The livestream gets a *transparent* lower third: lyrics in the lyric lower third, and scripture **automatically** in the Bible lower third. Sermon and announcement slides take over the stream full screen.
- **Stream Takeover:** the stream shows exactly the 1920×1080 slide the room sees.
- **Clean Stream:** only props reach the stream.

Change these under **Setup → Looks**. Each screen has layer toggles, a default render mode, and per-slide-type overrides for mode and theme.

## Lyrics: where "correct" lyrics come from

MultiTracks.com does not offer a public API for lyrics, so Lumen doesn't scrape it. Accurate, licensed lyrics come from **CCLI SongSelect**. Lumen gets them two ways:

- **Planning Center** (recommended). Songs in your plans carry SongSelect-imported lyrics and the arrangement's sequence (V1, C, V2, C, B, C…). Lumen builds the slides from them and re-syncs when the arrangement changes. Your own edits are protected with "Keep my edits".
- **Direct import** of SongSelect `.usr` or `.txt` downloads, OpenLyrics XML, or pasted text.

## Videos, images and worship backgrounds

- **Import:** the **+** menu in the sidebar takes images, videos, audio, PDFs, PowerPoint and Keynote. Several images become one presentation with slideshow timing. Videos play from the **Media** tab (with a scrub bar) or as a slide, and any macro or slide action can play a file.
- **Looping backgrounds with words on top:** set a video (or image) once and the lyrics sit on it. Use **Setup → Themes → Background** for a whole style (all worship songs, say), or the song's **Info → Background behind the words** for one song. The loop is seamless, keeps running from slide to slide without restarting, and stops when the slide is cleared. It plays on its own player, so a video clip can still play full screen on top of it. Order of precedence: slide's own media, then the song's background, then the theme's.
- **When a video ends:** a video slide can go to the next slide by itself, stay on its last frame, loop, clear the screen, or run any list of actions. Right-click a video slide in the grid → *When this video ends*, or set it in the slide's editor. Typical use: put the countdown video first in the playlist (or as the first slide of the service) and set it to *Go to the next slide*; when the countdown finishes, the first worship slide comes up and the video disappears. It crosses into the next playlist item if the video is the last slide of its presentation. A video belongs to its slide: if you click ahead before it ends, it's cleared and won't skip anything. Macros' *Play Media* action has the same choice. (Video only, not audio-only files.)
- **Pictures that aren't screen-shaped:** scaled until they touch the edges of the screen, centered on solid **black**, never the theme color. A 228×400 image on a 1920×1080 screen fills the full height with black on both sides. This is the default (**Setup → General → Images & videos**); each image or background can instead be set to *Fill* (crop to cover) or *Stretch*. On a keyed output (a transparent livestream layer) the margins stay transparent instead of black.
- **See what each screen is showing:** `http://<mac-ip>:8090/api/frame?screen=audience` (or `stream`, `stage`) returns a PNG of the live output.

## Chord charts and Nashville numbers on the stage display

- **Import:** select a song, then click **Chords** in the slide grid header (or right-click it in the Library → *Chords & Nashville Numbers…*). Then **Import Chord Chart…**. It accepts:
  - PDF chord charts from SongSelect, Planning Center or MultiTracks, including two-column layouts. Scanned PDFs go through on-device OCR.
  - ChordPro files (`.cho`, `.chordpro`).
  - Plain-text charts with chords written above the lyrics.
- **How chords get placed:** each chord is placed by its horizontal position over the lyric line below it. The chart's lyric lines are then matched to the song's slides by wording, so slides that break lines differently still get the right chords. A song with no slides yet is built from the chart.
- **Key:** read from the chart ("Key - G", `{key: G}`). If the chart doesn't say, it's guessed from the chords. Nashville numbers are computed from the key, and minor keys are numbered from their relative major (Em → 6m).
- **Fix mistakes:** every slide is editable ChordPro-style, e.g. `[G]Amazing grace how [C]sweet the [G]sound`. Move a bracket to move the chord. The preview next to each slide shows the numbers as the band will see them. You can also change the key, transpose, or clear the chords.
- **Stage display:** go to **Setup → Stage → Chords** to show or hide the chords and choose Nashville numbers, letters, or both, and the chord color. The phone/tablet stage page (`/stage`) shows them too.
- **Planning Center:** if an arrangement has a chord chart attached in Planning Center, sync applies it automatically. It never overwrites chords you've already fixed by hand.

## AI lyric following and scripture detection

- Choose the audio input under **Live panel → waveform tab**. A clean vocal or pastor feed from the board (USB, Dante or aux) works much better than a room mic.
- Speech recognition runs **on this Mac**, and no audio is uploaded. Recognizing sung lyrics is harder than recognizing speech, so the follower uses fuzzy word matching against the arrangement. It prefers moving forward, and treats a repeated chorus as the next instance rather than jumping back. It advances early when the last words of a slide are heard. It holds if nothing has matched for 8 seconds (spontaneous moments). It shows a confidence meter and a "suggest only" mode.
- **Esc**, the toolbar AI badge, or "I've got it" in volunteer mode hands control back to the operator immediately.
- Scripture detection understands spoken forms like "turn with me to First Corinthians chapter thirteen, verse four through seven". Ambiguous book names like "Mark" or "Acts" need a cue word or a verse number. Detections appear in the Scripture tab with a **Display** button.

## Remote, stage display, Lightkey, calendar

- **Setup → Remote & MIDI** shows the URLs and a QR code. Phones and tablets on the same network open it in any browser.
- **Lightkey:** enable MIDI input from "Lumen" in Lightkey and MIDI-learn a cue using **Send Test Note**. Then add **Send MIDI** actions to macros or individual slides.
- **Calendar:** turn it on under **Setup → General**. Event notes like `lumen: macro Walk In` or `lumen: slide Announcements 1` fire when the event starts.

## Permissions the show Mac will ask for

Microphone and Speech Recognition (AI listening), Camera (capture inputs), Screen Recording (sending the web browser to outputs), Automation → Keynote (PowerPoint/Keynote import), Calendars (calendar triggers), and Local Network (remote and NDI).

## How this was tested

Automated (`xcodebuild test`, 114 tests): lyric/Bible/chord parsing and fuzzing (random and hostile input, run for hangs and crashes); the live engine under 3,000 random operations; Planning Center sync replaying a service shaped like a real plan; the remote server over real sockets with malformed requests; library damage and recovery; scheduling across daylight saving; the updater's safety paths with real signed apps (update, crash-on-launch rollback, wrong version/checksum/signer, read-only folder); pixel checks of the compositor; and every screen rendered with realistic data.

Soak (real app, three outputs at 60/30/15 fps, 1080p video loop behind the lyrics): 25 minutes and 10 minutes of randomized operator actions over the phone-remote API (slide changes, clears, looks, props, messages, timers, macros, the countdown video). No crashes or errors; memory held near 200 MB; open files and threads stayed flat; every output held its exact rate with 3 late frames out of ~90,000.

**Not tested here** (needs the real equipment): frames to a physical DeckLink card or over NDI (the bridges compile and link against the real vendor SDK headers and report honestly with no card installed), a second physical display, a real capture card or Apple TV input, MIDI into Lightkey, a Planning Center account (replayed from real-shaped data instead; use *Preview Next Service* the first time), and lyric following on real singing. See the Sunday checklist and do a test output on the real rig before the first service.

## Known limits in this version

- DeckLink and NDI code is written against the vendor SDKs but couldn't be compiled or tested on the development Mac, because neither SDK was installed. Expect a short shakedown on the show Mac.
- Theme backgrounds can be colors or images. For video backgrounds, use slide or media-layer video.
- The browser source is captured from its own window at 30 fps, so the window has to stay open (it can sit behind other windows).
- PowerPoint import goes through Keynote's renderer, so the slides arrive as images, not editable text.
