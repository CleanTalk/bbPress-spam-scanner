#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "::error::Command failed on line ${LINENO}: ${BASH_COMMAND}"' ERR

VERSION="${INPUT_VERSION}"
BETA_TAG="${INPUT_BETA_TAG}"
ASSET_NAME="${INPUT_ASSET_NAME}"
DRY_RUN="${INPUT_DRY_RUN}"
SVN_USERNAME="${INPUT_SVN_USERNAME}"
SVN_PASSWORD="${INPUT_SVN_PASSWORD}"
SVN_URL="${INPUT_SVN_URL}"
GITHUB_TOKEN="${INPUT_GITHUB_TOKEN}"
MATRIX_SERVER="${INPUT_MATRIX_SERVER:-}"
MATRIX_ROOM="${INPUT_MATRIX_ROOM:-}"
MATRIX_TOKEN="${INPUT_MATRIX_TOKEN:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-${TMP_DIR}/summary.md}"
trap 'rm -rf "${TMP_DIR}"' EXIT

notice() { echo "::notice::$1"; }
warn() { echo "::warning::$1"; }
error_annot() { echo "::error::$1"; }
append_summary() { printf '%s\n' "$1" >> "$SUMMARY_FILE"; }

escape_html_text() {
  python3 - <<'PY' "$1"
import html, sys
print(html.escape(sys.argv[1]))
PY
}

send_matrix() {
  local body="$1"
  local formatted="${2:-}"
  python3 "$SCRIPT_DIR/matrix_notify.py" "$MATRIX_SERVER" "$MATRIX_ROOM" "$MATRIX_TOKEN" "$body" "$formatted"
}

log_stage() {
  local stage="$1"
  local text="$2"
  notice "$stage: $text"
  send_matrix "$stage: $text" "<strong>${stage}</strong><br>$(escape_html_text "$text")" || true
}

fail() {
  local msg="$1"
  error_annot "$msg"
  append_summary "## Error"
  append_summary "- $msg"
  send_matrix "SVN publish failed: $msg" "<strong>SVN publish failed</strong><br>$(escape_html_text "$msg")" || true
  exit 1
}

require_var() {
  [[ -n "${!1:-}" ]] || fail "Required environment variable is empty: $1"
}

require_var VERSION
require_var BETA_TAG
require_var ASSET_NAME
require_var SVN_USERNAME
require_var SVN_PASSWORD
require_var SVN_URL
require_var GITHUB_TOKEN

VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid version: $VERSION"
[[ "$DRY_RUN" == "true" || "$DRY_RUN" == "false" ]] || fail "dry_run must be true or false"

SLUG="$(basename "$GITHUB_REPOSITORY")"
DOWNLOAD_URL="https://downloads.wordpress.org/plugin/${SLUG}.${VERSION}.zip"
RELEASE_JSON="${TMP_DIR}/release.json"
BETA_ZIP="${TMP_DIR}/${ASSET_NAME}"
DOWNLOADED_ZIP="${TMP_DIR}/${SLUG}.${VERSION}.zip"
PREPARED_DIR="${TMP_DIR}/prepared"
LOCAL_MANIFEST="${TMP_DIR}/prepared.sha256"
ZIP_MANIFEST="${TMP_DIR}/zip.sha256"

append_summary "# WordPress SVN publish"
append_summary ""
append_summary "## Context"
append_summary "- Repository: ${GITHUB_REPOSITORY}"
append_summary "- Release payload source: GitHub beta asset"
append_summary "- Final version: ${VERSION}"
append_summary "- Beta tag: ${BETA_TAG}"
append_summary "- Asset name: ${ASSET_NAME}"
append_summary "- Dry run: ${DRY_RUN}"
append_summary "- SVN target: trunk and tags/${VERSION}"
append_summary "- Expected download URL: ${DOWNLOAD_URL}"
append_summary ""

