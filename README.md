# Hy3 isolated endpoint deployment package

This repo contains scripts to:
- pull Hy3 GGUF weights from Hugging Face,
- configure an isolated local Ollama endpoint,
- generate/run a systemd user service,
- and tune Hy3 inference for a 3×A100 hybrid setup.

## Files

- `deploy_hy3.sh`
  - Existing script that starts an ephemeral Ollama serve and pulls `hf.co/satgeze/Hy3-1M-GGUF:<class>`.
- `run_hy3_entrypoint.sh`
  - Existing `llama-server` launcher for hybrid CPU+GPU execution.
- `scripts/pull_hy3_gguf.sh`
  - Automatic download script for `/srv/hy3/hy3-1M-*.gguf`.
- `scripts/generate_hy3_isolated_service.sh`
  - Generates a systemd user service file for an isolated Ollama endpoint.
- `scripts/deploy_hy3_isolated.sh`
  - End-to-end local deploy: ensure model, generate service, enable/start, readiness check.
- `configs/hy3-a100-hybrid.env`
  - Strong default tuning profile for 3×A100 with llama-server.
- `templates/ollama-isolated-service.tpl`
  - Template for the Ollama systemd unit.
- `scripts/publish_to_github.sh`
  - Convenience publish script.

## Quickstart: pull and run new isolated endpoint

1. Pull/update the model weights:

```bash
HY3_MODELS_DIR=/srv/hy3 ./scripts/pull_hy3_gguf.sh 0
```

2. Deploy and start an isolated endpoint on `127.0.0.1:11452`:

```bash
HY3_MODELS_DIR=/srv/hy3 \
HY3_CLASS=Q2_K \
HY3_SERVICE_NAME=hy3-isolated \
HY3_PORT=11452 \
/home/roko/Documents/Projects/Adjacent/hy3/scripts/deploy_hy3_isolated.sh
```

3. Verify:

```bash
curl -sS http://127.0.0.1:11452/api/tags | jq
```

4. Hit it from Omnius or apps (OpenAI-compatible path):

```bash
curl -sS http://127.0.0.1:11452/v1/models
```

## A100 + hybrid tuning (`configs/hy3-a100-hybrid.env`)

- Uses:
  - `GPU_DEVICES=CUDA0,CUDA1,CUDA2`
  - `TENSOR_SPLIT=1,1,1`
  - `N_GPU_LAYERS=81`

Load with:

```bash
source configs/hy3-a100-hybrid.env
```

Then use the environment variables directly in `run_hy3_entrypoint.sh`:

```bash
source configs/hy3-a100-hybrid.env
./run_hy3_entrypoint.sh start
```

## Service generator internals

`generate_hy3_isolated_service.sh` writes:

- `$XDG_CONFIG_HOME/systemd/user/<SERVICE>.service` (default `~/.config/systemd/user/`)
- `$XDG_CONFIG_HOME/hy3/<SERVICE>.env` (default `~/.config/hy3/`)

Then `deploy_hy3_isolated.sh` does `systemctl --user enable --now` and performs readiness check.

You can stop / restart with:

```bash
systemctl --user stop hy3-isolated.service
systemctl --user start hy3-isolated.service
systemctl --user status hy3-isolated.service
```

## Publish

Run once to push these files to GitHub:

```bash
./scripts/publish_to_github.sh my-hy3-repo private
```

If `GITHUB_OWNER` is set, it will use `OWNER/repo`; otherwise it uses your logged in GitHub user.

## Notes

- Existing model path used by this setup is `/srv/hy3/hy3-1M-Q2_K.gguf`.
- If your endpoint port conflicts, change `HY3_PORT` and rerun deploy.
- Keep model files outside version control.
