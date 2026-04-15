#!/usr/bin/env python3
"""Convert VTT subtitle files to clean paragraph text.

Strips VTT headers, timestamps, and formatting tags, deduplicates
repeated lines (VTT repeats across cues), and joins into flowing
paragraph text output to stdout.

Usage:
    clean-transcript.py <input.vtt>
"""

import re
import sys


def strip_vtt_tags(line):
    """Remove VTT formatting tags like <c>, </c>, <00:01:02.345>, etc."""
    # Remove timestamp tags embedded in text (e.g., <00:01:02.345>)
    line = re.sub(r"<\d{2}:\d{2}:\d{2}\.\d{3}>", "", line)
    # Remove all other HTML-like tags (e.g., <c>, </c>, <b>, <i>)
    line = re.sub(r"</?[^>]+>", "", line)
    return line


def is_timestamp_line(line):
    """Check if a line is a VTT timestamp cue (e.g., 00:00:01.234 --> 00:00:04.567)."""
    return bool(re.match(r"\d{2}:\d{2}:\d{2}\.\d{3}\s*-->", line))


def is_cue_id_line(line):
    """Check if a line is a numeric cue identifier."""
    return bool(re.match(r"^\d+$", line.strip()))


def clean_vtt(content):
    """Parse VTT content and return deduplicated, clean paragraph text.

    VTT auto-subtitles typically repeat lines across overlapping cues.
    This function strips all metadata, deduplicates consecutive lines,
    and joins the result into flowing paragraphs.
    """
    lines = content.splitlines()
    seen_lines = []
    prev_line = None

    for line in lines:
        stripped = line.strip()

        # Skip empty lines, VTT header, timestamp lines, cue IDs, and NOTE blocks
        if not stripped:
            continue
        if stripped.startswith("WEBVTT"):
            continue
        if stripped.startswith("Kind:") or stripped.startswith("Language:"):
            continue
        if stripped.startswith("NOTE"):
            continue
        if is_timestamp_line(stripped):
            continue
        if is_cue_id_line(stripped):
            continue

        # Strip formatting tags from the text content
        cleaned = strip_vtt_tags(stripped)
        cleaned = cleaned.strip()

        if not cleaned:
            continue

        # Deduplicate: skip if identical to the previous kept line
        if cleaned == prev_line:
            continue

        seen_lines.append(cleaned)
        prev_line = cleaned

    # Join into flowing paragraph text
    return " ".join(seen_lines)


def main():
    if len(sys.argv) != 2:
        print("Usage: clean-transcript.py <input.vtt>", file=sys.stderr)
        sys.exit(1)

    vtt_path = sys.argv[1]

    try:
        with open(vtt_path, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        print(f"Error: file not found: {vtt_path}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        sys.exit(1)

    result = clean_vtt(content)
    print(result)


if __name__ == "__main__":
    main()
