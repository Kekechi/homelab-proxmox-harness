FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Pin tool versions — update these when upgrading
ARG TERRAFORM_VERSION=1.10.5
ARG TFLINT_VERSION=0.54.0
ARG TERRAFORM_DOCS_VERSION=0.19.0
ARG ANSIBLE_VERSION=11.3.0

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    git \
    jq \
    python3-pip \
    python3-venv \
    direnv \
    openssh-client \
    gnupg \
    software-properties-common \
    ncat \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Sandbox only command alias for claude
RUN echo "alias sandbox-ssh='ssh' \
    sandbox-scp='scp' \
    sandbox-claude='claude --allow-dangerously-skip-permissions'" > /etc/profile.d/aliases.sh
RUN chmod +x /etc/profile.d/aliases.sh

# Terraform
RUN curl -fsSL \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip \
    && terraform --version

# TFLint
RUN curl -fsSL \
    "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip" \
    -o /tmp/tflint.zip \
    && unzip /tmp/tflint.zip -d /usr/local/bin \
    && rm /tmp/tflint.zip \
    && tflint --version

# terraform-docs
RUN curl -fsSL \
    "https://github.com/terraform-docs/terraform-docs/releases/download/v${TERRAFORM_DOCS_VERSION}/terraform-docs-v${TERRAFORM_DOCS_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin \
    && terraform-docs --version

# Ansible (pinned version via pip for reproducibility)
RUN pip3 install --no-cache-dir --break-system-packages \
    ansible==${ANSIBLE_VERSION} \
    ansible-lint \
    && ansible --version

# MinIO
RUN wget https://dl.min.io/aistor/mc/release/linux-amd64/mcli_20260327155712.0.0_amd64.deb \
    && dpkg -i mcli_20260327155712.0.0_amd64.deb \
    && mcli --version

# direnv shell hook
RUN echo 'eval "$(direnv hook bash)"' >> /etc/bash.bashrc

# Terraform plugin cache directory
RUN mkdir -p /home/vscode/.terraform.d/plugin-cache \
    && chown -R vscode:vscode /home/vscode/.terraform.d

# Install Claude Code globally — runs as root so it lands in /usr/local/bin
RUN npm install -g @anthropic-ai/claude-code

USER vscode
