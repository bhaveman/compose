#!/usr/bin/env python3
"""
Calibre Library Mismatch Scanner

Scans EPUB files in a Calibre library, extracts the first ~1000 words of text,
and compares against the expected title/author from metadata.opf.

Reports:
  - Title not found in opening text
  - Author not found in opening text
  - EPUB internal metadata mismatches vs Calibre metadata
  - Files that can't be opened / are corrupt

Usage:
    python3 calibre-mismatch-scanner.py [LIBRARY_PATH] [OPTIONS]

Options:
    --limit N          Only scan first N books (for testing)
    --recent N         Scan N most recently added/updated EPUB books
    --workers N        Parallel workers (default: 4)
    --output FILE      Write CSV report to FILE
    --title-only       Fast mode: focus on title mismatches only
    --max-words N      Words to extract from opening text (default: 600)
    --verbose          Print every book scanned, not just mismatches
    --min-confidence N Minimum word-match ratio to consider a match (0-100, default: 50)
"""

import argparse
import csv
import io
import os
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path


# ---------------------------------------------------------------------------
# HTML → plain-text (stdlib only, no bs4 needed)
# ---------------------------------------------------------------------------
class _HTMLStripper(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts: list[str] = []
        self._skip = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self._skip = True

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self._skip = False

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)

    def get_text(self) -> str:
        return " ".join(self.parts)


def strip_html(html: str) -> str:
    s = _HTMLStripper()
    s.feed(html)
    return s.get_text()


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------
@dataclass
class CalibreMetadata:
    title: str = ""
    authors: list[str] = field(default_factory=list)
    series: str = ""
    calibre_id: str = ""
    language: str = ""


@dataclass
class ScanResult:
    epub_path: str = ""
    folder_author: str = ""
    folder_title: str = ""
    meta_title: str = ""
    meta_authors: list[str] = field(default_factory=list)
    meta_language: str = ""
    epub_internal_title: str = ""
    epub_internal_authors: list[str] = field(default_factory=list)
    epub_internal_language: str = ""
    title_in_text: bool = False
    author_in_text: bool = False
    author_text_check_required: bool = True
    meta_vs_epub_title_match: bool = True
    meta_vs_epub_author_match: bool = True
    likely_non_english: bool = False
    non_english_reason: str = ""
    error: str = ""
    text_snippet: str = ""


# ---------------------------------------------------------------------------
# Parse Calibre metadata.opf
# ---------------------------------------------------------------------------
OPF_NS = {
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
}


def parse_calibre_opf(opf_path: Path) -> CalibreMetadata:
    meta = CalibreMetadata()
    try:
        tree = ET.parse(opf_path)
        root = tree.getroot()

        # Handle namespace variations
        for ns_uri in ["http://purl.org/dc/elements/1.1/", ""]:
            title_el = root.find(f".//{{{ns_uri}}}title") if ns_uri else root.find(".//title")
            if title_el is not None and title_el.text:
                meta.title = title_el.text.strip()
                break

        for creator in root.iter():
            tag = creator.tag.split("}")[-1] if "}" in creator.tag else creator.tag
            if tag == "creator" and creator.text:
                meta.authors.append(creator.text.strip())

        for lang in root.iter():
            tag = lang.tag.split("}")[-1] if "}" in lang.tag else lang.tag
            if tag == "language" and lang.text:
                meta.language = lang.text.strip()
                break

        for meta_el in root.iter():
            tag = meta_el.tag.split("}")[-1] if "}" in meta_el.tag else meta_el.tag
            if tag == "meta":
                name = meta_el.get("name", "")
                if name == "calibre:series":
                    meta.series = meta_el.get("content", "")

        for ident in root.iter():
            tag = ident.tag.split("}")[-1] if "}" in ident.tag else ident.tag
            if tag == "identifier":
                scheme = ident.get("{http://www.idpf.org/2007/opf}scheme", "") or ident.get("scheme", "")
                if scheme == "calibre" and ident.text:
                    meta.calibre_id = ident.text.strip()

    except Exception:
        pass
    return meta


