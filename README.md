# DevOps Deployment Script

A production-grade Bash script that automates the deployment of Dockerized applications on remote Linux servers. This script handles everything from repository cloning to Docker container deployment and Nginx reverse proxy configuration.

## Overview

This deployment script streamlines the process of setting up and deploying containerized applications on remote servers. It includes comprehensive error handling, health checks, SSL configuration, and validation to ensure reliable deployments.

## Features

- **Automated Git Integration**: Clones repositories with Personal Access Token authentication
- **Docker Management**: Installs Docker and Docker Compose if not present, builds and runs containers
- **Nginx Reverse Proxy**: Automatically configures Nginx with SSL support
- **Health Validation**: Validates container health with retry logic
- **Comprehensive Logging**: All operations logged to timestamped files
- **Error Handling**: Trap functions and meaningful exit codes for debugging
- **Idempotent Execution**: Safe to run multiple times without breaking existing deployments
- **Cleanup Functionality**: Optional flag to remove all deployed resources

## Requirements

### Local Machine
- Bash version 4.0 or higher
- Git installed
- SSH client
- rsync utility
- curl

### Remote Server
- Ubuntu or Debian-based Linux distribution
- SSH access with key authentication
- sudo privileges
- Ports 22, 80, and 443 accessible

## Installation

Clone this repository and make the script executable:

```bash
git clone https://github.com/your-username/your-repo.git
cd your-repo
chmod +x deploy.sh
```

## Usage

### Running a Deployment

Execute the script and follow the interactive prompts:

```bash
./deploy.sh
```

You will be prompted to provide:

