# Directory Structure

```txt
meet-digest/
├── .gitignore
├── LICENSE
├── README.md                  # Setup, dependencies, and launchd installation guide
├── requirements.txt           # Python dependencies (whisperx, requests, etc.)
│
├── config/
│   └── config.yaml            # Paths for watching directories, Ollama model choices, prompts
│
├── com.user.meetdigest.plist  # The launchd property list file for macOS automation
│
├── scripts/
│   └── install_launchd.sh     # Helper script to copy the plist to LaunchAgents and load it
│
└── src/
    ├── __init__.py
    ├── main.py                # Entry point called by launchd (orchestrates the pipeline)
    ├── audio.py               # FFmpeg wrapper logic for extracting/optimizing audio
    ├── transcriber.py         # WhisperX integration code
    └── summarizer.py          # Ollama API client and summary prompting logic
```