# ---------------------------------------------------------------------------
# Extract text from EPUB (stdlib: zipfile + html.parser)
# ---------------------------------------------------------------------------
def extract_epub_text(
    epub_path: str,
    max_words: int = 1000,
    include_internal_metadata: bool = True,
) -> tuple[str, str, list[str], str]:
    """
    Returns (extracted_text, internal_title, internal_authors, internal_language).
    extracted_text is limited to approximately max_words words.
    """
    text_parts = []
    internal_title = ""
    internal_authors = []
    internal_language = ""
    word_count = 0

    try:
        with zipfile.ZipFile(epub_path, "r") as zf:
            # --- Parse internal OPF for metadata ---
            opf_path = _find_opf_in_epub(zf) if include_internal_metadata else None
            if include_internal_metadata and opf_path:
                try:
                    with zf.open(opf_path) as f:
                        opf_content = f.read().decode("utf-8", errors="replace")
                    opf_root = ET.fromstring(opf_content)
                    for el in opf_root.iter():
                        tag = el.tag.split("}")[-1] if "}" in el.tag else el.tag
                        if tag == "title" and el.text and not internal_title:
                            internal_title = el.text.strip()
                        if tag == "creator" and el.text:
                            internal_authors.append(el.text.strip())
                        if tag == "language" and el.text and not internal_language:
                            internal_language = el.text.strip()
                except Exception:
                    pass

            # --- Get reading order from spine/manifest ---
            content_files = _get_reading_order(zf, opf_path)

            # --- Extract text from content files ---
            for cf in content_files:
                if word_count >= max_words:
                    break
                try:
                    with zf.open(cf) as f:
                        raw = f.read().decode("utf-8", errors="replace")
                    plain = strip_html(raw)
                    words = plain.split()
                    remaining = max_words - word_count
                    text_parts.append(" ".join(words[:remaining]))
                    word_count += min(len(words), remaining)
                except Exception:
                    continue

    except zipfile.BadZipFile:
        return "", internal_title, internal_authors, internal_language
    except Exception:
        return "", internal_title, internal_authors, internal_language

    return " ".join(text_parts), internal_title, internal_authors, internal_language


def _find_opf_in_epub(zf: zipfile.ZipFile) -> str | None:
    """Find the .opf file inside the EPUB via container.xml or by searching."""
    # Try container.xml first
    try:
        with zf.open("META-INF/container.xml") as f:
            container = ET.fromstring(f.read())
        for rootfile in container.iter():
            tag = rootfile.tag.split("}")[-1] if "}" in rootfile.tag else rootfile.tag
            if tag == "rootfile":
                path = rootfile.get("full-path", "")
                if path:
                    return path
    except Exception:
        pass

    # Fallback: search for .opf files
    for name in zf.namelist():
        if name.endswith(".opf"):
            return name
    return None


def _get_reading_order(zf: zipfile.ZipFile, opf_path: str | None) -> list[str]:
    """Get ordered list of HTML/XHTML content files from the EPUB spine."""
    if not opf_path:
        # Fallback: just find all html-like files
        return sorted(
            n for n in zf.namelist()
            if n.endswith((".xhtml", ".html", ".htm"))
            and "toc" not in n.lower()
        )

    try:
        with zf.open(opf_path) as f:
            opf_root = ET.fromstring(f.read().decode("utf-8", errors="replace"))
    except Exception:
        return sorted(
            n for n in zf.namelist()
            if n.endswith((".xhtml", ".html", ".htm"))
        )

    opf_dir = "/".join(opf_path.split("/")[:-1])

    # Build manifest id→href map
    manifest = {}
    for item in opf_root.iter():
        tag = item.tag.split("}")[-1] if "}" in item.tag else item.tag
        if tag == "item":
            item_id = item.get("id", "")
            href = item.get("href", "")
            media_type = item.get("media-type", "")
            if item_id and href:
                full_href = f"{opf_dir}/{href}" if opf_dir else href
                manifest[item_id] = (full_href, media_type)

    # Get spine order
    spine_ids = []
    for itemref in opf_root.iter():
        tag = itemref.tag.split("}")[-1] if "}" in itemref.tag else itemref.tag
        if tag == "itemref":
            idref = itemref.get("idref", "")
            if idref:
                spine_ids.append(idref)

    ordered = []
    for sid in spine_ids:
        if sid in manifest:
            href, mtype = manifest[sid]
            if "html" in mtype or href.endswith((".xhtml", ".html", ".htm")):
                ordered.append(href)

    return ordered if ordered else sorted(
        n for n in zf.namelist()
        if n.endswith((".xhtml", ".html", ".htm"))
    )


