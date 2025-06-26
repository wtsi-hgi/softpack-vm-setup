# VM Creation

A tool for automated creation and management of virtual machines in OpenStack environments.

## Overview

This repository contains scripts and configurations for automating the creation and management of virtual machines using OpenStack. It provides simple commands to deploy and undeploy VMs with consistent configuration, and automatically configures the deployed VMs with a complete development environment.

## Prerequisites

- OpenStack RC file (credentials for OpenStack access)
- Base environment variables configured in `.env` file (created automatically during initialization)
- Bash shell

## Quick Start

```bash
# Clone the repository
git clone https://gitlab.internal.sanger.ac.uk/eh19/vm-creation.git
cd vm-creation

# Initialize the project (creates .env file and installs dependencies)
make init

# Now you should modify the .env to specify the VM properties (name, volume size etc.)

# Deploy a virtual machine
make deploy

# Undeploy a virtual machine when no longer needed
make undeploy
```

## Available Commands

| Command | Description |
|---------|-------------|
| `make init` | Initializes the project by creating a `.env` file from template, prompting for missing variables, and installing dependencies using the `uv` package manager. |
| `make openstack-check` | Verifies that OpenStack RC file exists and is correctly specified in `.env`. |
| `make deploy` | Deploys a virtual machine using OpenStack (runs `openstack-check` first), then automatically runs the setup script to configure the VM. |
| `make undeploy` | Removes a deployed virtual machine (runs `openstack-check` first). |
| `make all` | Runs initialization and deployment in sequence. |
| `./run-setup.sh` | Configures SSH access and runs the Ansible playbook to set up the development environment on the deployed VM. |

## VM Setup and Configuration

After deployment, the `run-setup.sh` script automatically configures the VM with a complete development environment using an Ansible playbook (`setup.yml`). This script:

1. **Sets up SSH configuration**: Automatically configures SSH access to the deployed VM using the IP address from the `.ip` file
2. **Runs Ansible playbook**: Executes `setup.yml` to configure the VM with:
   - **Shell environment**: Installs and configures zsh with oh-my-zsh
   - **Spack package manager**: Sets up Spack in a Singularity container for scientific software management
   - **Development tools**: Installs uv (Python package manager) and Go
   - **Git configuration**: Configures Git with GitHub token for repository access
   - **Repository setup**: Clones necessary repositories including spack-packages and spack-repo
   - **Build tools**: Sets up r-spack-recipe-builder for creating Spack recipes

The setup creates useful aliases and helper functions for working with Spack packages, making it easy to install, uninstall, and manage scientific software packages.

## Configuration

Configuration is managed through a `.env` file that is created from `.env.example` during initialization. 

Required variables include:
- `INFOBLOX_PASS`: Password for Infoblox integration
- `OPENSTACK_RC_PATH`: Path to your OpenStack RC file
- `GITHUB_TOKEN`: GitHub personal access token for repository access during VM setup
