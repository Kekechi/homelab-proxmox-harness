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
        loop-teardown loop-minio loop-secrets \
        ansible-lint ansible-env ansible-check ansible-minio ansible-pki \
        ansible-dns ansible-dns-records ansible-dns-dist \
        ansible-nexus bootstrap-minio docs-gen

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
	@touch .devcontainer/squid/squid.conf.local
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
	@_mkenv=$$(grep -E '^ENV\s*:?=' .env.mk 2>/dev/null | head -1 | sed 's/.*:*=\s*//' | tr -d '[:space:]'); \
	if [ -n "$$_mkenv" ] && [ "$$_mkenv" != "$(ENV)" ]; then \
		echo "ERROR: .env.mk records ENV=$$_mkenv but you requested ENV=$(ENV)."; \
		echo "  TF_BUCKET is bound from .env.mk at parse time, so 'make init' would"; \
		echo "  initialise the WRONG state bucket ($(TF_BUCKET))."; \
		echo "  Run 'make configure ENV=$(ENV)' first to realign .env.mk."; \
		exit 1; \
	fi
	cd $(TF_DIR) && terraform init -reconfigure \
		-backend-config="bucket=$(TF_BUCKET)" \
		-backend-config="access_key=$$MINIO_ACCESS_KEY" \
		-backend-config="secret_key=$$MINIO_SECRET_KEY" \
		-backend-config="endpoints={s3=\"$$MINIO_ENDPOINT\"}" \
		-backend-config="insecure=true"

validate: ## terraform validate
	cd $(TF_DIR) && terraform validate

fmt: ## terraform fmt (recursive)
	cd $(TF_DIR) && terraform fmt -recursive

lint: ## terraform fmt check + tflint + ansible-lint
	cd $(TF_DIR) && terraform fmt -check -recursive
	cd $(TF_DIR) && tflint
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/playbooks/

plan: configure ## Terraform plan for $(ENV) — saves $(ENV).tfplan (regenerates configs first)
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

destroy: configure ## Terraform destroy for $(ENV) via a destroy plan file (bare destroy is blocked by the guard hook)
	cd $(TF_DIR) && terraform plan -destroy -var-file=$(TF_VARFILE) -out=$(TF_PLANFILE)
	cd $(TF_DIR) && terraform apply $(TF_PLANFILE)

# ---------------------------------------------------------------------------
# Verification loop (sandbox only) — destroy→rebuild harness
# ---------------------------------------------------------------------------

loop-teardown: ## API sweep: delete all sandbox-pool members incl. MinIO (sandbox only)
	bash scripts/loop/teardown.sh $(ENV)

loop-minio: ## Recreate the MinIO LXC via PVE API + cloud-init (sandbox only)
	bash scripts/loop/recreate-minio.sh $(ENV)

loop-secrets: ## Generate any missing loop secrets (passphrases/keys) into .envrc
	bash scripts/loop/gen-secrets.sh $(ENV)

# ---------------------------------------------------------------------------
# Ansible
# ---------------------------------------------------------------------------

ansible-lint: ## Lint all playbooks
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/playbooks/

ansible-env: ## Run site playbook against all hosts in the current inventory
	cd ansible && ansible-playbook -i inventory/ playbooks/site.yml

ansible-check: ## Dry-run site playbook against all hosts in the current inventory
	cd ansible && ansible-playbook -i inventory/ playbooks/site.yml --check

ansible-minio: ## Deploy MinIO via Ansible
	cd ansible && ansible-playbook -i inventory/ playbooks/minio-setup.yml --limit minio

ansible-pki: ## Deploy PKI (root CA + issuing CA) via Ansible
	cd ansible && ansible-playbook -i inventory/ playbooks/pki-setup.yml

ansible-dns: ## Deploy PowerDNS Auth+Recursor via Ansible (dns-setup.yml only)
	cd ansible && ansible-playbook -i inventory/ playbooks/dns-setup.yml

ansible-dns-records: ## Populate DNS A records via PowerDNS API
	cd ansible && ansible-playbook -i inventory/ playbooks/dns-records.yml

ansible-dns-dist: ## Deploy DNSdist client-facing resolver
	cd ansible && ansible-playbook -i inventory/ playbooks/dns-dist-setup.yml

ansible-nexus: ## Deploy Nexus Repository CE via Ansible
	cd ansible && ansible-playbook -i inventory/ playbooks/nexus-setup.yml --limit nexus

# ---------------------------------------------------------------------------
# Bootstrap (one-time)
# ---------------------------------------------------------------------------

bootstrap-minio: ## Bootstrap MinIO bucket and scoped IAM for $(ENV) (one-time per environment)
	bash scripts/bootstrap-minio.sh $(ENV)

# ---------------------------------------------------------------------------
# Documentation
# ---------------------------------------------------------------------------

docs-gen: ## Regenerate terraform-docs for all modules
	terraform-docs markdown terraform/modules/proxmox-vm      > terraform/modules/proxmox-vm/README.md
	terraform-docs markdown terraform/modules/proxmox-lxc     > terraform/modules/proxmox-lxc/README.md
	terraform-docs markdown terraform/modules/proxmox-network > terraform/modules/proxmox-network/README.md
