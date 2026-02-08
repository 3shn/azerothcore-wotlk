#!/usr/bin/env bash

# Smart Self-Extracting Installer Script
# Designed for "fire-and-forget" deployment of Docker Compose stacks.

set -e

# ==============================================================================
# Configuration & Constants
# ==============================================================================

# Directories (Relative to the script location, which is the extraction root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_BUNDLE_DIR="${SCRIPT_DIR}/images"
DATA_BUNDLE_DIR="${SCRIPT_DIR}/data"
APP_DATA_DIR="${APP_DATA_DIR:-./app-data}" # Allow override via env, default to ./app-data
ENV_FILE="${ENV_FILE:-.env}"

# Log file
LOG_FILE="setup.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Flags
NON_INTERACTIVE=false
TS_KEY_ARG=""

# ==============================================================================
# Argument Parsing
# ==============================================================================

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -y|--non-interactive) NON_INTERACTIVE=true ;;
        --auth-key) TS_KEY_ARG="$2"; shift ;;
        --app-data) APP_DATA_DIR="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# ==============================================================================
# Helper Functions
# ==============================================================================

log() {
    echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

# ==============================================================================
# 1. Dependency Bootstrapping
# ==============================================================================

check_dependencies() {
    info "Checking dependencies..."

    if ! command -v docker &> /dev/null; then
        warn "Docker not found. Installing..."
        # Automated install using official script
        if curl -fsSL https://get.docker.com -o get-docker.sh; then
            sh get-docker.sh
            rm get-docker.sh
            info "Docker installed successfully."
        else
            error "Failed to download Docker installation script. Please install Docker manually."
        fi
    else
        info "Docker is already installed."
    fi

    # Check for Docker Compose (plugin)
    if ! docker compose version &> /dev/null; then
        warn "Docker Compose (v2) not found. Attempting to install plugin..."
        # Try to install the plugin via apt if possible, or error out
        # Since we are assuming a fresh linux server, likely Debian/Ubuntu
        if command -v apt-get &> /dev/null; then
             sudo apt-get update && sudo apt-get install -y docker-compose-plugin || warn "Failed to auto-install plugin."
        fi
        
        if ! docker compose version &> /dev/null; then
             error "Docker Compose (v2 plugin) is missing. Please install 'docker-compose-plugin'."
        fi
    else
        info "Docker Compose is present."
    fi

    # Ensure Docker daemon is running
    # Allow non-sudo if user is in docker group
    if ! docker info &> /dev/null; then
        warn "Docker daemon is not running or user lacks permission. Attempting to start/fix..."
        if command -v systemctl &> /dev/null; then
             sudo systemctl start docker
             sudo systemctl enable docker
             # Add current user to docker group if not already
             if ! groups | grep -q docker; then
                 warn "Adding user to docker group..."
                 sudo usermod -aG docker "$USER"
                 warn "User added to docker group. You may need to re-login for this to take effect."
             fi
        fi
        
        # Check again
        if ! docker info &> /dev/null; then
             # Try with sudo
             if sudo docker info &> /dev/null; then
                 info "Docker needs sudo. Will prepend sudo to commands."
                 DOCKER_CMD="sudo docker"
             else
                 error "Failed to start Docker daemon. Please start it manually."
             fi
        fi
    fi
}

# ==============================================================================
# 2. Smart Resource Hydration
# ==============================================================================

load_images() {
    info "Hydrating container images..."
    
    # Extract image names from docker-compose.yml
    if [ -f "docker-compose.yml" ]; then
        IMAGES=$(grep '^\s*image:' docker-compose.yml | awk '{print $2}')
    else
        warn "docker-compose.yml not found. Cannot determine images to pre-load."
        IMAGES=""
    fi

    if [ -n "$IMAGES" ]; then
        for IMG in $IMAGES; do
            info "Processing image: $IMG"
            
            # 1. Check Daemon
            if ${DOCKER_CMD:-docker} image inspect "$IMG" &> /dev/null; then
                info "  [SKIP] Image $IMG already present in daemon."
                continue
            fi

            # 2. Check Bundle
            CLEAN_NAME=$(echo "$IMG" | sed 's/[:\/]/_/g') 
            BUNDLE_PATH="$IMAGE_BUNDLE_DIR/$CLEAN_NAME.tar"
            
            if [ -f "$BUNDLE_PATH" ]; then
                info "  [LOAD] Found bundled image $BUNDLE_PATH. Loading..."
                if ${DOCKER_CMD:-docker} load -i "$BUNDLE_PATH"; then
                    info "  -> Successfully loaded."
                else
                    warn "  -> Failed to load bundle. Will fallback to pull."
                fi
            else
                info "  [PULL] No bundle found for $IMG. Will pull from registry."
            fi
        done
    else
        # Fallback if we couldn't parse images: Load all bundles blindly
        info "Could not parse image names. Loading all bundles in $IMAGE_BUNDLE_DIR..."
        if [ -d "$IMAGE_BUNDLE_DIR" ]; then
            for archive in "$IMAGE_BUNDLE_DIR"/*.tar; do
                [ -e "$archive" ] || continue
                info "Loading $archive..."
                ${DOCKER_CMD:-docker} load -i "$archive"
            done
        fi
    fi
}

hydrate_data() {
    info "Hydrating application data..."

    # Ensure app data dir exists
    if [ ! -d "$APP_DATA_DIR" ]; then
        mkdir -p "$APP_DATA_DIR"
    fi

    # Check if data exists
    if [ "$(ls -A "$APP_DATA_DIR")" ]; then
        info "  [SKIP] Destination ($APP_DATA_DIR) is not empty. Preserving user data."
    else
        # Check for bundle
        DATA_ARCHIVE="$DATA_BUNDLE_DIR/data.tar.gz"
        if [ -f "$DATA_ARCHIVE" ]; then
            info "  [EXTRACT] Found data bundle. Extracting..."
            tar -xzf "$DATA_ARCHIVE" -C "$APP_DATA_DIR"
            info "  -> Extraction complete."
        else
            info "  [INIT] No data bundle found. Application will initialize empty."
        fi
    fi
}

# ==============================================================================
# 3. Zero-Config Networking
# ==============================================================================

configure_networking() {
    info "Configuring networking..."

    # Ensure .env exists
    touch "$ENV_FILE"

    # Check for TS_AUTH_KEY in env file
    if grep -q "^TS_AUTH_KEY=" "$ENV_FILE"; then
        info "Tailscale Auth Key found in $ENV_FILE. Using existing key."
        return
    fi
    
    # Check for Environment Variable (CI/CD)
    if [ -n "$TS_AUTH_KEY" ]; then
        info "Tailscale Auth Key found in environment variables."
        TS_KEY="$TS_AUTH_KEY"
    # Check for argument override
    elif [ -n "$TS_KEY_ARG" ]; then
        info "Tailscale Auth Key provided via argument."
        TS_KEY="$TS_KEY_ARG"
    elif [ "$NON_INTERACTIVE" = true ]; then
        warn "Non-interactive mode: No Auth Key provided via env or args."
        warn "Tailscale setup will be skipped. You may need to configure it manually."
        return
    else
        # Interactive Prompt
        echo ""
        echo "===================================================================="
        echo " Tailscale Setup Required"
        echo "===================================================================="
        echo "Please enter your Tailscale Auth Key (tskey-auth-...) to join the mesh."
        read -r -p "Auth Key: " TS_KEY
    fi
    
    if [ -n "$TS_KEY" ]; then
        # Append to .env
        echo "" >> "$ENV_FILE"
        echo "TS_AUTH_KEY=$TS_KEY" >> "$ENV_FILE"
        info "Auth key saved to $ENV_FILE."
    else
        warn "No key provided. Tailscale might fail to connect."
    fi
}

# ==============================================================================
# 4. Atomic Execution
# ==============================================================================

deploy() {
    info "Deploying stack..."
    
    # Run Docker Compose
    # --remove-orphans cleans up old service containers if names changed
    # Use the sudo command if detected earlier
    ${DOCKER_CMD:-docker} compose up -d --remove-orphans
    
    info "Stack deployed successfully!"
    info "To view logs: ${DOCKER_CMD:-docker} compose logs -f"
}

# ==============================================================================
# Main Execution
# ==============================================================================

main() {
    echo "========================================================"
    echo "   Smart Installer - Fire & Forget Deployment"
    echo "========================================================"
    log "Starting Smart Installer..."
    
    check_dependencies
    load_images
    hydrate_data
    configure_networking
    deploy
    
    log "Installation Complete."
}

# Execute
main
