#!/usr/bin/env python3
"""
Bilibili playlist downloader.

Wraps yt-dlp, which has native Bilibili support (including multi-part
videos and playlists/collections).

Requirements:
    pip install -U yt-dlp

Usage:
    python bilibili_downloader.py <url> [options]

Examples:
    # Download an entire playlist/collection at best quality
    python bilibili_downloader.py "https://www.bilibili.com/video/BVxxxxxxx"

    # Download to a specific folder
    python bilibili_downloader.py "<url>" -o ~/Videos/bilibili

    # Limit resolution (helps avoid huge files / throttling)
    python bilibili_downloader.py "<url>" -q 720

    # List playlist entries without downloading
    python bilibili_downloader.py "<url>" --list-only

    # Download only specific items from a playlist (e.g. episodes 1-5)
    python bilibili_downloader.py "<url>" --items 1-5
"""

import argparse
import shutil
import sys

try:
    import yt_dlp
except ImportError:
    print("yt-dlp is not installed. Install it with:\n    pip install -U yt-dlp")
    sys.exit(1)


def build_format_string(quality: str | None) -> str:
    """Build a yt-dlp format selector capped at the given resolution."""
    if not quality or quality.lower() == "best":
        return "bestvideo+bestaudio/best"
    height = quality.rstrip("p")
    return f"bestvideo[height<={height}]+bestaudio/best[height<={height}]"


def main():
    parser = argparse.ArgumentParser(description="Download Bilibili videos/playlists via yt-dlp.")
    parser.add_argument("url", help="Bilibili video, playlist, or collection URL")
    parser.add_argument("-o", "--output-dir", default="./downloads",
                         help="Directory to save downloads into (default: ./downloads)")
    parser.add_argument("-q", "--quality", default="best",
                         help="Max resolution, e.g. 1080, 720, 480, or 'best' (default: best)")
    parser.add_argument("--items", default=None,
                         help="Playlist item range/selection, e.g. '1-5' or '1,3,7'")
    parser.add_argument("--audio-only", action="store_true",
                         help="Extract audio only (mp3)")
    parser.add_argument("--list-only", action="store_true",
                         help="List playlist entries without downloading")
    parser.add_argument("--subs", action="store_true",
                         help="Also download subtitles/danmaku-derived CC if available")
    parser.add_argument("--cookies", default=None,
                         help="Path to a cookies.txt file (needed for member-only/HD content)")
    args = parser.parse_args()

    if not shutil.which("ffmpeg"):
        print("Warning: ffmpeg not found on PATH. Merging video+audio or audio "
              "extraction may fail. Install ffmpeg and re-run if you hit errors.\n")

    ydl_opts = {
        "outtmpl": f"{args.output_dir}/%(playlist_title|)s/%(title)s.%(ext)s",
        "format": build_format_string(args.quality),
        "ignoreerrors": True,       # skip items that fail instead of aborting
        "noplaylist": False,        # allow playlist expansion
        "continuedl": True,         # resume partial downloads
        "retries": 5,
        "concurrent_fragment_downloads": 4,
    }

    if args.items:
        ydl_opts["playlist_items"] = args.items

    if args.audio_only:
        ydl_opts["format"] = "bestaudio/best"
        ydl_opts["postprocessors"] = [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "mp3",
            "preferredquality": "192",
        }]

    if args.subs:
        ydl_opts["writesubtitles"] = True
        ydl_opts["writeautomaticsub"] = True
        ydl_opts["subtitleslangs"] = ["all"]

    if args.cookies:
        ydl_opts["cookiefile"] = args.cookies

    if args.list_only:
        ydl_opts["extract_flat"] = "in_playlist"
        ydl_opts["skip_download"] = True

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(args.url, download=not args.list_only)

        if args.list_only:
            entries = info.get("entries") or [info]
            print(f"\nFound {len(entries)} item(s):")
            for i, entry in enumerate(entries, 1):
                if entry is None:
                    continue
                title = entry.get("title", "Unknown title")
                vid = entry.get("id", "")
                print(f"  {i:>3}. {title}  [{vid}]")


if __name__ == "__main__":
    main()

