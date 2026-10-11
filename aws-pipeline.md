# Moodle 5.3 Zero-Downtime Deployment on AWS

This guide covers deploying Moodle 5.3 from a GitHub repository to an EC2 instance using AWS CodePipeline and CodeDeploy, with zero-downtime symlink-based releases, Nginx + PHP-FPM 8.3, and retention of the last 3 deployments.

---

## Requirements

| Component      | Requirement                                                                                   |
| -------------- | --------------------------------------------------------------------------------------------- |
| PHP            | 8.3 (minimum 8.1)                                                                             |
| Web Server     | Nginx                                                                                         |
| PHP Processor  | PHP-FPM 8.3 (Unix socket)                                                                     |
| Database       | MySQL 8.0+, MariaDB 10.6+, or PostgreSQL 13+                                                  |
| PHP Extensions | mbstring, curl, zip, gd, intl, xml, soap, opcache, redis, pdo_mysql, xmlrpc, tokenizer, ctype |
| moodledata     | Must be outside the web root                                                                  |
| config.php     | Must be outside the web root                                                                  |

---

## Folder Structure

```
/var/www/website/
  ├── releases/
  │   ├── 20241009_001/        ← old release
  │   ├── 20241009_002/        ← old release
  │   ├── 20241009_003/        ← old release
  │   └── 20241009_004/        ← new release (staged here first)
  ├── shared/
  │   ├── config.php           ← persistent Moodle config (symlinked into each release)
  │   └── moodledata/          ← user uploads, course files (never in web root)
  └── current → releases/20241009_004   ← symlink, swapped atomically on deploy
        └── public/            ← Moodle web root served by Nginx
```

**Web request flow:**

```
User → ALB → Nginx (root: /var/www/website/current/public)
                  → PHP-FPM 8.3 (Unix socket)
                  → Moodle 5.3 application
```

---

## Step 1: Prepare EC2 — Install Nginx and PHP 8.3

SSH into your EC2 instance and run:

```bash
# Add PHP 8.3 repository
sudo apt-get update
sudo apt-get install -y ca-certificates apt-transport-https software-properties-common lsb-release curl
sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update

# Install Nginx and PHP 8.3 with all Moodle 5.3 required extensions
sudo apt-get install -y \
  nginx \
  php8.3 \
  php8.3-fpm \
  php8.3-cli \
  php8.3-mbstring \
  php8.3-curl \
  php8.3-zip \
  php8.3-gd \
  php8.3-intl \
  php8.3-xml \
  php8.3-soap \
  php8.3-opcache \
  php8.3-mysql \
  php8.3-pgsql \
  php8.3-redis \
  php8.3-xmlrpc \
  php8.3-tokenizer \
  php8.3-ctype

# Enable and start services
sudo systemctl enable nginx php8.3-fpm
sudo systemctl start nginx php8.3-fpm
```

### PHP-FPM Pool Configuration

Create `/etc/php/8.3/fpm/pool.d/moodle.conf`:

```ini
[moodle]
user = www-data
group = www-data

listen = /run/php/php8.3-fpm-moodle.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 50
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 20
pm.max_requests = 500

php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 512M
php_admin_value[post_max_size] = 512M
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_vars] = 5000
php_admin_value[date.timezone] = UTC
php_admin_flag[cgi.fix_pathinfo] = 0
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 128
php_admin_value[opcache.max_accelerated_files] = 10000
php_admin_value[opcache.revalidate_freq] = 60
```

Disable the default pool and restart PHP-FPM:

```bash
sudo mv /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/www.conf.disabled
sudo systemctl restart php8.3-fpm
```

### Set Up Folder Structure

```bash
sudo mkdir -p /var/www/website/releases
sudo mkdir -p /var/www/website/shared/moodledata
sudo chown -R www-data:www-data /var/www/website
sudo chmod -R 755 /var/www/website
sudo chmod -R 770 /var/www/website/shared/moodledata
```

---

## Step 2: Create Shared config.php

Create `/var/www/website/shared/config.php`:

```php
<?php  // Moodle configuration file

unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'mysqli';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'YOUR_AURORA_ENDPOINT';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'moodleuser';
$CFG->dbpass    = 'YOUR_DB_PASSWORD'; // Use Secrets Manager in production
$CFG->prefix    = 'mdl_';

$CFG->wwwroot   = 'https://your-domain.com';
$CFG->dataroot  = '/var/www/website/shared/moodledata';
$CFG->admin     = 'admin';

$CFG->directorypermissions = 02777;

// ElastiCache Redis session caching
$CFG->session_handler_class = '\core\session\redis';
$CFG->session_redis_host = 'YOUR_ELASTICACHE_ENDPOINT';
$CFG->session_redis_port = 6379;
$CFG->session_redis_database = 0;
$CFG->session_redis_prefix = 'moodle_sess_';
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->session_redis_lock_expire = 7200;

require_once(__DIR__ . '/lib/setup.php');
```

