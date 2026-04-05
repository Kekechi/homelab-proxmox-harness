---
name: deploy
description: RETIRED — use tf-deploy for Terraform changes, ansible-deploy for Ansible changes, or ansible-run for pre-flight + run + verify only.
disable-model-invocation: true
---

# Skill: Deploy (Retired)

This skill has been split. Use the appropriate skill for your change type:

| Change type | Skill |
|---|---|
| New/modified Terraform infrastructure | `/tf-deploy` |
| New/modified Ansible roles or playbooks | `/ansible-deploy` |
| Code already written and reviewed — just run it | `/ansible-run` |

For changes that require both Terraform and Ansible (new infra + service config), run `/tf-deploy` first in its own session, then `/ansible-deploy` in a separate session.
