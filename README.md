# Hy3 isolated endpoint deployment package

This repo contains scripts to:
- pull Hy3 GGUF weights from Hugging Face,
- configure isolated local endpoints,
- generate/run systemd user services,
- and tune Hy3 inference for a 3×A100 hybrid setup.

## Files

- `deploy_hy3.sh`
  - Existing script that starts a dedicated official Ollama `ollama serve` instance and pulls `hf.co/satgeze/Hy3-1M-GGUF:<class>`.
- `run_hy3_entrypoint.sh`
  - Existing direct `llama-server` launcher for hybrid CPU+GPU execution.
- `scripts/pull_hy3_gguf.sh`
  - Automatic Hy3 download script for `/srv/hy3/hy3-1M-*.gguf`.
- `scripts/generate_hy3_isolated_service.sh`
  - Generates a **user-level systemd** service for a dedicated **Ollama** endpoint.
- `scripts/deploy_hy3_isolated.sh`
  - Runs model pull + service generation + start + readiness check for the Ollama endpoint.
- `scripts/generate_hy3_llama_service.sh`
  - Generates a **user-level systemd** service for a dedicated **llama-server** endpoint.
- `scripts/deploy_hy3_llama_isolated.sh`
  - Runs model pull + service generation + start + readiness check for the llama-server endpoint.
- `configs/hy3-a100-hybrid.env`
  - Strong default tuning profile for 3×A100 with hybrid GPU/CPU execution.
- `templates/ollama-isolated-service.tpl`
  - Template for the Ollama systemd unit.
- `templates/llama-isolated-service.tpl`
  - Template for llama-server unit generation.
- `scripts/publish_to_github.sh`
  - Convenience publish script.

## Quickstart A: dedicated Ollama endpoint (fastest to consume)

```bash
HY3_MODELS_DIR=/srv/hy3 \
HY3_CLASS=Q2_K \
HY3_SERVICE_NAME=hy3-ollama-isolated \
HY3_PORT=11452 \
/home/roko/Documents/Projects/Adjacent/hy3/scripts/deploy_hy3_isolated.sh
```

Verify with:

```bash
curl -sS http://127.0.0.1:11452/api/tags | jq
```

## Quickstart B: dedicated llama-server endpoint (recommended for hy3-1M architecture support)

```bash
HY3_MODELS_DIR=/srv/hy3 \
HY3_CLASS=Q2_K \
CTX_SIZE=262000 \
SPLIT_MODE=layer \
N_GPU_LAYERS=81 \
PARALLEL=8 \
THREADS_BATCH=32 \
POLL_BATCH=1 \
CONT_BATCHING=1 \
CACHE_TYPE_K=q8_0 \
CACHE_TYPE_V=q8_0 \
HY3_SERVICE_NAME=hy3-llama-isolated \
HY3_PORT=11453 \
/home/roko/Documents/Projects/Adjacent/hy3/scripts/deploy_hy3_llama_isolated.sh
```

Verify with:

```bash
curl -sS http://127.0.0.1:11453/v1/models
curl -sS -X POST http://127.0.0.1:11453/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"/srv/hy3/hy3-1M-Q2_K.gguf","prompt":"say hello","max_tokens":12}'
```

## A100 + hybrid tuning (`configs/hy3-a100-hybrid.env`)

- `GPU_DEVICES=CUDA0,CUDA1,CUDA2`
- `SPLIT_MODE=layer`
- `TENSOR_SPLIT=0.34,0.33,0.33` (or 1,1,1 to test equal ratio)
- `MAIN_GPU=0`
- `N_GPU_LAYERS=81`
- `CTX_SIZE=262000`
- `PARALLEL=8` (raise to keep 3 GPUs busier during concurrent request flow)
- `THREADS_BATCH=32` (batch and prompt processing threads)
- `POLL_BATCH=1` (batching loop polling; keeps scheduling responsive)
- `CONT_BATCHING=1` (continuous batching for occupancy smoothing)
- `CACHE_TYPE_K=q8_0`
- `CACHE_TYPE_V=q8_0`

Why utilization looks spiky:
- Single low-turnover prompts cause bursty occupancy (prefill spikes, then short decode bursts).
- `stream=false` / tiny outputs can look like one GPU "stuttering" even with full tensor split.
- To force steadier occupancy, generate higher sustained traffic (multiple concurrent requests or higher `PARALLEL`), then tune with `CONT_BATCHING=1`.

Load and run the existing entrypoint:

```bash
source configs/hy3-a100-hybrid.env
./run_hy3_entrypoint.sh start
```

## Service generator internals

For Ollama service generation, files are written to:
- `$XDG_CONFIG_HOME/systemd/user/<service>.service`
- `$XDG_CONFIG_HOME/hy3/<service>.env`

For llama-server service generation, files are written to:
- `$XDG_CONFIG_HOME/systemd/user/<service>.service`
- `$XDG_CONFIG_HOME/hy3/<service>-llama.env`

Manage with:

```bash
systemctl --user stop hy3-ollama-isolated.service
systemctl --user start hy3-ollama-isolated.service
systemctl --user stop hy3-llama-isolated.service
systemctl --user start hy3-llama-isolated.service
```

## Publish

```bash
./scripts/publish_to_github.sh my-hy3-repo private
```

Notes:
- Keep model artifacts and downloaded blobs out of git.
- The existing symlink `/srv/hy3` points at `/srv/ollama/models` in this environment.
- If model architecture issues appear on an Ollama endpoint, use the llama-server path above.
