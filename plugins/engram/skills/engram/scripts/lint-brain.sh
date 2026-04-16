#!/usr/bin/env bash
# lint-brain.sh: Obsidian vault health scanner for engram
#
# Scans the vault for broken wikilinks, orphan notes, stale notes,
# and unfilled template placeholders. Designed to be run by Claude
# when something feels off, or on demand by the user.
#
# Usage: lint-brain.sh [vault-path]
#   Defaults to ~/engram
#
# Compatible with macOS bash 3.2 (no associative arrays, no ${var,,}).

set -euo pipefail

# --- Configuration -----------------------------------------------------------

VAULT="${1:-$HOME/engram}"
STALE_DAYS=90
TODAY=$(date +%Y-%m-%d)
NOW_EPOCH=$(date +%s)
STALE_THRESHOLD=$(( NOW_EPOCH - STALE_DAYS * 86400 ))

# --- Validation --------------------------------------------------------------

if [[ ! -d "$VAULT" ]]; then
	printf "Error: vault directory not found: %s\n" "$VAULT" >&2
	exit 1
fi

# --- Temp files for indexes (cleaned up on exit) -----------------------------

TMPDIR_LINT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LINT"' EXIT

# Index files: one line per entry
# names.idx: "lowercased_basename<TAB>relative_path"
# aliases.idx: "lowercased_alias<TAB>relative_path"
# paths.idx: one relative path per line
NAMES_IDX="$TMPDIR_LINT/names.idx"
ALIASES_IDX="$TMPDIR_LINT/aliases.idx"
PATHS_IDX="$TMPDIR_LINT/paths.idx"
touch "$NAMES_IDX" "$ALIASES_IDX" "$PATHS_IDX"

# --- Helper: lowercase a string (bash 3.2 compatible) ------------------------

to_lower() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# --- Build note index --------------------------------------------------------

while IFS= read -r filepath; do
	# Compute relative path by stripping vault prefix
	rel="${filepath#${VAULT}/}"
	printf '%s\n' "$rel" >> "$PATHS_IDX"

	# Index by basename without extension (lowercased)
	basename_full="${filepath##*/}"
	basename_noext="${basename_full%.md}"
	lower_name=$(to_lower "$basename_noext")
	printf '%s\t%s\n' "$lower_name" "$rel" >> "$NAMES_IDX"

	# Extract aliases from YAML frontmatter
	in_frontmatter=false
	in_aliases=false
	while IFS= read -r line; do
		if [[ "$line" == "---" ]]; then
			if $in_frontmatter; then
				break
			else
				in_frontmatter=true
				continue
			fi
		fi

		if ! $in_frontmatter; then
			continue
		fi

		# Inline format: aliases: [alias1, alias-2]
		if [[ "$line" =~ ^aliases:\ *\[(.+)\] ]]; then
			raw="${BASH_REMATCH[1]}"
			# Split on comma
			IFS=',' read -ra parts <<< "$raw"
			for part in "${parts[@]}"; do
				# Trim leading/trailing whitespace
				part=$(printf '%s' "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
				# Strip surrounding quotes
				part="${part#\"}"
				part="${part%\"}"
				part="${part#\'}"
				part="${part%\'}"
				if [[ -n "$part" ]]; then
					lower_alias=$(to_lower "$part")
					printf '%s\t%s\n' "$lower_alias" "$rel" >> "$ALIASES_IDX"
				fi
			done
			in_aliases=false
			continue
		fi

		# Multi-line format start: aliases:
		if [[ "$line" =~ ^aliases:\ *$ ]]; then
			in_aliases=true
			continue
		fi

		# Multi-line alias entry: - alias1
		if $in_aliases; then
			if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(.*) ]]; then
				part="${BASH_REMATCH[1]}"
				part="${part#\"}"
				part="${part%\"}"
				part="${part#\'}"
				part="${part%\'}"
				if [[ -n "$part" ]]; then
					lower_alias=$(to_lower "$part")
					printf '%s\t%s\n' "$lower_alias" "$rel" >> "$ALIASES_IDX"
				fi
			else
				in_aliases=false
			fi
		fi
	done < "$filepath"
done < <(find "$VAULT" -name '*.md' -not -path '*/.obsidian/*' -not -path '*/templates/*')

# --- Helper: resolve a wikilink target to a vault file -----------------------
# Returns 0 if resolved, 1 if broken.

resolve_link() {
	local target="$1"
	local target_lower
	target_lower=$(to_lower "$target")

	# Check by exact basename match (case-insensitive)
	if awk -F'\t' -v key="$target_lower" '$1 == key { found=1; exit } END { exit !found }' "$NAMES_IDX" 2>/dev/null; then
		return 0
	fi

	# Check by alias match (case-insensitive)
	if awk -F'\t' -v key="$target_lower" '$1 == key { found=1; exit } END { exit !found }' "$ALIASES_IDX" 2>/dev/null; then
		return 0
	fi

	# Check as a relative path within the vault (e.g., Sources/raw/file.pdf)
	if [[ -e "$VAULT/$target" ]]; then
		return 0
	fi

	# Also try with .md extension appended
	if [[ -e "$VAULT/$target.md" ]]; then
		return 0
	fi

	return 1
}

# --- 1. Broken Wikilinks -----------------------------------------------------

broken_count=0
broken_output=""

