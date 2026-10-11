#!/bin/bash
set -e

RELEASE_DIR="/var/www/website/releases/$(date +%Y%m%d_%H%M%S)"
echo $RELEASE_DIR > /tmp/moodle_release_dir

mkdir -p $RELEASE_DIR

# Point CodeDeploy temp destination to the new release dir
rm -rf /var/www/website/releases/new
ln -sfn $RELEASE_DIR /var/www/website/releases/new

echo "Prepared release directory: $RELEASE_DIR"