<<<<<<< HEAD
# TinyMedia — Lightweight Mobile Media Server
=======
# Tinymedia
>>>>>>> 928081ff9e3bc63cf97d11734219ae67571ec6f0

A tiny, lightweight file and media server designed to run on low-powered boards
like Raspberry Pi or Orange Pi and to be easily accessed from a cellphone.
It provides a simple browser UI for browsing folders, streaming video/audio
in the browser, downloading, uploading, and creating folders on local storage.

## Features

- Browse folders with arbitrary depth
- Stream video/audio directly in browser
- Download any file
- Upload files to any folder
- Create new folders
- Mobile-friendly interface
- Storage usage indicator
- No authentication (local network use)

## Requirements

```bash
pip install flask
```

## Usage

```bash
# Set media root (default: /media/usb)
export MEDIA_ROOT=/path/to/your/media

# Run server
python server.py
```

Server starts on `http://0.0.0.0:5000`

## Folder Structure

Organize however you like:

```
/media/usb/
├── Media/
│   ├── Video/
│   │   ├── Series Name/
│   │   │   └── episodes...
│   │   └── movies...
│   └── Audio/
│       └── music...
└── Install files/
    ├── Android/
    └── Windows/
```

## Production Use

For better performance with multiple users:

```bash
pip install gunicorn
gunicorn -w 2 -b 0.0.0.0:5000 server:app
```

## Quick install (from git)

If you fetched this repository with `git`, the `scripts/` folder includes helper scripts to get TinyMedia running quickly on a Raspberry Pi or Windows machine.

- Unix (Raspbian, Debian, Ubuntu, Orange Pi):

```bash
git clone <repo-url>
cd Tinymedia
sudo scripts/install.sh
```

The installer will create a `venv` inside the project, install dependencies, prompt for a `MEDIA_ROOT`, and set up a `systemd` service named `tinymedia`.

- Run manually (Unix):

```bash
cd Tinymedia
./scripts/run.sh
```

- Windows (PowerShell):

```powershell
git clone <repo-url>
cd Tinymedia
.\scripts\run.ps1
```

Notes:
- The server listens on port `5000` by default. Open `http://<device-ip>:5000` from your phone while on the same network.
- For production deployments consider using `gunicorn` or another WSGI server and put the app behind a reverse proxy.

## Recommended Media Formats

Pre-transcode for universal browser playback:

- **Video**: H.264 MP4, 720p
- **Audio**: MP3 or AAC

## Systemd Service (auto-start)

Create `/etc/systemd/system/tinymedia.service` to auto-start the server:

```ini
[Unit]
Description=TinyMedia Lightweight Media Server
After=network.target

[Service]
Type=simple
User=pi
Environment=MEDIA_ROOT=/media/usb
WorkingDirectory=/home/pi/tinymedia
ExecStart=/usr/bin/python3 server.py
Restart=always

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl enable tinymedia
sudo systemctl start tinymedia
```
