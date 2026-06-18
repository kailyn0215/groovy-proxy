#!/bin/bash

# Ensure this script is executable
chmod +x "$0"

# Kill any existing Node processes
echo "🛑 Stopping any existing Node processes..."
pkill -f "node server.js" 2>/dev/null || true
sleep 1

CONFIG_FILE="$HOME/.node-server-config"
CREDENTIALS_FILE="$HOME/.litellm-chat-config"
PROJECT_DIR=""

# Function to save the project directory
save_path() {
    echo "$1" > "$CONFIG_FILE"
    echo "Path saved to $CONFIG_FILE"
}

# Function to prompt for path
prompt_for_path() {
    echo "Please enter the full path to your Node project:"
    read -p "Path: " input_path
    
    # Remove trailing slash if present
    input_path="${input_path%/}"
    
    # Check if directory exists
    if [ ! -d "$input_path" ]; then
        echo "❌ Directory not found: $input_path"
        return 1
    fi
    
    # Check if server.js exists
    if [ ! -f "$input_path/server.js" ]; then
        echo "❌ server.js not found in $input_path"
        return 1
    fi
    
    save_path "$input_path"
    PROJECT_DIR="$input_path"
    return 0
}

# Check if config file exists and has a valid path
if [ -f "$CONFIG_FILE" ]; then
    PROJECT_DIR=$(cat "$CONFIG_FILE")
    
    # Verify the saved path still exists
    if [ ! -d "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/server.js" ]; then
        echo "⚠️  Saved path is invalid or has changed"
        if ! prompt_for_path; then
            exit 1
        fi
    fi
else
    echo "🚀 First time setup - let's find your project!"
    if ! prompt_for_path; then
        exit 1
    fi
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
# LiteLLM Chat Configuration
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
    echo "Enter your LiteLLM/OpenAI API base URL"
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

# Function to check for updates and auto-update
check_for_updates() {
    echo "🔍 Checking for updates from GitHub..."
    
    # Check if this is a git repository
    if [ ! -d ".git" ]; then
        echo "⚠️  Warning: Not a git repository, skipping update check"
        return 0
    fi
    
    # Fetch latest changes from remote
    if ! git fetch origin master 2>/dev/null; then
        echo "⚠️  Warning: Could not fetch from remote (no network or repo access)"
        echo "   Continuing with current version..."
        return 0
    fi
    
    # Get local and remote commit hashes
    LOCAL_HASH=$(git rev-parse HEAD 2>/dev/null)
    REMOTE_HASH=$(git rev-parse origin/master 2>/dev/null)
    
    if [ -z "$LOCAL_HASH" ] || [ -z "$REMOTE_HASH" ]; then
        echo "⚠️  Warning: Could not determine version info"
        echo "   Continuing with current version..."
        return 0
    fi
    
    # Compare versions
    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
        echo "✅ Already up to date!"
        return 0
    fi
    
    echo "📦 Update available! Updating to latest version..."
    
    # Check if there are uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        echo "⚠️  Warning: You have uncommitted local changes"
        echo "   Stashing changes before update..."
        git stash 2>/dev/null
    fi
    
    # Pull the latest changes
    if git pull origin master 2>/dev/null; then
        echo "✅ Successfully updated to latest version!"
        
        # Check if package.json was updated and run npm install
        if git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -q "package.json"; then
            echo "📦 package.json was updated, running npm install..."
            if npm install 2>/dev/null; then
                echo "✅ Dependencies updated successfully!"
            else
                echo "⚠️  Warning: npm install failed, some features may not work"
            fi
        fi
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