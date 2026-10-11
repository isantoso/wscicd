#!/bin/bash
set -e

RELEASE_DIR=$(cat /tmp/moodle_release_dir)

# Link persistent config.php into the new release (Moodle root level)
ln -sfn /var/www/website/shared/config.php $RELEASE_DIR/config.php

# Set correct ownership and permissions
chown -R www-data:www-data $RELEASE_DIR
find $RELEASE_DIR -type f -exec chmod 644 {} \;
find $RELEASE_DIR -type d -exec chmod 755 {} \;

# Make Moodle CLI scripts executable
# ==== chmod +x $RELEASE_DIR/admin/cli/*.php 2>/dev/null || true

echo "Permissions set for $RELEASE_DIR"