# ---------------------------------------------------------------------------
# String matching helpers
# ---------------------------------------------------------------------------
def normalize(text: str) -> str:
    """Lowercase and strip non-alphanumeric chars for fuzzy comparison."""
    return re.sub(r"[^a-z0-9\s]", "", text.lower()).strip()


def words_match_ratio(needle: str, haystack: str) -> float:
    """What fraction of significant words in needle appear in haystack."""
    stop_words = {"the", "a", "an", "and", "or", "of", "in", "to", "for", "is",
                  "it", "on", "at", "by", "no", "not", "with", "from", "as", "but"}
    needle_words = [w for w in normalize(needle).split() if w not in stop_words and len(w) > 1]
    if not needle_words:
        return 1.0  # nothing to match → treat as ok
    hay_norm = normalize(haystack)
    matches = sum(1 for w in needle_words if w in hay_norm)
    return matches / len(needle_words)


def title_in_text(title: str, text: str, threshold: float = 0.5) -> bool:
    """Check if title words appear in the text."""
    return words_match_ratio(title, text) >= threshold


def author_in_text(authors: list[str], text: str) -> bool:
    """Check if any author's last name appears in the text (common in title pages)."""
    text_norm = normalize(text)
    for author in authors:
        parts = normalize(author).split()
        if not parts:
            continue
        # Check last name (most reliable)
        last_name = parts[-1]
        if len(last_name) > 2 and last_name in text_norm:
            return True
        # Check full name
        if normalize(author) in text_norm:
            return True
    return False


def titles_match(t1: str, t2: str, threshold: float = 0.6) -> bool:
    """Check if two titles are roughly the same (handles subtitles, series info)."""
    if not t1 or not t2:
        return True  # can't compare, don't flag
    # Strip subtitle (after : or -) for both and compare main titles
    main1 = re.split(r"[:\-–—]", t1)[0].strip()
    main2 = re.split(r"[:\-–—]", t2)[0].strip()
    # If main titles match well, that's good enough
    if words_match_ratio(main1, main2) >= threshold:
        return True
    # Also try full titles
    return words_match_ratio(t1, t2) >= threshold


def _author_name_parts(name: str) -> set[str]:
    """Extract meaningful name parts, handling 'Last, First' and 'First Last' formats."""
    n = normalize(name)
    # Remove commas (handles "Christie, Agatha" → "christie agatha")
    n = n.replace(",", " ")
    parts = {p for p in n.split() if len(p) > 1}
    return parts


def authors_match(a1: list[str], a2: list[str]) -> bool:
    """Check if author lists overlap (handles First Last vs Last, First)."""
    if not a1 or not a2:
        return True  # can't compare
    parts1 = set()
    for a in a1:
        parts1.update(_author_name_parts(a))
    parts2 = set()
    for a in a2:
        parts2.update(_author_name_parts(a))
    # If they share at least one significant name part, consider a match
    common = parts1 & parts2
    # Require at least one part with 3+ chars to match
    return any(len(c) >= 3 for c in common)


def is_probably_english(text: str) -> bool:
    """Conservative English detector based on common stopword frequency."""
    words = normalize(text).split()
    if len(words) < 80:
        return True

    english_markers = {
        "the", "and", "that", "with", "from", "this", "have", "your", "you",
        "not", "for", "are", "was", "but", "his", "her", "they", "she", "him",
        "their", "there", "what", "when", "where", "would", "could", "into",
        "about", "after", "before", "because", "said", "were", "been", "then",
    }
    marker_hits = sum(1 for word in words[:300] if word in english_markers)
    marker_ratio = marker_hits / min(len(words), 300)
    return marker_ratio >= 0.035


