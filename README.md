# Narrator Studio
An offline Apple Silicon macOS app for reference-based narration, voice cleanup, and timed captions. Import a recording of your own voice or one you have permission to use. Voice profiles and generated takes are stored in the current user's Application Support directory.

## Project credits

**Md Sahil** created Narrator Studio and is its primary maintainer and lead contributor. [@mdsahilcse on GitHub](https://github.com/mdsahilcse)

## Build
On macOS 26 or later with Apple command-line developer tools and Python 3 installed, run from the repository root:

    python3 Scripts/prepare.py
    bash Scripts/package.sh

Preparation downloads the runtime and model weights. The disk image is written to dist. Open the app and choose **Import voice** to get started. See Assets/Notices.txt for model attribution.

## Working with a recording

Choose **Import Voice** and select clear speech recorded with the speaker's permission. Import saves the reference for later scripts. In **Voiceover**, pick a saved voice, paste a script, and preview the opening or generate the full take. The app generates each passage with the saved voice settings and shows a transcript for review. Single line breaks flow together, blank lines mark passage breaks, and the app cleans up list markers, stray quotes, and underscores before synthesis.

In **Cleanup**, choose a recording or video. Supply the intended script to help preserve deliberate English hesitations. In **Takes**, listen to the result and export WAV, MP3, M4A, or timed SRT captions. Editing a copy can reuse unchanged passages.

## Contributing

Run `python -m unittest discover -s Tests -v` from the root with NumPy, SciPy, and SoundFile installed. The tests generate their inputs locally. For cleanup reports, provide the expected words, the observed edit and timing, and the app and macOS versions. Use a synthetic reproduction when possible.

## License

Original app code is MIT licensed. Model weights and third-party dependencies retain their upstream licenses. See [LICENSE](LICENSE) and [component notices](Assets/Notices.txt).
