#!/usr/bin/env bash
# publish-devto.sh — publish changed blog posts to dev.to
#
# Usage:
#   publish-devto.sh [OPTIONS] [FILE...]
#
# Without FILE args: reads index.yaml, publishes entries changed since last commit.
# With FILE args: publishes those files directly, skipping the index/git check.
#
# Options:
#   -h, --help          Show this help
#   -n, --dry-run       Print what would happen without calling the API
#   -f, --force         Publish all indexed files regardless of git status
#   -d, --draft         Override: publish as draft (unpublished)
#   --last-commit       Diff against HEAD~1 instead of the working tree
#
# Environment:
#   DEV_TO_API_KEY      Required — your dev.to API key
#
# State:
#   .devto-state.yaml   Tracks article IDs so updates go to the right article.
#                       Commit this file alongside your posts.

set -euo pipefail
IFS=$'\n\t'

# ── paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INDEX_FILE="${SCRIPT_DIR}/index.yaml"
STATE_FILE="${SCRIPT_DIR}/.devto-state.yaml"
DEVTO_API="https://dev.to/api/articles"

# ── flags ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
FORCE=false
DRAFT_OVERRIDE=false
USE_LAST_COMMIT=false

# ── logging ───────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  →  $*"; }
warn() { echo "WARN:  $*" >&2; }
step() { echo; echo "▸ $*"; }

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^$/{ s/^# \{0,1\}//; p }' "$0"
  exit 0
}

# ── parse args ────────────────────────────────────────────────────────────────
DIRECT_FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)         usage ;;
    -n|--dry-run)      DRY_RUN=true;         shift ;;
    -f|--force)        FORCE=true;           shift ;;
    -d|--draft)        DRAFT_OVERRIDE=true;  shift ;;
    --last-commit)     USE_LAST_COMMIT=true; shift ;;
    --)                shift; DIRECT_FILES+=("$@"); break ;;
    -*)                die "unknown option: $1 (try --help)" ;;
    *)                 DIRECT_FILES+=("$1"); shift ;;
  esac
done

# ── dependency check ──────────────────────────────────────────────────────────
for cmd in curl yq pandoc jq git; do
  command -v "$cmd" &>/dev/null || die "required command not found: $cmd (please install it)"
done

[[ -n "${DEV_TO_API_KEY:-}" ]] || die "DEV_TO_API_KEY is not set in the environment"

# ── temp dir (auto-cleaned on exit) ──────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── state helpers (yq v4) ─────────────────────────────────────────────────────

# Ensure the state file exists with the correct shape.
state_init() {
  [[ -f "$STATE_FILE" ]] || printf 'files: {}\n' > "$STATE_FILE"
}

# Print the article_id for a file, or empty string if unknown.
state_get_id() {
  local file="$1"
  state_init
  # yq outputs "null" when key is absent; convert that to empty.
  local val
  val=$(yq ".files[\"${file}\"].article_id // \"\"" "$STATE_FILE" 2>/dev/null) || true
  [[ "$val" == "null" ]] && val=""
  printf '%s' "$val"
}

# Store article_id and url for a file.
state_set() {
  local file="$1" article_id="$2" url="$3"
  state_init
  yq -i ".files[\"${file}\"].article_id = ${article_id}" "$STATE_FILE"
  yq -i ".files[\"${file}\"].url = \"${url}\""          "$STATE_FILE"
  yq -i ".files[\"${file}\"].published_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$STATE_FILE"
}

# ── git helpers ───────────────────────────────────────────────────────────────

# Returns true if the directory is inside a git repo with at least one commit.
is_git_repo() {
  git -C "$SCRIPT_DIR" rev-parse HEAD &>/dev/null
}

# List files that differ from the reference point.
changed_files() {
  if $USE_LAST_COMMIT; then
    # What changed IN the last commit (HEAD vs HEAD~1).
    if git -C "$SCRIPT_DIR" rev-parse HEAD~1 &>/dev/null; then
      git -C "$SCRIPT_DIR" diff --name-only HEAD~1 HEAD
    else
      # Only one commit — everything in it is "changed".
      git -C "$SCRIPT_DIR" diff --name-only --root HEAD
    fi
  else
    # What has changed since HEAD: staged + unstaged modifications.
    {
      git -C "$SCRIPT_DIR" diff          --name-only HEAD 2>/dev/null || true
      git -C "$SCRIPT_DIR" diff --cached --name-only HEAD 2>/dev/null || true
    } | sort -u
  fi
}

# ── org helpers ───────────────────────────────────────────────────────────────

# Extract a #+KEYWORD: value from an org file (case-insensitive).
org_keyword() {
  local file="$1" keyword="$2"
  # Matches lines like #+TITLE: My Post  or  #+title: My Post
  grep -i "^#\+${keyword}:[[:space:]]*" "$file" \
    | head -1 \
    | sed -E "s/^#\\+${keyword}:[[:space:]]*//" \
    || true
}

