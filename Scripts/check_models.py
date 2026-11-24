import hashlib
import sys
from pathlib import Path

checks = {
    "Qwen/model.safetensors": "b965c581ccf6aa852a4124feeb7a8a111542ee7b213139368b4cc7ba7fd4728b",
    "Qwen/speech_tokenizer/model.safetensors": "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258",
    "Whisper/model.bin": "d01c3014881c9c6f3133c182f3d2887eb6ca1c789a7538c5c007196857a0a6a9",
    "Speaker/wespeaker.onnx": "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012",
}
root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".build/Models")
for name, expected in checks.items():
    digest = hashlib.sha256()
    with (root / name).open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        raise SystemExit("Checksum failed for " + name)
    print("Verified", name)
