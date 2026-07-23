#!/usr/bin/env python3
"""
extract_slides.py

Extract one screenshot per "slide" from a video that is essentially a slideshow
(e.g. a screen recording of a presentation). It detects slide changes
automatically by comparing frames and saves an image whenever a significant,
stable change is detected.

Usage:
    python extract_slides.py input_video.mp4 -o output_folder

Options:
    -o, --output      Output folder for screenshots (default: "slides")
    --sample-rate     How many frames per second to sample (default: 2)
    --threshold       Sensitivity of change detection, 0-1 (default: 0.03)
                       Lower = more sensitive (detects smaller changes)
    --stable-frames   Number of consecutive sampled frames that must look the
                       same before a slide is saved (avoids capturing mid-
                       transition/blurry frames). Default: 2
    --min-gap         Minimum seconds between two saved slides (default: 1.0)

Requires: opencv-python, numpy
    pip install opencv-python numpy --break-system-packages
"""

import argparse
import os
import sys

import cv2
import numpy as np


def frame_diff_score(frame_a, frame_b):
    """Return a normalized difference score (0 = identical, 1 = totally different)
    between two frames, robust to minor noise/compression artifacts."""
    gray_a = cv2.cvtColor(frame_a, cv2.COLOR_BGR2GRAY)
    gray_b = cv2.cvtColor(frame_b, cv2.COLOR_BGR2GRAY)

    # Slight blur to ignore compression noise / cursor blinking etc.
    gray_a = cv2.GaussianBlur(gray_a, (5, 5), 0)
    gray_b = cv2.GaussianBlur(gray_b, (5, 5), 0)

    diff = cv2.absdiff(gray_a, gray_b)
    # Fraction of pixels that changed meaningfully
    changed_pixels = np.count_nonzero(diff > 25)
    total_pixels = diff.size
    return changed_pixels / total_pixels


def extract_slides(video_path, output_dir, sample_rate=2, threshold=0.03,
                    stable_frames=2, min_gap=1.0):
    if not os.path.isfile(video_path):
        print(f"Error: video file not found: {video_path}")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"Error: could not open video: {video_path}")
        sys.exit(1)

    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    duration = total_frames / fps if fps else 0

    frame_interval = max(1, int(round(fps / sample_rate)))
    min_gap_frames = int(round(min_gap * fps))

    print(f"Video: {video_path}")
    print(f"  FPS: {fps:.2f}, Frames: {total_frames}, Duration: {duration:.1f}s")
    print(f"  Sampling every {frame_interval} frames (~{sample_rate}/sec)")

    slide_count = 0
    last_saved_frame_idx = -min_gap_frames
    last_sample = None          # last sampled frame (for diff comparison)
    candidate_frame = None      # frame currently being confirmed as a new slide
    candidate_streak = 0

    frame_idx = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if frame_idx % frame_interval == 0:
            if last_sample is None:
                # First sample = first slide
                last_sample = frame
                candidate_frame = frame
                candidate_streak = 1
            else:
                score = frame_diff_score(last_sample, frame)
                if score > threshold:
                    # Looks like a change is happening (could be mid-transition)
                    candidate_frame = frame
                    candidate_streak = 1
                else:
                    # Frame matches previous sample -> stable
                    if candidate_streak < stable_frames:
                        candidate_streak += 1
                    candidate_frame = frame

                # If we've been stable for enough samples and this content differs
                # from the last SAVED slide, save it.
                if candidate_streak >= stable_frames:
                    should_save = False
                    if slide_count == 0:
                        should_save = True
                    else:
                        # Compare to the previously saved slide to avoid duplicates
                        saved_score = frame_diff_score(last_saved_frame, candidate_frame)
                        if saved_score > threshold and (frame_idx - last_saved_frame_idx) >= min_gap_frames:
                            should_save = True

                    if should_save:
                        slide_count += 1
                        timestamp = frame_idx / fps
                        filename = os.path.join(
                            output_dir,
                            f"slide_{slide_count:03d}_{timestamp:07.2f}s.png"
                        )
                        cv2.imwrite(filename, candidate_frame)
                        last_saved_frame = candidate_frame
                        last_saved_frame_idx = frame_idx
                        print(f"  Saved {filename}")

                last_sample = frame

        frame_idx += 1

    cap.release()
    print(f"\nDone. Extracted {slide_count} slide(s) to '{output_dir}'.")


def main():
    parser = argparse.ArgumentParser(description="Extract slide screenshots from a slideshow video.")
    parser.add_argument("video", help="Path to the input video file")
    parser.add_argument("-o", "--output", default="slides", help="Output folder (default: slides)")
    parser.add_argument("--sample-rate", type=float, default=2,
                         help="Frames per second to sample (default: 2)")
    parser.add_argument("--threshold", type=float, default=0.03,
                         help="Change-detection sensitivity, 0-1 (default: 0.03)")
    parser.add_argument("--stable-frames", type=int, default=2,
                         help="Consecutive stable samples required before saving (default: 2)")
    parser.add_argument("--min-gap", type=float, default=1.0,
                         help="Minimum seconds between saved slides (default: 1.0)")
    args = parser.parse_args()

    extract_slides(
        args.video,
        args.output,
        sample_rate=args.sample_rate,
        threshold=args.threshold,
        stable_frames=args.stable_frames,
        min_gap=args.min_gap,
    )


if __name__ == "__main__":
    main()

