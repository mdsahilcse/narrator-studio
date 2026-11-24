# Narrator Studio
An offline Apple Silicon macOS app for reference-based narration, voice cleanup, and timed captions. Import a recording of your own voice or one you have permission to use. Voice profiles and generated takes are stored in the current user's Application Support directory.

## Build
On macOS 26 or later with Apple command-line developer tools and Python 3 installed, run from the repository root:

    python3 Scripts/prepare.py
    bash Scripts/package.sh

Preparation downloads the runtime and model weights. The disk image is written to dist. Open the app and choose **Import voice** to get started. See Assets/Notices.txt for model attribution.

## Working with a recording

Choose **Import Voice** and select clear speech recorded with the speaker's permission. Paste a script in **Voiceover** and preview the first passage. Smart match compares candidate takes using a transcript and a speaker embedding. The similarity score measures agreement between embeddings and has no calibrated conversion to a percentage of perceived likeness.

In **Cleanup**, choose a recording or video. Supply the intended script to help preserve deliberate English hesitations. In **Takes**, listen to the result and export WAV, MP3, M4A, or timed SRT captions. Editing a copy can reuse unchanged passages.

## Contributing

Run `python -m unittest discover -s Tests -v` from the root with NumPy, SciPy, and SoundFile installed. The tests generate their inputs locally. For cleanup reports, provide the expected words, the observed edit and timing, and the app and macOS versions. Use a synthetic reproduction when possible.

## License

Original app code is MIT licensed. Model weights and third-party dependencies retain their upstream licenses. See [LICENSE](LICENSE) and [component notices](Assets/Notices.txt).
