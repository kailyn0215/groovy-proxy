#!/bin/bash

# Ensure this script is executable
chmod +x "$0"

# Kill any existing Node processes
echo "🛑 Stopping any existing Node processes..."
pkill -f "node server.js" 2>/dev/null || true
sleep 1

# Auto-detect project directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
CREDENTIALS_FILE="$HOME/.groovy-proxy-config"

# Verify server.js exists in this directory
if [ ! -f "$PROJECT_DIR/server.js" ]; then
    echo "❌ Error: server.js not found in $PROJECT_DIR"
    echo "   Make sure this script is in the Groovy Proxy directory."
    exit 1
fi

# Navigate to project directory
cd "$PROJECT_DIR" || exit 1

# Function to load credentials from config file
load_credentials() {
    if [ -f "$CREDENTIALS_FILE" ]; then
        # Source the credentials file to load environment variables
        source "$CREDENTIALS_FILE"
        return 0
    fi
    return 1
}

# Function to save credentials securely
save_credentials() {
    local base_url="$1"
    local api_key="$2"
    
    # Create the credentials file with restricted permissions
    cat > "$CREDENTIALS_FILE" << EOF
# Groovy Proxy Configuration
# This file contains sensitive credentials - do not share!
export LITELLM_BASE_URL="$base_url"
export LITELLM_API_KEY="$api_key"
EOF
    
    # Set restrictive permissions (owner read/write only)
    chmod 600 "$CREDENTIALS_FILE"
    echo "✅ Credentials saved securely to $CREDENTIALS_FILE"
}

# Function to prompt for credentials
prompt_for_credentials() {
    echo ""
    echo "🔐 First time setup - Let's configure your API credentials"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Enter your API base URL"
    echo "Examples:"
    echo "  • OpenAI: https://api.openai.com/v1"
    echo "  • Local LiteLLM proxy: http://localhost:4000"
    echo "  • Azure: https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT"
    echo ""
    read -p "API Base URL: " input_base_url
    
    if [ -z "$input_base_url" ]; then
        echo "❌ Base URL cannot be empty"
        return 1
    fi
    
    echo ""
    echo "Enter your API key (input will be hidden for security)"
    read -s -p "API Key: " input_api_key
    echo ""  # New line after hidden input
    
    if [ -z "$input_api_key" ]; then
        echo "❌ API key cannot be empty"
        return 1
    fi
    
    # Save the credentials
    save_credentials "$input_base_url" "$input_api_key"
    
    # Export for current session
    export LITELLM_BASE_URL="$input_base_url"
    export LITELLM_API_KEY="$input_api_key"
    
    echo ""
    return 0
}

# Check and load credentials
echo "🔐 Checking API credentials..."
if load_credentials; then
    echo "✅ Credentials loaded from $CREDENTIALS_FILE"
else
    echo "⚠️  No credentials found"
    if ! prompt_for_credentials; then
        echo "❌ Failed to configure credentials"
        exit 1
    fi
fi

# GitHub repository URL for auto-updates
GITHUB_REPO="https://github.com/KailynBrown-KR/groovy-proxy.git"

# Function to check for updates and auto-update
check_for_updates() {
    echo "🔍 Checking for updates from GitHub..."
    
    # Check if this is a git repository
    if [ ! -d ".git" ]; then
        echo "⚠️  Not a git repository. Initializing git and adding remote..."
        git init 2>/dev/null
        git remote add origin "$GITHUB_REPO" 2>/dev/null
    fi
    
    # Ensure the remote is set to the correct URL
    CURRENT_REMOTE=$(git remote get-url origin 2>/dev/null)
    if [ "$CURRENT_REMOTE" != "$GITHUB_REPO" ]; then
        echo "📡 Updating remote URL to $GITHUB_REPO"
        git remote set-url origin "$GITHUB_REPO" 2>/dev/null || \
        git remote add origin "$GITHUB_REPO" 2>/dev/null
    fi
    
    # Detect the default branch (main or master)
    DEFAULT_BRANCH="main"
    if git ls-remote --heads origin master 2>/dev/null | grep -q master; then
        # Check if main also exists, prefer main
        if ! git ls-remote --heads origin main 2>/dev/null | grep -q main; then
            DEFAULT_BRANCH="master"
        fi
    fi
    
    echo "📡 Fetching from origin/$DEFAULT_BRANCH..."
    
    # Fetch latest changes from remote
    if ! git fetch origin "$DEFAULT_BRANCH" 2>/dev/null; then
        echo "⚠️  Warning: Could not fetch from remote (no network or repo access)"
        echo "   Continuing with current version..."
        return 0
    fi
    
    # Get local and remote commit hashes
    LOCAL_HASH=$(git rev-parse HEAD 2>/dev/null)
    REMOTE_HASH=$(git rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null)
    
    if [ -z "$LOCAL_HASH" ] || [ -z "$REMOTE_HASH" ]; then
        echo "⚠️  Warning: Could not determine version info"
        echo "   Continuing with current version..."
        return 0
    fi
    
    # Show version info
    LOCAL_SHORT="${LOCAL_HASH:0:7}"
    REMOTE_SHORT="${REMOTE_HASH:0:7}"
    echo "   Local version:  $LOCAL_SHORT"
    echo "   Remote version: $REMOTE_SHORT"
    
    # Compare versions
    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
        echo "✅ Already up to date!"
        return 0
    fi
    
    # Count commits behind
    COMMITS_BEHIND=$(git rev-list --count HEAD.."origin/$DEFAULT_BRANCH" 2>/dev/null || echo "?")
    echo "📦 Update available! ($COMMITS_BEHIND commits behind)"
    echo "   Updating to latest version..."
    
    # Check if there are uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "⚠️  Warning: You have uncommitted local changes"
        echo "   Stashing changes before update..."
        git stash push -m "Auto-stash before update $(date +%Y%m%d-%H%M%S)" 2>/dev/null
    fi
    
    # Pull the latest changes
    if git pull origin "$DEFAULT_BRANCH" 2>/dev/null; then
        NEW_HASH=$(git rev-parse HEAD 2>/dev/null)
        NEW_SHORT="${NEW_HASH:0:7}"
        echo "✅ Successfully updated to version $NEW_SHORT!"
        
        # Show what changed
        echo ""
        echo "📝 Recent changes:"
        git log --oneline -5 2>/dev/null | head -5 | while read line; do
            echo "   • $line"
        done
        echo ""
        
        # Check if package.json was updated and run npm install
        if git diff --name-only "$LOCAL_HASH" HEAD 2>/dev/null | grep -q "package.json"; then
            echo "📦 package.json was updated, running npm install..."
            if npm install 2>/dev/null; then
                echo "✅ Dependencies updated successfully!"
            else
                echo "⚠️  Warning: npm install failed, some features may not work"
            fi
        fi
        
        # Make start script executable again (in case it was updated)
        chmod +x "$0" 2>/dev/null
    else
        echo "⚠️  Warning: Failed to pull updates"
        echo "   Continuing with current version..."
    fi
    
    return 0
}

# Check for updates before starting
check_for_updates

echo "✅ Starting Node server from: $PROJECT_DIR"
node server.js &
SERVER_PID=$!

# Wait for server to start
sleep 3

# Check if server is actually running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ Error: Server failed to start"
    exit 1
fi

echo "✅ Opening http://localhost:3000"
open http://localhost:3000  # Change to 'xdg-open' on Linux or 'start' on Windows

echo "✅ Server running with PID: $SERVER_PID"
echo "To stop the server, run: kill $SERVER_PID"