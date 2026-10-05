#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "::error::Command failed on line ${LINENO}: ${BASH_COMMAND}"' ERR

VERSION="${INPUT_VERSION}"
DRY_RUN="${INPUT_DRY_RUN}"
SVN_USERNAME="${INPUT_SVN_USERNAME}"
SVN_PASSWORD="${INPUT_SVN_PASSWORD}"
SVN_URL="${INPUT_SVN_URL}"
MATRIX_SERVER="${INPUT_MATRIX_SERVER:-}"
MATRIX_ROOM="${INPUT_MATRIX_ROOM:-}"
MATRIX_TOKEN="${INPUT_MATRIX_TOKEN:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-${TMP_DIR}/summary.md}"
MATRIX_LOG_TXT="${TMP_DIR}/matrix.txt"
MATRIX_LOG_HTML="${TMP_DIR}/matrix.html"
: > "$MATRIX_LOG_TXT"
: > "$MATRIX_LOG_HTML"
trap 'rm -rf "${TMP_DIR}"' EXIT

notice() { echo "::notice::$1"; }
warn() { echo "::warning::$1"; }
error_annot() { echo "::error::$1"; }
append_summary() { printf '%s\n' "$1" >> "$SUMMARY_FILE"; }

escape_html_text() {
  python3 "$SCRIPT_DIR/utils.py" escape-text "$1"
}

send_matrix() {
  local body="$1"
  local formatted="${2:-}"
  [[ -n "$MATRIX_SERVER" && -n "$MATRIX_ROOM" && -n "$MATRIX_TOKEN" ]] || return 0
  python3 "$SCRIPT_DIR/matrix_send.py" "$MATRIX_SERVER" "$MATRIX_ROOM" "$MATRIX_TOKEN" "$body" "$formatted"
}

log_stage() {
  local stage="$1"
  local text="$2"
  notice "$stage: $text"
  printf '%s: %s\n' "$stage" "$text" >> "$MATRIX_LOG_TXT"
  printf '<li><strong>%s</strong>: %s</li>\n' "$stage" "$(escape_html_text "$text")" >> "$MATRIX_LOG_HTML"
}

flush_matrix() {
  local header="$1"
  local body_txt formatted
  body_txt="${header}"$'\n\n'"$(cat "$MATRIX_LOG_TXT")"
  formatted="<strong>${header}</strong><br><ul>$(cat "$MATRIX_LOG_HTML")</ul>"
  send_matrix "$body_txt" "$formatted" || true
}

fail() {
  local msg="$1"
  error_annot "$msg"
  append_summary "## Error"
  append_summary "- $msg"
  printf 'ERROR: %s\n' "$msg" >> "$MATRIX_LOG_TXT"
  printf '<li><strong>ERROR</strong>: %s</li>\n' "$(escape_html_text "$msg")" >> "$MATRIX_LOG_HTML"
  flush_matrix "SVN publish failed"
  exit 1
}

require_var() {
  [[ -n "${!1:-}" ]] || fail "Required environment variable is empty: $1"
}

require_var VERSION
require_var SVN_USERNAME
require_var SVN_PASSWORD
require_var SVN_URL
[[ -n "${GITHUB_WORKSPACE:-}" ]] || fail "GITHUB_WORKSPACE is empty"

VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid version: $VERSION"
[[ "$DRY_RUN" == "true" || "$DRY_RUN" == "false" ]] || fail "dry_run must be true or false"

SLUG="cleantalk-bbpress-spam-scanner"
DOWNLOAD_URL="https://downloads.wordpress.org/plugin/${SLUG}.${VERSION}.zip"
DOWNLOADED_ZIP="${TMP_DIR}/${SLUG}.${VERSION}.zip"
PREPARED_CONTENT_DIR="${TMP_DIR}/prepared"
LOCAL_MANIFEST="${TMP_DIR}/prepared.sha256"
ZIP_MANIFEST="${TMP_DIR}/zip.sha256"
IGNORE_FILE="${GITHUB_WORKSPACE}/.7zignore"

