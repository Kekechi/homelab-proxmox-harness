#!/usr/bin/env bash
# vault-pass.sh — Ansible vault password provider
# Ansible calls this script and uses stdout as the vault password.
# Set ANSIBLE_VAULT_PASSWORD in .envrc (the single secrets file).
printf '%s' "${ANSIBLE_VAULT_PASSWORD:?ANSIBLE_VAULT_PASSWORD is not set. Fill it in .envrc and run: source .envrc}"
