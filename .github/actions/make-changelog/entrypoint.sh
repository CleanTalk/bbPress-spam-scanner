#!/usr/bin/env bash
set -euo pipefail

PLUGIN_FILE="${INPUT_PLUGIN_FILE}"
README_FILE="${INPUT_README_FILE}"
MATRIX_SERVER="${INPUT_MATRIX_SERVER:-}"
MATRIX_ROOM="${INPUT_MATRIX_ROOM:-}"
MATRIX_TOKEN="${INPUT_MATRIX_TOKEN:-}"
TARGET_BRANCH="${INPUT_TARGET_BRANCH:-beta}"
AUTO_COMMIT_MESSAGE="${INPUT_AUTO_COMMIT_MESSAGE:-}"

TMP_DIR="$(mktemp -d)"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-${TMP_DIR}/summary.md}"
ENTRIES_FILE="${TMP_DIR}/entries.txt"
BLOCK_FILE="${TMP_DIR}/block.txt"
trap 'rm -rf "${TMP_DIR}"' EXIT

notice() { echo "::notice::$1"; }
warn() { echo "::warning::$1"; }
error_annot() { echo "::error::$1"; }
append_summary() { printf '%s\n' "$1" >> "$SUMMARY_FILE"; }

escape_html() {
  python3 - <<'PY' "$1"
import html, sys
print(html.escape(sys.argv[1]))
PY
}

send_matrix() {
  local body="$1"
  local formatted="${2:-}"
  [[ -n "$MATRIX_SERVER" && -n "$MATRIX_ROOM" && -n "$MATRIX_TOKEN" ]] || return 0
  python3 - "$MATRIX_SERVER" "$MATRIX_ROOM" "$MATRIX_TOKEN" "$body" "$formatted" <<'PY'
import json, sys, urllib.request, urllib.parse, uuid
server, room, token, body, formatted = sys.argv[1:6]
server = server.rstrip('/')
room = urllib.parse.quote(room, safe='')
txn = urllib.parse.quote(uuid.uuid4().hex, safe='')
token = urllib.parse.quote(token, safe='')
url = f"{server}/_matrix/client/v3/rooms/{room}/send/m.room.message/{txn}?access_token={token}"
payload = {"msgtype": "m.text", "body": body}
if formatted:
    payload["format"] = "org.matrix.custom.html"
    payload["formatted_body"] = formatted
req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}, method="PUT")
with urllib.request.urlopen(req, timeout=30) as response:
    response.read()
PY
}

fail() {
  local msg="$1"
  error_annot "$msg"
  append_summary "## Error\n- $msg\n"
  send_matrix "Make changelog failed: $msg" "<strong>Make changelog failed</strong><br>$(escape_html "$msg")"
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "Required file not found: $1"
}

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

current_date() {
  date '+%b %d %Y'
}

get_plugin_version() {
  local version
  version="$(sed -nE 's/^\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$/\1/p' "$PLUGIN_FILE" | head -n1)"
  [[ -n "$version" ]] || fail "Could not read Version from $PLUGIN_FILE"
  printf '%s' "$version"
}

get_stable_tag() {
  local stable
  stable="$(sed -nE 's/^Stable tag:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$/\1/p' "$README_FILE" | head -n1)"
  [[ -n "$stable" ]] || fail "Could not read Stable tag from $README_FILE"
  printf '%s' "$stable"
}

