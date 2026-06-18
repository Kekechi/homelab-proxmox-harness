"""genconfig — environment config generator (split from generate-configs.py).

Single source of truth is config/<env>.yml; this package renders every
generated artifact (tfvars, inventory, allowed-cidrs, .envrc, .env.mk, PKI
group_vars). Output is byte-stable for unchanged input — scripts/test-golden.py
is the regression gate.

See scripts/genconfig/CLAUDE.md for the function → file routing table and
scripts/genconfig/emit/CLAUDE.md for the shared emitter contract.
"""
