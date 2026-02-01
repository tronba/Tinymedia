#!/usr/bin/env python3
"""
Lightweight Media Server for Emergency Hub
- Browse folders with arbitrary depth
- Stream video/audio in browser
- Download any file
- Upload files to any folder
- Create new folders
"""

from flask import (
    Flask, render_template, send_file, request, 
    redirect, url_for, jsonify, abort
)
from pathlib import Path
from functools import wraps
import os
import mimetypes

app = Flask(__name__)

# Configuration
MEDIA_ROOT = Path(os.environ.get('MEDIA_ROOT', '/media/usb'))

# Ensure mimetypes are properly registered
mimetypes.add_type('video/mp4', '.mp4')
mimetypes.add_type('video/webm', '.webm')
mimetypes.add_type('video/x-matroska', '.mkv')
mimetypes.add_type('audio/mpeg', '.mp3')
mimetypes.add_type('audio/ogg', '.ogg')
mimetypes.add_type('audio/flac', '.flac')
mimetypes.add_type('application/vnd.android.package-archive', '.apk')


def safe_path(func):
    """Decorator to validate paths and prevent directory traversal"""
    @wraps(func)
    def wrapper(subpath=''):
        # Normalize and resolve path
        subpath = subpath.strip('/')
        full_path = (MEDIA_ROOT / subpath).resolve()
        
        # Ensure we're still within MEDIA_ROOT
        try:
            full_path.relative_to(MEDIA_ROOT.resolve())
        except ValueError:
            abort(403)  # Path traversal attempt
        
        return func(subpath, full_path)
    return wrapper


def get_file_info(path: Path) -> dict:
    """Get file/folder info for display"""
    stat = path.stat()
    is_dir = path.is_dir()
    
    info = {
        'name': path.name,
        'is_dir': is_dir,
        'size': stat.st_size if not is_dir else None,
        'size_human': format_size(stat.st_size) if not is_dir else None,
    }
    
    if not is_dir:
        mime, _ = mimetypes.guess_type(path.name)
        info['mime'] = mime or 'application/octet-stream'
        info['type'] = get_file_type(mime)
    
    return info


def get_file_type(mime: str) -> str:
    """Categorize file by MIME type"""
    if not mime:
        return 'file'
    if mime.startswith('video/'):
        return 'video'
    if mime.startswith('audio/'):
        return 'audio'
    if mime.startswith('image/'):
        return 'image'
    if mime in ('application/pdf',):
        return 'document'
    return 'file'


def format_size(size: int) -> str:
    """Human-readable file size"""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


def get_storage_info() -> dict:
    """Get storage usage for MEDIA_ROOT"""
    try:
        stat = os.statvfs(MEDIA_ROOT)
        total = stat.f_blocks * stat.f_frsize
        free = stat.f_bavail * stat.f_frsize
        used = total - free
        return {
            'total': format_size(total),
            'used': format_size(used),
            'free': format_size(free),
            'percent': round((used / total) * 100, 1) if total > 0 else 0
        }
    except OSError:
        return None


def get_breadcrumbs(subpath: str) -> list:
    """Generate breadcrumb navigation"""
    crumbs = [{'name': 'Home', 'path': ''}]
    
    if subpath:
        parts = subpath.split('/')
        for i, part in enumerate(parts):
            crumbs.append({
                'name': part,
                'path': '/'.join(parts[:i+1])
            })
    
    return crumbs


@app.route('/')
def index():
    return redirect(url_for('browse'))


