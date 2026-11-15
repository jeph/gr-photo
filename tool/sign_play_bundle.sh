#!/usr/bin/env bash
# Signs a release app bundle with GR Photo's Play upload key and checks that
# the result carries the upload certificate and nothing else. A signature the
# bundle already has, such as the debug key's that the build leaves on it, is
# removed first. Google Play checks the upload signature, then signs the app
# for users with GR Photo's release key. .github/workflows/release.yml runs
# this in a job that holds the upload key and nothing else.
#
# Adapted from scripts/sign-play-bundle.sh of Pipkin (github.com/jeph/pipkin,
# v0.0.22, MIT License).
#
# Usage: tool/sign_play_bundle.sh <built.aab> <signed.aab>
#
# Environment:
#   PLAY_UPLOAD_KEYSTORE_BASE64    the PKCS12 keystore, base64-encoded
#   PLAY_UPLOAD_KEYSTORE_PASSWORD  the keystore's password, which PKCS12 also
#                                  uses for the key
#   PLAY_UPLOAD_KEY_ALIAS          the key's alias in the keystore
#   PLAY_UPLOAD_CERT_SHA256        the SHA-256 digest of the upload
#                                  certificate, in hex; colons are optional
#
# Needs zip, unzip, and jarsigner and keytool from a JDK on the PATH.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <built.aab> <signed.aab>" >&2
  exit 2
fi
built=$1
signed=$2

: "${PLAY_UPLOAD_KEYSTORE_BASE64:?is not set}"
: "${PLAY_UPLOAD_KEYSTORE_PASSWORD:?is not set}"
: "${PLAY_UPLOAD_KEY_ALIAS:?is not set}"
: "${PLAY_UPLOAD_CERT_SHA256:?is not set}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
keystore="$work/upload.p12"
(
  umask 077
  printf '%s' "$PLAY_UPLOAD_KEYSTORE_BASE64" | base64 --decode >"$keystore"
)

# jarsigner adds a signer beside those a bundle already has, so the debug
# key's signature files are removed first: the signature file (.SF), its
# signature block (.RSA, .DSA or .EC) and any SIG-* block. The manifest stays;
# jarsigner brings its digests up to date.
bundle="$work/bundle.aab"
cp "$built" "$bundle"
signature_files=$(unzip -Z1 "$bundle" | grep -E '^META-INF/([^/]+\.(SF|RSA|DSA|EC)|SIG-[^/]+)$' || true)
if [[ -n "$signature_files" ]]; then
  # -nw takes each name as it is, not as a wildcard pattern.
  tr '\n' '\0' <<<"$signature_files" | xargs -0 zip -q -d -nw "$bundle" --
fi

# The password reaches jarsigner through the environment, never the command
# line.
jarsigner \
  -keystore "$keystore" \
  -storetype PKCS12 \
  -storepass:env PLAY_UPLOAD_KEYSTORE_PASSWORD \
  -sigalg SHA256withRSA \
  -digestalg SHA-256 \
  -signedjar "$signed" \
  "$bundle" \
  "$PLAY_UPLOAD_KEY_ALIAS" >/dev/null

# Not -strict: that also fails on the upload certificate being self-signed, as
# Google Play expects it to be.
jarsigner -verify "$signed" >/dev/null
# keytool prints each signer's certificate; there must be one, the upload
# certificate.
actual=$(keytool -printcert -jarfile "$signed" | sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':' | tr 'A-F' 'a-f')
expected=$(printf '%s' "$PLAY_UPLOAD_CERT_SHA256" | tr -d ':' | tr 'A-F' 'a-f')
if [[ "$actual" != "$expected" ]]; then
  echo "$signed is signed by $actual, not the upload certificate $expected" >&2
  exit 1
fi
