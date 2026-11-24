# Narrator Studio
An offline Apple Silicon macOS app for reference-based narration, voice cleanup, and timed captions. Import a recording of your own voice or one you have permission to use. Voice profiles and generated takes are stored in the current user's Application Support directory.

## Build
On macOS 26 or later with Apple command-line developer tools and Python 3 installed, run from the repository root:

    python3 Scripts/prepare.py
    bash Scripts/package.sh

Preparation downloads the runtime and model weights. The disk image is written to dist. Open the app and choose **Import voice** to get started. See Assets/Notices.txt for model attribution.
