"""Local narrator studio worker. Requests arrive from the native application as JSON."""
from __future__ import annotations

import functools
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false")
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

RES = Path(os.environ.get("NARRATOR_RESOURCES", Path(__file__).resolve().parent))
HOME = Path(os.environ.get("NARRATOR_LIBRARY", Path.home() / "Library/Application Support/Narrator Studio"))
RATE = 24000
STYLES = {"Gentle": 4, "Balanced": 10, "Strong": 18}
LANGUAGES = {"english": "en", "chinese": "zh", "japanese": "ja", "korean": "ko",
             "german": "de", "french": "fr", "russian": "ru", "portuguese": "pt",
             "spanish": "es", "italian": "it"}


def event(message, **values):
    print("STUDIO " + json.dumps(dict(message=message, **values), ensure_ascii=False), flush=True)


def write_json(path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")


def ffmpeg(source, dest, options):
    import imageio_ffmpeg
    args = [imageio_ffmpeg.get_ffmpeg_exe(), "-nostdin", "-hide_banner", "-loglevel", "error",
            "-y", "-i", str(source), "-map", "0:a:0", "-vn", "-map_metadata", "-1", *options, str(dest)]
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise ValueError("Audio conversion failed. " + result.stderr.decode(errors="replace")[-600:])


def clean(source, dest, style, normalize):
    filters = ["highpass=f=55", f"afftdn=nr={STYLES[style]}:nf=-50:tn=1"]
    if normalize:
        filters.append("loudnorm=I=-16:TP=-1.5:LRA=9")
    ffmpeg(source, dest, ["-af", ",".join(filters), "-ar", "48000", "-c:a", "pcm_s24le"])


def at_rate(audio, old, new):
    if old == new:
        return np.ascontiguousarray(audio, dtype=np.float32)
    divisor = math.gcd(old, new)
    return resample_poly(audio, new // divisor, old // divisor).astype("float32")


@functools.lru_cache(1)
def recognizer():
    from faster_whisper import WhisperModel
    return WhisperModel(str(RES / "Models/Whisper"), device="cpu", compute_type="int8", cpu_threads=4)


def transcribe(audio, language=None, detailed=False):
    segments, info = recognizer().transcribe(at_rate(audio, RATE, 16000), language=language,
        beam_size=3, word_timestamps=detailed, condition_on_previous_text=False, vad_filter=detailed)
    return list(segments), info.language


@functools.lru_cache(1)
def verifier():
    import sherpa_onnx
    config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(RES / "Models/Speaker/wespeaker.onnx"),
                                                          num_threads=2, provider="cpu")
    return sherpa_onnx.SpeakerEmbeddingExtractor(config)


def unit(vector):
    vector = np.asarray(vector, dtype=np.float32)
    return vector / max(1.e-10, np.linalg.norm(vector))


def embedding(audio):
    if len(audio) > 24 * RATE:
        windows = np.array_split(audio, math.ceil(len(audio) / (18 * RATE)))
        return unit(np.mean([embedding(w) for w in windows], axis=0))
    model = verifier()
    stream = model.create_stream()
    stream.accept_waveform(sample_rate=16000, waveform=at_rate(audio, RATE, 16000))
    stream.input_finished()
    if not model.is_ready(stream):
        raise ValueError("This audio is too short to measure the voice.")
    return unit(model.compute(stream))


def excerpts(segments, length):
    """Partition spoken words into disjoint, sentence-aligned enrollment and test windows."""
    words = [w for seg in segments for w in (seg.words or [])
             if w.word.strip() and w.end > w.start and w.probability > 0.05]
    groups, current = [], []
    def finish():
        if current:
            t = "".join(w.word for w in current).strip()
            begin, end = current[0].start, current[-1].end
            if end - begin >= 2.3:
                groups.append(dict(start=begin, end=min(end, length), text=t,
                                   confidence=float(np.mean([w.probability for w in current]))))
            current.clear()
    for word in words:
        if current and (word.start - current[-1].end > 1.3 or word.end - current[0].start > 14):
            finish()
        current.append(word)
        if word.end - current[0].start >= 6.5 and re.search(r"[.!?。！？][’”\"]?$", word.word.strip()):
            finish()
    finish()
    return groups


def read_profile(identifier):
    path = HOME / "Profiles" / str(uuid.UUID(identifier))
    return path, json.loads((path / "profile.json").read_text())


def import_profile(req):
    src = Path(req["source"])
    folder = HOME / "Profiles"
    folder.mkdir(parents=True, exist_ok=True)
    identity = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix=".import-", dir=folder) as temp:
        root = Path(temp) / identity
        root.mkdir()
        original = "Original" + src.suffix.lower()
        shutil.copyfile(src, root / original)
        event("Finding speech in the recording…")
        analysis = root / "analysis.wav"
        ffmpeg(src, analysis, ["-t", "300", "-ac", "1", "-ar", str(RATE)])
        audio, _ = sf.read(analysis, dtype="float32")
        duration = len(audio) / RATE
        segments, language = transcribe(audio, detailed=True)
        candidates = excerpts(segments, duration)
        if not candidates:
            raise ValueError("Import a recording with at least three seconds of clear speech. You can also clean the file directly in Cleanup.")
        event("Selecting reference passages…")
        vectors = []
        for c in candidates:
            clip = audio[round(c["start"]*RATE):round(c["end"]*RATE)]
            vectors.append(embedding(clip))
        # Reserve later, disjoint passages for scoring. Never condition synthesis on those passages.
        count = len(candidates)
        split = max(1, int(count * 0.62))
        pool = list(range(split))
        # Use only enrollment passages to identify representative reference clips.
        center = unit(np.mean([vectors[i] for i in pool], axis=0))
        pool.sort(key=lambda i: float(center @ vectors[i]) + .12*candidates[i]["confidence"], reverse=True)
        refs = []
        for slot, i in enumerate(pool[:5]):
            c = dict(candidates[i], file=f"Reference-{slot+1}.wav")
            sf.write(root / c["file"], audio[round(c["start"]*RATE):round(c["end"]*RATE)], RATE)
            refs.append(c)
        reserve = list(range(split, count))
        # Keep a second independent audit set whenever the recording is long enough.
        validation = reserve[:max(1, len(reserve)//2)] or pool[:1]
        audit = reserve[len(validation):]
        checks = dict(validation=unit(np.mean([vectors[i] for i in validation], axis=0)).tolist(),
                      audit=unit(np.mean([vectors[i] for i in audit], axis=0)).tolist() if audit else None,
                      baseline=[float(vectors[i] @ unit(np.mean([vectors[j] for j in audit], axis=0))) for i in pool] if audit else [],
                      validationRanges=[candidates[i] for i in validation],
                      auditRanges=[candidates[i] for i in audit])
        write_json(root / "checks.json", checks)
        profile = dict(id=identity, name=req.get("name") or src.stem, original=original,
                       refs=refs, language=language, heldOut=bool(reserve), created=time.time())
        write_json(root / "profile.json", profile)
        analysis.unlink()
        root.rename(folder / identity)
    event("Voice added", profile=identity)


def split_script(text):
    """Prefer sentence and word boundaries, including scripts without spaces."""
    chunks, buf = [], ""
    for para in text.splitlines():
        for sentence in re.split(r"(?<=[.!?;])\s+|(?<=[。！？；])", para.strip()):
            while sentence:
                if len(buf) + len(sentence) + bool(buf) <= 240:
                    buf = (buf + " " + sentence).strip()
                    break
                if buf:
                    chunks.append(buf)
                    buf = ""
                elif len(sentence) > 240:
                    split = max(sentence.rfind(" ", 65, 240), sentence.rfind(",", 65, 240))
                    split = split + 1 if split > 0 else 240
                    chunks.append(sentence[:split].strip())
                    sentence = sentence[split:].strip()
        if buf:
            chunks.append(buf)
            buf = ""
    return [c for c in chunks if c]


NUMBER_WORDS = {word: str(number) for number, word in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split())}


def text_units(text):
    units = re.findall(r"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]|[^\W_\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]+",
                      text.casefold().replace("’", "").replace("'", ""))
    return [NUMBER_WORDS.get(unit, unit) for unit in units]


def error_rate(expected, heard):
    a, b = text_units(expected), text_units(heard)
    row = list(range(len(b)+1))
    for i, word in enumerate(a, 1):
        nxt = [i]
        for j, token in enumerate(b, 1):
            nxt.append(min(nxt[-1]+1, row[j]+1, row[j-1]+(word != token)))
        row = nxt
    return row[-1] / max(1, len(a))


def match_tone(audio, tone):
    if not tone or not tone["strength"]:
        return audio
    from scipy.signal import firwin2, oaconvolve
    gains = 10 ** (np.asarray(tone["db"]) * tone["strength"] / 20)
    impulse = firwin2(257, tone["hz"], gains, fs=RATE)
    shaped = oaconvolve(audio, impulse.astype("float32"), mode="same")
    return shaped * min(1, .98 / max(.001, np.max(np.abs(shaped))))


def finish_take(root, folder, req, path, extra):
    identity = root.name
    info = dict(id=identity, file=path.name, created=time.time(), kind=req["action"], **extra)
    write_json(root / "take.json", info)
    root.rename(folder / identity)
    event("Ready to play", take=identity)


def tidy_recording(audio, rate, script=None, language=None):
    import importlib.util
    spec = importlib.util.spec_from_file_location("speech_cleanup", Path(__file__).with_name("speech_cleanup.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    mono = audio if audio.ndim == 1 else audio.mean(axis=1)
    segments, info = recognizer().transcribe(at_rate(mono, rate, 16000), language=language,
        beam_size=3, word_timestamps=True, condition_on_previous_text=False,
        initial_prompt="Um, uh, uhh, erm, ugh." if language == "en" else None)
    words = [word for segment in segments for word in (segment.words or [])]
    return module.tidy(audio, rate, words, script, info.language == "en")


def cleaned_take(req, root, folder):
    src = Path(req["source"])
    path = root / "Cleaned audio.wav"
    event("Reducing noise and rendering the cleaned recording…")
    clean(src, path, req.get("style", "Balanced"), req.get("normalize", True))
    edits = []
    if req.get("tidy", True):
        event("Checking pauses and spoken hesitations…")
        audio, rate = sf.read(path, dtype="float32")
        audio, edits = tidy_recording(audio, rate, req.get("script"), req.get("spokenLanguage"))
        if edits:
            sf.write(path, audio, rate, subtype="PCM_24")
    finish_take(root, folder, req, path, dict(name=src.stem + " · Cleaned", speechEdits=edits))


@functools.lru_cache(1)
def voice_model(adapter=None):
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model
    mx.set_cache_limit(256 << 20)
    model = load_model(str(RES / "Models/Qwen"))
    if adapter:
        model.load_weights(str(adapter), strict=False)
        mx.eval(model.parameters())
    return model


def reuse_signature(profile_dir, profile, checks, language, attempts, adaptive):
    # Bind stored audio to the exact voice inputs, even after replacing a profile.
    digest = hashlib.sha256(json.dumps([profile, checks["validation"], language, attempts, adaptive, 2],
                                       sort_keys=True).encode())
    files = [profile_dir / ref["file"] for ref in profile["refs"]]
    adapter = profile.get("tuning", {}).get("adapter")
    if adapter:
        files.append(profile_dir / adapter)
    for path in files:
        stat = path.stat()
        digest.update(f"{stat.st_size}:{stat.st_mtime_ns}".encode())
    return digest.hexdigest()


def reusable_passages(folder, previous, signature):
    if not previous:
        return {}
    root = folder / str(uuid.UUID(previous))
    try:
        saved = json.loads((root / "take.json").read_text())
    except (OSError, ValueError):
        return {}
    if saved.get("reuseSignature") != signature:
        return {}
    groups = {}
    for i, passage in enumerate(saved.get("trials", [])):
        path = root / "Passages" / f"{i:04}.wav"
        if path.is_file() and passage.get("selected") and passage.get("text"):
            groups.setdefault(passage["text"], []).append((path, passage))
    return groups


def generate_passage(model, part, profile_dir, profile, checks, language, attempts, adaptive, index, total, base_seed):
    import mlx.core as mx
    prefs = profile.get("tuning", {})
    refs = profile["refs"]
    order = prefs.get("order", list(range(len(refs))))
    temperatures = prefs.get("temperatures", [.72, .85, .6])
    target = np.asarray(checks["validation"])
    winner = None
    tested = []
    # Stop on a stable high-quality result after three trials without a meaningful gain.
    last_gain = 0
    best_exact_score = -1.0
    for attempt in range(attempts):
        slot = order[attempt % len(order)]
        ref = refs[slot]
        temperature = temperatures[attempt % len(temperatures)]
        seed = (base_seed + index * 307 + attempt * 151) % 2**31
        mx.random.seed(seed)
        event(f"Passage {index+1} of {total} · Take {attempt+1} of {attempts}")
        result = list(model.generate(text=part, ref_audio=str(profile_dir/ref["file"]),
            ref_text=ref["text"], lang_code=language, temperature=temperature,
            max_tokens=min(1800, max(160, len(part)*6)), verbose=False))
        if not result:
            continue
        samples = np.concatenate([np.asarray(r.audio).reshape(-1) for r in result]).astype("float32")
        samples = at_rate(samples, int(result[0].sample_rate), RATE)
        if len(samples) < RATE * .35 or not np.isfinite(samples).all() or np.max(np.abs(samples)) < .001:
            continue
        # Rank the sound after the profile's tone correction, as heard in the final take.
        vector = embedding(match_tone(samples, prefs.get("tone")))
        score = float(target @ vector)
        record = dict(reference=slot, temperature=temperature, seed=seed, cosine=score)
        tested.append(record)
        # Once we have a word-perfect candidate, a lower-scoring candidate cannot win.
        if winner and winner[2]["errorRate"] == 0 and score <= winner[2]["cosine"]:
            if adaptive and attempt >= 3 and best_exact_score >= .92 and attempt - last_gain >= 2:
                break
            continue
        segments, _ = transcribe(samples, LANGUAGES.get(language))
        heard = " ".join(seg.text.strip() for seg in segments)
        wer = error_rate(part, heard)
        record.update(transcript=heard, errorRate=wer)
        rank = (wer == 0, wer <= .1, score - min(wer, 2)*.8)
        if winner is None or rank > winner[0]:
            winner = rank, samples, record
        if wer == 0 and score > best_exact_score + .01:
            last_gain = attempt
            best_exact_score = score
        if adaptive and attempt >= 3 and best_exact_score >= .92 and attempt - last_gain >= 2:
            break
        if wer == 0 and score >= (.95 if adaptive and checks.get("validationRanges") else .98):
            break
    if winner is None:
        raise ValueError("The model produced no usable speech. Try another reference passage.")
    return winner[1], dict(text=part, selected=winner[2], trials=tested)


def generated_take(req, root, folder):
    script = req["text"].strip()
    if req.get("preview"):
        first = next((line.strip() for line in script.splitlines() if line.strip()), "")
        script = re.split(r"(?<=[.!?])\s+|(?<=[。！？])", first, maxsplit=1)[0]
        script = next(iter(split_script(script)), "")
    parts = split_script(script)
    if not parts or not text_units(script):
        raise ValueError("Enter some words to narrate.")
    started = time.monotonic()
    profile_dir, profile = read_profile(req["profile"])
    checks = json.loads((profile_dir / "checks.json").read_text())
    language = req.get("language", "auto").lower()
    speed = max(.75, min(1.4, float(req.get("speed", 1))))
    gap = max(0., min(1.5, float(req.get("pause", .18))))
    attempts = min(15, max(1, int(req.get("attempts", 3))))
    adaptive = bool(req.get("adaptive", False))
    if req.get("preview"):
        attempts, adaptive = 1, False
    signature = reuse_signature(profile_dir, profile, checks, language, attempts, adaptive)
    previous = reusable_passages(folder, req.get("editTake"), signature)
    prefs = profile.get("tuning", {})
    adapter = profile_dir / prefs["adapter"] if prefs.get("adapter") else None
    model = None
    chosen, details = [], []
    reused = 0
    base_seed = int(req.get("seed", time.time_ns()))
    (root / "Passages").mkdir()
    for index, part in enumerate(parts):
        samples = None
        if previous.get(part):
            path, old = previous[part].pop(0)
            try:
                audio, rate = sf.read(path, dtype="float32")
                if rate == RATE and audio.ndim == 1 and len(audio) and np.isfinite(audio).all():
                    samples = audio
                    detail = dict(old, reused=True)
                    reused += 1
                    event(f"Reusing passage {index+1} of {len(parts)}")
            except (OSError, sf.LibsndfileError):
                pass
        if samples is None:
            if model is None:
                event("Loading the voice model…")
                model = voice_model(adapter)
            samples, detail = generate_passage(model, part, profile_dir, profile, checks, language,
                attempts, adaptive, index, len(parts), base_seed)
            original_samples = samples
            samples, edits = tidy_recording(samples, RATE, part, LANGUAGES.get(language))
            if edits:
                checked, _ = transcribe(samples, LANGUAGES.get(language))
                heard = " ".join(seg.text.strip() for seg in checked)
                if error_rate(part, heard) > detail["selected"]["errorRate"]:
                    # A timing boundary clipped speech. Keep the original selected performance.
                    samples = original_samples
                    edits = []
                else:
                    detail["selected"] = dict(detail["selected"], transcript=heard, errorRate=error_rate(part, heard))
            detail["speechEdits"] = edits
        sf.write(root / "Passages" / f"{index:04}.wav", samples, RATE, subtype="FLOAT")
        chosen.append(samples)
        details.append(detail)
    raw = root / "dry.wav"
    pause = np.zeros(round(RATE * gap), dtype="float32")
    joined = np.concatenate([arr for i,c in enumerate(chosen) for arr in ([pause,c] if i else [c])])
    sf.write(raw, match_tone(joined, prefs.get("tone")), RATE, subtype="PCM_24")
    path = root / "Narration.wav"
    ffmpeg(raw, path, ["-af", f"atempo={speed},alimiter=limit=0.96:level=false:latency=true",
                       "-ar", str(RATE), "-c:a", "pcm_s24le"])
    raw.unlink()
    rendered, _ = sf.read(path, dtype="float32")
    audit = checks.get("audit")
    vector = embedding(rendered)
    score = float(np.asarray(audit if audit is not None else checks["validation"]) @ vector)
    scope = "Independent test" if audit is not None else ("Held-out reference" if profile["heldOut"] else "Prompt reference")
    heard = " ".join(d["selected"]["transcript"] for d in details)
    name = ("Preview · " if req.get("preview") else "") + script[:60]
    finish_take(root, folder, req, path, dict(name=name, text=script, profile=profile["id"],
        profileName=profile["name"], score=score, scoreScope=scope, transcript=heard, preview=bool(req.get("preview")),
        errorRate=error_rate(script, heard), trials=details, speed=speed, pause=gap, language=language,
        attempts=attempts, adaptive=adaptive, reuseSignature=signature, reused=reused,
        renderSeconds=round(time.monotonic()-started,2)))


def captions(source, destination, language):
    event("Timing captions to the finished recording…")
    import av
    with av.open(str(source)) as container:
        audio = []
        resampler = av.AudioResampler(format="s16", layout="mono", rate=16000)
        for frame in container.decode(audio=0):
            frame.pts = None
            audio.extend(f.to_ndarray().ravel() for f in resampler.resample(frame))
        audio.extend(f.to_ndarray().ravel() for f in resampler.resample(None))
    if not audio:
        raise ValueError("No audio was available for captions.")
    wave = np.concatenate(audio).astype("float32") / 32768
    segments, _ = recognizer().transcribe(wave, language=LANGUAGES.get(language), word_timestamps=True,
        beam_size=3, vad_filter=True, condition_on_previous_text=False)
    cues, group = [], []
    def finish():
        if group:
            cues.append((group[0].start, group[-1].end, "".join(w.word for w in group).strip()))
            group.clear()
    for seg in segments:
        for word in seg.words or []:
            if not word.word.strip() or word.end <= word.start:
                continue
            if group and (word.start-group[-1].end > .55 or word.end-group[0].start > 2.8
                          or sum(len(w.word) for w in group)+len(word.word) > 38):
                finish()
            group.append(word)
            if re.search(r"[.!?。！？]$", word.word.strip()):
                finish()
        finish()
    if not cues:
        raise ValueError("No spoken words were detected for captions.")
    def stamp(ms):
        h, rest = divmod(ms, 3600000)
        m, rest = divmod(rest, 60000)
        sec, ms = divmod(rest, 1000)
        return f"{h:02}:{m:02}:{sec:02},{ms:03}"
    rows, last = [], 0
    for n,(begin,end,words) in enumerate(cues,1):
        first = max(last, round(1000*begin))
        last = max(first+1,round(1000*end))
        rows.append(f"{n}\n{stamp(first)} --> {stamp(last)}\n{words}\n")
    destination.write_text("\n".join(rows), encoding="utf-8")


def run(req):
    action = req["action"]
    if action == "import":
        return import_profile(req)
    if action == "export":
        src, dest = Path(req["source"]), Path(req["destination"])
        fmt = dest.suffix.lower()
        options = {".wav": ["-c:a","pcm_s24le"], ".mp3": ["-c:a","libmp3lame","-q:a","2"],
                   ".m4a": ["-c:a","aac","-b:a","192k"]}
        with tempfile.TemporaryDirectory(prefix=".studio-", dir=dest.parent) as tmp:
            converted = Path(tmp)/("take" + fmt)
            if fmt == ".srt":
                captions(src, converted, req.get("language", "auto"))
            else:
                ffmpeg(src, converted, options[fmt])
            os.replace(converted, dest)
        return event("Captions exported" if fmt == ".srt" else "Audio exported")
    if action not in ("clean","generate"):
        raise ValueError("Unknown operation")
    folder = HOME / "Takes"
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".render-", dir=folder) as temp:
        root = Path(temp) / str(uuid.uuid4())
        root.mkdir()
        (generated_take if action == "generate" else cleaned_take)(req, root, folder)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(130))
    try:
        run(json.loads(Path(sys.argv[1]).read_text()))
    except Exception as exc:
        import traceback
        traceback.print_exc()
        event(str(exc) or type(exc).__name__, error=True)
        sys.exit(1)
