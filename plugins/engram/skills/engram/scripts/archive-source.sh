#!/usr/bin/env bash
set -euo pipefail

# archive-source.sh — Main URL dispatcher for engram Sources ingestion.
#
# Takes a URL or local file path, detects the source type, routes to the
# appropriate download/conversion tool, and saves a markdown note (with YAML
# frontmatter) to ~/engram/Sources/.
#
# Usage:
#   archive-source.sh <url-or-path> [custom-filename-stem]
#
# Output contract:
#   - Prints the companion markdown note path to stdout on success.
#   - Prints "↩ <path>" if a dedup match is found (exit 0).
#   - Non-zero exit on failure.

# -- Configuration ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VAULT_DIR="$HOME/engram"
SOURCES_DIR="$VAULT_DIR/Sources"
TODAY="$(date +%Y-%m-%d)"

# -- Helpers ------------------------------------------------------------------

die() { echo "Error: $*" >&2; exit 1; }
warn() { echo "Warning: $*" >&2; }

# Slugify a string: lowercase, replace non-alnum with hyphens, collapse,
# trim leading/trailing hyphens, cap at 80 chars.
slugify() {
  local input="$1"
  echo "$input" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-80
}

# Canonicalize a URL: strip tracking params, fragments, trailing slashes.
canonicalize_url() {
  local url="$1"
  # Strip fragment
  url="${url%%#*}"
  # Strip trailing slashes (but keep protocol slashes)
  url="$(echo "$url" | sed 's|/*$||')"
  # Strip common tracking params (utm_*, ref, fbclid, etc.)
  # We parse query string carefully to preserve non-tracking params.
  local base query clean_params
  base="${url%%\?*}"
  if [[ "$url" == *"?"* ]]; then
    query="${url#*\?}"
    clean_params=""
    # Split on & and filter
    IFS='&' read -ra params <<< "$query"
    for param in "${params[@]}"; do
      local key="${param%%=*}"
      case "$key" in
        utm_*|ref|fbclid|gclid|mc_cid|mc_eid|__s|_hsenc|_hsmi|mkt_tok|s_cid) ;;
        *) clean_params="${clean_params:+${clean_params}&}${param}" ;;
      esac
    done
    if [[ -n "$clean_params" ]]; then
      url="${base}?${clean_params}"
    else
      url="$base"
    fi
  fi
  echo "$url"
}

# Check if a URL already exists in Sources frontmatter. Prints the path if found.
check_dedup() {
  local canonical="$1"
  # Search all .md files in Sources/ for a matching url: frontmatter line
  # Use -F for fixed-string matching so dots/question marks in URLs aren't
  # interpreted as regex operators.
  local match
  match="$(grep -rlF "url: \"${canonical}\"" "$SOURCES_DIR" --include='*.md' 2>/dev/null | head -1)" || true
  if [[ -n "$match" ]]; then
    echo "$match"
    return 0
  fi
  return 1
}

# Write YAML frontmatter + body to a file.
# Wraps body in ## Content / ## Related sections per source template.
# Arguments: file type url author raw_ref body
write_note() {
  local file="$1" type="$2" url="$3" author="$4" raw_ref="$5"
  shift 5
  local body="$*"

  {
    echo "---"
    echo "aliases: []"
    echo "tags: [source]"
    echo "type: $type"
    echo "url: \"$url\""
    if [[ -n "$author" ]]; then
      echo "author: \"$author\""
    fi
    if [[ -n "$raw_ref" ]]; then
      echo "raw: \"[[${raw_ref}]]\""
    fi
    echo "captured: $TODAY"
    echo "---"
    echo ""
    echo "## Content"
    echo ""
    printf '%s\n' "$body"
    echo ""
    echo "## Related"
    echo ""
  } > "$file"
}

