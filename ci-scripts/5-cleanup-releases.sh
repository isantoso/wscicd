#!/bin/bash

RELEASES_DIR="/var/www/website/releases"
KEEP=3

# Get timestamped release folders sorted newest first (exclude 'new' symlink)
RELEASES=$(ls -dt $RELEASES_DIR/[0-9]* 2>/dev/null)
RELEASE_COUNT=$(echo "$RELEASES" | grep -c . || true)

if [ "$RELEASE_COUNT" -gt "$KEEP" ]; then
  echo "$RELEASES" | tail -n +$(($KEEP + 1)) | while read dir; do
    echo "Removing old release: $dir"
    rm -rf "$dir"
  done
else
  echo "Only $RELEASE_COUNT release(s) found — nothing to clean up"
fi