> **Note:** Store `dbpass` in AWS Secrets Manager and retrieve it at runtime using the AWS SDK for PHP.

---

## Step 3: Nginx Configuration

Create `/etc/nginx/sites-available/moodle`:

```nginx
# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name your-domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name your-domain.com;

    # Web root — Nginx follows /current symlink to the active release
    root /var/www/website/current/public;
    index index.php index.html;

    client_max_body_size 512M;

    access_log /var/log/nginx/moodle_access.log;
    error_log  /var/log/nginx/moodle_error.log;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Block sensitive paths
    location = /config.php {
        deny all;
        return 404;
    }

    location ~ /\. {
        deny all;
        return 404;
    }

    location ~* \.(bak|config|sql|fla|psd|ini|log|sh|inc|swp|dist)$ {
        deny all;
        return 404;
    }

    # Moodle routing
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    # PHP-FPM handler
    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.*)$;
        fastcgi_pass unix:/run/php/php8.3-fpm-moodle.sock;
        fastcgi_index index.php;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_param HTTPS on;

        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_connect_timeout 300;

        fastcgi_buffer_size 128k;
        fastcgi_buffers 256 16k;
        fastcgi_busy_buffers_size 256k;
    }

    # Static file caching
    location ~* \.(jpg|jpeg|gif|png|ico|css|js|woff|woff2|ttf|svg|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
        access_log off;
        try_files $uri =404;
    }
}
```

Enable and test:

```bash
sudo ln -s /etc/nginx/sites-available/moodle /etc/nginx/sites-enabled/moodle
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

---

## Step 4: Install CodeDeploy Agent on EC2

```bash
sudo apt-get install -y ruby wget
wget https://aws-codedeploy-ap-southeast-2.s3.ap-southeast-2.amazonaws.com/latest/install
chmod +x ./install
sudo ./install auto
sudo service codedeploy-agent status
```

---

## Step 5: IAM Roles

### EC2 Role (attach to your EC2 instance)

- **Role name:** `EC2CodeDeployRole`
- **Policy:** `AmazonEC2RoleforAWSCodeDeploy`
- Attach via: EC2 Console → Instance → Actions → Security → Modify IAM role

### CodeDeploy Service Role

- **Role name:** `CodeDeployServiceRole`
- **Trusted entity:** AWS service → CodeDeploy
- **Policy:** `AWSCodeDeployRole` (auto-attached)

---

## Step 6: appspec.yml

Place at the **root** of your GitHub repository:

```yaml
version: 0.0
os: linux
files:
  - source: /
    destination: /var/www/website/releases/new
hooks:
  BeforeInstall:
    - location: scripts/before_install.sh
      timeout: 300
      runas: root
  AfterInstall:
    - location: scripts/after_install.sh
      timeout: 300
      runas: root
  ValidateService:
    - location: scripts/validate_service.sh
      timeout: 60
      runas: root
  ApplicationStart:
    - location: scripts/swap_symlink.sh
      timeout: 60
      runas: root
  ApplicationStop:
    - location: scripts/cleanup_releases.sh
      timeout: 60
      runas: root
```

---

## Step 7: Deployment Scripts

### scripts/before_install.sh

```bash
#!/bin/bash
set -e

RELEASE_DIR="/var/www/website/releases/$(date +%Y%m%d_%H%M%S)"
echo $RELEASE_DIR > /tmp/moodle_release_dir

mkdir -p $RELEASE_DIR

# Point CodeDeploy temp destination to the new release dir
rm -rf /var/www/website/releases/new
ln -sfn $RELEASE_DIR /var/www/website/releases/new