log_stage "Start" "Workflow started for final version ${VERSION}. Beta asset source: ${BETA_TAG}/${ASSET_NAME}. Dry run: ${DRY_RUN}."

ASSET_URL="$(python3 "$SCRIPT_DIR/github_release_asset.py" "$GITHUB_REPOSITORY" "$BETA_TAG" "$ASSET_NAME" "$GITHUB_TOKEN" "$RELEASE_JSON")"
[[ -n "$ASSET_URL" ]] || fail "Could not resolve asset URL for ${ASSET_NAME} in beta release ${BETA_TAG}"
log_stage "Release API" "Fetched beta release metadata and resolved asset URL."

curl -fL -H "Authorization: Bearer ${GITHUB_TOKEN}" -o "$BETA_ZIP" "$ASSET_URL"
log_stage "Asset download" "Downloaded prepared beta asset ${ASSET_NAME}."

mkdir -p "$PREPARED_DIR"
unzip -q "$BETA_ZIP" -d "$PREPARED_DIR"
RELEASE_ROOT="$(python3 "$SCRIPT_DIR/manifest_tools.py" zip-root "$BETA_ZIP")"
PREPARED_CONTENT_DIR="${PREPARED_DIR}/${RELEASE_ROOT}"
[[ -d "$PREPARED_CONTENT_DIR" ]] || fail "Prepared content directory not found after unzip: ${PREPARED_CONTENT_DIR}"
log_stage "Extract" "Prepared beta asset extracted successfully from top-level directory ${RELEASE_ROOT}."

python3 "$SCRIPT_DIR/manifest_tools.py" dir-manifest "$PREPARED_CONTENT_DIR" "$LOCAL_MANIFEST"
LOCAL_FILE_COUNT="$(wc -l < "$LOCAL_MANIFEST" | tr -d ' ')"
log_stage "Manifest" "Prepared release manifest built from beta asset with ${LOCAL_FILE_COUNT} files."

svn checkout "$SVN_URL" svn-repo \
  --username "$SVN_USERNAME" \
  --password "$SVN_PASSWORD" \
  --non-interactive \
  --trust-server-cert
log_stage "Checkout" "SVN repository checked out successfully."

rsync -a --delete "$PREPARED_CONTENT_DIR/" svn-repo/trunk/
log_stage "Sync" "Prepared beta asset content synced to svn-repo/trunk."

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
  log_stage "Dry run" "Trunk would be committed from beta asset and tags/${VERSION} would be created from trunk. Expected download URL: ${DOWNLOAD_URL}"
  append_summary "## Result"
  append_summary "- Dry run completed."
  append_summary "- trunk would be updated from beta asset ${ASSET_NAME}."
  append_summary "- tags/${VERSION} would be created from trunk."
  append_summary "- Expected download URL: ${DOWNLOAD_URL}"
  exit 0
fi

svn commit -m "Release ${VERSION}: update trunk from beta asset ${ASSET_NAME}" \
  --username "$SVN_USERNAME" \
  --password "$SVN_PASSWORD" \
  --non-interactive \
  --trust-server-cert
log_stage "Commit trunk" "SVN trunk committed for version ${VERSION} from beta asset ${ASSET_NAME}."

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
  fail "Downloaded ZIP content hash manifest does not match prepared beta asset content"
fi

append_summary "## Result"
append_summary "- trunk updated successfully from beta asset ${ASSET_NAME}."
append_summary "- tags/${VERSION} created successfully."
append_summary "- Download URL: ${DOWNLOAD_URL}"
append_summary "- Downloaded ZIP SHA-256: ${DOWNLOADED_SHA256}"
append_summary "- Prepared file count: ${LOCAL_FILE_COUNT}"
append_summary "- ZIP file count: ${ZIP_FILE_COUNT}"

log_stage "Validation" "Downloaded ZIP content matches prepared beta asset manifest."
log_stage "Success" "Release ${VERSION} published to SVN from beta asset ${ASSET_NAME} and validated. Download URL: ${DOWNLOAD_URL}"
