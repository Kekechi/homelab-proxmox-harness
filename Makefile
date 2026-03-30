.DEFAULT_GOAL := help
SHELL         := /bin/bash

TF_DIR      := terraform
TF_BUCKET   := tfstate-sandbox
TF_VARFILE  := sandbox.tfvars
TF_PLANFILE := sandbox.tfplan

.PHONY: help build verify-isolation init validate lint plan apply destroy plan-prod \
        ansible-lint ansible-sandbox ansible-check bootstrap-minio docs-gen

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Dev container
# ---------------------------------------------------------------------------

build: ## Rebuild dev container images (run after editing .devcontainer/squid/)
	docker compose -f .devcontainer/docker-compose.yml build

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify-isolation: ## Run network isolation verification inside the container
	bash scripts/verify-isolation.sh

# ---------------------------------------------------------------------------
# Terraform — sandbox (Claude may plan and apply)
# ---------------------------------------------------------------------------

init: ## terraform init for sandbox (TF_BUCKET=tfstate-sandbox by default)
	cd $(TF_DIR) && terraform init \
		-backend-config="bucket=$(TF_BUCKET)" \
		-backend-config="access_key=$$MINIO_ACCESS_KEY" \
		-backend-config="secret_key=$$MINIO_SECRET_KEY" \
		-backend-config="endpoints={s3=\"$$MINIO_ENDPOINT\"}"

validate: ## terraform validate
	cd $(TF_DIR) && terraform validate

lint: ## tflint + ansible-lint
	cd $(TF_DIR) && tflint
	ansible-lint ansible/playbooks/

plan: ## terraform plan for sandbox (saves sandbox.tfplan)
	cd $(TF_DIR) && terraform plan -var-file=$(TF_VARFILE) -out=$(TF_PLANFILE)

apply: ## terraform apply sandbox.tfplan (plan-file required)
	@if [ ! -f $(TF_DIR)/$(TF_PLANFILE) ]; then \
		echo "ERROR: No plan file found at $(TF_DIR)/$(TF_PLANFILE). Run 'make plan' first."; exit 1; \
	fi
	cd $(TF_DIR) && terraform apply $(TF_PLANFILE)

destroy: ## terraform destroy for sandbox (requires confirmation)
	cd $(TF_DIR) && terraform destroy -var-file=$(TF_VARFILE)

# ---------------------------------------------------------------------------
# Terraform — production (plan only — human operator applies)
# ---------------------------------------------------------------------------

plan-prod: ## terraform plan for production (saves production.tfplan — DO NOT apply from here)
	cd $(TF_DIR) && terraform init \
		-backend-config="bucket=tfstate-production" \
		-backend-config="access_key=$$MINIO_ACCESS_KEY" \
		-backend-config="secret_key=$$MINIO_SECRET_KEY" \
		-backend-config="endpoints={s3=\"$$MINIO_ENDPOINT\"}" \
		-reconfigure
	cd $(TF_DIR) && terraform plan -var-file=production.tfvars -out=production.tfplan
	@echo ""
	@echo "Plan saved to $(TF_DIR)/production.tfplan"
	@echo "Hand this file to the human operator for review and apply."
	@echo "DO NOT run 'terraform apply' from the dev container for production."

# ---------------------------------------------------------------------------
# Ansible
# ---------------------------------------------------------------------------

ansible-lint: ## Lint all playbooks
	ansible-lint ansible/playbooks/

ansible-sandbox: ## Run sandbox playbook
	ansible-playbook -i ansible/inventory/sandbox/hosts.yml ansible/playbooks/sandbox.yml

ansible-check: ## Dry-run site playbook against sandbox
	ansible-playbook -i ansible/inventory/sandbox/hosts.yml ansible/playbooks/site.yml --check

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