append_summary "# WordPress SVN publish"
append_summary ""
append_summary "## Context"
append_summary "- Repository: ${GITHUB_REPOSITORY}"
append_summary "- Release payload source: master checkout"
append_summary "- Ignore file: .7zignore"
append_summary "- Final version: ${VERSION}"
append_summary "- Dry run: ${DRY_RUN}"
append_summary "- SVN target: trunk and tags/${VERSION}"
append_summary "- Expected download URL: ${DOWNLOAD_URL}"
append_summary ""

log_stage "Start" "Workflow started for final version ${VERSION}. Payload source: master checkout filtered by .7zignore. Dry run: ${DRY_RUN}."

[[ -f "$IGNORE_FILE" ]] || fail ".7zignore is missing in the repository root"
mkdir -p "$PREPARED_CONTENT_DIR"
rsync -a --exclude-from="$IGNORE_FILE" "${GITHUB_WORKSPACE}/" "$PREPARED_CONTENT_DIR/"
log_stage "Prepare payload" "Copied master checkout to the release tree using .7zignore."

README_FILE="${PREPARED_CONTENT_DIR}/readme.txt"
[[ -f "$README_FILE" ]] || fail "readme.txt not found in the filtered master tree"
HEADER_FILES=()
while IFS= read -r -d '' file; do
  if grep -q -E '^[[:space:]]*Version:[[:space:]]*' "$file"; then
    HEADER_FILES+=("$file")
  fi
