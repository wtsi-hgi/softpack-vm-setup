#!/bin/bash
set -euo pipefail

# This script retrieves the floating IP for the instance
# It can be sourced or executed directly

# Load environment variables if not already loaded
if [ -z "${INSTANCE_NAME:-}" ] || [ -z "${OPENSTACK_RC_PATH:-}" ]; then
    # When sourced, the return statement prevents script exit
    # When executed directly, this has no effect
    [ "$0" != "${BASH_SOURCE[0]}" ] && source .env || source .env

    # Activate virtualenv if not already active
    if [ -z "${VIRTUAL_ENV:-}" ]; then
        [ "$0" != "${BASH_SOURCE[0]}" ] && source .venv/bin/activate || source .venv/bin/activate
    fi
    
    # Source OpenStack credentials
    [ "$0" != "${BASH_SOURCE[0]}" ] && source "$OPENSTACK_RC_PATH" || source "$OPENSTACK_RC_PATH"
fi

if [ -z "${INSTANCE_NAME:-}" ]; then
    echo "Error: INSTANCE_NAME environment variable not set"
    [ "$0" != "${BASH_SOURCE[0]}" ] && return 1 || exit 1
fi

# Get the floating IP for the instance - select only the public IP
NETWORK_INFO=$(openstack server show "$INSTANCE_NAME" -f value -c addresses)
FLOATING_IP=$(echo "$NETWORK_INFO" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -1)

if [ -z "$FLOATING_IP" ]; then
    echo "Error: Could not determine floating IP for instance $INSTANCE_NAME"
    [ "$0" != "${BASH_SOURCE[0]}" ] && return 1 || exit 1
fi

echo "Using floating IP: $FLOATING_IP"

# Export the floating IP when the script is executed directly
if [ "$0" = "${BASH_SOURCE[0]}" ]; then
    export FLOATING_IP
fi 