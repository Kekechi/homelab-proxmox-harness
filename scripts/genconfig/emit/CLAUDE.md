# scripts/genconfig/emit/ — emitter contract

One module per generated artifact. Each exposes a single **pure** `gen_*`
function that takes `(cfg, env)` and returns the rendered string. No file I/O
here — `main.py` owns writing (and `helpers.atomic_write` owns the `.envrc`
smart-merge).

## The contract every emitter must honour

1. **DO-NOT-EDIT header.** Every generated artifact starts with a header naming
   `scripts/generate-configs.py` as the source and telling the reader to run
   `make configure` to regenerate. Generated files are never hand-edited.

2. **Byte-stability.** Output MUST be byte-identical for unchanged input.
   `scripts/test-golden.py` byte-compares every emitter against a committed
   golden and is the regression gate. Implications:
   - Iterate inputs in a deterministic order (sorted, or config insertion order
     — never set iteration that affects output).
   - Don't introduce timestamps, hostnames, `os.environ`, or any
     non-config-derived value into the output.
   - A refactor is correct iff the golden still matches **without `--update`**.
     If it differs, you changed output — fix the code, not the golden.

3. **`_hcl_str` null-if-empty (tfvars).** Optional/empty scalars are emitted via
   `helpers._hcl_str`, which renders `null` (not `""`) when the value is falsy.
   Required strings are quoted directly. Never emit a bare empty `""` for an
   optional HCL value.

4. **Validate-then-emit, fail loud.** Validation that an emitter needs inline
   (CIDR shape, Nexus repo completeness, required-field presence) prints a clear
   `ERROR:`/`Config error:` to stderr and `sys.exit(1)` — never emit partial or
   silently-wrong output.

## Where cross-service logic goes

`inventory.py` is the one emitter that reads across services (log_server ←
minio/splunk; dns.dist ← its CIDR + log_server; A-records ← all services). That
coupling is the reason the package is split per-artifact, not per-service. Keep
new cross-service derivations there; don't scatter them.
