# /// script
# requires-python = ">=3.10"
# dependencies = ["onnx-asr[cpu]", "numpy", "transcribe-cpp==0.3.1", "transcribe-cpp-native==0.3.1", "huggingface-hub"]
# ///
"""Transcribe audio files on-device with Parakeet or Canary speech models.

usage: uv run transcribe.py [--model ID] file.mp3 [more files...]   -> writes file.txt next to each
       uv run transcribe.py --list                 -> JSON {"installed": [ids], "available": [names]}
       uv run transcribe.py --download NAME        -> fetch a model from Hugging Face (see CATALOG)

Models are picked up from Handy (https://handy.computer) if it's installed, or from the Hugging Face
cache, which is where --download puts them (and where Handy keeps its GGUF models too).
ONNX models (Parakeet) run via onnx-asr; GGUF models (Canary etc.) via transcribe.cpp, Handy's engine.
Default model is the first one found (see --list).

Prints tab-separated progress lines (read by Transcriber.app), file index first:
  START i | PROGRESS i sec_done sec_total words | DONE i | ERR i message
"""
import json, os, subprocess, sys, tempfile, wave
from pathlib import Path

HANDY = Path.home() / "Library/Application Support/com.pais.handy"
HF_CACHE = Path.home() / ".cache/huggingface/hub"
SR = 16000
# ponytail: fixed 30s chunks (Canary drops words past ~30s) can split a word at the boundary; switch to VAD-based splits if that bites
CHUNK = 30 * SR
# name -> (Hugging Face repo, files). Same files Handy downloads.
CATALOG = {
    "parakeet-v3": ("istupakov/parakeet-tdt-0.6b-v3-onnx",
                    ["config.json", "vocab.txt", "nemo128.onnx", "encoder-model.int8.onnx", "decoder_joint-model.int8.onnx"]),
    "canary-180m-flash": ("handy-computer/canary-180m-flash-gguf", ["canary-180m-flash-Q8_0.gguf"]),
}
THREADS = max(1, (os.cpu_count() or 2) // 2)  # leave half the Mac free


def installed_models():
    """{id: path}"""
    models = {d.name: d for d in sorted((HANDY / "models").glob("*/")) if (d / "config.json").exists()}
    for f in sorted(HF_CACHE.glob("models--*/snapshots/*/*")):
        repo = f.parts[-4].removeprefix("models--").replace("--", "/")
        if f.suffix == ".gguf" and repo.startswith("handy-computer/"):
            models[f"{repo}/{f.name}"] = f
        elif f.name == "config.json" and any(f.parent.glob("*.onnx")):
            models[repo] = f.parent
    return models


def available(models):
    """CATALOG names with no installed copy (from Handy or a previous --download)."""
    def stem(name): return CATALOG[name][0].split("/")[1].removesuffix("-onnx").removesuffix("-gguf")
    return [n for n in CATALOG if not any(stem(n) in m for m in models)]


def download(name):
    from huggingface_hub import snapshot_download
    if name not in CATALOG:
        sys.exit(f"Unknown model {name!r}. Choose from: {', '.join(CATALOG)}")
    repo, files = CATALOG[name]
    snapshot_download(repo, allow_patterns=files, cache_dir=HF_CACHE)
    print(f"Downloaded {name}")


def load_model(path):
    """Returns recognize(float32 16 kHz mono chunk) -> str."""
    if path.suffix == ".gguf":
        import transcribe_cpp
        session = transcribe_cpp.Model(path).session(n_threads=THREADS)
        return lambda audio: session.run(audio).text  # ponytail: language left on auto/English; Canary also does de/es/fr

    import onnx_asr, onnxruntime as rt
    # Plain CPU: the default CoreML backend split Parakeet into ~300 pieces, crawled, and lagged the Mac.
    opts = rt.SessionOptions()
    opts.intra_op_num_threads = THREADS
    model_type = json.loads((path / "config.json").read_text())["model_type"]
    quant = "int8" if any(path.glob("*.int8.onnx")) else None
    model = onnx_asr.load_model(model_type, path, quantization=quant, sess_options=opts,
                                providers=["CPUExecutionProvider"])
    return lambda audio: model.recognize(audio, sample_rate=SR)


def emit(*parts):
    print("\t".join(map(str, parts)), flush=True)


def load_audio(path):
    import numpy as np
    # afconvert ships with macOS: decodes mp3/m4a/wav/aiff to 16 kHz mono 16-bit wav
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        r = subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{SR}", "-c", "1", str(path), tmp.name],
                           capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError("not a readable audio file")
        with wave.open(tmp.name) as w:
            return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768


def main(args):
    models = installed_models()
    if args[:1] == ["--list"]:
        print(json.dumps({"installed": list(models), "available": available(models)}))
        return
    if args[:1] == ["--download"] and len(args) == 2:
        return download(args[1])
    model_id, files = (args[1], args[2:]) if args[:1] == ["--model"] else (next(iter(models), None), args)
    if not models:
        sys.exit(f"No models found. Download one: uv run transcribe.py --download {next(iter(CATALOG))}")
    if model_id not in models:
        sys.exit(f"Model not installed: {model_id}")

    os.nice(10)
    recognize = load_model(models[model_id])
    for i, f in enumerate(map(Path, files)):
        emit("START", i)
        try:
            audio = load_audio(f)
            total, parts, words = len(audio) / SR, [], 0
            for start in range(0, len(audio), CHUNK):
                parts.append(recognize(audio[start:start + CHUNK]).strip())
                words += len(parts[-1].split())
                emit("PROGRESS", i, round(min(start + CHUNK, len(audio)) / SR, 2), round(total, 2), words)
            f.with_suffix(".txt").write_text(" ".join(parts).strip() + "\n")
            emit("DONE", i)
        except Exception as e:  # one bad file shouldn't sink the batch
            emit("ERR", i, str(e).replace("\n", " ") or type(e).__name__)


if __name__ == "__main__":
    main(sys.argv[1:])
