cd /var/www

# Load environment variables from deploy.env (created by GitHub Actions)
if [ -f "/var/www/deploy.env" ]; then
    source /var/www/deploy.env
    echo "## Environment variables loaded from deploy.env"
else
    echo "## Warning: deploy.env not found, using defaults"
fi

docker compose build
docker compose up -d db --wait && docker compose up -d mautic_web --wait

echo "## Detecting mautic_web container name dynamically"
MAUTIC_WEB_CONTAINER=$(docker ps --format '{{.Names}}' | grep '_mautic_web_1$' || docker ps --format '{{.Names}}' | grep 'mautic_web')
if [ -z "$MAUTIC_WEB_CONTAINER" ]; then
    echo "No mautic_web container found. Exiting..."
    exit 1
fi
echo "## Wait for $MAUTIC_WEB_CONTAINER container to be fully running"
while ! docker exec "$MAUTIC_WEB_CONTAINER" sh -c 'echo "Container is running"'; do
    echo "### Waiting for $MAUTIC_WEB_CONTAINER to be fully running..."
    sleep 2
done

echo "## Check if Mautic is installed"
if docker compose exec -T mautic_web test -f /var/www/html/config/local.php && docker compose exec -T mautic_web grep -q "site_url" /var/www/html/config/local.php; then
    echo "## Mautic is installed already."
    MAUTIC_ALREADY_INSTALLED=true
else
    MAUTIC_ALREADY_INSTALLED=false
    # Check if the container exists and is running
    MAUTIC_WORKER_CONTAINER=$(docker ps --format '{{.Names}}' | grep '_mautic_worker_1$' || docker ps --format '{{.Names}}' | grep 'mautic_worker')
    if [ -n "$MAUTIC_WORKER_CONTAINER" ]; then
        echo "Stopping $MAUTIC_WORKER_CONTAINER to avoid https://github.com/mautic/docker-mautic/issues/270"
        docker stop "$MAUTIC_WORKER_CONTAINER"
        echo "## Ensure the worker is stopped before installing Mautic"
        while docker ps -q --filter name="$MAUTIC_WORKER_CONTAINER" | grep -q .; do
            echo "### Waiting for $MAUTIC_WORKER_CONTAINER to stop..."
            sleep 2
        done
    else
        echo "Container $MAUTIC_WORKER_CONTAINER does not exist or is not running."
    fi
    echo "## Installing Mautic..."
    docker compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console mautic:install --force --admin_email "${EMAIL_ADDRESS}" --admin_password "${MAUTIC_PASSWORD}" "http://${IP_ADDRESS}:${PORT}"
fi

echo "## Installing custom themes and plugins..."

# Install themes
if [ ! -z "$MAUTIC_THEMES" ]; then
    echo "### Processing themes..."
    IFS=',' read -ra THEME_ARRAY <<< "$MAUTIC_THEMES"
    for package in "${THEME_ARRAY[@]}"; do
        package=$(echo "$package" | xargs) # trim whitespace
        if [ ! -z "$package" ]; then
            echo "#### Installing theme: $package"
            docker compose exec -T -u www-data -w /var/www/html mautic_web composer require "$package" --no-scripts --no-interaction || echo "Warning: Failed to install theme $package"
        fi
    done
else
    echo "### No themes defined in MAUTIC_THEMES"
fi

# Install plugins
if [ ! -z "$MAUTIC_PLUGINS" ]; then
    echo "### Processing plugins..."
    IFS=',' read -ra PLUGIN_ARRAY <<< "$MAUTIC_PLUGINS"
    for package in "${PLUGIN_ARRAY[@]}"; do
        package=$(echo "$package" | xargs) # trim whitespace
        if [ ! -z "$package" ]; then
            # Extract package name without version constraint
            package_name=$(echo "$package" | cut -d':' -f1)
            
            # Check if plugin is already installed
            if docker compose exec -T -u www-data -w /var/www/html mautic_web composer show | grep -q "^$package_name "; then
                echo "✓ Plugin $package_name is already installed, skipping"
                continue
            fi
            
            echo "#### Installing plugin: $package"
            if docker compose exec -T -u www-data -w /var/www/html mautic_web composer require "$package" --no-scripts --no-interaction; then
                echo "✓ Successfully installed plugin: $package"
                # Verify installation
                if docker compose exec -T -u www-data -w /var/www/html mautic_web composer show | grep -q "$package_name"; then
                    echo "✓ Plugin $package_name confirmed in composer packages"
                else
                    echo "⚠ Plugin $package_name not found in composer list after installation"
                fi
            else
                echo "✗ Failed to install plugin: $package"
            fi
        fi
    done
    
    # Show all installed packages for verification
    echo "### Current Composer packages:"
    docker compose exec -T -u www-data -w /var/www/html mautic_web composer show | grep -E "(kuzmany|mautic)" || echo "No kuzmany or mautic packages found"
    
    # Clear cache after plugin installation
    echo "### Clearing Mautic cache..."
    if docker compose exec -T -u www-data -w /var/www/html mautic_web php ./bin/console cache:clear --no-interaction; then
        echo "✓ Mautic cache cleared successfully"
    else
        echo "⚠ Failed to clear Mautic cache"
    fi