def classify_language_code(value: str) -> str:
    """Classify a language code as english, non_english, or unknown."""
    lang = value.strip().lower()
    if not lang:
        return "unknown"

    english_codes = {
        "en", "eng", "en-us", "en-gb", "enus", "engb",
    }
    unknown_codes = {
        "und", "unknown", "mul", "zxx", "mis", "qaa", "eee",
    }

    compact = lang.replace("_", "-")
    normalized = compact.replace("-", "")
    if compact in english_codes or normalized in english_codes:
        return "english"
    if compact in unknown_codes:
        return "unknown"

    # Treat common 2/3-letter non-English ISO-style codes as non-English.
    if re.fullmatch(r"[a-z]{2,3}", compact):
        return "non_english"

    return "unknown"


def likely_non_english(meta_language: str, internal_language: str, text: str) -> tuple[bool, str]:
    """Classify likely non-English using metadata first, then text heuristics."""
    for source, value in (("calibre_metadata", meta_language), ("epub_metadata", internal_language)):
        classification = classify_language_code(value)
        if classification == "unknown":
            continue
        if classification == "english":
            return False, ""
        return True, f"{source}:{value}"

    if text and not is_probably_english(text):
        return True, "text_heuristic"

    return False, ""


# ---------------------------------------------------------------------------
# Per-book scanner
# ---------------------------------------------------------------------------
def scan_book(
    book_dir: str,
    min_confidence: int = 50,
    max_words: int = 600,
    title_only: bool = False,
) -> ScanResult:
    """Scan a single book directory. Runs in worker process."""
    result = ScanResult()
    book_path = Path(book_dir)
    threshold = min_confidence / 100.0

    # Parse folder structure: Author/Title (id)/
    result.folder_author = book_path.parent.name
    folder_name = book_path.name
    # Strip trailing calibre ID like " (1234)"
    result.folder_title = re.sub(r"\s*\(\d+\)\s*$", "", folder_name).strip()

    # Find metadata.opf
    opf_files = list(book_path.glob("metadata.opf")) + list(book_path.glob("*.opf"))
    calibre_meta = CalibreMetadata()
    if opf_files:
        calibre_meta = parse_calibre_opf(opf_files[0])

    result.meta_title = calibre_meta.title
    result.meta_authors = calibre_meta.authors
    result.meta_language = calibre_meta.language

    # Find EPUB
    epubs = list(book_path.glob("*.epub"))
    if not epubs:
        result.error = "NO_EPUB_FOUND"
        result.epub_path = str(book_path)
        return result

    epub_path = epubs[0]
    result.epub_path = str(epub_path)

    # Extract text from EPUB
    try:
        text, internal_title, internal_authors, internal_language = extract_epub_text(
            str(epub_path),
            max_words=max_words,
            include_internal_metadata=not title_only,
        )
    except Exception as e:
        result.error = f"EXTRACT_FAILED: {e}"
        return result

    if not text:
        result.error = "NO_TEXT_EXTRACTED"
        return result

    result.epub_internal_title = internal_title
    result.epub_internal_authors = internal_authors
    result.epub_internal_language = internal_language
    result.text_snippet = text[:200]

    # Use the best available title/author for comparison
    check_title = calibre_meta.title or result.folder_title
    check_authors = calibre_meta.authors or [result.folder_author]

    # Check 1: Title words in opening text
    result.title_in_text = title_in_text(check_title, text, threshold)

    if title_only:
        # Fast mode: stop after title check and avoid secondary mismatch work.
        result.author_in_text = True
        result.author_text_check_required = False
        return result

    # Check 2: Author in opening text
    result.author_in_text = author_in_text(check_authors, text)

    # Check 3: EPUB internal metadata vs Calibre metadata
    result.meta_vs_epub_title_match = titles_match(
        calibre_meta.title, internal_title, threshold
    )
    result.meta_vs_epub_author_match = authors_match(
        calibre_meta.authors, internal_authors
    )

    result.author_text_check_required = not result.meta_vs_epub_author_match
    if not result.author_text_check_required:
        result.author_in_text = True

    result.likely_non_english, result.non_english_reason = likely_non_english(
        calibre_meta.language, internal_language, text
    )

    return result


