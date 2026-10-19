# /// script
# requires-python = ">=3.10"
# dependencies = ["onnx-asr[cpu]", "numpy", "transcribe-cpp==0.3.1", "transcribe-cpp-native==0.3.1"]
# ///
"""Transcribe audio files with the models Handy already downloaded.

usage: uv run transcribe.py [--model ID] file.mp3 [more files...]   -> writes file.txt next to each
       uv run transcribe.py --list                                   -> JSON list of installed models

Models: ONNX folders in Handy's models dir (Parakeet, via onnx-asr) and GGUF files Handy pulled
into the Hugging Face cache (Canary etc., via transcribe.cpp, the engine Handy itself uses).
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
THREADS = max(1, (os.cpu_count() or 2) // 2)  # leave half the Mac free


def installed_models():
    """{id: path}"""
    models = {d.name: d for d in sorted((HANDY / "models").glob("*/")) if (d / "config.json").exists()}
    for f in sorted(HF_CACHE.glob("models--handy-computer--*/snapshots/*/*.gguf")):
        repo = f.parts[-4].removeprefix("models--").replace("--", "/")
        models[f"{repo}/{f.name}"] = f
    return models


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
        print(json.dumps(list(models)))
        return
    model_id, files = (args[1], args[2:]) if args[:1] == ["--model"] else (next(iter(models), None), args)
    if not models:
        sys.exit("No Handy models found. Download one in Handy first.")
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
