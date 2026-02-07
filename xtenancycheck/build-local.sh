#!/bin/bash

# build-local.sh - Build and deploy xtenancycheck function for local testing with OCI CLI config
# ⚠️ WARNING: This script uses Dockerfile.oci_cli which embeds OCI credentials - ONLY for local testing

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
APP_NAME=""
FN_REGISTRY=""
IMAGE_NAME="xtenancycheck:local"
USE_EXISTING_IMAGE=false
VERBOSE=false
LOCAL_MODE=true  # Default to local mode

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}[VERBOSE]${NC} $1"
    fi
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build and deploy xtenancycheck function for local testing with OCI CLI config.

OPTIONS:
    -a, --app-name NAME          Oracle Functions application name (required)
    -r, --registry REGISTRY       Docker registry (optional, for fn deploy)
    -i, --image IMAGE             Docker image name (default: xtenancycheck:local)
    -e, --use-existing            Use existing Docker image instead of building
    -l, --local                   Deploy to local fn server (default)
    -v, --verbose                 Enable verbose output
    -h, --help                    Show this help message

EXAMPLES:
    $0 -a myapp
    $0 -a myapp -r myregistry.ocir.io
    $0 -a myapp -e -i xtenancycheck:local
    $0 -a myapp -v

⚠️  WARNING: This script uses Dockerfile.oci_cli which embeds OCI credentials.
   ONLY use this for local testing. DO NOT push images to public registries.
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--app-name)
            APP_NAME="$2"
            shift 2
            ;;
        -r|--registry)
            FN_REGISTRY="$2"
            shift 2
            ;;
        -i|--image)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -e|--use-existing)
            USE_EXISTING_IMAGE=true
            shift
            ;;
        -l|--local)
            LOCAL_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check if app-name is provided
if [ -z "$APP_NAME" ]; then
    print_error "Application name is required. Use -a or --app-name"
    usage
    exit 1
fi

if [ "$VERBOSE" = true ]; then
    print_verbose "Verbose mode enabled"
    print_verbose "Application name: $APP_NAME"
    print_verbose "Image name: $IMAGE_NAME"
    print_verbose "Use existing image: $USE_EXISTING_IMAGE"
    print_verbose "Local mode: $LOCAL_MODE"
    if [ -n "$FN_REGISTRY" ]; then
        print_verbose "Registry: $FN_REGISTRY"
    fi
    print_verbose "Current directory: $(pwd)"
    print_verbose "User: $(whoami)"
    echo
fi

# Check prerequisites
print_info "Checking prerequisites..."

if [ ! -f "Dockerfile.oci_cli" ]; then
    print_error "Dockerfile.oci_cli not found. Run this script from the xtenancycheck/ directory."
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi
print_verbose "Docker found: $(docker --version)"

# Check if fn CLI is installed
if ! command -v fn &> /dev/null; then
    print_error "Fn CLI is not installed. Please install Fn CLI first."
    exit 1
fi
print_verbose "Fn CLI found: $(fn version 2>/dev/null || echo 'version unknown')"

# Check Fn context
if [ "$VERBOSE" = true ]; then
    print_verbose "Current Fn context:"
    fn list contexts 2>/dev/null | grep -E "^\*|default|oci" || print_verbose "  (unable to list contexts)"
    print_verbose "Current Fn context details:"
    fn inspect context 2>/dev/null || print_verbose "  (unable to inspect context)"
fi

# Check if local fn server is running
if ! fn list apps &> /dev/null; then
    print_warning "Cannot connect to local fn server. Make sure it's running with 'fn start'"
    if [ "$VERBOSE" = true ]; then
        print_verbose "Attempting to check fn server status..."
        fn list apps 2>&1 || true
    fi
    # Check if running in non-interactive mode (CI/CD, script automation)
    if [ -t 0 ] && [ -t 1 ]; then
        # Interactive mode - prompt user
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        # Non-interactive mode - show warning but continue
        print_warning "Non-interactive mode detected. Continuing anyway..."
        print_warning "Make sure fn server is running before deployment step"
    fi