find_version_boundary() {
  local version="$1"
  local escaped_version
  escaped_version="${version//./\\.}"
  local commits commit content current previous
  mapfile -t commits < <(git log --format='%H' -- "$PLUGIN_FILE")
  [[ ${#commits[@]} -gt 0 ]] || fail "No git history found for $PLUGIN_FILE"
  for ((i=0; i<${#commits[@]}; i++)); do
    commit="${commits[$i]}"
    content="$(git show "${commit}:${PLUGIN_FILE}" 2>/dev/null || true)"
    [[ -n "$content" ]] || continue
    current="$(printf '%s\n' "$content" | sed -nE 's/^\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$/\1/p' | head -n1)"
    [[ "$current" == "$version" ]] || continue
    if (( i + 1 < ${#commits[@]} )); then
      previous="$(git show "${commits[$((i+1))]}:${PLUGIN_FILE}" 2>/dev/null | sed -nE 's/^\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$/\1/p' | head -n1)"
      if [[ "$previous" != "$version" ]]; then
        printf '%s' "$commit"
        return 0
      fi
    else
      printf '%s' "$commit"
      return 0
    fi
  done
  fail "Could not find the commit where version $version was introduced"
}

validate_release_subject() {
  local sha="$1"
  local subject="$2"
  local marker_count
  marker_count="$(printf '%s' "$subject" | grep -oE '\{to_release:[[:space:]]*[0-9]+\}' | wc -l | tr -d ' ')"
  if [[ "$marker_count" -gt 1 ]]; then
    fail "Commit $sha contains more than one {to_release: ...} marker"
  fi
  if [[ "$marker_count" -eq 1 ]] && ! printf '%s' "$subject" | grep -Eq '^\{to_release:[[:space:]]*[0-9]+\}[[:space:]]+(Fix|Upd|New)\..+$'; then
    fail "Commit $sha has invalid release subject: $subject"
  fi
}

collect_release_entries() {
  local boundary_commit="$1"
  : > "$ENTRIES_FILE"
  local found=0 sha subject parsed task kind text line
  while IFS=$'\x1f' read -r sha subject; do
    [[ -n "$sha" ]] || continue
    validate_release_subject "$sha" "$subject"
    if printf '%s' "$subject" | grep -Eq '^\{to_release:[[:space:]]*[0-9]+\}[[:space:]]+(Fix|Upd|New)\..+$'; then
      parsed="$(python3 - <<'PY' "$subject"
import re, sys
subject = sys.argv[1]
m = re.match(r'^\{to_release:\s*(\d+)\}\s+(Fix|Upd|New)\.\s*(.+)$', subject)
if m:
    print('\t'.join(m.groups()))
PY
)"
      IFS=$'\t' read -r task kind text <<< "$parsed"
      text="$(trim "$text")"
      line="${kind}. ${text} [https://app.doboard.com/1/task/${task}](https://app.doboard.com/1/task/${task})"
      printf '%s\n' "$line" >> "$ENTRIES_FILE"
      found=1
    fi
  done < <(git log --first-parent --format='%H%x1f%s' "${boundary_commit}..HEAD")
  [[ "$found" -eq 1 ]] || fail "No valid release commits found after version boundary"
  sort -o "$ENTRIES_FILE" "$ENTRIES_FILE"
}

build_changelog_block() {
  local version="$1"
  local when="$2"
  {
    printf '= %s %s =\n' "$version" "$when"
    while IFS= read -r entry; do
      printf ' * %s\n' "$entry"
    done < "$ENTRIES_FILE"
  } > "$BLOCK_FILE"
}

rewrite_readme() {
  local version="$1"
  python3 - <<'PY' "$README_FILE" "$BLOCK_FILE" "$version"
from pathlib import Path
import re, sys
readme_path = Path(sys.argv[1])
block_path = Path(sys.argv[2])
version = sys.argv[3]
text = readme_path.read_text(encoding='utf-8')
block = block_path.read_text(encoding='utf-8').rstrip() + '\n\n'
text_new = re.sub(r'^Stable tag:\s*.*$', f'Stable tag: {version}', text, count=1, flags=re.MULTILINE)
if text_new == text:
    raise SystemExit('Stable tag not found for replacement')
pattern = re.compile(r'(== Changelog ==\n\n)(.*?)(\n(?== [A-Z][a-z]+ ==)|\Z)', re.S)
m = pattern.search(text_new)
if not m:
    raise SystemExit('Changelog section not found')
replacement = m.group(1) + block + (m.group(3) if m.group(3).startswith('\n== ') else '')
text_new = text_new[:m.start()] + replacement + text_new[m.end():]
readme_path.write_text(text_new, encoding='utf-8')
PY
}

append_job_summary() {
  local version="$1"
  local stable="$2"
  local boundary="$3"
  append_summary "# Make changelog"
  append_summary ""
  append_summary "## Validation"
  append_summary "- Plugin version: \\`${version}\\`"
  append_summary "- Stable tag before update: \\`${stable}\\`"
  append_summary "- Version boundary commit: \\`${boundary}\\`"
  append_summary ""
  append_summary "## Entries"
  while IFS= read -r entry; do
    append_summary "- ${entry}"
  done < "$ENTRIES_FILE"
  append_summary ""
  append_summary "## Changelog block"
  append_summary '```text'
  cat "$BLOCK_FILE" >> "$SUMMARY_FILE"
  append_summary '```'
  append_summary ""
}

send_stage_notice() {
  local stage="$1"
  local text="$2"
  notice "$stage: $text"
  send_matrix "${stage}: ${text}" "<strong>${stage}</strong><br>$(escape_html "$text")"
}

commit_and_push() {
  local version="$1"
  local message="${AUTO_COMMIT_MESSAGE:-chore(changelog): rebuild readme for v${version} [skip ci]}"
  if git diff --quiet -- "$README_FILE"; then
    warn "No readme changes detected after rebuild"
    append_summary "## Commit\n- No changes to commit.\n"
    return 0
  fi
  git config user.name 'github-actions[bot]'
  git config user.email 'github-actions[bot]@users.noreply.github.com'
  git add "$README_FILE"
  git commit -m "$message"
  git push origin "HEAD:${TARGET_BRANCH}"
  append_summary "## Commit\n- Changes committed and pushed to \\`${TARGET_BRANCH}\\`.\n"
}

main() {
  require_file "$PLUGIN_FILE"
  require_file "$README_FILE"
  append_summary ""
  send_stage_notice "Start" "Workflow started for branch ${TARGET_BRANCH}."

  local version stable boundary date_now
  version="$(get_plugin_version)"
  stable="$(get_stable_tag)"
  [[ "$stable" == "$version" ]] || fail "Stable tag ${stable} does not match plugin version ${version} before rebuild"

  send_stage_notice "Parsing" "Detected plugin version ${version}."
  boundary="$(find_version_boundary "$version")"
  send_stage_notice "Validation" "Found version boundary at ${boundary}."

  collect_release_entries "$boundary"
  date_now="$(current_date)"
  build_changelog_block "$version" "$date_now"
  send_stage_notice "Changelog" "Built top changelog block with $(wc -l < "$ENTRIES_FILE" | tr -d ' ') entries."

  rewrite_readme "$version"
  send_stage_notice "Readme" "Updated Stable tag and top changelog block in ${README_FILE}."

  append_job_summary "$version" "$stable" "$boundary"
  send_matrix "Make changelog entries for v${version}" "<strong>Make changelog entries for v${version}</strong><br><pre>$(python3 - <<'PY' "$BLOCK_FILE"
from pathlib import Path
import html, sys
print(html.escape(Path(sys.argv[1]).read_text(encoding='utf-8')))
PY
)</pre>"

  commit_and_push "$version"
  send_stage_notice "Success" "Changelog rebuilt successfully for v${version}."
}

main "$@"
