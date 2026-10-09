# Lumen

A native macOS presentation and show-control app for church services, built in Swift, SwiftUI and Core Image/Metal.

## Install

Download `Lumen-<version>.dmg` from the GitHub release, open it, and drag Lumen to Applications. The app is signed with the Hope Church Developer ID but not yet notarized. The first time, right-click Lumen.app and choose **Open**, then confirm (or go to System Settings → Privacy & Security → Open Anyway).

To build a DMG yourself, run `Scripts/make_dmg.sh`. It writes `dist/Lumen-<version>.dmg`, and notarizes it automatically if a `lumen-notary` notarytool profile is saved on the Mac (see the comment at the top of the script).

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

If you use SDK 15 or later, the frame-buffer access path is selected by `BLACKMAGIC_DECKLINK_API_VERSION` in `LMDeckLink.mm`. That's the one place to adjust if Blackmagic changes the API again.

## NDI

1. Install the **NDI SDK for Apple** (headers go to `/Library/NDI SDK for Apple/include`, which is already on the header search path). You can instead copy the headers to `Vendor/NDISDK/include`.
2. Install **NDI Tools** on the show Mac (it provides `libndi.dylib`). Lumen loads the library at run time, so the app still launches on Macs without NDI.
3. Add an **NDI** output to any screen. It's sent as BGRA with alpha, so vMix, OBS and TriCaster get keyed lower thirds without a separate key feed. NDI **inputs** are under **Media → NDI sources**.

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

## Known limits in this version

- DeckLink and NDI code is written against the vendor SDKs but couldn't be compiled or tested on the development Mac, because neither SDK was installed. Expect a short shakedown on the show Mac.
- Theme backgrounds can be colors or images. For video backgrounds, use slide or media-layer video.
- The browser source is captured from its own window at 30 fps, so the window has to stay open (it can sit behind other windows).
- PowerPoint import goes through Keynote's renderer, so the slides arrive as images, not editable text.