else
    print_verbose "Local fn server is accessible"
    if [ "$VERBOSE" = true ]; then
        print_verbose "Available applications:"
        fn list apps 2>/dev/null || print_verbose "  (none or unable to list)"
    fi
fi

print_info "Prerequisites check passed"

# Step 1: Setup OCI credentials
print_info "Setting up OCI credentials..."

# Dockerfile.oci_cli requires .oci/config and .oci/oci_api_key.pem in the function directory
if [ ! -d ".oci" ]; then
    print_info "Creating .oci directory (required by Dockerfile.oci_cli)..."
    mkdir -p .oci
    print_verbose "Created .oci directory"
    
    if [ -f "$HOME/.oci/config" ] && [ -f "$HOME/.oci/oci_api_key.pem" ]; then
        print_info "Copying OCI credentials from ~/.oci/"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Source config: $HOME/.oci/config"
            print_verbose "Source key: $HOME/.oci/oci_api_key.pem"
        fi
        cp "$HOME/.oci/config" .oci/
        cp "$HOME/.oci/oci_api_key.pem" .oci/
        print_info "OCI credentials copied successfully"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Copied to: .oci/config and .oci/oci_api_key.pem"
        fi
    else
        print_error "OCI credentials not found in ~/.oci/"
        print_info "Please ensure you have:"
        print_info "  - ~/.oci/config"
        print_info "  - ~/.oci/oci_api_key.pem"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Checking for config: $([ -f "$HOME/.oci/config" ] && echo 'found' || echo 'not found')"
            print_verbose "Checking for key: $([ -f "$HOME/.oci/oci_api_key.pem" ] && echo 'found' || echo 'not found')"
        fi
        exit 1
    fi
else
    if [ ! -f ".oci/config" ] || [ ! -f ".oci/oci_api_key.pem" ]; then
        print_error ".oci directory exists but credentials are missing"
        print_info "Please ensure .oci/config and .oci/oci_api_key.pem exist"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Checking .oci/config: $([ -f ".oci/config" ] && echo 'found' || echo 'not found')"
            print_verbose "Checking .oci/oci_api_key.pem: $([ -f ".oci/oci_api_key.pem" ] && echo 'found' || echo 'not found')"
        fi
        exit 1
    else
        print_info "Using existing .oci credentials"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Using .oci/config and .oci/oci_api_key.pem"
        fi
    fi
fi

print_warning "The .oci directory contains sensitive credentials. Ensure .oci/ is in your .gitignore"

# Step 2: Build Docker image
if [ "$USE_EXISTING_IMAGE" = false ]; then
    print_info "Building Docker image: $IMAGE_NAME"
    if [ "$VERBOSE" = true ]; then
        print_verbose "Dockerfile: Dockerfile.oci_cli"
        print_verbose "Build context: $(pwd)"
        print_verbose "Running: docker build -f Dockerfile.oci_cli -t $IMAGE_NAME ."
    fi
    
    # Check Docker daemon accessibility
    if ! docker info &> /dev/null; then
        print_error "Cannot connect to Docker daemon"
        print_info "Please ensure Docker is running and you have permission to access it"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Docker daemon check failed. Common issues:"
            print_verbose "  - Docker Desktop is not running"
            print_verbose "  - User is not in docker group (Linux)"
            print_verbose "  - Docker socket permissions issue"
        fi
        exit 1
    fi
    
    if docker build -f Dockerfile.oci_cli -t "$IMAGE_NAME" .; then
        print_info "Docker image built successfully"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Image details:"
            docker image inspect "$IMAGE_NAME" --format '  Size: {{.Size}} bytes' 2>/dev/null || true
            docker image inspect "$IMAGE_NAME" --format '  Created: {{.Created}}' 2>/dev/null || true
        fi
    else
        print_error "Failed to build Docker image"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Build failed. Check the error messages above for details."
        fi
        exit 1
    fi