# Derive a filename stem from a URL or title.
# $1 = URL, $2 = optional custom stem
get_stem() {
  local url="$1"
  local custom="${2:-}"

  if [[ -n "$custom" ]]; then
    slugify "$custom"
    return
  fi

  # Try to get title from defuddle for HTTP URLs
  if [[ "$url" =~ ^https?:// ]]; then
    local title
    title="$(defuddle parse "$url" -p title 2>/dev/null)" || true
    if [[ -n "$title" && ${#title} -gt 2 ]]; then
      slugify "$title"
      return
    fi
  fi

  # Fallback: last URL path segment (or filename for local paths)
  local segment
  segment="$(basename "${url%%\?*}")"
  # Remove file extension for the slug
  segment="${segment%.*}"
  slugify "$segment"
}

# Ensure a target directory exists.
ensure_dir() { mkdir -p "$1"; }

# Resolve a collision-safe output path.
# If the file already exists, append -1, -2, etc. until a free name is found.
# Arguments: directory stem extension
resolve_outpath() {
  local dir="$1" stem="$2" ext="${3:-.md}"
  local candidate="$dir/${stem}${ext}"
  if [[ ! -e "$candidate" ]]; then
    echo "$candidate"
    return
  fi
  local i=1
  while [[ -e "$dir/${stem}-${i}${ext}" ]]; do
    (( i++ ))
  done
  echo "$dir/${stem}-${i}${ext}"
}

# -- Handlers -----------------------------------------------------------------

handle_twitter() {
  local url="$1" stem="$2"
  local outdir="$SOURCES_DIR/tweets"
  ensure_dir "$outdir"

  local body author
  body="$("$SCRIPT_DIR/crawl-thread.py" "$url")" || die "crawl-thread.py failed for $url"

  # Extract author from the first markdown heading line
  author="$(echo "$body" | sed -n 's/.*Thread by @\([A-Za-z0-9_]*\).*/\1/p' | head -1)" || true

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "tweet" "$url" "${author:-}" "" "$body"
  echo "$outfile"
}

handle_bluesky() {
  local url="$1" stem="$2"
  local outdir="$SOURCES_DIR/posts"
  ensure_dir "$outdir"

  # Parse handle and post ID from URL: bsky.app/profile/<handle>/post/<id>
  local handle post_id
  handle="$(echo "$url" | sed -n 's|.*bsky\.app/profile/\([^/]*\)/post/.*|\1|p')"
  post_id="$(echo "$url" | sed -n 's|.*/post/\([^/?#]*\).*|\1|p')"

  [[ -n "$handle" && -n "$post_id" ]] || die "Could not parse Bluesky URL: $url"

  # Resolve handle to DID
  local did_resp did
  did_resp="$(curl -sL "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle=${handle}")" \
    || die "Failed to resolve Bluesky handle: $handle"
  did="$(echo "$did_resp" | jq -r '.did // empty')"
  [[ -n "$did" ]] || die "Could not resolve DID for handle: $handle"

  # Construct AT URI and fetch post
  local at_uri="at://${did}/app.bsky.feed.post/${post_id}"
  local encoded_uri
  encoded_uri="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${at_uri}', safe=''))")"
  local post_resp
  post_resp="$(curl -sL "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=${encoded_uri}&depth=0")" \
    || die "Failed to fetch Bluesky post: $at_uri"

  # Extract fields from JSON
  local text author_name created_at
  text="$(echo "$post_resp" | jq -r '.thread.post.record.text // "No text"')"
  author_name="$(echo "$post_resp" | jq -r '.thread.post.author.displayName // .thread.post.author.handle')"
  created_at="$(echo "$post_resp" | jq -r '.thread.post.record.createdAt // ""' | cut -dT -f1)"

  local body
  body="$(cat <<BSKY
# Post by ${author_name} (@${handle})

**Date:** ${created_at}
**Source:** ${url}

---

${text}
BSKY
)"

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "post" "$url" "$author_name" "" "$body"
  echo "$outfile"
}

handle_youtube() {
  local url="$1" stem="$2"
  local outdir="$SOURCES_DIR/videos"
  ensure_dir "$outdir"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" RETURN

  # Download subtitles (auto-generated or manual)
  yt-dlp --write-auto-sub --write-sub --sub-lang en --sub-format vtt \
    --skip-download --no-playlist -o "$tmpdir/%(title)s.%(ext)s" "$url" 2>/dev/null \
    || die "yt-dlp failed for $url"

  # Find the VTT file
  local vtt_file
  vtt_file="$(find "$tmpdir" -name '*.vtt' | head -1)"
  [[ -n "$vtt_file" ]] || die "No subtitles found for $url"

  # Clean the transcript
  local transcript
  transcript="$("$SCRIPT_DIR/clean-transcript.py" "$vtt_file")" \
    || die "clean-transcript.py failed"

  # Get video title from yt-dlp
  local title author
  title="$(yt-dlp --get-title --no-playlist "$url" 2>/dev/null)" || title=""
  author="$(yt-dlp --print uploader --no-playlist "$url" 2>/dev/null)" || author=""

  # Re-derive stem from video title if no custom stem was given
  if [[ -z "$2" && -n "$title" ]]; then
    stem="$(slugify "$title")"
  fi

  local body
  body="$(cat <<VID
# ${title:-Video}

**Channel:** ${author:-Unknown}
**Source:** ${url}

---

## Transcript

${transcript}
VID
)"

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "video" "$url" "${author:-}" "" "$body"
  echo "$outfile"
}

handle_gist() {
  local url="$1" stem="$2"
  local outdir="$SOURCES_DIR/articles"
  ensure_dir "$outdir"

  # Extract user/gist_id from URL
  local gist_path
  gist_path="$(echo "$url" | sed -n 's|.*gist\.github\.com/\(.*\)|\1|p' | sed 's|/$||')"
  [[ -n "$gist_path" ]] || die "Could not parse gist URL: $url"

  local raw_content
  raw_content="$(curl -sL "https://gist.githubusercontent.com/${gist_path}/raw")" \
    || die "Failed to fetch gist: $url"

  # Extract author from gist path (first segment)
  local author
  author="$(echo "$gist_path" | cut -d/ -f1)"

  local body
  body="$(cat <<GIST
# Gist by ${author}

**Source:** ${url}

---

\`\`\`
${raw_content}
\`\`\`
GIST
)"

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "article" "$url" "$author" "" "$body"
  echo "$outfile"
}

handle_reddit() {
  local url="$1" stem="$2"
  local outdir="$SOURCES_DIR/posts"
  ensure_dir "$outdir"

  # Rewrite to old.reddit.com for cleaner HTML
  local old_url
  old_url="$(echo "$url" | sed 's|://www\.reddit\.com|://old.reddit.com|; s|://reddit\.com|://old.reddit.com|')"

  local body
  body="$(defuddle parse "$old_url" --md 2>/dev/null)" || die "defuddle failed for $old_url"

  local author
  author="$(defuddle parse "$old_url" -p author 2>/dev/null)" || author=""

  # Paywall / thin content detection
  if [[ ${#body} -lt 500 ]]; then
    warn "Content is very short (${#body} chars). Possible paywall or empty page."
    warn "Check Wayback Machine: curl -sI \"https://web.archive.org/web/2024*/$url\""
  fi

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "post" "$url" "${author:-}" "" "$body"
  echo "$outfile"
}

handle_pdf() {
  local input="$1" stem="$2"
  local rawdir="$SOURCES_DIR/raw"
  local outdir="$SOURCES_DIR/articles"
  ensure_dir "$rawdir"
  ensure_dir "$outdir"

  local raw_file="$rawdir/${stem}.pdf"

  # Download or copy the PDF
  if [[ "$input" =~ ^https?:// ]]; then
    curl -sL -o "$raw_file" "$input" || die "Failed to download PDF: $input"
  else
    cp "$input" "$raw_file" || die "Failed to copy PDF: $input"
  fi

  # Extract text
  local text
  text="$(pdftotext "$raw_file" - 2>/dev/null)" || text="(pdftotext extraction failed)"

  local raw_ref="Sources/raw/${stem}.pdf"

  local body
  body="$(cat <<PDF
# ${stem}

**Source:** ${input}

---

${text}
PDF
)"

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "paper" "$input" "" "$raw_ref" "$body"
  echo "$outfile"
}

handle_docx() {
  local input="$1" stem="$2"
  local outdir="$SOURCES_DIR/documents"
  ensure_dir "$outdir"

  local pandoc_input="$input"
  local tmpfile=""

  # If the input is a URL, download to a temp file first
  if [[ "$input" =~ ^https?:// ]]; then
    tmpfile="$(mktemp "${TMPDIR:-/tmp}/docx-XXXXXX.docx")"
    curl -sL -o "$tmpfile" "$input" || { rm -f "$tmpfile"; die "Failed to download docx: $input"; }
    pandoc_input="$tmpfile"
  fi

  local body
  body="$(pandoc -f docx -t markdown "$pandoc_input" 2>/dev/null)" || { rm -f "$tmpfile"; die "pandoc failed for $input"; }

  [[ -n "$tmpfile" ]] && rm -f "$tmpfile"

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "document" "$input" "" "" "$body"
  echo "$outfile"
}

handle_pptx() {
  local input="$1" stem="$2"
  local outdir="$SOURCES_DIR/documents"
  ensure_dir "$outdir"

  local pandoc_input="$input"
  local tmpfile=""

  # If the input is a URL, download to a temp file first
  if [[ "$input" =~ ^https?:// ]]; then
    tmpfile="$(mktemp "${TMPDIR:-/tmp}/pptx-XXXXXX.pptx")"
    curl -sL -o "$tmpfile" "$input" || { rm -f "$tmpfile"; die "Failed to download pptx: $input"; }
    pandoc_input="$tmpfile"
  fi

  local body
  body="$(pandoc -f pptx -t markdown "$pandoc_input" 2>/dev/null)" || { rm -f "$tmpfile"; die "pandoc failed for $input"; }

  [[ -n "$tmpfile" ]] && rm -f "$tmpfile"

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "document" "$input" "" "" "$body"
  echo "$outfile"
}

handle_web_article() {
  local url="$1" stem="$2"
  local outdir="$SOURCES_DIR/articles"
  ensure_dir "$outdir"

  local body
  body="$(defuddle parse "$url" --md 2>/dev/null)" || die "defuddle failed for $url"

  local author
  author="$(defuddle parse "$url" -p author 2>/dev/null)" || author=""

  # Paywall / thin content detection
  if [[ ${#body} -lt 500 ]]; then
    warn "Content is very short (${#body} chars). Possible paywall or empty page."
    warn "Check Wayback Machine: curl -sI \"https://web.archive.org/web/2024*/$url\""
  fi

  local outfile
  outfile="$(resolve_outpath "$outdir" "$stem")"
  write_note "$outfile" "article" "$url" "${author:-}" "" "$body"
  echo "$outfile"
}

handle_local_file() {
  local input="$1" stem="$2"
  local rawdir="$SOURCES_DIR/raw"
  ensure_dir "$rawdir"

  local ext="${input##*.}"
  local raw_file="$rawdir/${stem}.${ext}"
  cp "$input" "$raw_file" || die "Failed to copy local file: $input"

  local raw_ref="Sources/raw/${stem}.${ext}"

  local body
  body="$(cat <<LOCAL
# ${stem}

**Source:** local file — ${input}

---

(Binary file archived. See raw file for original content.)
LOCAL
)"

  local outfile
  outfile="$(resolve_outpath "$rawdir" "$stem")"
  write_note "$outfile" "raw" "$input" "" "$raw_ref" "$body"
  echo "$outfile"
}

# -- Main dispatch ------------------------------------------------------------

main() {
  [[ $# -ge 1 ]] || { echo "Usage: archive-source.sh <url-or-path> [custom-stem]" >&2; exit 1; }

  local input="$1"
  local custom_stem="${2:-}"

  # Determine if this is a URL or local file
  local is_url=false
  if [[ "$input" =~ ^https?:// ]]; then
    is_url=true
  fi

  # -- Dedup check for URLs --
  if $is_url; then
    local canonical
    canonical="$(canonicalize_url "$input")"
    local existing
    if existing="$(check_dedup "$canonical")"; then
      echo "↩ $existing"
      exit 0
    fi
    # Use canonical URL from here on for frontmatter consistency
    input="$canonical"
  fi

  # -- Detect source type and route --
  local stem
  local handler=""

  case "$input" in
    *x.com/* | *twitter.com/*)
      handler="twitter"
      stem="${custom_stem:-$(slugify "$(echo "$input" | sed -n 's|.*status/\([0-9]*\).*|\1|p' || basename "$input")")}"
      ;;
    *bsky.app/profile/*/post/*)
      handler="bluesky"
      stem="${custom_stem:-$(slugify "$(echo "$input" | sed 's|.*/post/||; s|[/?#].*||')")}"
      ;;
    *youtube.com/watch* | *youtu.be/*)
      handler="youtube"
      stem="${custom_stem:-$(get_stem "$input" "")}"
      ;;
    *gist.github.com/*)
      handler="gist"
      stem="${custom_stem:-$(slugify "$(echo "$input" | sed 's|.*/||; s|[/?#].*||')")}"
      ;;
    *reddit.com/*)
      handler="reddit"
      stem="${custom_stem:-$(get_stem "$input" "")}"
      ;;
    *.pdf)
      handler="pdf"
      stem="${custom_stem:-$(slugify "$(basename "${input%.*}")")}"
      ;;
    *.docx)
      handler="docx"
      stem="${custom_stem:-$(slugify "$(basename "${input%.*}")")}"
      ;;
    *.pptx)
      handler="pptx"
      stem="${custom_stem:-$(slugify "$(basename "${input%.*}")")}"
      ;;
    *)
      if $is_url; then
        handler="web_article"
        stem="${custom_stem:-$(get_stem "$input" "")}"
      else
        # Local file (non-URL, not a recognized extension)
        [[ -f "$input" ]] || die "File not found: $input"
        handler="local_file"
        stem="${custom_stem:-$(slugify "$(basename "${input%.*}")")}"
      fi
      ;;
  esac

  # Apply custom stem override (slugify it)
  if [[ -n "$custom_stem" ]]; then
    stem="$(slugify "$custom_stem")"
  fi

  # Ensure stem is not empty
  [[ -n "$stem" ]] || stem="source-$(date +%s)"

  echo "Archiving [$handler]: $input" >&2
  echo "Stem: $stem" >&2

  # Dispatch to handler
  "handle_${handler}" "$input" "$stem"
}

main "$@"
