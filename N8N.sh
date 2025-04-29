#!/bin/bash

# === Configuration ===
# N8N Data Directory (relative to the user running the script, e.g., /root/n8n-data if run as root)
N8N_BASE_DIR="$HOME/n8n-data" # You can change this path if desired
N8N_VOLUME_DIR="$N8N_BASE_DIR/n8n_local_data"
DOCKER_COMPOSE_FILE="$N8N_BASE_DIR/docker-compose.yml"
# Cloudflared config file path
CLOUDFLARED_CONFIG_FILE="/etc/cloudflared/config.yml"
# Default Timezone if system TZ is not set
DEFAULT_TZ="Asia/Ho_Chi_Minh"

# === Script Execution ===
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Prevent errors in a pipeline from being masked.
set -o pipefail

# --- Check if running as root ---
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root. Please use 'sudo ./install_n8n_docker_cloudflared.sh'" >&2
   exit 1
fi

# --- Get User Input ---
echo "--------------------------------------------------"
echo " Cloudflare Tunnel and n8n Setup Script "
echo "--------------------------------------------------"
echo "This script will install Docker, Cloudflared, and configure n8n"
echo "to be accessible via your Cloudflare Tunnel."
echo ""

read -p "Enter your Cloudflare Tunnel Token: " CF_TOKEN
if [ -z "$CF_TOKEN" ]; then
    echo "Error: Cloudflare Tunnel Token cannot be empty." >&2
    exit 1
fi

read -p "Enter the Public Hostname (e.g., n8n.yourdomain.com): " CF_HOSTNAME
if [ -z "$CF_HOSTNAME" ]; then
    echo "Error: Public Hostname cannot be empty." >&2
    exit 1
fi
echo "" # Newline for better formatting

# --- System Update and Prerequisites ---
echo ">>> Updating system packages..."
apt update
echo ">>> Installing prerequisites (curl, wget, gpg, etc.)..."
apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release wget

# --- Install Docker ---
if ! command -v docker &> /dev/null; then
    echo ">>> Docker not found. Installing Docker..."
    # Add Docker's official GPG key:
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt update

    # Install Docker packages
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo ">>> Docker installed successfully."

    # Add the current sudo user (if exists) to the docker group
    # This avoids needing sudo for every docker command AFTER logging out/in again
    REAL_USER="${SUDO_USER:-$(whoami)}"
    if id "$REAL_USER" &>/dev/null && ! getent group docker | grep -qw "$REAL_USER"; then
      echo ">>> Adding user '$REAL_USER' to the 'docker' group..."
      usermod -aG docker "$REAL_USER"
      echo ">>> NOTE: User '$REAL_USER' needs to log out and log back in for docker group changes to take full effect."
    fi

else
    echo ">>> Docker is already installed."
fi

# Ensure Docker service is running and enabled
echo ">>> Ensuring Docker service is running and enabled..."
systemctl start docker
systemctl enable docker
echo ">>> Docker service check complete."

# --- Install Cloudflared ---
if ! command -v cloudflared &> /dev/null; then
    echo ">>> Cloudflared not found. Installing Cloudflared..."
    # Download the ARM64 package
    CLOUDFLARED_DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
    CLOUDFLARED_DEB_PATH="/tmp/cloudflared-linux-arm64.deb"
    echo ">>> Downloading Cloudflared package from $CLOUDFLARED_DEB_URL..."
    wget -q "$CLOUDFLARED_DEB_URL" -O "$CLOUDFLARED_DEB_PATH"
    echo ">>> Installing Cloudflared package..."
    dpkg -i "$CLOUDFLARED_DEB_PATH"
    rm "$CLOUDFLARED_DEB_PATH" # Clean up downloaded file
    echo ">>> Cloudflared installed successfully."
else
    echo ">>> Cloudflared is already installed."
fi

# --- Setup n8n Directory and Permissions ---
echo ">>> Setting up n8n data directory: $N8N_BASE_DIR"
mkdir -p "$N8N_VOLUME_DIR" # Create the specific volume dir as well
# Set ownership to UID 1000, GID 1000 (standard 'node' user in n8n container)
# This prevents permission errors when n8n tries to write data
echo ">>> Setting permissions for n8n data volume..."
chown -R 1000:1000 "$N8N_VOLUME_DIR"

