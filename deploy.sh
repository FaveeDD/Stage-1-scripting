#!/bin/bash
set -euo pipefail

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo "Error occurred at line $LINENO. Check $LOG_FILE"; exit 1' ERR

echo "Starting deployment..."

# Collect Parameters
read -p "Git Repository URL: " REPO_URL
if [[ ! "$REPO_URL" =~ ^https?:// ]]; then
    echo "Invalid URL format. Must start with http:// or https://"
    exit 1
fi

read -sp "Personal Access Token (PAT): " PAT
echo ""
if [[ -z "$PAT" ]]; then
    echo "PAT cannot be empty"
    exit 1
fi

read -p "Branch name [main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Remote SSH Username: " SSH_USER
read -p "Remote Server IP: " SERVER_IP

read -p "SSH Key Path [~/.ssh/id_rsa]: " SSH_KEY
SSH_KEY=${SSH_KEY:-~/.ssh/id_rsa}
SSH_KEY="${SSH_KEY/#\~/$HOME}"

if [[ ! -f "$SSH_KEY" ]]; then
    echo "SSH key not found at: $SSH_KEY"
    exit 1
fi
chmod 600 "$SSH_KEY"

read -p "Application Port (internal container port): " APP_PORT
if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
    echo "Invalid port: $APP_PORT"
    exit 1
fi

REPO_NAME=$(basename "$REPO_URL" .git)
REMOTE_DIR="/opt/$REPO_NAME"

echo "Input validation complete"

# Clone or Pull Repository
if [ -d "$REPO_NAME" ]; then
    echo "Repository exists. Pulling latest changes..."
    cd "$REPO_NAME"
    if ! git pull origin "$BRANCH" 2>&1 | grep -v "$PAT"; then
        echo "Failed to pull repository"
        exit 2
    fi
else
    echo "Cloning repository..."
    REPO_DOMAIN=$(echo "$REPO_URL" | sed -E 's|https?://([^/]+)/.*|\1|')
    REPO_PATH=$(echo "$REPO_URL" | sed -E 's|https?://[^/]+/(.*)|\1|')
    
    if ! git clone "https://$PAT@$REPO_DOMAIN/$REPO_PATH" "$REPO_NAME" 2>&1 | grep -v "$PAT"; then
        echo "Failed to clone repository. Check PAT and URL."
        exit 2
    fi
    cd "$REPO_NAME"
fi

git checkout "$BRANCH"
CURRENT_COMMIT=$(git rev-parse --short HEAD)
echo "On branch: $BRANCH (commit: $CURRENT_COMMIT)"

# Verify Docker Configuration
if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
    echo "No Dockerfile or docker-compose.yml found"
    exit 2
fi
echo "Docker configuration verified"

# Test Network Connectivity
echo "Testing network connectivity to server..."
if ping -c 2 -W 3 "$SERVER_IP" > /dev/null 2>&1; then
    echo "Server is reachable"
else
    echo "Warning: Server ping failed, attempting SSH connection anyway"
fi

# SSH Connectivity Check
echo "Testing SSH connection..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful'" 2>&1; then
    echo "SSH connection failed"
    exit 3
fi

# Prepare Remote Environment
echo "Preparing remote environment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<'EOF'
set -e

if command -v docker &> /dev/null; then
    echo "Docker already installed: $(docker --version)"
else
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sudo sh /tmp/get-docker.sh > /dev/null 2>&1
    sudo usermod -aG docker $USER
    echo "Docker installed"
fi

if command -v docker-compose &> /dev/null; then
    echo "Docker Compose already installed: $(docker-compose --version)"
else
    echo "Installing Docker Compose..."
    sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    echo "Docker Compose installed"
fi

if command -v nginx &> /dev/null; then
    echo "Nginx already installed: $(nginx -v 2>&1)"
else
    echo "Installing Nginx..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq nginx
    echo "Nginx installed"
fi

sudo systemctl enable docker nginx 2>/dev/null || true
sudo systemctl start docker 2>/dev/null || true
sudo systemctl start nginx 2>/dev/null || true

echo "Remote environment prepared"
EOF

# Transfer Project Files
echo "Transferring project files..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" "sudo mkdir -p $REMOTE_DIR && sudo chown $SSH_USER:$SSH_USER $REMOTE_DIR"

rsync -avz --delete \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='*.log' \
    --exclude='__pycache__' \
    -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
    . "$SSH_USER@$SERVER_IP:$REMOTE_DIR/"

echo "Files transferred"

# Deploy Application
echo "Deploying Docker containers..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
set -e
cd $REMOTE_DIR

echo "Cleaning up old containers..."
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
    docker-compose down 2>/dev/null || true
else
    docker stop $REPO_NAME 2>/dev/null || true
    docker rm $REPO_NAME 2>/dev/null || true
fi

docker network prune -f 2>/dev/null || true

echo "Building containers..."
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
    docker-compose up -d --build
else
    docker build -t $REPO_NAME:latest .
    docker run -d --name $REPO_NAME -p $APP_PORT:$APP_PORT --restart unless-stopped $REPO_NAME:latest
fi

echo "Waiting for container initialization..."
sleep 5

echo "Validating container health..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
    if docker ps | grep -q $REPO_NAME; then
        CONTAINER_STATUS=\$(docker inspect --format='{{.State.Status}}' $REPO_NAME 2>/dev/null || echo "not found")
        if [ "\$CONTAINER_STATUS" = "running" ]; then
            if curl -f -s http://localhost:$APP_PORT > /dev/null 2>&1; then
                echo "Container is healthy and responding"
                break
            fi
        fi
    fi
    RETRY_COUNT=\$((RETRY_COUNT+1))
    sleep 2
done

if [ \$RETRY_COUNT -eq \$MAX_RETRIES ]; then
    echo "Container failed health check after \$MAX_RETRIES attempts"
    docker logs --tail 50 $REPO_NAME 2>&1 || docker-compose logs --tail 50 2>&1 || true
    exit 4
fi

docker ps --filter "name=$REPO_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo "Container deployment complete"
EOF

# Configure Nginx with SSL
echo "Configuring Nginx reverse proxy..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
set -e

NGINX_CONF="/etc/nginx/sites-available/$REPO_NAME"

echo "Setting up SSL certificate..."
sudo mkdir -p /etc/nginx/ssl
if [ ! -f /etc/nginx/ssl/cert.pem ]; then
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/key.pem \
        -out /etc/nginx/ssl/cert.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost" 2>/dev/null
    echo "Self-signed SSL certificate created"
else
    echo "SSL certificate already exists"
fi

sudo tee \$NGINX_CONF > /dev/null <<'EOL'
upstream ${REPO_NAME}_backend {
    server 127.0.0.1:${APP_PORT};
}

server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;
    
    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    client_max_body_size 100M;

    location / {
        proxy_pass http://${REPO_NAME}_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOL

sudo ln -sf \$NGINX_CONF /etc/nginx/sites-enabled/$REPO_NAME
sudo rm -f /etc/nginx/sites-enabled/default

if sudo nginx -t 2>&1; then
    sudo systemctl reload nginx
    echo "Nginx configured successfully"
else
    echo "Nginx configuration test failed"
    exit 5
fi
EOF

# Validate Deployment
echo "Validating deployment..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
set -e

echo "Checking Docker service status..."
sudo systemctl status docker | grep Active || true

echo ""
echo "Running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "Checking port $APP_PORT..."
if sudo ss -tlnp | grep -q ":$APP_PORT"; then
    echo "Port $APP_PORT is listening"
else
    echo "Warning: Port $APP_PORT not found in listening state"
fi

echo ""
echo "Testing Nginx proxy (HTTP)..."
HTTP_CODE=\$(curl -k -s -o /dev/null -w "%{http_code}" http://localhost:80)
if [ "\$HTTP_CODE" = "301" ] || [ "\$HTTP_CODE" = "200" ]; then
    echo "HTTP proxy responding (code: \$HTTP_CODE)"
else
    echo "Warning: HTTP proxy returned code \$HTTP_CODE"
fi

echo ""
echo "Testing Nginx proxy (HTTPS)..."
HTTPS_CODE=\$(curl -k -s -o /dev/null -w "%{http_code}" https://localhost:443)
if [ "\$HTTPS_CODE" = "200" ] || [ "\$HTTPS_CODE" = "301" ] || [ "\$HTTPS_CODE" = "302" ]; then
    echo "HTTPS proxy responding (code: \$HTTPS_CODE)"
else
    echo "Warning: HTTPS proxy returned code \$HTTPS_CODE"
fi

echo ""
echo "Recent container logs:"
docker logs --tail 20 $REPO_NAME 2>&1 || docker-compose logs --tail 20 2>&1 || true
EOF

# Local validation from deployment machine
echo ""
echo "Testing external connectivity from deployment machine..."
HTTP_TEST=$(curl -k -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP" 2>&1 || echo "failed")
if [[ "$HTTP_TEST" =~ ^(200|301|302)$ ]]; then
    echo "External HTTP access confirmed (code: $HTTP_TEST)"
else
    echo "Warning: External HTTP test returned: $HTTP_TEST"
    echo "Check firewall rules on server"
fi

HTTPS_TEST=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$SERVER_IP" 2>&1 || echo "failed")
if [[ "$HTTPS_TEST" =~ ^(200|301|302)$ ]]; then
    echo "External HTTPS access confirmed (code: $HTTPS_TEST)"
else
    echo "Warning: External HTTPS test returned: $HTTPS_TEST"
fi

echo ""
echo "Deployment completed successfully"
echo "Server URL: http://$SERVER_IP (redirects to HTTPS)"
echo "HTTPS URL: https://$SERVER_IP"
echo "Container: $REPO_NAME"
echo "Application Port: $APP_PORT"
echo "Remote Path: $REMOTE_DIR"
echo "Log File: $LOG_FILE"
echo ""
echo "Note: SSL certificate is self-signed. For production, use Certbot:"
echo "  ssh $SSH_USER@$SERVER_IP 'sudo apt install certbot python3-certbot-nginx && sudo certbot --nginx'"

# Cleanup option
if [ "${1:-}" == "--cleanup" ]; then
    echo ""
    read -p "Are you sure you want to remove all deployed resources? (yes/no): " CONFIRM
    if [ "$CONFIRM" == "yes" ]; then
        echo "Cleaning up deployment..."
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" bash <<EOF
set -e
cd $REMOTE_DIR

if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
    docker-compose down -v
else
    docker stop $REPO_NAME 2>/dev/null || true
    docker rm $REPO_NAME 2>/dev/null || true
fi

docker network prune -f 2>/dev/null || true

sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
sudo rm -f /etc/nginx/sites-available/$REPO_NAME
sudo nginx -t && sudo systemctl reload nginx

sudo rm -rf $REMOTE_DIR

echo "Cleanup complete"
EOF
        echo "All resources removed successfully"
    else
        echo "Cleanup cancelled"
    fi
fi