else
    print_info "Skipping build, using existing image: $IMAGE_NAME"
    if ! docker image inspect "$IMAGE_NAME" &> /dev/null; then
        print_error "Image $IMAGE_NAME not found"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Available images:"
            docker images | grep xtenancycheck || print_verbose "  (no xtenancycheck images found)"
        fi
        exit 1
    else
        if [ "$VERBOSE" = true ]; then
            print_verbose "Image found:"
            docker image inspect "$IMAGE_NAME" --format '  Size: {{.Size}} bytes' 2>/dev/null || true
            docker image inspect "$IMAGE_NAME" --format '  Created: {{.Created}}' 2>/dev/null || true
        fi
    fi
fi

# Step 3: Deploy to local fn server
print_info "Deploying to local fn server..."

# fn deploy uses Dockerfile in the function directory; we use Dockerfile.oci_cli for CLI auth
# Temporarily copy Dockerfile.oci_cli to Dockerfile for deployment
DOCKERFILE_BACKUP=""
if [ -f "Dockerfile" ]; then
    DOCKERFILE_BACKUP="Dockerfile.backup.$$"
    print_verbose "Backing up existing Dockerfile to $DOCKERFILE_BACKUP"
    mv Dockerfile "$DOCKERFILE_BACKUP"
fi

print_verbose "Copying Dockerfile.oci_cli to Dockerfile for deployment"
cp Dockerfile.oci_cli Dockerfile

# Cleanup function
cleanup_dockerfile() {
    if [ -f "Dockerfile" ]; then
        rm -f Dockerfile
    fi
    if [ -n "$DOCKERFILE_BACKUP" ] && [ -f "$DOCKERFILE_BACKUP" ]; then
        print_verbose "Restoring original Dockerfile"
        mv "$DOCKERFILE_BACKUP" Dockerfile
    fi
}

# Set trap to cleanup on exit
trap cleanup_dockerfile EXIT

# Build deployment command based on local mode
DEPLOY_CMD="fn deploy"
if [ "$LOCAL_MODE" = true ]; then
    DEPLOY_CMD="$DEPLOY_CMD --local"
fi
DEPLOY_CMD="$DEPLOY_CMD --app $APP_NAME"

if [ -n "$FN_REGISTRY" ]; then
    print_info "Deploying with registry: $FN_REGISTRY"
    if [ "$LOCAL_MODE" = true ]; then
        print_info "Deploying to local fn server"
    fi
    if [ "$VERBOSE" = true ]; then
        print_verbose "Deployment command: $DEPLOY_CMD --build-arg FN_REGISTRY=$FN_REGISTRY"
    fi
    if $DEPLOY_CMD --build-arg FN_REGISTRY="$FN_REGISTRY"; then
        print_info "Function deployed successfully"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Checking deployed function:"
            fn inspect function "$APP_NAME" xtenancycheck 2>/dev/null | head -20 || print_verbose "  (unable to inspect)"
        fi
    else
        print_error "Failed to deploy function"
        cleanup_dockerfile
        exit 1
    fi
else
    if [ "$USE_EXISTING_IMAGE" = true ]; then
        print_info "Deploying using Dockerfile (image $IMAGE_NAME already exists locally)"
    else
        print_info "Deploying using Dockerfile"
    fi
    if [ "$LOCAL_MODE" = true ]; then
        print_info "Deploying to local fn server"
    fi
    if [ "$VERBOSE" = true ]; then
        print_verbose "Deployment command: $DEPLOY_CMD"
    fi
    if $DEPLOY_CMD; then
        print_info "Function deployed successfully"
        if [ "$VERBOSE" = true ]; then
            print_verbose "Checking deployed function:"
            fn inspect function "$APP_NAME" xtenancycheck 2>/dev/null | head -20 || print_verbose "  (unable to inspect)"
        fi
    else
        print_error "Failed to deploy function"
        cleanup_dockerfile
        exit 1
    fi
fi

# Cleanup
cleanup_dockerfile
trap - EXIT

# Step 4: Configuration reminder
print_info "Deployment complete!"
echo
print_warning "Don't forget to set the required configuration:"
echo "  fn config function $APP_NAME xtenancycheck secret \"<your_secret>\""
echo
print_info "To invoke the function:"
echo "  fn invoke $APP_NAME xtenancycheck"