done < <(find "$PREPARED_CONTENT_DIR" -maxdepth 1 -type f -name '*.php' -print0)
[[ ${#HEADER_FILES[@]} -eq 1 ]] || fail "Expected exactly one plugin main file with a Version header in the filtered tree, found ${#HEADER_FILES[@]}"
MAIN_PLUGIN_FILE="${HEADER_FILES[0]}"
PLUGIN_HEADER_VERSION="$(grep -m1 -E '^[[:space:]]*Version:[[:space:]]*' "$MAIN_PLUGIN_FILE" | sed -E 's/^[[:space:]]*Version:[[:space:]]*//; s/[[:space:]]+$//')"
README_STABLE_TAG="$(grep -m1 -E '^Stable tag:[[:space:]]*' "$README_FILE" | sed -E 's/^Stable tag:[[:space:]]*//; s/[[:space:]]+$//')"
[[ "$PLUGIN_HEADER_VERSION" == "$VERSION" ]] || fail "Plugin header Version (${PLUGIN_HEADER_VERSION}) in $(basename "$MAIN_PLUGIN_FILE") does not match requested version (${VERSION})"
[[ "$README_STABLE_TAG" == "$VERSION" ]] || fail "readme.txt Stable tag (${README_STABLE_TAG}) does not match requested version (${VERSION})"
log_stage "Version check" "Plugin header in $(basename "$MAIN_PLUGIN_FILE") and readme.txt Stable tag both match ${VERSION}."

python3 "$SCRIPT_DIR/manifest_tools.py" dir-manifest "$PREPARED_CONTENT_DIR" "$LOCAL_MANIFEST"
LOCAL_FILE_COUNT="$(wc -l < "$LOCAL_MANIFEST" | tr -d ' ')"
log_stage "Manifest" "Prepared release manifest built from filtered master tree with ${LOCAL_FILE_COUNT} files."

svn checkout "$SVN_URL" svn-repo \
  --username "$SVN_USERNAME" \
  --password "$SVN_PASSWORD" \
  --non-interactive \
  --trust-server-cert
log_stage "Checkout" "SVN repository checked out successfully."

rsync -a --delete "$PREPARED_CONTENT_DIR/" svn-repo/trunk/
log_stage "Sync" "Filtered master tree synced to svn-repo/trunk."

cd svn-repo
svn status | awk '/^!/{print $2}' | xargs -r svn rm
svn add --force trunk --parents --depth infinity >/dev/null 2>&1 || true
STATUS_OUTPUT="$(svn status || true)"
log_stage "Prepare" "SVN working copy prepared for trunk update."

append_summary "## SVN status"
append_summary '```text'
if [[ -n "$STATUS_OUTPUT" ]]; then
  printf '%s\n' "$STATUS_OUTPUT" >> "$SUMMARY_FILE"
else
  append_summary "No changes detected."
fi
append_summary '```'
append_summary ""

if [[ "$DRY_RUN" == "true" ]]; then
  log_stage "Dry run" "Trunk would be committed from the filtered master tree and tags/${VERSION} would be created from trunk. Expected download URL: ${DOWNLOAD_URL}"
  append_summary "## Result"
  append_summary "- Dry run completed."
  append_summary "- trunk would be updated from the filtered master tree."
  append_summary "- tags/${VERSION} would be created from trunk."
  append_summary "- Expected download URL: ${DOWNLOAD_URL}"
  flush_matrix "SVN publish dry-run completed"
  exit 0
fi

svn commit -m "Release ${VERSION}: update trunk from master" \
  --username "$SVN_USERNAME" \
  --password "$SVN_PASSWORD" \
  --non-interactive \
  --trust-server-cert
log_stage "Commit trunk" "SVN trunk committed for version ${VERSION} from the filtered master tree."

svn copy \
  "$SVN_URL/trunk" \
  "$SVN_URL/tags/${VERSION}" \
  -m "Release ${VERSION}: create tag from trunk" \
  --username "$SVN_USERNAME" \
  --password "$SVN_PASSWORD" \
  --non-interactive \
  --trust-server-cert
log_stage "Tag" "SVN tag tags/${VERSION} created from trunk."

ATTEMPTS=12
SLEEP_SECONDS=20
DOWNLOAD_OK=0
for attempt in $(seq 1 "$ATTEMPTS"); do
  if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 -o "$DOWNLOADED_ZIP" "$DOWNLOAD_URL"; then
    DOWNLOAD_OK=1
    log_stage "Download check" "Archive became available on attempt ${attempt}/${ATTEMPTS}."
    break
  fi
  log_stage "Download check" "Archive not available yet on attempt ${attempt}/${ATTEMPTS}; waiting ${SLEEP_SECONDS}s."
  sleep "$SLEEP_SECONDS"
done

[[ "$DOWNLOAD_OK" -eq 1 ]] || fail "Published ZIP did not become available at ${DOWNLOAD_URL} after ${ATTEMPTS} attempts"

DOWNLOADED_SHA256="$(sha256sum "$DOWNLOADED_ZIP" | awk '{print $1}')"
log_stage "Archive hash" "Downloaded ZIP SHA-256: ${DOWNLOADED_SHA256}."

python3 "$SCRIPT_DIR/manifest_tools.py" zip-manifest "$DOWNLOADED_ZIP" "$ZIP_MANIFEST"
ZIP_FILE_COUNT="$(wc -l < "$ZIP_MANIFEST" | tr -d ' ')"
log_stage "ZIP manifest" "Downloaded archive manifest built with ${ZIP_FILE_COUNT} files."

if ! diff -u "$LOCAL_MANIFEST" "$ZIP_MANIFEST" > "${TMP_DIR}/manifest.diff"; then
  append_summary "## Manifest diff"
  append_summary '```diff'
  cat "${TMP_DIR}/manifest.diff" >> "$SUMMARY_FILE"
  append_summary '```'
  fail "Downloaded ZIP content hash manifest does not match the filtered master tree"
fi

append_summary "## Result"
append_summary "- trunk updated successfully from the filtered master tree."
append_summary "- tags/${VERSION} created successfully."
append_summary "- Download URL: ${DOWNLOAD_URL}"
append_summary "- Downloaded ZIP SHA-256: ${DOWNLOADED_SHA256}"
append_summary "- Prepared file count: ${LOCAL_FILE_COUNT}"
append_summary "- ZIP file count: ${ZIP_FILE_COUNT}"

log_stage "Validation" "Downloaded ZIP content matches the filtered master tree."
log_stage "Success" "Release ${VERSION} published to SVN from the filtered master tree and validated. Download URL: ${DOWNLOAD_URL}"
flush_matrix "SVN publish completed"
