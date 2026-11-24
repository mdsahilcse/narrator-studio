"""Fetch the portable arm64 runtime and the three pinned offline model snapshots."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / ".build"
build.mkdir(exist_ok=True)
runtime = "https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.11.18%2B20261110-aarch64-apple-darwin-install_only_stripped.tar.gz"
models = [
    ("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", "e7dd0585652209fa0d7783659aad4e8a324de11c", "Qwen", [
        "README.md","config.json","generation_config.json","merges.txt","model.safetensors",
        "model.safetensors.index.json","preprocessor_config.json","speech_tokenizer/config.json",
        "speech_tokenizer/configuration.json","speech_tokenizer/model.safetensors",
        "speech_tokenizer/preprocessor_config.json","tokenizer_config.json","vocab.json"]),
    ("Systran/faster-whisper-base","ebe41f70d5b6dfa9166e2c581c45c9c0cfc57b66","Whisper",[
        "README.md","config.json","model.bin","tokenizer.json","vocabulary.txt"]),
    ("csukuangfj/speaker-embedding-models","a8055d6daef723a6a4ecf4de233708575bf4994f","Speaker",[
        "wespeaker_en_voxceleb_resnet34_LM.onnx"]),
]


def fetch(item):
    url, dest = item
    if dest.is_file():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    temp = dest.with_name(dest.name + ".download")
    subprocess.run(["curl","-fLsS","--retry","4","-o",str(temp),url],check=True)
    temp.replace(dest)


if not (build/"python/bin/python3").exists():
    fetch((runtime, build/"python.tar.gz"))
    subprocess.run(["tar","-xf",str(build/"python.tar.gz"),"-C",str(build)],check=True)
subprocess.run([str(build/"python/bin/python3"),"-m","pip","install","--no-compile","-r",str(root/"Scripts/requirements.lock")],check=True)
shutil.copyfile(root/"Scripts/requirements.lock",build/"requirements.lock")
jobs = []
for repo, revision, folder, files in models:
    for f in files:
        name = "wespeaker.onnx" if folder == "Speaker" else f
        jobs.append((f"https://huggingface.co/{repo}/resolve/{revision}/{f}", build/"Models"/folder/name))
with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(fetch,jobs))
subprocess.run(["python3","Scripts/check_models.py"],cwd=root,check=True)
