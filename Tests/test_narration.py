import unittest
from types import SimpleNamespace

import numpy as np

from Sources.speech_cleanup import tidy
from Sources.studio import split_script


class NarrationTests(unittest.TestCase):
    def test_passage_limit(self):
        for size in (239, 240, 241, 480):
            script = "文" * size
            chunks = split_script(script)
            self.assertEqual("".join(chunks), script)
            self.assertTrue(all(0 < len(chunk) <= 240 for chunk in chunks))

    def test_long_pause(self):
        tone = np.ones(4800, dtype=np.float32) * .1
        audio = np.concatenate([tone, np.zeros(24000), tone])
        result, edits = tidy(audio, 24000, [])
        self.assertEqual([edit["kind"] for edit in edits], ["pause"])
        self.assertEqual(len(result), 2 * len(tone) + 5760)

    def test_scripted_hesitation(self):
        word = SimpleNamespace(word="um", start=.1, end=.4, probability=.95)
        audio = np.full(12000, .1, dtype=np.float32)
        kept, edits = tidy(audio, 24000, [word], "Um.")
        self.assertEqual(edits, [])
        np.testing.assert_array_equal(kept, audio)
        _, edits = tidy(audio, 24000, [word])
        self.assertEqual([edit["kind"] for edit in edits], ["filler"])
