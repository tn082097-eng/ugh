# G2 Mic

Use the microphones on your **Even Realities G2** glasses with your iPhone, instead of the phone's own mic.

## What it does

- **Dictate in any app.** The "G2 Mic" keyboard has a mic button. Tap it, talk, and tap again. The text goes into whatever you were typing in: Messages, Notes, email, search boxes.
- **Dictate in the app.** Talk, stop, and the text is copied, ready to paste.
- **Voice memos.** Record audio from the glasses as WAV files. You can share them or find them in the Files app.

Everything is recognized on the iPhone itself, and the phone's microphone is never used.

## What it can't do (an iOS limit, not a bug)

iOS only lets the system use microphones that it recognizes as audio devices: the built-in mic, wired or USB mics, and Bluetooth *headsets* such as AirPods. The G2 connects over Bluetooth Low Energy as a *data* device, and iOS doesn't let any app add a new system microphone. So **phone calls, FaceTime, Siri, and voice recording inside other apps keep using the phone mic.** The only way around that is extra hardware that pretends to be a headset. See "Future" below.

## Install it on your iPhone

You need a Mac with Xcode 16 or newer and an Apple ID. A free account works, but the app stops opening after 7 days until you reinstall it. A paid developer account ($99 a year) lasts a year.

1. On the Mac:
   ```sh
   brew install xcodegen
   cd g2mic
   ```
2. Open `project.yml` and change two lines:
   - `BUNDLE_PREFIX`: something unique to you, e.g. `com.yourname.g2mic`
   - `DEVELOPMENT_TEAM`: your Team ID (Xcode › Settings › Accounts › your Apple ID › Team ID)
3. Generate the project, then open it:
   ```sh
   xcodegen generate
   open G2Mic.xcodeproj
   ```
4. Plug in your iPhone, choose it as the run destination, and press ▶︎ Run. If the iPhone asks, turn on Developer Mode (Settings › Privacy & Security) and trust your developer profile (Settings › General › VPN & Device Management).

## Set it up

1. Open **G2 Mic**, allow Bluetooth, and wear the glasses. It finds and connects to both arms by itself.
2. Tap **Dictate with glasses mic** and allow Speech Recognition when asked.
3. For the keyboard: Settings › General › Keyboard › Keyboards › Add New Keyboard › **G2 Mic**. Then tap it and turn on **Allow Full Access**. The keyboard needs that to talk to the app. It doesn't send anything anywhere.
4. In any app, hold 🌐 to switch to G2 Mic and tap the mic.

If the app isn't running, the keyboard opens it to start listening. Swipe back to the app you were typing in. While "Stay ready in background" is on (30 minutes by default), the keyboard starts the mic instantly, with no app switch.

## Tips and troubleshooting

- **Quiet or too loud?** Adjust *Mic boost* in Settings. The green bar shows the input level.
- **"Glasses not found"**: make sure the glasses are on and in range. The Even app can stay installed, but if the two apps seem to fight over the glasses, close the Even app while dictating.
- **"No audio from glasses"**: the app re-arms the mic by itself after a few seconds. The connection log at the bottom of the main screen shows what happened.
- The glasses show a small "G2 Mic · listening" card while the mic is on. It disappears about 10 seconds after you stop.

## How it works

```
G2 left arm ──BLE notify (LC3 audio, 205-byte packets)──┐
G2 right arm ◀─BLE write (commands) / notify (replies)──┤
                                                        ▼
            GlassesLink (CoreBluetooth) ─▶ G2AudioDecoder (liblc3) ─▶ 16 kHz PCM
                                                        │
                    ┌───────────────────────────────────┼─────────────────┐
                    ▼                                   ▼                 ▼
         Apple Speech (on-device)                 WAV recorder      level meter
                    │
      App Group + Darwin notifications
                    ▼
         G2 Mic keyboard ─▶ inserts text into the current app
```

- `Packages/G2Core`: platform-independent protocol code with unit tests. It covers framing, CRC, protobuf messages, and the audio packet format, plus Google's [liblc3](https://github.com/google/liblc3) (Apache-2.0) for decoding.
- `App/`: the iPhone app, which handles Bluetooth, speech, recording, and the UI.
- `Keyboard/`: the keyboard extension.
- `Shared/`: code that lets the app and keyboard talk to each other.

The G2 Bluetooth protocol isn't officially documented. This app uses the community's reverse-engineered notes from [g2-kit](https://github.com/Commute773/g2-kit), which were verified on real glasses, and [even-g2-protocol](https://github.com/i-soxi/even-g2-protocol). Even Realities doesn't endorse either project. A firmware update could change the protocol. If that happens, the connection log should show where it stopped.

### Steps in the conversation with the glasses

1. Connect both arms. Subscribe to `…5402` (replies) and `…6402` (audio).
2. Send the app-launch prelude to the right arm (a captured byte sequence that the glasses acknowledge).
3. Create a small page on the lens (EvenHub Cmd 0). The mic needs an active page.
4. Send a heartbeat (Cmd 12) every 5 seconds. Without one, the glasses drop the page and the mic about 10 seconds later.
5. Send AudioControl (Cmd 15) to turn the mic on. Audio then arrives as 205-byte packets: five 40-byte LC3 frames (10 ms each, 16 kHz, mono) plus a counter byte.

## Future ideas

- **Calls and Siri through the G2:** a small Bluetooth bridge (for example, an ESP32) that receives the G2's audio and shows up on the iPhone as a headset. It needs earbuds plugged into the bridge, because the G2 has no speakers.
- Show the live transcript on the glasses' display.
- An Action Button / Shortcuts action for "dictate with G2".