@app.route('/browse/')
@app.route('/browse/<path:subpath>')
@safe_path
def browse(subpath, full_path):
    """Browse folder contents"""
    if not full_path.exists():
        abort(404)
    
    if full_path.is_file():
        # If user navigates to a file, redirect to stream
        return redirect(url_for('stream', subpath=subpath))
    
    # List folder contents
    items = []
    # System folders to hide (common Windows/system folders)
    hidden_folders = {'System Volume Information', '$RECYCLE.BIN', 'Thumbs.db', '.Trashes', '.Spotlight-V100'}
    try:
        for entry in sorted(full_path.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower())):
            if entry.name.startswith('.') or entry.name in hidden_folders:
                continue  # Skip hidden files and system folders
            items.append(get_file_info(entry))
    except PermissionError:
        abort(403)
    
    return render_template('index.html',
        items=items,
        current_path=subpath,
        breadcrumbs=get_breadcrumbs(subpath),
        storage=get_storage_info()
    )


@app.route('/stream/<path:subpath>')
@safe_path
def stream(subpath, full_path):
    """Stream file with range request support"""
    if not full_path.is_file():
        abort(404)
    
    mime, _ = mimetypes.guess_type(full_path.name)
    
    # send_file handles range requests automatically
    return send_file(
        full_path,
        mimetype=mime,
        conditional=True  # Enables range request support
    )


@app.route('/download/<path:subpath>')
@safe_path
def download(subpath, full_path):
    """Download file as attachment"""
    if not full_path.is_file():
        abort(404)
    
    return send_file(
        full_path,
        as_attachment=True,
        download_name=full_path.name
    )


@app.route('/upload/<path:subpath>', methods=['POST'])
@app.route('/upload/', methods=['POST'], defaults={'subpath': ''})
@safe_path
def upload(subpath, full_path):
    """Upload file to folder"""
    if not full_path.is_dir():
        return jsonify({'error': 'Invalid folder'}), 400
    
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    
    file = request.files['file']
    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400
    
    # Sanitize filename
    filename = Path(file.filename).name  # Remove any path components
    if filename.startswith('.'):
        return jsonify({'error': 'Hidden files not allowed'}), 400
    
    dest = full_path / filename
    
    # Don't overwrite existing files - add number suffix
    if dest.exists():
        base = dest.stem
        suffix = dest.suffix
        counter = 1
        while dest.exists():
            dest = full_path / f"{base}_{counter}{suffix}"
            counter += 1
    
    try:
        file.save(dest)
        return jsonify({
            'success': True, 
            'filename': dest.name,
            'size': format_size(dest.stat().st_size)
        })
    except OSError as e:
        return jsonify({'error': str(e)}), 500


@app.route('/mkdir/<path:subpath>', methods=['POST'])
@app.route('/mkdir/', methods=['POST'], defaults={'subpath': ''})
@safe_path
def mkdir(subpath, full_path):
    """Create new folder"""
    if not full_path.is_dir():
        return jsonify({'error': 'Invalid parent folder'}), 400
    
    data = request.get_json()
    if not data or 'name' not in data:
        return jsonify({'error': 'Folder name required'}), 400
    
    # Sanitize folder name
    folder_name = data['name'].strip()
    folder_name = ''.join(c for c in folder_name if c.isalnum() or c in ' -_').strip()
    
    if not folder_name:
        return jsonify({'error': 'Invalid folder name'}), 400
    
    new_folder = full_path / folder_name
    
    if new_folder.exists():
        return jsonify({'error': 'Folder already exists'}), 400
    
    try:
        new_folder.mkdir()
        return jsonify({'success': True, 'name': folder_name})
    except OSError as e:
        return jsonify({'error': str(e)}), 500


@app.errorhandler(404)
def not_found(e):
    return render_template('error.html', error='Not found', code=404), 404


@app.errorhandler(403)
def forbidden(e):
    return render_template('error.html', error='Access denied', code=403), 403


if __name__ == '__main__':
    # Ensure media root exists
    MEDIA_ROOT.mkdir(parents=True, exist_ok=True)
    
    print(f"Media root: {MEDIA_ROOT}")
    print(f"Starting server on http://0.0.0.0:5000")
    
    # For production, use: gunicorn -w 2 -b 0.0.0.0:5000 server:app
    app.run(host='0.0.0.0', port=5000, debug=False, threaded=True)
