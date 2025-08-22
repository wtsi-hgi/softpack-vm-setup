#!/bin/bash

# Source .env file if it exists
if [ -f .env ]; then
    echo "Loading environment variables from .env..."
    export $(grep -v '^#' .env | xargs)
else
    echo "Warning: .env file not found."
fi

# read DEPLOY_IP from .ip file
if [ -f .ip ]; then
    DEPLOY_IP=$(cat .ip)
else
    echo "Error: .ip file not found."
    exit 1
fi

if ! grep -q "Host spb" ~/.ssh/config; then
    echo "Adding SSH config for Host spb..."
    mkdir -p ~/.ssh
    cat >> ~/.ssh/config << EOF
Host spb
    HostName $DEPLOY_IP
    User ubuntu
    IdentityFile ~/.ssh/id_${INSTANCE_NAME}
    IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
    echo "SSH config added successfully!"
else
    echo "Updating SSH config hostname for spb to $DEPLOY_IP..."
    # Update HostName
    sed -i "/^Host spb$/,/^Host / s/^[[:space:]]*HostName[[:space:]].*/    HostName $DEPLOY_IP/" ~/.ssh/config
    
    # Check if IdentityFile exists in the spb block
    if grep -A 10 "^Host spb$" ~/.ssh/config | grep -q "IdentityFile"; then
        # Update existing IdentityFile
        sed -i "/^Host spb$/,/^Host / s|^[[:space:]]*IdentityFile[[:space:]].*|    IdentityFile ~/.ssh/id_${INSTANCE_NAME}|" ~/.ssh/config
    else
        # Add IdentityFile after User line
        sed -i "/^Host spb$/,/^Host / s/^[[:space:]]*User[[:space:]].*/    User ubuntu\n    IdentityFile ~/.ssh/id_${INSTANCE_NAME}/" ~/.ssh/config
    fi
    
    # Ensure IdentitiesOnly is set to yes
    if grep -A 10 "^Host spb$" ~/.ssh/config | grep -q "IdentitiesOnly"; then
        sed -i "/^Host spb$/,/^Host / s/^[[:space:]]*IdentitiesOnly[[:space:]].*/    IdentitiesOnly yes/" ~/.ssh/config
    else
        # Prefer to place after IdentityFile if it exists, otherwise after User
        if grep -A 10 "^Host spb$" ~/.ssh/config | grep -q "IdentityFile"; then
            sed -i "/^Host spb$/,/^Host / s|^[[:space:]]*IdentityFile[[:space:]].*|&\n    IdentitiesOnly yes|" ~/.ssh/config
        else
            sed -i "/^Host spb$/,/^Host / s/^[[:space:]]*User[[:space:]].*/&\n    IdentitiesOnly yes/" ~/.ssh/config
        fi
    fi
    
    echo "SSH config hostname updated successfully!"
fi

# Run the Ansible playbook on softpack-build (spb) host
echo "Running Ansible playbook for VM setup on spb..."
ansible-playbook -i inventory.ini setup.yml

echo "Ansible playbook execution completed!" 