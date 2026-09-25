#!/usr/bin/env bash
# Cursor's sandbox cache is /tmp/cursor-sandbox-cache. On this machine /tmp
# is tmpfs, so a Gradle cache there fills RAM. Point that path at the
# Samsung SSD when it is mounted.
set -euo pipefail

disk=/run/media/hocti/92C4A6B3C4A698CD
dest=$disk/cursor-sandbox-cache
link=/tmp/cursor-sandbox-cache

if [[ ! -d $disk ]]; then
  echo "SSD not mounted ($disk); sandbox cache stays on /tmp" >&2
  exit 0
fi

mkdir -p "$dest"

if [[ -L $link ]]; then
  if [[ $(readlink -f "$link") == "$dest" ]]; then
    exit 0
  fi
  rm "$link"
elif [[ -d $link ]]; then
  shopt -s dotglob nullglob
  for item in "$link"/*; do
    mv "$item" "$dest/"
  done
  shopt -u dotglob nullglob
  if ! rmdir "$link"; then
    echo "Could not replace $link (still in use). Cache was copied to $dest." >&2
    exit 1
  fi
fi

ln -s "$dest" "$link"
echo "Sandbox cache: $link -> $dest"
