#!/usr/bin/env python3
"""
renumber_exercises.py

For the "Programming Abstractions in C++" Obsidian task folder, this script
finds task files whose exercise counter is missing from both the filename
and the frontmatter `title` field, and fills it in.

Expected filename shape:
    <YYYY-MM-DD> Exercise <chapter><sep><number>.md
e.g.
    2026-06-22 Exercise 12 - 1.md
    2026-06-05 Exercise 10-3.md

A file is considered "missing its number" when <number> is empty, e.g.:
    2026-06-05 Exercise 10-.md
    2026-06-13 Exercise 11 -.md

For each chapter:
  1. All files are grouped together.
  2. The next available counter starts at (highest existing number in that
     chapter) + 1. If no numbered files exist yet for that chapter, it
     starts at 1.
  3. Files missing a number are sorted by their frontmatter `date` field
     (falling back to the date in the filename if `date` is absent) and
     assigned counters in that order.
  4. The separator style ("-" tight, vs " - " spaced) is inferred from the
     file's own filename/title so existing conventions per chapter are
     preserved.

The frontmatter `title` field is updated to match the (new or existing)
filename (minus the date prefix and extension) so the Full Calendar plugin
displays the correct, numbered title.

Importantly, this also catches files whose *filename* already has a
number but whose frontmatter `title` field was never updated to match
(e.g. filename "Exercise 14 - 5.md" but title still reads "Exercise 14 -").
Those files aren't renamed, but their title field is corrected.

Usage:
    python renumber_exercises.py /path/to/vault/folder            # dry run
    python renumber_exercises.py /path/to/vault/folder --apply    # do it

Dry run (the default) only prints what would change; nothing is written
to disk until you pass --apply.
"""

import argparse
import re
import sys
from datetime import date
from pathlib import Path

FILENAME_RE = re.compile(
    r'^(?P<filedate>\d{4}-\d{2}-\d{2}) Exercise (?P<chapter>\d+)(?P<sep>\s*-\s*)(?P<num>\d*)\.md$'
)
FRONTMATTER_DATE_RE = re.compile(r'^date:\s*(\d{4}-\d{2}-\d{2})', re.MULTILINE)
FRONTMATTER_TITLE_RE = re.compile(r'^title:\s*(.*)$', re.MULTILINE)
FRONTMATTER_TITLE_SUB_RE = re.compile(r'^(title:\s*).*$', re.MULTILINE)


def parse_file(path: Path):
    """Extract chapter/sep/number/date info from a task file. Returns None if it doesn't match."""
    m = FILENAME_RE.match(path.name)
    if not m:
        return None

    chapter = m.group('chapter')
    sep_raw = m.group('sep')
    num = int(m.group('num')) if m.group('num') else None

    text = path.read_text(encoding='utf-8')
    date_match = FRONTMATTER_DATE_RE.search(text)
    if date_match:
        fdate = date.fromisoformat(date_match.group(1))
    else:
        fdate = date.fromisoformat(m.group('filedate'))

    title_match = FRONTMATTER_TITLE_RE.search(text)
    current_title = title_match.group(1).strip() if title_match else None

    return {
        'path': path,
        'chapter': chapter,
        'sep_raw': sep_raw,
        'num': num,
        'date': fdate,
        'text': text,
        'filedate': m.group('filedate'),
        'current_title': current_title,
    }


def normalized_separator(sep_raw: str) -> str:
    """Reproduce the chapter's dash convention: tight '-' or spaced ' - '."""
    return ' - ' if any(ch.isspace() for ch in sep_raw) else '-'


def plan_renames(folder: Path):
    """
    Return a list of actions. Each action is a dict with:
      entry, new_name (None if no rename needed), new_title, rename (bool)
    Covers two cases:
      1. Filename is missing its number -> rename file + fix title.
      2. Filename already has a number but title field doesn't match
         (e.g. still "Exercise 14 -" instead of "Exercise 14 - 5") -> fix
         title only, no rename.
    """
    entries = [parse_file(f) for f in folder.glob('*.md')]
    entries = [e for e in entries if e]

    by_chapter = {}
    for e in entries:
        by_chapter.setdefault(e['chapter'], []).append(e)

    plan = []
    for chapter, chapter_entries in by_chapter.items():
        numbered = [e for e in chapter_entries if e['num'] is not None]
        missing = [e for e in chapter_entries if e['num'] is None]

        # Case 1: files missing a number in the filename -> assign one.
        if missing:
            next_num = max((e['num'] for e in numbered), default=0) + 1
            missing.sort(key=lambda e: e['date'])

            for offset, entry in enumerate(missing):
                new_num = next_num + offset
                sep = normalized_separator(entry['sep_raw'])
                new_title = f"Exercise {chapter}{sep}{new_num}"
                new_name = f"{entry['filedate']} {new_title}.md"
                plan.append({
                    'entry': entry,
                    'new_name': new_name,
                    'new_title': new_title,
                    'rename': True,
                })

        # Case 2: files that already have a number in the filename, but
        # whose title field doesn't reflect it -> fix title only.
        for entry in numbered:
            sep = normalized_separator(entry['sep_raw'])
            expected_title = f"Exercise {chapter}{sep}{entry['num']}"
            if entry['current_title'] != expected_title:
                plan.append({
                    'entry': entry,
                    'new_name': None,
                    'new_title': expected_title,
                    'rename': False,
                })

    return plan


def apply_plan(plan, dry_run: bool):
    for action in plan:
        entry = action['entry']
        old_path = entry['path']
        new_title = action['new_title']

        if action['rename']:
            new_path = old_path.parent / action['new_name']
            print(f"{old_path.name}")
            print(f"  -> {action['new_name']}")
            print(f"  title -> {new_title}")
        else:
            new_path = old_path
            print(f"{old_path.name}")
            print(f"  title: {entry['current_title']!r} -> {new_title!r}")

        if dry_run:
            continue

        new_text = FRONTMATTER_TITLE_SUB_RE.sub(rf'\g<1>{new_title}', entry['text'], count=1)
        new_path.write_text(new_text, encoding='utf-8')
        if new_path != old_path:
            old_path.unlink()


def main():
    parser = argparse.ArgumentParser(description="Fill in missing exercise numbers in filenames + frontmatter titles.")
    parser.add_argument('folder', type=Path, help="Path to the exercises folder")
    parser.add_argument('--apply', action='store_true', help="Actually rename files (default is dry run)")
    args = parser.parse_args()

    if not args.folder.is_dir():
        sys.exit(f"Not a directory: {args.folder}")

    plan = plan_renames(args.folder)

    if not plan:
        print("Nothing to do — all filenames and title fields already have their exercise number.")
        return

    if not args.apply:
        print("DRY RUN — no files will be changed. Pass --apply to write changes.\n")
    apply_plan(plan, dry_run=not args.apply)


if __name__ == '__main__':
    main()

