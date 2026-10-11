#!/bin/bash
set -e

RELEASE_DIR=$(cat /tmp/moodle_release_dir)

# Atomically swap /current symlink — Nginx serves /current/public
ln -sfn $RELEASE_DIR /var/www/website/current

echo "Symlink /current swapped to $RELEASE_DIR"

# Run Moodle upgrade CLI to apply any DB schema changes
sudo -u www-data php8.3 /var/www/website/current/admin/cli/upgrade.php --non-interactive

# Purge Moodle caches
sudo -u www-data php8.3 /var/www/website/current/admin/cli/purge_caches.php

# Reload Nginx and PHP-FPM gracefully (no dropped connections)
systemctl reload nginx
systemctl reload php8.3-fpm

echo "Moodle application deployment complete"