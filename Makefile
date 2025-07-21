SHELL := /bin/bash

.PHONY: init deploy undeploy openstack-check

init:
	@echo "Initializing project..."
	@if [ ! -f .env ]; then \
		echo "Creating .env file from example..."; \
		cp .env.example .env; \
	fi
	@echo "Checking required environment variables..."
	@for var in INFOBLOX_PASS GITHUB_TOKEN; do \
		if ! grep -q "$$var=" .env || [ -z "$$(grep "$$var=" .env | cut -d '=' -f2 | tr -d '\"' | tr -d \"\'\")" ]; then \
			echo -n "Enter $$var: "; \
			read value; \
			if grep -q "^$$var=" .env; then \
				sed -i "s|^$$var=.*|$$var=$$value|" .env; \
			else \
				echo "$$var=$$value" >> .env; \
			fi; \
		fi; \
	done
	@if ! command -v uv >/dev/null 2>&1; then \
		echo "Installing uv package manager..."; \
		curl -LsSf https://astral.sh/uv/install.sh | sh; \
	else \
		echo "uv is already installed"; \
	fi
	@echo "Installing dependencies using uv..."
	uv sync

docker-login:
	@echo "Logging in to DockerHub..."
	@if [ ! -f .env ]; then \
		echo "Error: .env file not found"; \
		exit 1; \
	fi
	@DOCKER_USER=$$(grep -oP '^DOCKER_USER=\K.*' .env | tr -d '"' | tr -d "'"); \
	DOCKER_TOKEN=$$(grep -oP '^DOCKER_TOKEN=\K.*' .env | tr -d '"' | tr -d "'"); \
	if [ -z "$$DOCKER_USER" ] || [ -z "$$DOCKER_TOKEN" ]; then \
		echo "Error: DOCKER_USER and DOCKER_TOKEN must be defined in .env file"; \
		exit 1; \
	else \
		echo "Logging in as $$DOCKER_USER"; \
		docker login -u "$$DOCKER_USER" -p "$$DOCKER_TOKEN"; \
	fi


openstack-check:
	@echo "Checking OpenStack rc file..."
	@if [ ! -f .env ]; then \
		echo "Error: .env file not found"; \
		exit 1; \
	fi
	@OPENSTACK_RC_PATH=$$(grep -oP '^OPENSTACK_RC_PATH=\K.*' .env | tr -d '"' | tr -d "'") && \
	if [ -z "$$OPENSTACK_RC_PATH" ]; then \
		echo "Error: OPENSTACK_RC_PATH not defined in .env file"; \
		exit 1; \
	elif [ ! -f "$$OPENSTACK_RC_PATH" ]; then \
		echo "Error: OpenStack rc file not found at $$OPENSTACK_RC_PATH"; \
		exit 1; \
	else \
		echo "OpenStack rc file found at $$OPENSTACK_RC_PATH"; \
	fi

deploy: openstack-check
	@echo "Deploying VM..."
	bash deploy/deploy.sh
	@echo "Running setup script..."
	bash run-setup.sh

undeploy: openstack-check
	@echo "Undeploying VM..."
	bash deploy/undeploy.sh

mcp: deploy
	@echo "Running MCP..."
	ansible-playbook -i inventory.ini mcp.yml

all: init deploy
