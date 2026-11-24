#!/usr/bin/env bash
# Checks out the pinned llama.cpp commit (shallow, detached) and verifies it.
# Verifies: HEAD == pinned SHA, and the tag resolves (peeled) to the same commit.
# Needs git + network. Destination: $LAI_LLAMA_DIR or third_party/llama.cpp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/third_party/llama.cpp.pin"
DST="${LAI_LLAMA_DIR:-$ROOT/third_party/llama.cpp}"
if [ ! -d "$DST/.git" ]; then
  mkdir -p "$DST"
  git -C "$DST" init -q
  git -C "$DST" remote add origin "$REPO"
fi
git -C "$DST" fetch --depth 1 origin "$COMMIT"
git -C "$DST" checkout -q --detach FETCH_HEAD
HEAD_SHA="$(git -C "$DST" rev-parse HEAD)"
[ "$HEAD_SHA" = "$COMMIT" ] || { echo "FAIL: HEAD=$HEAD_SHA, expected $COMMIT"; exit 1; }
# Peeled tag (annotated tags have their own object id; ^{} gives the commit it points to).
TAG_SHA="$(git ls-remote "$REPO" "refs/tags/$TAG^{}" | awk '{print $1}')"
if [ -z "$TAG_SHA" ]; then
  echo "WARNING: tag $TAG not found on the remote; commit is pinned, tag relation unverified."
  [ "${LAI_ALLOW_TAG_MISMATCH:-0}" = 1 ] || exit 3
elif [ "$TAG_SHA" != "$COMMIT" ]; then
  echo "FAIL: tag $TAG points to $TAG_SHA, NOT the pinned commit $COMMIT."
  [ "${LAI_ALLOW_TAG_MISMATCH:-0}" = 1 ] || exit 3
else
  echo "OK: tag $TAG -> $COMMIT"
fi
echo "Pinned: $HEAD_SHA"