# ---------------------------------------------------------------------------
# Main / CLI
# ---------------------------------------------------------------------------
def discover_book_dirs(library_path: Path) -> list[str]:
    """Find all book directories (Author/Title/) in the Calibre library."""
    book_dirs = []
    try:
        for author_dir in sorted(library_path.iterdir()):
            if not author_dir.is_dir() or author_dir.name.startswith("."):
                continue
            for book_dir in sorted(author_dir.iterdir()):
                if not book_dir.is_dir() or book_dir.name.startswith("."):
                    continue
                book_dirs.append(str(book_dir))
    except PermissionError:
        pass
    return book_dirs


def _book_dir_latest_epub_mtime(book_dir: str) -> float:
    """Return latest EPUB mtime for a book dir; -1 when no EPUB exists."""
    try:
        epubs = list(Path(book_dir).glob("*.epub"))
        if not epubs:
            return -1.0
        return max(epub.stat().st_mtime for epub in epubs)
    except Exception:
        return -1.0


def select_most_recent_book_dirs(book_dirs: list[str], count: int) -> list[str]:
    """Select top N book dirs by newest EPUB modification time."""
    if count <= 0:
        return book_dirs

    with_epub_times = []
    for bd in book_dirs:
        mtime = _book_dir_latest_epub_mtime(bd)
        if mtime >= 0:
            with_epub_times.append((bd, mtime))

    with_epub_times.sort(key=lambda item: item[1], reverse=True)
    return [bd for bd, _ in with_epub_times[:count]]


