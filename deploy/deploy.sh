#!/bin/bash
set -euo pipefail

# Load environment variables from .env
set -a
source .env
set +a

# Volume configuration - set defaults if not provided in .env
VOLUME_NAME=${VOLUME_NAME:-"${INSTANCE_NAME}-data"}
VOLUME_SIZE=${VOLUME_SIZE:-0}
VOLUME_MOUNT=${VOLUME_MOUNT:-"/mnt/data"}

# Key configuration - derive from INSTANCE_NAME if not specified
KEY_NAME=${KEY_NAME:-"${INSTANCE_NAME}-key"}
KEY_PATH=${KEY_PATH:-"$HOME/.ssh/id_${INSTANCE_NAME}"}

# Host configuration - derive from INSTANCE_NAME if not specified
DEPLOY_HOST=${DEPLOY_HOST:-"${INSTANCE_NAME}.hgi.sanger.ac.uk"}

# Check if volume creation should be skipped (VOLUME_SIZE=0)
SKIP_VOLUME=false
if [ "${VOLUME_SIZE}" -eq 0 ]; then
    SKIP_VOLUME=true
    echo "VOLUME_SIZE is 0, skipping volume creation and attachment."
fi

# OpenStack credentials and configuration
source "$OPENSTACK_RC_PATH"

# Activate the virtual environment
source .venv/bin/activate

# Generate SSH key if it doesn't exist locally
if [ ! -f "$KEY_PATH" ]; then
    echo "Generating new SSH key pair at $KEY_PATH..."
    ssh-keygen -t rsa -b 4096 -f "$KEY_PATH" -N "" -C "vm-deployment-${INSTANCE_NAME}"
    chmod 600 "$KEY_PATH"
    chmod 644 "$KEY_PATH.pub"
fi

# Check if instance already exists
echo "Checking if instance '$INSTANCE_NAME' already exists..."
if openstack server show "$INSTANCE_NAME" &>/dev/null; then
    echo "Instance '$INSTANCE_NAME' already exists, skipping creation..."
    # Get existing floating IP
    source deploy/get_floating_ip.sh
    
    # Now handle SSH key in OpenStack
    echo "Checking SSH key in OpenStack..."
    if openstack keypair show "$KEY_NAME" &>/dev/null; then
        echo "Keypair '$KEY_NAME' already exists in OpenStack."
        
        echo "Testing SSH connection with local key..."
        if ! ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -o ConnectTimeout=5 -i "$KEY_PATH" ubuntu@"$FLOATING_IP" 'exit' &>/dev/null; then
            echo "ERROR: Cannot connect to existing instance with local SSH key."
            echo "You need the original private key that was used for initial deployment."
            echo "Alternatively, you can deploy to a new instance by changing INSTANCE_NAME in your .env file."
            exit 1
        fi
        echo "Local SSH key works with the existing instance."
    else
        echo "WARNING: Instance exists but keypair not found in OpenStack."
        echo "Creating keypair '$KEY_NAME' in OpenStack..."
        openstack keypair create --public-key "$KEY_PATH.pub" "$KEY_NAME"
    fi