1. **Git Repository URL**: HTTPS URL of your repository (e.g., https://github.com/username/repo.git)
2. **Personal Access Token**: GitHub PAT with repo access permissions
3. **Branch Name**: Branch to deploy (defaults to 'main' if left empty)
4. **SSH Username**: Username for remote server access
5. **Server IP Address**: IP address of the target server
6. **SSH Key Path**: Path to SSH private key (defaults to ~/.ssh/id_rsa)
7. **Application Port**: Internal container port your application listens on

### Cleanup Deployment

To remove all deployed resources from the remote server:

```bash
./deploy.sh --cleanup
```

This will prompt for confirmation before removing containers, Nginx configurations, and project files.

## How It Works

### Stage 1: Input Collection and Validation

The script collects and validates all required parameters:
- Validates Git repository URL format
- Securely collects Personal Access Token (hidden input)
- Verifies SSH key file exists and sets correct permissions
- Validates port number is within valid range (1-65535)

### Stage 2: Repository Management

Handles Git repository operations:
- Clones repository if not present locally
- Pulls latest changes if repository already exists
- Checks out specified branch
- Hides PAT from all log output
- Verifies commit hash for audit trail

### Stage 3: Docker Configuration Verification

Validates the repository contains necessary Docker files:
- Checks for Dockerfile
- Checks for docker-compose.yml or docker-compose.yaml
- Exits with error if neither is found

### Stage 4: Connectivity Testing

Tests connection to remote server:
- Pings server to verify network connectivity
- Performs SSH connection test with timeout
- Validates SSH credentials before proceeding

### Stage 5: Remote Environment Preparation

Prepares the remote server for deployment:
- Checks if Docker is installed, installs if missing
- Checks if Docker Compose is installed, installs if missing
- Checks if Nginx is installed, installs if missing
- Adds SSH user to docker group
- Enables and starts all required services
- Confirms installation versions

### Stage 6: File Transfer

Transfers project files to remote server:
- Creates remote project directory with correct permissions
- Uses rsync for efficient file transfer
- Excludes unnecessary files (.git, node_modules, logs, __pycache__)
- Only transfers changed files on subsequent deployments

### Stage 7: Container Deployment

Builds and starts Docker containers:
- Stops any existing containers gracefully
- Cleans up unused Docker networks
- Builds Docker images from Dockerfile or docker-compose
- Starts containers with restart policy
- Waits for container initialization
- Validates container health with 30 retry attempts (60 seconds total)
- Checks container responds on specified port
- Displays container logs if health check fails

### Stage 8: Nginx Configuration

Sets up reverse proxy with SSL:
- Creates self-signed SSL certificate if not present
- Generates Nginx configuration file
- Configures upstream to application port
- Sets up HTTP to HTTPS redirect
- Configures SSL with TLSv1.2 and TLSv1.3
- Adds proxy headers for proper request forwarding
- Sets connection timeouts
- Tests Nginx configuration
- Reloads Nginx service

### Stage 9: Deployment Validation

Verifies deployment success:
- Checks Docker service is running
- Lists all running containers
- Verifies application port is listening
- Tests HTTP proxy response (expects 301 redirect)
- Tests HTTPS proxy response
- Displays recent container logs
- Tests external connectivity from deployment machine
- Validates both HTTP and HTTPS access from external network

### Stage 10: Logging and Cleanup

Throughout execution:
- All output written to timestamped log file
- Error trap captures failures with line numbers
- Meaningful exit codes for different failure types
- Optional cleanup removes all deployed resources

## Exit Codes

The script uses specific exit codes for different error scenarios:

| Exit Code | Description |
|-----------|-------------|
| 0 | Deployment completed successfully |
| 1 | Input validation error (invalid URL, port, missing files) |
| 2 | Repository error (clone failed, no Dockerfile found) |
| 3 | SSH connection error (authentication failed, timeout) |
| 4 | Docker deployment error (build failed, health check failed) |
| 5 | Nginx configuration error (config test failed) |

## Logging

All deployment operations are logged to a timestamped file in the current directory:

```
deploy_YYYYMMDD_HHMMSS.log
```

The log file contains:
- All command outputs
- Success and error messages
- Timestamps for each operation
- Container logs if deployment fails

## Security Considerations

### Personal Access Token Protection
- PAT is collected with hidden input (not displayed on screen)
- PAT is filtered from all log output
- Never written to disk in plain text

### SSH Key Management
- Script automatically sets correct permissions (600) on SSH key
- Uses key-based authentication only
- StrictHostKeyChecking disabled for automation (can be enabled for production)

### SSL/TLS Configuration
- Self-signed certificate created for testing
- TLSv1.2 and TLSv1.3 enabled
- Strong cipher suites configured
- HTTP traffic redirected to HTTPS

### Production Recommendations
For production deployments, replace self-signed certificate with valid certificate:

```bash
ssh user@server
sudo apt update
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com
```

## Idempotency

The script is designed to be safely re-run multiple times:

- Existing repositories are updated instead of re-cloned
- Software packages only installed if not present
- Old containers gracefully stopped before new deployment
- Nginx configurations safely overwritten
- Docker networks cleaned up to prevent duplicates
- No data loss on re-deployment

## Troubleshooting

### SSH Connection Fails

Check SSH key permissions and connectivity:
```bash
chmod 600 ~/.ssh/id_rsa
ssh -i ~/.ssh/id_rsa user@server-ip
```

Verify server allows key authentication in `/etc/ssh/sshd_config`:
```
PubkeyAuthentication yes
```

### Docker Permission Denied

Add user to docker group on remote server:
```bash
ssh user@server
sudo usermod -aG docker $USER
newgrp docker
```

### Port Already in Use

Check what service is using the port:
```bash
ssh user@server
sudo lsof -i :80
sudo lsof -i :443
sudo systemctl stop <conflicting-service>
```

### Container Fails Health Check

View container logs for errors:
```bash
ssh user@server
docker logs <container-name>
docker ps -a
```

Common issues:
- Application not binding to 0.0.0.0 (binds to 127.0.0.1 only)
- Application port mismatch in Dockerfile
- Dependencies not installed in container
- Environment variables not set

### Nginx Configuration Test Fails

Check Nginx configuration syntax:
```bash
ssh user@server
sudo nginx -t
sudo tail -f /var/log/nginx/error.log
```

### Cannot Access Application Externally

Check firewall rules on server:
```bash
ssh user@server
sudo ufw status
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw reload
```

For cloud providers, check security group rules allow inbound traffic on ports 80 and 443.

### Self-Signed Certificate Warning

Browsers will show security warnings for self-signed certificates. This is expected behavior. For testing:
1. Click "Advanced" in browser
2. Click "Proceed to site" or "Accept risk"

For production, use Certbot to get a valid certificate from Let's Encrypt.

## Testing

### Recommended Test Repositories

Simple Node.js applications for testing:
- https://github.com/brandoncaulfield/node-api-docker
- https://github.com/BretFisher/node-docker-good-defaults
- https://github.com/nickjj/docker-node-example

### Example Deployment

```bash
./deploy.sh

# Enter when prompted:
Git Repository URL: https://github.com/brandoncaulfield/node-api-docker.git
Personal Access Token (PAT): ghp_your_token_here
Branch name [main]: main
Remote SSH Username: ubuntu
Remote Server IP: 192.168.1.100
SSH Key Path [~/.ssh/id_rsa]: 
Application Port (internal container port): 8080
```

After successful deployment, access your application:
- HTTP: http://192.168.1.100 (redirects to HTTPS)
- HTTPS: https://192.168.1.100

### Local Testing with Virtual Machine

Use Multipass for local testing:

```bash
# Install Multipass
sudo snap install multipass

# Create Ubuntu VM
multipass launch --name test-server --cpus 2 --memory 2G --disk 10G

# Get VM IP address
multipass info test-server

# Copy SSH key to VM
multipass exec test-server -- bash -c "mkdir -p ~/.ssh && echo '$(cat ~/.ssh/id_rsa.pub)' >> ~/.ssh/authorized_keys"

# Use VM IP in deployment script
```

## Performance Optimization

The script includes several optimizations:

- Checks if software is installed before attempting installation
- Uses rsync with exclusions to transfer only necessary files
- Reuses existing Docker layers when rebuilding images
- Cleans up unused Docker networks and volumes
- Minimal logging verbosity for package installations

## Limitations

- Requires sudo access on remote server
- Only supports Debian/Ubuntu-based distributions
- Assumes systemd for service management
- Self-signed SSL certificates not suitable for production
- No built-in rollback mechanism
- Does not handle secrets management

## Contributing

When modifying this script:
1. Test all changes on a clean server
2. Maintain idempotency for all operations
3. Add appropriate error handling
4. Update documentation for new features
5. Verify all 10 task requirements still met

## License

This script is provided for the HNG Internship DevOps Stage 1 challenge.

## Additional Resources

- Docker Documentation: https://docs.docker.com
- Nginx Documentation: https://nginx.org/en/docs
- Let's Encrypt: https://letsencrypt.org
- GitHub PAT Documentation: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token