# --- Create Docker Compose File ---
echo ">>> Creating Docker Compose file: $DOCKER_COMPOSE_FILE"
# Determine Timezone
SYSTEM_TZ=$(cat /etc/timezone 2>/dev/null || echo "$DEFAULT_TZ")
cat <<EOF > "$DOCKER_COMPOSE_FILE"
services:
  n8n:
    image: n8nio/n8n
    container_name: n8n_service
    restart: unless-stopped
    ports:
      # Bind only to localhost, as Cloudflared will handle external access
      - "127.0.0.1:5678:5678"
    environment:
      # Use system timezone if available, otherwise default
      - TZ=${SYSTEM_TZ}
      # N8N_SECURE_COOKIE=false # DO NOT USE THIS when accessing via HTTPS (Cloudflared)
      # Add any other specific n8n environment variables here:
      # - N8N_HOST=$CF_HOSTNAME # Optional: Tell n8n its public hostname
      # - WEBHOOK_URL=https://$CF_HOSTNAME/ # Optional: Base URL for webhooks
    volumes:
      # Mount the local data directory into the container
      - ./n8n_local_data:/home/node/.n8n

networks:
  default:
    name: n8n-network # Define a specific network name (optional but good practice)

EOF
echo ">>> Docker Compose file created."

# --- Configure Cloudflared Service ---
echo ">>> Configuring Cloudflared..."
# Create directory if it doesn't exist
mkdir -p /etc/cloudflared

# Create cloudflared config.yml
echo ">>> Creating Cloudflared config file: $CLOUDFLARED_CONFIG_FILE"
cat <<EOF > "$CLOUDFLARED_CONFIG_FILE"
# This file is configured for tunnel runs via 'cloudflared service install'
# It defines the ingress rules. Tunnel ID and credentials file are managed
# automatically by the service install command using the provided token.
# Do not add 'tunnel:' or 'credentials-file:' lines here.

ingress:
  - hostname: ${CF_HOSTNAME}
    service: http://localhost:5678 # Points to n8n running locally via Docker port mapping
  - service: http_status:404 # Catch-all rule
EOF
echo ">>> Cloudflared config file created."

# Install cloudflared as a service using the token
echo ">>> Installing Cloudflared service using the provided token..."
# The service install command handles storing the token securely
cloudflared service install "$CF_TOKEN"
echo ">>> Cloudflared service installed."

# --- Start Services ---
echo ">>> Enabling and starting Cloudflared service..."
systemctl enable cloudflared
systemctl start cloudflared

# Brief pause to allow service to stabilize
sleep 5
echo ">>> Checking Cloudflared service status:"
systemctl status cloudflared --no-pager || echo "Warning: Cloudflared status check indicates an issue. Use 'sudo journalctl -u cloudflared' for details."

echo ">>> Starting n8n container via Docker Compose..."
# Use -f to specify the file, ensuring it runs from anywhere
# Use --remove-orphans to clean up any old containers if the compose file changed significantly
# Use -d to run in detached mode
docker compose -f "$DOCKER_COMPOSE_FILE" up --remove-orphans -d

# --- Final Instructions ---
echo ""
echo "--------------------------------------------------"
echo " Setup Complete! "
echo "--------------------------------------------------"
echo "n8n should now be running in Docker and accessible via Cloudflare Tunnel."
echo ""
echo "Access your n8n instance at:"
echo "  https://${CF_HOSTNAME}"
echo ""
echo "Notes:"
echo "- It might take a minute or two for the Cloudflare Tunnel connection to be fully established."
echo "- If you encounter issues, check the n8n container logs: 'docker logs n8n_service'"
echo "- Check Cloudflared service logs: 'sudo journalctl -u cloudflared -f'"
echo "- Ensure DNS for ${CF_HOSTNAME} is correctly pointing to your Cloudflare Tunnel (usually handled automatically by Cloudflare)."
echo "- Remember to log out and log back in if user '$REAL_USER' was just added to the 'docker' group."
echo "--------------------------------------------------"

exit 0
