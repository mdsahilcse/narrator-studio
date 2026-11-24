"""Conservative, sample-rate independent edits for finished speech."""
from difflib import SequenceMatcher
import re
import numpy as np

FILLER = re.compile(r"(?:u+h+|u+m+|e+r+m*|u+g+h+|h+m{2,})$")


def tokens(text):
    return re.findall(r"[^\W_]+", text.casefold().replace("’", "").replace("'", ""))


def runs(mask):
    edges = np.flatnonzero(np.diff(np.r_[False, mask, False].astype(int)))
    return zip(edges[::2], edges[1::2])


def sustained_voice(samples, rate):
    """Require stable periodic energy across several frames of an isolated sound."""
    from scipy.signal import correlate
    window = int(.04 * rate)
    pitches = []
    for offset in range(0, len(samples)-window+1, window//2):
        frame = samples[offset:offset+window].astype(float)
        frame -= np.mean(frame)
        corr = correlate(frame, frame, mode="full", method="fft")[window-1:]
        lo, hi = rate//420, rate//75
        lag = lo + int(np.argmax(corr[lo:hi]))
        if corr[lag] > .60 * max(corr[0], 1e-9):
            pitches.append(rate/lag)
    return len(pitches) >= max(4, .65*(len(samples)/(.02*rate)-1)) and np.std(pitches)/np.mean(pitches) < .14


def tidy(audio, rate, words, script=None, english=True):
    mono = audio if audio.ndim == 1 else np.mean(audio, axis=1)
    hop = max(1,round(rate*.01))
    n = len(mono)//hop
    if n < 3:
        return audio, []
    frames = mono[:n*hop].reshape(n,hop)
    levels = np.sqrt(np.mean(frames*frames,axis=1))
    gate = np.clip(np.percentile(levels,90)*.035, .001, .008)
    edits = []
    # Keep the quiet edges beside words. Shorten only the middle of a long gap.
    for a,b in runs(levels < gate):
        edge = a == 0 or b == n
        if b-a >= (32 if edge else 55) and b-a < n:
            lo = a if a == 0 else a+12
            hi = b if b == n else b-12
            edits.append((lo*hop,hi*hop,"pause"))
    words = [w for w in words if tokens(w.word) and w.end > w.start]
    expected = tokens(script or "")
    spoken = [t for w in words for t in tokens(w.word)]
    positions = []
    pos = 0
    for w in words:
        length = len(tokens(w.word))
        positions.append((pos,pos+length-1))
        pos += length
    aligned = {}
    if script:
        for a,b,length in SequenceMatcher(None,spoken,expected,autojunk=False).get_matching_blocks():
            aligned.update((a+i,b+i) for i in range(length))
    for i,w in enumerate(words):
        first,last = positions[i]
        if not english or not FILLER.fullmatch("".join(tokens(w.word))):
            continue
        if first in aligned or not .09 <= w.end-w.start <= 1.25:
            continue
        begin = max(w.start,words[i-1].end+.012 if i else 0)
        end = min(w.end,words[i+1].start-.012 if i+1<len(words) else len(mono)/rate)
        # Word timestamps can lead the actual vowel. Two aligned neighboring
        # script words plus a single isolated sound corroborate a low-confidence label.
        before = aligned.get(positions[i-1][1]) if i else -1
        after = aligned.get(positions[i+1][0]) if i+1 < len(words) else len(expected)
        anchored = bool(expected) and before is not None and after == before+1
        lo = max(0,round(((words[i-1].end+.025) if i else 0)*rate/hop))
        hi = min(n,round(((words[i+1].start-.025) if i+1<len(words) else len(mono)/rate)*rate/hop))
        from scipy.ndimage import binary_closing
        active = binary_closing(levels[lo:hi] > gate*1.6,structure=np.ones(4))
        islands = [(lo+a,lo+b) for a,b in runs(active) if .08 <= (b-a)*hop/rate <= 1.25
                   and a >= 4 and len(active)-b >= 4 and
                   min((lo+b)*hop/rate,w.end)-max((lo+a)*hop/rate,w.start) >= .055]
        if len(islands) == 1:
            a,b = islands[0]
            begin,end = (a-1)*hop/rate,(b+1)*hop/rate
        if w.probability < .60 and not (anchored and len(islands)==1 and w.probability >= .20):
            continue
        if end-begin >= .08:
            edits.append((round(begin*rate),round(end*rate),"filler"))
    # A recognizer may omit a hesitation entirely. Only inspect gaps bounded by
    # two words that are also adjacent in the intended script.
    gaps = []
    if words and aligned.get(positions[0][0]) == 0:
        gaps.append((0., words[0].start))
    if words and expected and aligned.get(positions[-1][1]) == len(expected)-1:
        gaps.append((words[-1].end,len(mono)/rate))
    for i,(left,right) in enumerate(zip(words,words[1:])):
        l = aligned.get(positions[i][1]); r = aligned.get(positions[i+1][0])
        if l is not None and r == l+1:
            gaps.append((left.end,right.start))
    for left_end,right_start in gaps:
        if not english or right_start-left_end < .32:
            continue
        start = max(0,round((left_end+.045)*rate/hop))
        stop = min(n,round((right_start-.045)*rate/hop))
        active = levels[start:stop] > gate*1.8
        for a,b in runs(active):
            if a < 3 or len(active)-b < 3 or not 12 <= b-a <= 70:
                continue
            lo,hi = (start+a)*hop,(start+b)*hop
            if sustained_voice(mono[lo:hi],rate):
                edits.append((lo-hop,hi+hop,"isolated vocalization"))
    merged = []
    for lo,hi,kind in sorted(edits):
        lo,hi = max(0,lo),min(len(audio),hi)
        if lo>=hi: continue
        if merged and lo<=merged[-1][1]:
            merged[-1][1]=max(hi,merged[-1][1])
        else:
            merged.append([lo,hi,kind])
    if not merged: return audio, []
    pieces=[]; cursor=0
    for lo,hi,kind in merged:
        pieces.append(audio[cursor:lo].copy()); cursor=hi
    pieces.append(audio[cursor:].copy())
    for i,piece in enumerate(pieces):
        length=min(len(piece)//2,round(rate*.005))
        if length:
            ramp=np.linspace(0,1,length,dtype="float32").reshape((-1,)+(1,)*(piece.ndim-1))
            if i: piece[:length]*=ramp
            if i+1<len(pieces): piece[-length:]*=ramp[::-1]
    return np.concatenate(pieces), [dict(start=a/rate,end=b/rate,kind=k) for a,b,k in merged]
