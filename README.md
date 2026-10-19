<p align="center"><img src="Transcriber/icons/0-current/preview.png" width="160" alt="Transcriber icon"></p>

# Transcriber

A small Mac app that turns audio files into text transcripts, entirely on-device. Nothing gets uploaded.

Drop mp3, m4a or wav files on the window (or the Dock icon), and a `.txt` transcript is saved
next to each one. Progress is shown per file and for the whole batch: percent done, audio time
processed, word count, elapsed time, time remaining, and speed compared with realtime.

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

## Requirements

- macOS 14+ (Apple Silicon)
- [uv](https://docs.astral.sh/uv/) (`brew install uv`). It installs the Python dependencies on first run.
- Xcode or the Command Line Tools, to build

## Build & install

```bash
./build.sh
```

This builds `Transcriber.app`, signs it for local use, and installs it to `~/Applications`.

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
