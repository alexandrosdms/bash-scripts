#!/usr/bin/env python3
"""
slides_to_images.py

Convert each slide/page of a PDF or PPTX file into image files (PNG/JPEG).

PPTX files are first converted to PDF via LibreOffice (soffice), then every
PDF page is rasterized with poppler's pdftoppm, one page at a time.

Requirements
------------
No Python packages needed. Only these system tools:
    - poppler-utils (provides pdftoppm) -> rasterizes PDF pages
        Debian/Ubuntu: sudo apt install poppler-utils
    - LibreOffice (provides `soffice`) -> only needed for .pptx input
        Debian/Ubuntu: sudo apt install libreoffice

Pages are rendered by shelling out to `pdftoppm`, which writes each page to
disk as it goes. This keeps memory usage low and roughly constant regardless
of how many slides are in the deck (earlier versions of this script used
pdf2image's convert_from_path, which decodes every page into memory at once
and can get OOM-killed on large decks -- avoid that approach).

Usage
-----
    python slides_to_images.py input.pdf
    python slides_to_images.py deck.pptx --out-dir slides --format png --dpi 200
    python slides_to_images.py deck.pptx -o slides -f jpg -d 150 --prefix slide

Output files are named "<prefix>_001.<ext>", "<prefix>_002.<ext>", ...
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def check_tool(name: str) -> bool:
    """Return True if `name` is found on PATH."""
    return shutil.which(name) is not None


def pptx_to_pdf(pptx_path: Path, workdir: Path) -> Path:
    """Convert a PPTX (or PPT/ODP/etc.) file to PDF using LibreOffice, returns the PDF path."""
    if not check_tool("soffice"):
        sys.exit(
            "LibreOffice ('soffice') is required to convert PPTX files but was not "
            "found on PATH.\nInstall it with: sudo apt install libreoffice"
        )

    cmd = [
        "soffice",
        "--headless",
        "--norestore",
        "--convert-to",
        "pdf",
        "--outdir",
        str(workdir),
        str(pptx_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        sys.exit(
            f"LibreOffice conversion failed (exit {result.returncode}):\n"
            f"{result.stdout}\n{result.stderr}"
        )

    pdf_path = workdir / (pptx_path.stem + ".pdf")
    if not pdf_path.exists():
        sys.exit(f"Expected converted PDF at {pdf_path}, but it was not created.")
    return pdf_path


def pdf_to_images(pdf_path: Path, out_dir: Path, fmt: str, dpi: int, prefix: str) -> list[Path]:
    """Rasterize every page of a PDF into image files via pdftoppm (streams each page
    to disk instead of holding every rendered page in memory at once)."""
    if not check_tool("pdftoppm"):
        sys.exit(
            "'pdftoppm' is required but was not found on PATH.\n"
            "Install it with: sudo apt install poppler-utils"
        )

    fmt = fmt.lower()
    if fmt == "png":
        fmt_flag, ext = "-png", "png"
    elif fmt in ("jpg", "jpeg"):
        fmt_flag, ext = "-jpeg", "jpg"
    else:
        sys.exit(f"Unsupported format '{fmt}'. Use png, jpg, or jpeg.")

    out_dir.mkdir(parents=True, exist_ok=True)
    out_prefix = out_dir / prefix

    cmd = ["pdftoppm", fmt_flag, "-r", str(dpi), str(pdf_path), str(out_prefix)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"pdftoppm failed (exit {result.returncode}):\n{result.stderr}")

    # pdftoppm names files "<prefix>-N.<ext>" (zero-padded once it knows the page count)
    written = sorted(out_dir.glob(f"{prefix}-*.{ext}"))
    if not written:
        sys.exit(f"pdftoppm reported success but no output files matched {out_prefix}-*.{ext}")
    return written


def main():
    parser = argparse.ArgumentParser(
        description="Convert PDF or PPTX slides into images (one image per slide/page)."
    )
    parser.add_argument("input", type=Path, help="Path to the input .pdf or .pptx file")
    parser.add_argument(
        "-o", "--out-dir", type=Path, default=None,
        help="Directory to write images to (default: '<input_stem>_images')",
    )
    parser.add_argument(
        "-f", "--format", default="png", choices=["png", "jpg", "jpeg"],
        help="Output image format (default: png)",
    )
    parser.add_argument(
        "-d", "--dpi", type=int, default=200,
        help="Rendering resolution in DPI (default: 200; use 300+ for print quality)",
    )
    parser.add_argument(
        "-p", "--prefix", default="slide",
        help="Filename prefix for output images (default: 'slide')",
    )
    args = parser.parse_args()

    input_path: Path = args.input
    if not input_path.exists():
        sys.exit(f"Input file not found: {input_path}")

    suffix = input_path.suffix.lower()
    out_dir = args.out_dir or Path(f"{input_path.stem}_images")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)

        if suffix == ".pdf":
            pdf_path = input_path
        elif suffix in (".pptx", ".ppt", ".odp"):
            print(f"Converting {input_path.name} to PDF via LibreOffice...")
            pdf_path = pptx_to_pdf(input_path, tmp_path)
        else:
            sys.exit(f"Unsupported input type '{suffix}'. Use .pdf or .pptx.")

        print(f"Rendering pages at {args.dpi} DPI as {args.format.upper()}...")
        written = pdf_to_images(pdf_path, out_dir, args.format, args.dpi, args.prefix)

    print(f"Done. Wrote {len(written)} image(s) to {out_dir}/")
    for p in written[:5]:
        print(f"  {p}")
    if len(written) > 5:
        print(f"  ... and {len(written) - 5} more")


if __name__ == "__main__":
    main()

