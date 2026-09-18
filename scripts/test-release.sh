#!/bin/bash
# Network-free tests of publication authorization, idempotency and tag ownership.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/docs" "$TMP/bin"
cp "$ROOT/scripts/publish-prerelease.sh" "$TMP/scripts/"
cp "$ROOT/docs/PRERELEASE_NOTES.md" "$TMP/docs/"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *matching-refs*)
    [[ "${FAKE_LIST_FAIL:-0}" == 0 ]] || exit 42
    printf '%s\n' "${FAKE_EXISTING_SHA:-}" ;;
  *'--method POST'*) [[ "${FAKE_TAG_FAIL:-0}" == 0 ]] || exit 43 ;;
  'release view'*) [[ "${FAKE_RELEASE_EXISTS:-0}" == 1 ]] || exit 1 ;;
  'release create'*) ;;
  *) echo 'Unexpected gh invocation' >&2; exit 44 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FAKE_LOG="$TMP/calls"
export GITHUB_REPOSITORY=example/PresenceKit GITHUB_SHA=1111111111111111111111111111111111111111
export GITHUB_RUN_ID=123 GH_TOKEN=test-only-not-a-credential
reset() {
  export GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/main
  export FAKE_LIST_FAIL=0 FAKE_TAG_FAIL=0 FAKE_RELEASE_EXISTS=0 FAKE_EXISTING_SHA=''
  printf '0.1.0-beta.1\n' > "$TMP/VERSION"
  : > "$FAKE_LOG"
}
run() { bash "$TMP/scripts/publish-prerelease.sh" > "$TMP/output" 2>&1; }
fail() { echo "$1" >&2; cat "$TMP/output" >&2; exit 1; }
reset; export GITHUB_EVENT_NAME=pull_request
if run; then fail 'PR must not publish'; fi
[[ ! -s "$FAKE_LOG" ]] || fail 'PR accessed GitHub'
reset; printf '1.0.0\n' > "$TMP/VERSION"
if run; then fail 'Stable version must not use beta publisher'; fi
[[ ! -s "$FAKE_LOG" ]] || fail 'Invalid version accessed GitHub'
reset; export FAKE_LIST_FAIL=1
if run; then fail 'Network failure must not be treated as absent tag'; fi
! grep -q 'release create' "$FAKE_LOG" || fail 'Published after network error'
reset; export FAKE_EXISTING_SHA=2222222222222222222222222222222222222222
run || fail 'Existing different version should be left unchanged'
[[ "$(wc -l < "$FAKE_LOG" | tr -d ' ')" == 1 ]] || fail 'Existing tag was modified'
reset
run || fail 'New tested beta should publish'
grep -q -- '--method POST .*git/refs.*sha=1111111111111111111111111111111111111111' "$FAKE_LOG" || fail 'Tag was not bound to tested SHA'
grep -q 'release create v0.1.0-beta.1.*--verify-tag.*--prerelease' "$FAKE_LOG" || fail 'Release was not explicitly verified and prerelease'
reset; export FAKE_EXISTING_SHA="$GITHUB_SHA" FAKE_RELEASE_EXISTS=1
run || fail 'Existing release should be idempotent'
! grep -q 'release create' "$FAKE_LOG" || fail 'Duplicate publication'
reset; export FAKE_EXISTING_SHA="$GITHUB_SHA"
run || fail 'Retry must finish an interrupted release'
! grep -q -- '--method POST' "$FAKE_LOG" || fail 'Retry recreated tag'
grep -q 'release create' "$FAKE_LOG" || fail 'Retry failed to publish'
reset; export FAKE_TAG_FAIL=1
if run; then fail 'Concurrent tag writer must abort publication'; fi
! grep -q 'release create' "$FAKE_LOG" || fail 'Published despite tag conflict'
echo 'All 8 publication safety tests passed.'