# Normalise org #+FILETAGS: :tag1:tag2: or #+KEYWORDS: tag1, tag2 → "tag1,tag2"
org_tags_csv() {
  local file="$1"
  local raw=""

  # Prefer KEYWORDS over FILETAGS (more readable for blog posts).
  raw=$(org_keyword "$file" "KEYWORDS")
  if [[ -z "$raw" ]]; then
    raw=$(org_keyword "$file" "FILETAGS")
  fi
  if [[ -z "$raw" ]]; then
    raw=$(org_keyword "$file" "TAGS")
  fi

  # Normalise colon-delimited (:tag1:tag2:) → comma-separated.
  if [[ "$raw" == :*: ]]; then
    raw="${raw//:/ }"
  fi

  # Strip leading/trailing whitespace, collapse spaces/commas.
  raw=$(echo "$raw" | tr ',;' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')
  echo "$raw"
}

# ── markdown front-matter helpers ─────────────────────────────────────────────

# Extract a field from YAML front matter (--- ... ---) in a markdown file.
md_field() {
  local file="$1" field="$2"
  # Grab lines between the first two "---" delimiters.
  local fm
  fm=$(awk 'BEGIN{p=0;c=0} /^---$/{c++;if(c==1){p=1;next}if(c==2){p=0}} p{print}' "$file")
  [[ -z "$fm" ]] && { echo ""; return; }
  echo "$fm" | yq ".${field} // \"\"" - 2>/dev/null || echo ""
}

# Extract the body of a markdown file (everything after front matter).
md_body() {
  local file="$1" dest="$2"
  if head -1 "$file" | grep -q '^---'; then
    # Has front matter — skip past the closing ---.
    awk 'BEGIN{p=0;c=0}
         /^---$/{c++;if(c==2){p=1;next};next}
         p{print}' "$file" > "$dest"
  else
    cp "$file" "$dest"
  fi
}

# ── tags → JSON array ─────────────────────────────────────────────────────────

# Convert a raw tags string (space- or comma-separated) to a JSON array.
# dev.to: max 4 tags, lowercase, letters/numbers/underscores only.
tags_to_json() {
  local raw="$1"
  if [[ -z "$raw" || "$raw" == "null" ]]; then
    echo "[]"
    return
  fi

  # From yq, arrays come out as "tag1\ntag2" or as "[tag1,tag2]" — normalise.
  # Replace commas, brackets, colons with spaces, then split on whitespace.
  echo "$raw" \
    | tr ',;:[]\n' ' ' \
    | tr -s ' ' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | head -4 \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_]/_/g' \
    | jq -R . \
    | jq -s .
}

# ── body conversion ───────────────────────────────────────────────────────────

# Convert an org file to a GFM markdown body (metadata stripped by pandoc).
org_to_md() {
  local src="$1" dest="$2"
  pandoc \
    --from org \
    --to   gfm \
    --wrap=none \
    --strip-comments \
    "$src" \
    -o "$dest" \
  || die "pandoc failed to convert: $src"
}

# ── API call ──────────────────────────────────────────────────────────────────

# Build the JSON payload for the dev.to articles API.
build_payload() {
  local title="$1" body="$2" tags_json="$3" description="$4" \
        canonical="$5" published="$6"

  jq -n \
    --arg     title       "$title"       \
    --arg     body        "$body"        \
    --argjson tags        "$tags_json"   \
    --arg     description "$description" \
    --arg     canonical   "$canonical"   \
    --argjson published   "$published"   \
    '{article: {
        title:        $title,
        body_markdown: $body,
        tags:         $tags,
        description:  $description,
        canonical_url: (if $canonical == "" then null else $canonical end),
        published:    $published
      }}'
}

# Call the dev.to API. Prints the response body; returns 0 on success.
api_call() {
  local method="$1" url="$2" payload="$3"
  local tmp_resp="${WORK}/response-$$.json"

  local http_code
  http_code=$(
    curl -s \
      -o "$tmp_resp" \
      -w "%{http_code}" \
      -X "$method" "$url" \
      -H "api-key: ${DEV_TO_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --retry 3 \
      --retry-delay 2 \
      --retry-all-errors \
      -d "$payload"
  )

  local response
  response=$(<"$tmp_resp")

  if [[ "$http_code" -ge 400 ]]; then
    local msg
    msg=$(echo "$response" | jq -r '.error // .message // "unknown error"' 2>/dev/null || echo "$response")
    warn "HTTP $http_code from dev.to: $msg"
    return 1
  fi

  echo "$response"
}

# ── publish one file ──────────────────────────────────────────────────────────