else
    echo "### No plugins defined in MAUTIC_PLUGINS"
fi

echo "## Custom extensions installation completed"

# Final plugin verification
echo "## Final plugin verification..."
if [ ! -z "$MAUTIC_PLUGINS" ]; then
    echo "### Checking if plugins are properly registered in Mautic..."
    # Check vendor directory for installed packages
    docker compose exec -T mautic_web find /var/www/html/vendor -name "*amazon*" -type d 2>/dev/null || echo "No amazon-related packages found in vendor"
    
    # Check if plugin directories exist
    docker compose exec -T mautic_web find /var/www/html -name "*Amazon*" -type d 2>/dev/null || echo "No Amazon plugin directories found"
    
    # List all composer packages
    echo "### All installed Composer packages:"
    docker compose exec -T mautic_web composer show 2>/dev/null | head -20
fi

echo "## Starting all the containers"
docker compose up -d

# Use DOMAIN_NAME from environment variables
DOMAIN="$DOMAIN_NAME"

if [ -z "$DOMAIN" ]; then
    echo "The DOMAIN_NAME variable is not set yet."
    exit 0
fi

DROPLET_IP=$(curl -s http://icanhazip.com)

echo "## Checking if $DOMAIN points to this DO droplet..."
DOMAIN_IP=$(dig +short $DOMAIN)
if [ "$DOMAIN_IP" != "$DROPLET_IP" ]; then
    echo "## $DOMAIN does not point to this droplet IP ($DROPLET_IP). Exiting..."
    exit 1
fi

echo "## $DOMAIN is available and points to this droplet. Nginx configuration..."

SOURCE_PATH="/var/www/nginx-virtual-host-$DOMAIN"
TARGET_PATH="/etc/nginx/sites-enabled/nginx-virtual-host-$DOMAIN"

# Remove the existing symlink if it exists
if [ -L "$TARGET_PATH" ]; then
    rm $TARGET_PATH
    echo "Existing symlink for $DOMAIN configuration removed."
fi

# Create a new symlink
ln -s $SOURCE_PATH $TARGET_PATH
echo "Symlink created for $DOMAIN configuration."

if ! nginx -t; then
    echo "Nginx configuration test failed, stopping the script."
    exit 1
fi

# Check if Nginx is running and reload to apply changes
if ! pgrep -x nginx > /dev/null; then
    echo "Nginx is not running, starting Nginx..."
    systemctl start nginx
else
    echo "Reloading Nginx to apply new configuration."
    nginx -s reload
fi

echo "## Configuring Let's Encrypt for $DOMAIN..."

# Use Certbot with the Nginx plugin to obtain and install a certificate
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m "$EMAIL_ADDRESS"

# Nginx will be reloaded automatically by Certbot after obtaining the certificate
echo "## Let's Encrypt configured for $DOMAIN"

# Check if the cron job for renewal is already set
if ! crontab -l | grep -q 'certbot renew'; then
    echo "## Setting up cron job for Let's Encrypt certificate renewal..."
    (crontab -l 2>/dev/null; echo "0 0 1 * * certbot renew --post-hook 'systemctl reload nginx'") | crontab -
else
    echo "## Cron job for Let's Encrypt certificate renewal is already set"
fi

echo "## Check if Mautic is installed"
if docker compose exec -T mautic_web test -f /var/www/html/config/local.php && docker compose exec -T mautic_web grep -q "site_url" /var/www/html/config/local.php; then
    echo "## Mautic is installed already."
    
    # Replace the site_url value with the domain
    echo "## Updating site_url in Mautic configuration..."
    docker compose exec -T mautic_web sed -i "s|'site_url' => '.*',|'site_url' => 'https://$DOMAIN',|g" /var/www/html/config/local.php
fi

echo "## Script execution completed"