while IFS= read -r rel; do
	filepath="$VAULT/$rel"
	source_name="${rel##*/}"
	source_name="${source_name%.md}"

	# Extract all wikilinks: [[...]]
	while IFS= read -r raw_link; do
		[[ -z "$raw_link" ]] && continue

		# Strip outer [[ and ]]
		inner="${raw_link#\[\[}"
		inner="${inner%\]\]}"

		# Strip embed prefix !
		inner="${inner#!}"

		# Strip display text (after |)
		inner="${inner%%|*}"

		# Strip heading/block ref (after #)
		inner="${inner%%\#*}"

		# Trim whitespace
		inner=$(printf '%s' "$inner" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

		# Skip empty targets
		if [[ -z "$inner" ]]; then
			continue
		fi

		if ! resolve_link "$inner"; then
			broken_output="${broken_output}  ✗ [[${inner}]] in ${source_name}\n"
			broken_count=$(( broken_count + 1 ))
		fi
	done < <(grep -oE '\[\[!?[^]]+\]\]' "$filepath" 2>/dev/null || true)
done < "$PATHS_IDX"

# --- 2. Orphan Notes ---------------------------------------------------------
# Notes with zero inbound links. Exclude templates/ (already excluded from
# index) and Sessions/.

orphan_count=0
orphan_output=""

while IFS= read -r rel; do
	# Skip Sessions/ folder
	case "$rel" in
		Sessions/*) continue ;;
	esac

	basename_noext="${rel##*/}"
	basename_noext="${basename_noext%.md}"

	# Collect all searchable names: the basename itself + any aliases
	searchable=()
	searchable+=("$basename_noext")

	# Find aliases that map to this rel path
	while IFS=$'\t' read -r alias_name alias_path; do
		if [[ "$alias_path" == "$rel" ]]; then
			searchable+=("$alias_name")
		fi
	done < "$ALIASES_IDX"

	# Check if any other file links to this note
	found_inbound=false
	for name in "${searchable[@]}"; do
		# Search for [[Name in all .md files (partial match covers [[Name]],
		# [[Name|display]], [[Name#heading]])
		# Pipe through grep -v to exclude self-references
		if grep -rilF "[[${name}" "$VAULT" \
			--include='*.md' \
			--exclude-dir='.obsidian' \
			--exclude-dir='templates' \
			2>/dev/null | grep -vq "/${rel}$"; then
			found_inbound=true
			break
		fi
	done

	if ! $found_inbound; then
		orphan_output="${orphan_output}  ○ ${basename_noext} (${rel})\n"
		orphan_count=$(( orphan_count + 1 ))
	fi
done < "$PATHS_IDX"

# --- 3. Stale Notes -----------------------------------------------------------
# Knowledge/ and Decisions/ notes not modified in 90+ days.

stale_count=0
stale_output=""

while IFS= read -r rel; do
	# Only check Knowledge/ and Decisions/
	case "$rel" in
		Knowledge/*|Decisions/*) ;;
		*) continue ;;
	esac

	filepath="$VAULT/$rel"
	basename_noext="${rel##*/}"
	basename_noext="${basename_noext%.md}"

	# macOS: stat -f %m gives modification epoch
	mod_epoch=$(stat -f %m "$filepath")
	if (( mod_epoch < STALE_THRESHOLD )); then
		days_old=$(( (NOW_EPOCH - mod_epoch) / 86400 ))
		stale_output="${stale_output}  ⏳ ${basename_noext} (${days_old} days old)\n"
		stale_count=$(( stale_count + 1 ))
	fi
done < "$PATHS_IDX"

# --- 4. Empty Sections --------------------------------------------------------
# Notes with HTML comment placeholders (<!-- ... -->) indicating unfilled
# template sections. Templates themselves are already excluded from index.

placeholder_count=0
placeholder_output=""

while IFS= read -r rel; do
	filepath="$VAULT/$rel"
	basename_noext="${rel##*/}"
	basename_noext="${basename_noext%.md}"

	count=$(grep -c '<!--.*-->' "$filepath" 2>/dev/null) || count=0
	if (( count > 0 )); then
		placeholder_output="${placeholder_output}  📝 ${basename_noext} (${count} placeholder(s))\n"
		placeholder_count=$(( placeholder_count + 1 ))
	fi
done < "$PATHS_IDX"

# --- Output Report ------------------------------------------------------------

note_count=$(wc -l < "$PATHS_IDX" | tr -d ' ')

cat <<HEADER
=== Brain Lint Report ===
Vault: ${VAULT}
Date: ${TODAY}
HEADER

printf "\n## Broken Wikilinks\n"
if (( broken_count == 0 )); then
	printf "  ✓ No broken links found\n"
else
	printf '%b' "${broken_output}"
fi

printf "\n## Orphan Notes (no inbound links)\n"
if (( orphan_count == 0 )); then
	printf "  ✓ No orphan notes found\n"
else
	printf '%b' "${orphan_output}"
fi

printf "\n## Stale Notes (not modified in %d+ days)\n" "$STALE_DAYS"
if (( stale_count == 0 )); then
	printf "  ✓ No stale notes found\n"
else
	printf '%b' "${stale_output}"
fi

printf "\n## Empty Sections (template placeholders remaining)\n"
if (( placeholder_count == 0 )); then
	printf "  ✓ No template placeholders found\n"
else
	printf '%b' "${placeholder_output}"
fi

printf "\n## Summary\n"
printf "  Notes: %d\n" "$note_count"
printf "  Broken links: %d\n" "$broken_count"
printf "  Orphans: %d\n" "$orphan_count"
printf "  Stale: %d\n" "$stale_count"
printf "  With placeholders: %d\n" "$placeholder_count"
