#!/bin/sh
# Called by after_create inside a disposable workspace, never the production checkout.
set -eu

if [ "$#" -ne 2 ]; then
  echo 'Usage: bootstrap-workspace.sh REPOSITORY FULL_REVIEWED_SOURCE_SHA' >&2
  exit 2
fi

repository=$1
revision=$2
case "$repository" in
  ''|-*) echo 'A repository URL or absolute local path is required' >&2; exit 2 ;;
esac
if ! printf '%s\n' "$revision" | LC_ALL=C grep -Eq '^[0-9a-f]{40}$'; then
  echo 'Development source must be a full immutable reviewed commit SHA' >&2
  exit 2
fi

marker=.git/symphony-bootstrap
if [ -e .git ]; then
  if [ ! -f "$marker" ] || [ "$(git remote get-url origin)" != "$repository" ]; then
    echo 'Existing workspace has no matching bootstrap/repository binding' >&2
    exit 1
  fi
  expected=$(printf '%s\n%s' "$repository" "$revision")
  if [ "$(cat "$marker")" != "$expected" ]; then
    echo 'Existing workspace was bootstrapped from a different immutable source' >&2
    exit 1
  fi
  # Preserve issue branches, commits, and uncommitted work on retries.
  exit 0
fi

if [ -n "$(find . -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  echo 'Refusing to bootstrap a nonempty workspace' >&2
  exit 1
fi

git -c core.hooksPath=/dev/null -c core.fsmonitor=false init --quiet
git config core.hooksPath /dev/null
git config core.fsmonitor false
git remote add origin "$repository"
git fetch --quiet --depth=1 origin "$revision"
test "$(git rev-parse FETCH_HEAD)" = "$revision"
git -c advice.detachedHead=false checkout --quiet --detach "$revision"
printf '%s\n%s\n' "$repository" "$revision" > "$marker"
