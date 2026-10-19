<p align="center"><img src="Transcriber/icons/0-current/preview.png" width="160" alt="Transcriber icon"></p>

# Transcriber

A small Mac app that turns audio files into text transcripts, entirely on-device. Nothing gets uploaded.

Drop mp3, m4a or wav files on the window (or the Dock icon), and a `.txt` transcript is saved
next to each one. Progress is shown per file and for the whole batch: percent done, audio time
processed, word count, elapsed time, time remaining, and speed compared with realtime.

## Install

1. Install [uv](https://docs.astral.sh/uv/), which runs the transcription engine:
   ```bash
   brew install uv
   ```
2. Download `Transcriber.zip` from the [latest release](https://github.com/mukiprojects/Transcriber/releases/latest),
   unzip it, and drag `Transcriber.app` into your Applications folder.
3. Open it. The first time, macOS will block it (see below).
4. Download a model from the app's start screen (Parakeet V3 is the most accurate). The first
   transcription takes a minute longer while uv sets up the Python packages.

Requires macOS 14+ on Apple Silicon.

### "Transcriber can't be opened" / "Apple could not verify…"

The app isn't signed with a paid Apple Developer account, so macOS blocks it the first time you
open it. The code is all here if you'd like to check it, or [build it yourself](#build-from-source).
To allow it, do this once:

- **macOS 15 and later:** open the app and dismiss the warning. Then go to **System Settings →
  Privacy & Security**, scroll down to the message about Transcriber, click **Open Anyway**, and
  confirm with your password.
- **macOS 14:** right-click (or Control-click) `Transcriber.app` in Finder, choose **Open**, then
  click **Open** in the dialog.
- **Or, in Terminal** (any version), clear the download flag:
  ```bash
  xattr -dr com.apple.quarantine /Applications/Transcriber.app
  ```

After that it opens normally.

## Models

| Model | Engine | Speed (5 min audio, M3) | Notes |
|---|---|---|---|
| Parakeet V3 | [onnx-asr](https://github.com/istupakov/onnx-asr), CPU | ~12 s | Most accurate, 25 languages, ~670 MB |
| Canary 180M Flash | [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), Metal | ~8 s | Lighter (~430 MB RAM), en/de/es/fr, ~220 MB |

There are two ways to get the models. Use whichever suits you:

- **Download them in Transcriber.** On first launch the window offers a download button for each
  model, and later you can use the **Download Models** menu in the toolbar. Or from the terminal:
  ```bash
  uv run transcribe.py --download parakeet-v3
  uv run transcribe.py --download canary-180m-flash
  ```
  Models come from Hugging Face ([Parakeet](https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx),
  [Canary](https://huggingface.co/handy-computer/canary-180m-flash-gguf)) and are stored in
  `~/.cache/huggingface/hub`.
- **Already use [Handy](https://handy.computer)?** Any model you've downloaded in Handy shows up
  automatically, so there's nothing to download twice.

Pick the model from the toolbar. Transcription uses half the CPU cores at low priority, so
your Mac stays responsive.

## Build from source

You'll need Xcode or the Command Line Tools, plus uv.

```bash
./build.sh
```

This builds `Transcriber.app`, signs it for local use, and installs it to `~/Applications`.
An app you build yourself doesn't get the macOS warning.

## Command line

The app is a thin SwiftUI wrapper around `transcribe.py`, which also works on its own:

```bash
uv run transcribe.py --list                                   # installed + downloadable models
uv run transcribe.py --download parakeet-v3                   # fetch a model
uv run transcribe.py a.mp3 b.m4a                              # transcribe with the first installed model
uv run transcribe.py --model <id from --list> a.mp3           # pick a model
```

## Layout

```
transcribe.py                         model discovery, download, and transcription (progress on stdout)
Transcriber/Sources/Transcriber/      SwiftUI app
Transcriber/AppIcon.icns, icon.svg    app icon
Transcriber/icons/                    icon explorations
build.sh                              build + bundle + install
```

## Credits

Built on the work of [Handy](https://handy.computer) by [@cjpais](https://github.com/cjpais),
including its [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) engine and model
conversions. Also uses [onnx-asr](https://github.com/istupakov/onnx-asr), and NVIDIA's Parakeet and
Canary models (CC-BY-4.0).

## License

[MIT](LICENSE)