else
    # Handle SSH key in OpenStack for new instance
    echo "Checking SSH key in OpenStack..."
    if openstack keypair show "$KEY_NAME" &>/dev/null; then
        echo "Keypair '$KEY_NAME' already exists in OpenStack."
        echo "No existing instance found. Will create a new one with current key."
        echo "Replacing existing keypair '$KEY_NAME' with local key..."
        openstack keypair delete "$KEY_NAME"
        openstack keypair create --public-key "$KEY_PATH.pub" "$KEY_NAME"
    else
        echo "Creating new keypair '$KEY_NAME' in OpenStack..."
        openstack keypair create --public-key "$KEY_PATH.pub" "$KEY_NAME"
    fi

    # Create OpenStack instance
    echo "Creating OpenStack instance..."
    SECURITY_GROUP_ARGS=""

    # Check if SECURITY_GROUPS is defined
    if [ -n "${SECURITY_GROUPS:-}" ]; then
        echo "Security groups from env: $SECURITY_GROUPS"
        
        # Split the comma-separated SECURITY_GROUPS and create arguments
        for group in ${SECURITY_GROUPS//,/ }; do
            if [ -n "$group" ]; then
                SECURITY_GROUP_ARGS+=" --security-group $group"
            fi
        done
    else
        # Default security groups if not specified in .env
        echo "No security groups specified, using defaults"
        SECURITY_GROUP_ARGS="--security-group cloudforms_ssh_in --security-group cloudforms_web_in --security-group cloudforms_ext_in"
    fi

    echo "Security group arguments: $SECURITY_GROUP_ARGS"

    openstack server create \
        --image "$IMAGE_NAME" \
        --flavor "$FLAVOR" \
        --network cloudforms_network \
        $SECURITY_GROUP_ARGS \
        --key-name "$KEY_NAME" \
        "$INSTANCE_NAME"

    # Wait for instance to be active
    echo "Waiting for instance to become active..."
    while [[ $(openstack server show "$INSTANCE_NAME" -f value -c status) != "ACTIVE" ]]; do
        sleep 5
    done

    # Create and assign floating IP
    echo "Creating and assigning floating IP..."
    FLOATING_IP=$(openstack floating ip create public -f value -c floating_ip_address)
    openstack server add floating ip "$INSTANCE_NAME" "$FLOATING_IP"
    echo "Using floating IP: $FLOATING_IP"
fi

# Wait for SSH to become available
echo "Waiting for SSH to become available..."
until ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -i "$KEY_PATH" ubuntu@"$FLOATING_IP" 'exit'; do
    sleep 5
done

# Handle volume for data storage only if not skipped
if [ "$SKIP_VOLUME" = false ]; then
    echo "Checking for existing volume '$VOLUME_NAME'..."
    if ! openstack volume show "$VOLUME_NAME" &>/dev/null; then
        echo "Volume '$VOLUME_NAME' not found, creating new volume (${VOLUME_SIZE}GB)..."
        openstack volume create --size "$VOLUME_SIZE" "$VOLUME_NAME"
        
        # Wait for volume to become available
        echo "Waiting for volume to become available..."
        while [[ $(openstack volume show "$VOLUME_NAME" -f value -c status) != "available" ]]; do
            sleep 5
        done
        
        echo "Volume created successfully."
    else
        echo "Volume '$VOLUME_NAME' already exists, reusing it."
        
        # Check if volume is already attached to this instance or another
        ATTACHED_SERVER=$(openstack volume show "$VOLUME_NAME" -f value -c attachments | grep -oP "server_id': '\K[^']*" || echo "")
        CURRENT_SERVER_ID=$(openstack server show "$INSTANCE_NAME" -f value -c id)
        
        if [[ -n "$ATTACHED_SERVER" && "$ATTACHED_SERVER" != "$CURRENT_SERVER_ID" ]]; then
            echo "ERROR: Volume '$VOLUME_NAME' is already attached to another instance. Please use a different volume name."
            exit 1
        elif [[ -n "$ATTACHED_SERVER" && "$ATTACHED_SERVER" == "$CURRENT_SERVER_ID" ]]; then
            echo "Volume is already attached to this instance."
            VOLUME_ATTACHED=true
        else
            echo "Volume exists but is not attached to any instance."
            VOLUME_ATTACHED=false
        fi
    fi

    # Attach volume if not already attached
    if [[ "${VOLUME_ATTACHED:-false}" != "true" ]]; then
        echo "Attaching volume '$VOLUME_NAME' to instance '$INSTANCE_NAME'..."
        openstack server add volume "$INSTANCE_NAME" "$VOLUME_NAME"
        sleep 5  # Give some time for attachment to complete
    fi

    # Configure volume on the VM
    echo "Configuring volume on the VM..."
ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -i "$KEY_PATH" ubuntu@"$FLOATING_IP" << EOF
        set -e
        echo "Checking for attached volume..."
        
        # Get a list of block devices before we scan for the volume
        echo "Listing all block devices:"
        lsblk
        
        # Specifically exclude known system disks (vda is typically the boot disk)
        echo "Looking for data volume..."
        # Look for additional disks (exclude vda which is typically the boot disk)
        DEVICE=\$(lsblk -p -n -o NAME,TYPE | grep -v "vda" | grep "disk" | head -1 | awk '{print \$1}')
        
        if [ -z "\$DEVICE" ]; then
            echo "Trying alternative detection method..."
            # Alternative: look for a disk that matches our expected size (with some tolerance)
            MIN_SIZE=\$((${VOLUME_SIZE} * 950000000)) # 95% of expected size
            MAX_SIZE=\$((${VOLUME_SIZE} * 1050000000)) # 105% of expected size
            DEVICE=\$(lsblk -b -o NAME,SIZE,TYPE | grep -v "vda" | grep "disk" | 
                      awk "\\\$2 >= \$MIN_SIZE && \\\$2 <= \$MAX_SIZE {print \\\"/dev/\\\"\\\$1}" | head -1)
        fi
        
        if [ -z "\$DEVICE" ]; then
            echo "ERROR: Could not find attached volume device"
            echo "Available devices:"
            lsblk -p
            echo "Checking for attached volume in /dev/disk/by-id:"
            ls -la /dev/disk/by-id/ | grep openstack
            DEVICE=\$(readlink -f /dev/disk/by-id/virtio-$(echo $VOLUME_NAME | head -c 20) 2>/dev/null || echo "")
            if [ -n "\$DEVICE" ]; then
                echo "Found volume device through by-id: \$DEVICE"
            else
                exit 1
            fi
        fi
        
        echo "Found volume at \$DEVICE"
        echo "Confirming this is not the boot disk..."
        if [[ "\$DEVICE" == "/dev/vda" ]]; then
            echo "ERROR: Device \$DEVICE appears to be the boot disk! Aborting to prevent data loss."
            exit 1
        fi
        
        # Double-check if device is mounted or in use
        if mount | grep -q "\$DEVICE"; then
            echo "Device \$DEVICE is already mounted:"
            mount | grep "\$DEVICE"
        fi
        
        # Check if volume is already formatted
        if ! sudo file -s \$DEVICE | grep -q filesystem; then
            echo "Volume is not formatted. Formatting with ext4..."
            sudo mkfs.ext4 \$DEVICE
        else
            echo "Volume is already formatted"
        fi
        
        # Create mount directory
        echo "Creating mount directory at ${VOLUME_MOUNT}..."
        sudo mkdir -p ${VOLUME_MOUNT}
        
        # Add to fstab if not already there
        if ! grep -q "\$DEVICE" /etc/fstab; then
            echo "Adding volume to /etc/fstab..."
            echo "\$DEVICE ${VOLUME_MOUNT} ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
        fi
        
        # Mount the volume
        echo "Mounting volume..."
        sudo mount ${VOLUME_MOUNT} || sudo mount -a
        
        # Set permissions on the mount point itself (not a subdirectory)
        echo "Setting permissions on ${VOLUME_MOUNT}..."
        sudo chown -R ubuntu:ubuntu ${VOLUME_MOUNT}
        
        # Verify mount
        df -h ${VOLUME_MOUNT}
        echo "Volume mounted successfully at ${VOLUME_MOUNT}"
EOF
    
    VOLUME_INFO="Volume mounted at: ${VOLUME_MOUNT}"
else
    VOLUME_INFO="No data volume attached (VOLUME_SIZE=0)"
fi

# Register DNS in Infoblox
echo "Registering DNS in Infoblox..."
# DEPLOY_HOST is already set from .env file
export DEPLOY_IP="$FLOATING_IP"

# First, delete any existing DNS record
echo "Removing any existing DNS records..."
./deploy/register_dns.sh deploy/dns_delete.json

# Then register the new DNS record
echo "Creating new DNS record..."
./deploy/register_dns.sh deploy/dns_template.json

# remove old ssh known_hosts entry
ssh-keygen -f "$HOME/.ssh/known_hosts" -R $DEPLOY_HOST

# save the floating IP to .ip file
echo "$FLOATING_IP" > .ip

echo "VM deployment complete!"
echo "VM is accessible via SSH: ssh -i $KEY_PATH ubuntu@$FLOATING_IP"
echo "Hostname: $DEPLOY_HOST"
echo "${VOLUME_INFO}" 