publish_file() {
  local file="$1"

  # Resolve to an absolute path; keep a repo-relative version for state keys.
  local abs_file rel_file
  if [[ "$file" = /* ]]; then
    abs_file="$file"
    rel_file="${file#"${SCRIPT_DIR}/"}"
  else
    abs_file="${SCRIPT_DIR}/${file}"
    rel_file="$file"
  fi

  [[ -f "$abs_file" ]] || die "file not found: $abs_file"

  local ext="${abs_file##*.}"
  local title="" description="" tags_raw="" canonical="" published_val="true"
  local body_file="${WORK}/body-$$.md"

  step "Processing: $rel_file"

  # ── extract metadata & body ────────────────────────────────────────────────
  case "$ext" in
    org)
      title=$(org_keyword "$abs_file" "TITLE")
      description=$(org_keyword "$abs_file" "DESCRIPTION")
      tags_raw=$(org_tags_csv "$abs_file")
      canonical=$(org_keyword "$abs_file" "CANONICAL_URL")
      local draft
      draft=$(org_keyword "$abs_file" "DRAFT")
      [[ "${draft,,}" == "true" ]] && published_val="false"
      info "Converting org → markdown via pandoc"
      org_to_md "$abs_file" "$body_file"
      ;;
    md|markdown)
      title=$(md_field "$abs_file" "title")
      description=$(md_field "$abs_file" "description")
      # tags may be a YAML array or a string — yq outputs either; normalise later.
      tags_raw=$(md_field "$abs_file" "tags")
      canonical=$(md_field "$abs_file" "canonical_url")
      local draft
      draft=$(md_field "$abs_file" "draft")
      [[ "${draft,,}" == "true" ]] && published_val="false"
      md_body "$abs_file" "$body_file"
      ;;
    *)
      die "unsupported extension .$ext — supported: .org, .md, .markdown"
      ;;
  esac

  # draft flag from CLI always wins.
  $DRAFT_OVERRIDE && published_val="false"

  [[ -n "$title" ]] || die "could not extract a title from: $rel_file"

  local body tags_json payload
  body=$(<"$body_file")
  tags_json=$(tags_to_json "$tags_raw")
  payload=$(build_payload "$title" "$body" "$tags_json" "$description" "$canonical" "$published_val")

  info "Title:     $title"
  info "Published: $published_val"
  info "Tags:      $tags_json"

  # ── dry run ────────────────────────────────────────────────────────────────
  if $DRY_RUN; then
    info "[dry-run] would call API — skipping."
    return 0
  fi

  # ── create or update ───────────────────────────────────────────────────────
  local article_id
  article_id=$(state_get_id "$rel_file")

  local response
  if [[ -z "$article_id" ]]; then
    info "Creating new article on dev.to…"
    response=$(api_call POST "$DEVTO_API" "$payload") \
      || die "failed to create article for: $rel_file"
  else
    info "Updating existing article id=$article_id on dev.to…"
    response=$(api_call PUT "${DEVTO_API}/${article_id}" "$payload") \
      || die "failed to update article id=$article_id for: $rel_file"
  fi

  local new_id new_url
  new_id=$(echo  "$response" | jq -r '.id')
  new_url=$(echo "$response" | jq -r '.url')

  [[ "$new_id" != "null" && -n "$new_id" ]] \
    || die "dev.to response missing article id for: $rel_file"

  state_set "$rel_file" "$new_id" "$new_url"
  info "Done: $new_url  (id=$new_id)"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  if [[ ${#DIRECT_FILES[@]} -gt 0 ]]; then
    # ── direct file mode ─────────────────────────────────────────────────────
    for f in "${DIRECT_FILES[@]}"; do
      publish_file "$f"
    done
    return
  fi

  # ── index mode ───────────────────────────────────────────────────────────
  [[ -f "$INDEX_FILE" ]] || die "index file not found: $INDEX_FILE"

  local indexed_files=()
  mapfile -t indexed_files < <(yq '.pages[]' "$INDEX_FILE" 2>/dev/null)
  [[ ${#indexed_files[@]} -gt 0 ]] || die "no entries found under .pages in $INDEX_FILE"

  if $FORCE; then
    for f in "${indexed_files[@]}"; do
      publish_file "$f"
    done
    return
  fi

  if ! is_git_repo; then
    warn "Not inside a git repo — publishing all indexed files."
    for f in "${indexed_files[@]}"; do
      publish_file "$f"
    done
    return
  fi

  # Collect changed files (paths relative to repo root).
  local changed=()
  mapfile -t changed < <(changed_files)

  local published=0
  for f in "${indexed_files[@]}"; do
    local matched=false
    for c in "${changed[@]}"; do
      # Match on full relative path OR basename (handles different CWD).
      if [[ "$c" == "$f" || "$(basename "$c")" == "$(basename "$f")" ]]; then
        matched=true
        break
      fi
    done

    if $matched; then
      publish_file "$f"
      (( published++ )) || true
    else
      echo "  –  skipping (unchanged): $f"
    fi
  done

  echo
  if [[ $published -eq 0 ]]; then
    echo "Nothing to publish — no indexed files have changed since the last commit."
    echo "(Use --force to publish all, or pass a filename directly.)"
  else
    echo "Published $published file(s)."
  fi
}

main
