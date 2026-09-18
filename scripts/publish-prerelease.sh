#!/bin/bash
# Invoked only by the successful main-branch CI job. Never force/move a tag.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GITHUB_REPOSITORY:?Missing repository}"
: "${GITHUB_SHA:?Missing tested commit}"
: "${GH_TOKEN:?Missing workflow token}"
[[ "${GITHUB_EVENT_NAME:-}" == push && "${GITHUB_REF:-}" == refs/heads/main ]] || {
  echo 'Publication is restricted to a tested push to main.' >&2; exit 1;
}
version="$(cat VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] || {
  echo 'VERSION must be an explicit beta version.' >&2; exit 1;
}
tag="v$version"
# Listing refs through the API fails on network/auth errors instead of treating
# those errors as a missing tag. Version tags are immutable by this script.
existing="$(gh api "repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$tag" \
  --jq ".[] | select(.ref == \"refs/tags/$tag\") | .object.sha")"
if [[ -n "$existing" && "$existing" != "$GITHUB_SHA" ]]; then
  echo "Tag $tag already exists at $existing; leaving it unchanged. Bump VERSION to publish a new build."
  exit 0
fi
if [[ -z "$existing" ]]; then
  # Create the exact tag atomically. If another writer won the race, fail rather
  # than creating a release from a tag whose commit has not been checked here.
  gh api --method POST "repos/$GITHUB_REPOSITORY/git/refs" \
    -f ref="refs/tags/$tag" -f sha="$GITHUB_SHA" >/dev/null
elif gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "Release $tag already exists at the tested commit."
  exit 0
fi
notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
cat docs/PRERELEASE_NOTES.md > "$notes"
printf '\nTested commit: `%s`\nValidation run: https://github.com/%s/actions/runs/%s\n' \
  "$GITHUB_SHA" "$GITHUB_REPOSITORY" "${GITHUB_RUN_ID:?}" >> "$notes"
gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" --verify-tag \
  --prerelease --latest=false --title "PresenceKit $version" --notes-file "$notes"