echo "Prepared release directory: $RELEASE_DIR"
```

### scripts/after_install.sh

```bash
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
chmod +x $RELEASE_DIR/admin/cli/*.php 2>/dev/null || true

echo "Permissions set for $RELEASE_DIR"
```

### scripts/validate_service.sh

```bash
#!/bin/bash
set -e

RELEASE_DIR=$(cat /tmp/moodle_release_dir)

# Check Moodle 5.3 core files exist
for file in "index.php" "config-dist.php" "lib/setup.php" "admin/index.php"; do
  if [ ! -f "$RELEASE_DIR/$file" ]; then
    echo "FAILED: Missing Moodle file: $RELEASE_DIR/$file"
    exit 1
  fi
done

# Check public/ subfolder exists
if [ ! -d "$RELEASE_DIR/public" ]; then
  echo "FAILED: public/ subfolder missing in $RELEASE_DIR"
  exit 1
fi

# Check config.php symlink is in place
if [ ! -L "$RELEASE_DIR/config.php" ]; then
  echo "FAILED: config.php symlink missing in $RELEASE_DIR"
  exit 1
fi

# Check PHP 8.3 syntax
php8.3 -l $RELEASE_DIR/index.php > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "FAILED: PHP syntax error in $RELEASE_DIR/index.php"
  exit 1
fi

# Check moodledata is writable
if [ ! -w "/var/www/website/shared/moodledata" ]; then
  echo "FAILED: moodledata directory is not writable"
  exit 1
fi

# Check Nginx is running
if ! systemctl is-active --quiet nginx; then
  echo "FAILED: Nginx is not running"
  exit 1
fi

# Check PHP-FPM is running
if ! systemctl is-active --quiet php8.3-fpm; then
  echo "FAILED: PHP 8.3 FPM is not running"
  exit 1
fi

# Check PHP-FPM socket exists
if [ ! -S "/run/php/php8.3-fpm-moodle.sock" ]; then
  echo "FAILED: PHP-FPM socket not found"
  exit 1
fi

echo "Moodle 5.3 validation passed for $RELEASE_DIR"
exit 0
```

### scripts/swap_symlink.sh

```bash
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

echo "Moodle 5.3 deployment complete"
```

### scripts/cleanup_releases.sh

```bash
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
```

---

## Step 8: Commit Scripts to GitHub

```bash
chmod +x scripts/*.sh
git add appspec.yml scripts/
git commit -m "Moodle 5.3 zero-downtime symlink deployment with Nginx"
git push
```

---

## Step 9: Create CodeDeploy Application

1. Open CodeDeploy Console → **Create application**
2. **Application name:** `moodle-app`
3. **Compute platform:** EC2/On-premises
4. Click **Create application**

### Create Deployment Group

1. Click **Create deployment group**
2. **Deployment group name:** `production`
3. **Service role:** `CodeDeployServiceRole`
4. **Deployment type:** In-place
5. **Environment:** Amazon EC2 instances — tag your EC2 instance by Name
6. **Deployment settings:** `CodeDeployDefault.AllAtOnce`
7. Under **Rollbacks:** check **Roll back when a deployment fails**
8. Click **Create deployment group**

---

## Step 10: Create CodePipeline

1. Open CodePipeline Console → **Create pipeline**
2. **Pipeline name:** `moodle-pipeline`
3. **Execution mode:** Superseded
4. **Service role:** Create new role (auto)
5. Click **Next**

### Source Stage

- **Provider:** GitHub (Version 2)
- Connect to GitHub, select your repository and branch (e.g. `main`)

### Build Stage

- Click **Skip build stage**

### Deploy Stage

- **Provider:** AWS CodeDeploy
- **Application:** `moodle-app`
- **Deployment group:** `production`

Click **Create pipeline**.

---

## Step 11: Rollback Strategy

### Automatic Rollback (CodeDeploy)

- **On deployment failure:** enabled in deployment group (Step 9)
- **On CloudWatch alarm:** attach a `moodle-high-cpu` or `moodle-5xx-errors` alarm to the deployment group for post-deploy rollback

### Manual Rollback (instant, zero downtime)

```bash
# List available releases
ls /var/www/website/releases/

# Roll back to a specific release
sudo ln -sfn /var/www/website/releases/20241009_002 /var/www/website/current

# Re-run Moodle upgrade CLI
sudo -u www-data php8.3 /var/www/website/current/admin/cli/upgrade.php --non-interactive

# Reload Nginx
sudo systemctl reload nginx
```

---

## Deployment Flow Summary

```
GitHub push (main branch)
    ↓
CodePipeline detects change
    ↓
CodeDeploy triggered
    ↓
before_install.sh   → Creates /releases/YYYYMMDD_HHMMSS/
    ↓
Files copied        → Moodle 5.3 code staged in new release folder
    ↓
after_install.sh    → Symlinks config.php, sets permissions
    ↓
validate_service.sh → Checks files, PHP syntax, Nginx, PHP-FPM, moodledata
    ↓
swap_symlink.sh     → ln -sfn to /current, runs upgrade.php + purge_caches.php, reloads Nginx
    ↓
cleanup_releases.sh → Keeps last 3 releases, removes the rest
```

---

## Key Configuration Reference

| Item                   | Value                                 |
| ---------------------- | ------------------------------------- |
| Web root (Nginx)       | `/var/www/website/current/public`     |
| Active release symlink | `/var/www/website/current`            |
| Releases directory     | `/var/www/website/releases/`          |
| Shared config.php      | `/var/www/website/shared/config.php`  |
| moodledata             | `/var/www/website/shared/moodledata/` |
| PHP version            | 8.3                                   |
| PHP-FPM socket         | `/run/php/php8.3-fpm-moodle.sock`     |
| Releases retained      | 3                                     |
| CodeDeploy agent       | Installed on EC2, runs as root        |
| Moodle wwwroot         | `https://your-domain.com`             |
