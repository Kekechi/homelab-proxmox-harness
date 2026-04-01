.DEFAULT_GOAL := help
SHELL         := /bin/bash

# ---------------------------------------------------------------------------
# Environment selection — override with: make <target> ENV=production
# ---------------------------------------------------------------------------
ENV ?= sandbox

# Load generated Makefile variables from config (TF_BUCKET, TF_VARFILE, TF_PLANFILE).
# Falls back to ENV-derived defaults if .env.mk has not been generated yet.
-include .env.mk
TF_BUCKET   ?= tfstate-$(ENV)
TF_VARFILE  ?= $(ENV).tfvars
TF_PLANFILE ?= $(ENV).tfplan

TF_DIR := terraform

.PHONY: help build configure verify-isolation init validate fmt lint plan apply destroy \
        ansible-lint ansible-sandbox ansible-check bootstrap-minio docs-gen

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Configuration — single source of truth
# ---------------------------------------------------------------------------

configure: ## Generate tfvars, inventory, envrc, and allowed-cidrs from config/$(ENV).yml
	python3 scripts/generate-configs.py $(ENV)

# ---------------------------------------------------------------------------
# Dev container
# ---------------------------------------------------------------------------

build: ## Rebuild dev container images (run after make configure updates allowed-cidrs.conf)
	docker compose -f .devcontainer/docker-compose.yml build

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify-isolation: ## Run network isolation verification inside the container
	bash scripts/verify-isolation.sh

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------

init: ## Initialize Terraform backend for $(ENV) (use -reconfigure to switch environments)
	cd $(TF_DIR) && terraform init -reconfigure \
		-backend-config="bucket=$(TF_BUCKET)" \
		-backend-config="access_key=$$MINIO_ACCESS_KEY" \
		-backend-config="secret_key=$$MINIO_SECRET_KEY" \
		-backend-config="endpoints={s3=\"$$MINIO_ENDPOINT\"}"

validate: ## terraform validate
	cd $(TF_DIR) && terraform validate

fmt: ## terraform fmt (recursive)
	cd $(TF_DIR) && terraform fmt -recursive

lint: ## terraform fmt check + tflint + ansible-lint
	cd $(TF_DIR) && terraform fmt -check -recursive
	cd $(TF_DIR) && tflint
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/playbooks/

plan: ## Terraform plan for $(ENV) — saves $(ENV).tfplan
	cd $(TF_DIR) && terraform plan -var-file=$(TF_VARFILE) -out=$(TF_PLANFILE)
	@if [ "$(ENV)" != "sandbox" ]; then \
		echo ""; \
		echo "=========================================================="; \
		echo " PRODUCTION PLAN SAVED: $(TF_DIR)/$(TF_PLANFILE)"; \
		echo " Hand this file to the operator for review and apply."; \
		echo " DO NOT run 'terraform apply' from the dev container."; \
		echo " Run 'make init' to switch back to sandbox when done."; \
		echo "=========================================================="; \
	fi

apply: ## Terraform apply $(ENV).tfplan (plan file required)
	@if [ ! -f $(TF_DIR)/$(TF_PLANFILE) ]; then \
		echo "ERROR: No plan file at $(TF_DIR)/$(TF_PLANFILE). Run 'make plan' first."; exit 1; \
	fi
	cd $(TF_DIR) && terraform apply $(TF_PLANFILE)

destroy: ## Terraform destroy for $(ENV) (requires confirmation — blocked by hook for production)
	cd $(TF_DIR) && terraform destroy -var-file=$(TF_VARFILE)

# ---------------------------------------------------------------------------
# Ansible
# ---------------------------------------------------------------------------

ansible-lint: ## Lint all playbooks
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/playbooks/

ansible-sandbox: ## Run sandbox playbook against generated inventory
	ansible-playbook -i ansible/inventory/ ansible/playbooks/sandbox.yml --limit sandbox

ansible-check: ## Dry-run site playbook against sandbox inventory
	ansible-playbook -i ansible/inventory/ ansible/playbooks/site.yml --limit sandbox --check

ansible-minio: ## Deploy MinIO via Ansible (runs minio-setup.yml against minio group)
	ansible-playbook -i ansible/inventory/ ansible/playbooks/minio-setup.yml --limit minio

# ---------------------------------------------------------------------------
# Bootstrap (one-time)
# ---------------------------------------------------------------------------

bootstrap-minio: ## Bootstrap MinIO buckets and sandbox-scoped IAM (one-time)
	bash scripts/bootstrap-minio.sh

# ---------------------------------------------------------------------------
# Documentation
# ---------------------------------------------------------------------------

docs-gen: ## Regenerate terraform-docs for all modules
	terraform-docs markdown terraform/modules/proxmox-vm      > terraform/modules/proxmox-vm/README.md
	terraform-docs markdown terraform/modules/proxmox-lxc     > terraform/modules/proxmox-lxc/README.md
	terraform-docs markdown terraform/modules/proxmox-network > terraform/modules/proxmox-network/README.md
