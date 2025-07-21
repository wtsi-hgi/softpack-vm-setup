#!/bin/bash
set -euo pipefail

# Load environment variables from .env
set -a
source .env
set +a

# Volume configuration - set defaults if not provided in .env
VOLUME_NAME=${VOLUME_NAME:-"${INSTANCE_NAME}-data"}
VOLUME_SIZE=${VOLUME_SIZE:-0}

# Key configuration - derive from INSTANCE_NAME if not specified
KEY_NAME=${KEY_NAME:-"${INSTANCE_NAME}-key"}
KEY_PATH=${KEY_PATH:-"$HOME/.ssh/id_${INSTANCE_NAME}"}

# Host configuration - derive from INSTANCE_NAME if not specified
DEPLOY_HOST=${DEPLOY_HOST:-"${INSTANCE_NAME}.hgi.sanger.ac.uk"}

# OpenStack credentials and configuration
source "$OPENSTACK_RC_PATH"

# Activate the virtual environment
source .venv/bin/activate

# Function to check if volume exists
volume_exists() {
    openstack volume show "$VOLUME_NAME" &>/dev/null
    return $?
}

# Check if instance exists
if ! openstack server show "$INSTANCE_NAME" &>/dev/null; then
    echo "Instance '$INSTANCE_NAME' does not exist, nothing to undeploy."
    exit 0
fi

# Get instance ID for later volume detachment
INSTANCE_ID=$(openstack server show "$INSTANCE_NAME" -f value -c id)
echo "Found instance '$INSTANCE_NAME' with ID: $INSTANCE_ID"

# First, remove DNS records
echo "Removing DNS records..."
# Get existing floating IP
source deploy/get_floating_ip.sh
export DEPLOY_IP="$FLOATING_IP"
./deploy/register_dns.sh deploy/dns_delete.json

# Handle volume detachment and removal
if volume_exists; then
    echo "Found volume '$VOLUME_NAME'"
    
    # Check if the volume is attached to our instance
    ATTACHED_SERVER=$(openstack volume show "$VOLUME_NAME" -f value -c attachments | grep -oP "server_id': '\K[^']*" || echo "")
    
    if [[ -n "$ATTACHED_SERVER" && "$ATTACHED_SERVER" == "$INSTANCE_ID" ]]; then
        echo "Volume is attached to the instance, detaching..."
        openstack server remove volume "$INSTANCE_NAME" "$VOLUME_NAME"
        
        # Wait for volume to be detached
        echo "Waiting for volume to be detached..."
        while openstack volume show "$VOLUME_NAME" -f value -c attachments | grep -q "$INSTANCE_ID"; do
            sleep 2
        done
        echo "Volume successfully detached."
    elif [[ -n "$ATTACHED_SERVER" ]]; then
        echo "WARNING: Volume '$VOLUME_NAME' is attached to a different instance. Will not detach or delete it."
        echo "If you want to delete this volume, detach it manually and delete it using 'openstack volume delete $VOLUME_NAME'"
    else
        echo "Volume is not attached to any instance."
    fi
    
    # Delete the volume if it's not attached to any instance
    if [[ -z "$(openstack volume show "$VOLUME_NAME" -f value -c attachments | grep -oP "server_id': '\K[^']*" || echo "")" ]]; then
        echo "Deleting volume '$VOLUME_NAME'..."
        openstack volume delete "$VOLUME_NAME"
        echo "Volume deleted successfully."
    fi
else
    echo "No volume named '$VOLUME_NAME' found, skipping volume cleanup."
fi

# Delete the instance
echo "Deleting instance '$INSTANCE_NAME'..."
openstack server delete "$INSTANCE_NAME"

# Delete the keypair if it exists
if openstack keypair show "$KEY_NAME" &>/dev/null; then
    echo "Deleting keypair '$KEY_NAME'..."
    openstack keypair delete "$KEY_NAME"
fi

echo "Undeployment complete!"
echo "Local SSH key at $KEY_PATH has been preserved. You can remove it manually if no longer needed." 