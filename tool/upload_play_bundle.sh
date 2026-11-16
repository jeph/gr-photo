#!/usr/bin/env bash
# Uploads a signed app bundle to Google Play and releases it to every user of
# one track and to the internal testers, through one edit of the Google Play
# Developer API. A bundle Play already has, as when a release is rerun, isn't
# uploaded again; the tracks still get it. .github/workflows/release.yml runs
# this in a job that holds the Play publishing credential and nothing else.
#
# While the app is still a draft in Play Console (it has never been through
# Google's review), Play accepts only draft releases on every track but
# internal testing. The release is then left as a draft on the track, to be
# sent for review from Play Console, and only internal testers get it.
#
# Adapted from scripts/upload-play-bundle.sh of Pipkin (github.com/jeph/pipkin,
# v0.0.22, MIT License).
#
# Usage: tool/upload_play_bundle.sh <signed.aab>
#
# Environment:
#   PLAY_ACCESS_TOKEN  an OAuth access token with the androidpublisher scope
#   PLAY_PACKAGE       the app's package name
#   PLAY_TRACK         the track to release to, such as internal, alpha
#                      (closed testing) or production
#   VERSION_CODE       the bundle's version code
#   VERSION_NAME       the version name, which names the release in Play
#                      Console
#
# Needs curl and jq on the PATH.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <signed.aab>" >&2
  exit 2
fi
bundle=$1

: "${PLAY_ACCESS_TOKEN:?is not set}"
: "${PLAY_PACKAGE:?is not set}"
: "${PLAY_TRACK:?is not set}"
: "${VERSION_CODE:?is not set}"
: "${VERSION_NAME:?is not set}"

api="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PLAY_PACKAGE"
upload_api="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$PLAY_PACKAGE"

# The token reaches curl through a header file, never the command line.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
headers="$work/headers"
(
  umask 077
  printf 'Authorization: Bearer %s\n' "$PLAY_ACCESS_TOKEN" >"$headers"
)

# Prints the response, or on an HTTP error sends it to stderr, where it tells
# what Google Play rejected.
play() {
  local response
  if ! response=$(curl --silent --show-error --fail-with-body --retry 3 --header "@$headers" "$@"); then
    printf '%s\n' "$response" >&2
    return 1
  fi
  printf '%s\n' "$response"
}

edit=$(play --request POST "$api/edits" | jq -r '.id')

bundles=$(play "$api/edits/$edit/bundles")
if jq -e --argjson code "$VERSION_CODE" '.bundles // [] | any(.versionCode == $code)' <<<"$bundles" >/dev/null; then
  echo "Google Play already has version code $VERSION_CODE"
else
  uploaded=$(
    play --request POST \
      --header 'Content-Type: application/octet-stream' \
      --data-binary "@$bundle" \
      --max-time 1800 \
      "$upload_api/edits/$edit/bundles?uploadType=media" | jq -r '.versionCode'
  )
  if [[ "$uploaded" != "$VERSION_CODE" ]]; then
    echo "The bundle carries version code $uploaded, not $VERSION_CODE" >&2
    exit 1
  fi
fi

# Sets a track to this version alone, with the given release status.
put_release() {
  local track=$1 status=$2
  jq -n --arg track "$track" --arg name "$VERSION_NAME" --arg code "$VERSION_CODE" --arg status "$status" \
    '{track: $track, releases: [{name: $name, versionCodes: [$code], status: $status}]}' |
    play --request PUT --header 'Content-Type: application/json' --data-binary @- \
      "$api/edits/$edit/tracks/$track" >/dev/null
}

if [[ "$PLAY_TRACK" != internal ]]; then
  put_release internal completed
fi
put_release "$PLAY_TRACK" completed
status=completed
if ! validation=$(play --request POST "$api/edits/$edit:validate" 2>&1); then
  if ! grep -q 'Only releases with status draft may be created on draft app' <<<"$validation"; then
    printf '%s\n' "$validation" >&2
    exit 1
  fi
  echo "The app is still a draft in Play Console, so the release is left as a draft"
  put_release "$PLAY_TRACK" draft
  status=draft
fi

play --request POST "$api/edits/$edit:commit" >/dev/null
if [[ "$PLAY_TRACK" != internal ]]; then
  echo "Released $VERSION_NAME ($VERSION_CODE) on the internal track"
fi
if [[ "$status" == draft ]]; then
  echo "Added $VERSION_NAME ($VERSION_CODE) to the $PLAY_TRACK track as a draft; send it for review in Play Console"
else
  echo "Released $VERSION_NAME ($VERSION_CODE) on the $PLAY_TRACK track"
fi
