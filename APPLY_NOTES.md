# v2.4.4 Action candidate

This tree is intended to replace the current monolithic workflow with a thin
orchestrator plus a fail-closed semantic Firefox source port.

## Files

- `.github/workflows/firefox-sandbox.yml` — replacement workflow
- `port/port.toml` — single version/validation contract
- `port/prepare_recipe.py` — Termux recipe-only edits
- `port/firefox_sandbox_port.py` — idempotent source transformer/verifier
- `port/ci.sh` — Docker/sccache/build orchestration
- `port/runtime-test.sh` — level-6 device test with per-process A/B switches
- `port/media-capabilities.html` — H264/VP9/AV1/AAC/Opus regression probe
- `port/DESIGN.md` — maintenance/security model
- `port/REGRESSION.md` — release gate

## Validation already performed locally

- Python `py_compile`: PASS
- Bash `bash -n` for CI/runtime helpers: PASS
- YAML parse: PASS
- `prepare_recipe.py` repeated execution: idempotent
- semantic transformer synthetic apply: PASS
- semantic transformer second apply: all `ALREADY_PRESENT`, no source changes
- semantic verifier: PASS
- generated patch: read-only Termux runtime paths and exact Utility fstatfs rule

A full Firefox/Termux package build has **not** been run from this environment.
The next gate is one GitHub Actions build, followed by the device regression in
`port/REGRESSION.md`.

## Applying to the repository

Copy this tree over the repository root, then review and commit:

```bash
cp -a .github/workflows/firefox-sandbox.yml /path/to/repo/.github/workflows/
cp -a port /path/to/repo/
cd /path/to/repo
git diff --check
git status --short
git add .github/workflows/firefox-sandbox.yml port/
git commit -m 'Refactor Firefox sandbox port for v2.4.4'
```


## r2 CI bootstrap fixes

- Invoke `port/ci.sh` through `bash` so Git/Web upload executable-bit loss cannot break CI.
- Add `prepare-zram-workspace`, a narrow workspace bridge for the upstream Termux zram composite action. The action assumes `termux-packages` is checked out at `${{ github.workspace }}`; our two-checkout layout intentionally does not. Only the signing-key/action metadata paths it needs are mirrored.
- Collected runtime/CI shell helpers are installed with mode `0755`.