def main():
    parser = argparse.ArgumentParser(
        description="Scan Calibre EPUB library for metadata/content mismatches"
    )
    parser.add_argument(
        "library_path",
        nargs="?",
        default="/home/brad/media/media3/books",
        help="Path to Calibre library (default: /home/brad/media/media3/books)",
    )
    parser.add_argument("--limit", type=int, default=0, help="Only scan first N books (0=all)")
    parser.add_argument(
        "--recent", type=int, default=0,
        help="Scan N most recently added/updated EPUB books (0=disabled)"
    )
    parser.add_argument("--workers", type=int, default=4, help="Parallel workers (default: 4)")
    parser.add_argument("--output", type=str, default="", help="Write CSV report to file")
    parser.add_argument(
        "--title-only", action="store_true",
        help="Fast mode: focus on title mismatches and extraction errors"
    )
    parser.add_argument(
        "--max-words", type=int, default=600,
        help="Words to extract from opening text (default: 600)"
    )
    parser.add_argument("--verbose", action="store_true", help="Print every book, not just mismatches")
    parser.add_argument(
        "--min-confidence", type=int, default=50,
        help="Min word-match percentage to consider title a match (0-100, default: 50)"
    )

    args = parser.parse_args()
    library = Path(args.library_path)

    if not library.is_dir():
        print(f"Error: {library} is not a directory", file=sys.stderr)
        sys.exit(1)

    print(f"Discovering books in {library} ...")
    book_dirs = discover_book_dirs(library)
    total = len(book_dirs)
    print(f"Found {total} book directories")

    if args.recent > 0:
        book_dirs = select_most_recent_book_dirs(book_dirs, args.recent)
        print(f"Selecting {len(book_dirs)} most recently added/updated EPUB books")

    if args.limit > 0:
        book_dirs = book_dirs[: args.limit]
        print(f"Limiting scan to first {args.limit} books")

    if args.title_only:
        print("Title-only fast mode enabled (author/internal/language checks skipped)")

    # Counters
    scanned = 0
    errors = 0
    title_mismatches = 0
    author_mismatches = 0
    internal_title_mismatches = 0
    internal_author_mismatches = 0
    non_english_books = 0
    flagged_results: list[ScanResult] = []

    print(f"\nScanning with {args.workers} workers (min-confidence: {args.min_confidence}%) ...\n")

    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(
                scan_book,
                bd,
                args.min_confidence,
                args.max_words,
                args.title_only,
            ): bd
            for bd in book_dirs
        }

        for future in as_completed(futures):
            scanned += 1
            try:
                result = future.result()
            except Exception as e:
                errors += 1
                if scanned % 100 == 0:
                    print(f"  [{scanned}/{len(book_dirs)}] ...", file=sys.stderr)
                continue

            is_flagged = False

            if result.error:
                errors += 1
                is_flagged = True

            if not result.title_in_text and not result.error:
                title_mismatches += 1
                is_flagged = True

            if not result.author_in_text and not result.error:
                author_mismatches += 1
                is_flagged = True

            if not result.meta_vs_epub_title_match:
                internal_title_mismatches += 1
                is_flagged = True

            if not result.meta_vs_epub_author_match:
                internal_author_mismatches += 1
                is_flagged = True

            if result.likely_non_english:
                non_english_books += 1
                is_flagged = True

            if is_flagged:
                flagged_results.append(result)

            if args.verbose or is_flagged:
                flags = []
                if result.error:
                    flags.append(f"ERROR: {result.error}")
                if not result.title_in_text and not result.error:
                    flags.append("TITLE_NOT_IN_TEXT")
                if not result.author_in_text and not result.error:
                    flags.append("AUTHOR_NOT_IN_TEXT")
                if not result.meta_vs_epub_title_match:
                    flags.append(f"INTERNAL_TITLE_MISMATCH: '{result.meta_title}' vs '{result.epub_internal_title}'")
                if not result.meta_vs_epub_author_match:
                    flags.append(f"INTERNAL_AUTHOR_MISMATCH: {result.meta_authors} vs {result.epub_internal_authors}")
                if result.likely_non_english:
                    flags.append(f"LIKELY_NON_ENGLISH: {result.non_english_reason}")

                flag_str = " | ".join(flags) if flags else "OK"
                print(f"  [{scanned}/{len(book_dirs)}] {result.folder_author} / {result.folder_title}")
                if flags:
                    for f in flags:
                        print(f"    ⚠ {f}")
                elif args.verbose:
                    print(f"    ✓ OK")

            elif scanned % 200 == 0:
                print(f"  [{scanned}/{len(book_dirs)}] scanning ...", file=sys.stderr)

    # --- Summary ---
    print("\n" + "=" * 70)
    print("SCAN COMPLETE")
    print("=" * 70)
    print(f"  Total book dirs:              {len(book_dirs)}")
    print(f"  Successfully scanned:         {scanned - errors}")
    print(f"  Errors (corrupt/missing):     {errors}")
    print(f"  Title not in text:            {title_mismatches}")
    print(f"  Author not in text:           {author_mismatches}")
    print(f"  Internal title mismatch:      {internal_title_mismatches}")
    print(f"  Internal author mismatch:     {internal_author_mismatches}")
    print(f"  Likely non-English:           {non_english_books}")
    print(f"  Total flagged:                {len(flagged_results)}")

    # --- CSV output ---
    if args.output:
        with open(args.output, "w", newline="", encoding="utf-8") as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow([
                "epub_path", "folder_author", "folder_title",
                "meta_title", "meta_authors",
                "meta_language",
                "epub_internal_title", "epub_internal_authors",
                "epub_internal_language",
                "title_in_text", "author_in_text",
                "meta_title_match", "meta_author_match",
                "likely_non_english", "non_english_reason",
                "error", "text_snippet",
            ])
            for r in flagged_results:
                writer.writerow([
                    r.epub_path, r.folder_author, r.folder_title,
                    r.meta_title, "; ".join(r.meta_authors),
                    r.meta_language,
                    r.epub_internal_title, "; ".join(r.epub_internal_authors),
                    r.epub_internal_language,
                    r.title_in_text, r.author_in_text,
                    r.meta_vs_epub_title_match, r.meta_vs_epub_author_match,
                    r.likely_non_english, r.non_english_reason,
                    r.error, r.text_snippet[:200],
                ])
        print(f"\nCSV report written to: {args.output}")

    print()


if __name__ == "__main__":
    main()
