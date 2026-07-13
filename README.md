# Hy3 isolated llama.cpp deployment for three A100s

This repository installs and serves the Hy3 GGUF distillations from
`satgeze/Hy3-1M-GGUF` through the custom `satindergrewal/llama.cpp`
`hy3-mtp` branch. The production endpoint is an isolated, OpenAI-compatible
`llama-server` service. It is not the ordinary Ollama service and does not
replace Ollama's default endpoint.

## Quick start: just do this

Run this as the target service user from a login session, not as root:

```bash
git clone https://github.com/robit-man/hy3-ollama-isolated-a100.git
cd hy3-ollama-isolated-a100

./scripts/install_hy3.sh \
  --class auto \
  --tier auto \
  --qualification auto \
  --install-nccl \
  --enable-linger
```

The installer detects the host, installs missing build dependencies, resolves
the best qualified Hy3 artifact, builds the custom CUDA server, generates the
user systemd unit, pulls missing weights, restarts only the Hy3 service, and
runs an API/GPU smoke test.

Check the endpoint:

```bash
# This starts the model if it is unloaded, then returns its metadata.
curl -fsS http://127.0.0.1:11453/v1/models | jq '.data[0].meta | {n_ctx,n_ctx_train,ftype,size}'
systemctl --user status hy3-llama-live.service --no-pager
```

Expected endpoint: `http://127.0.0.1:11453`.

## Operator console

The installer also puts `hy3` in `~/.local/bin`, so it is available from any
terminal. Running it with no arguments opens an interactive console for the
live `hy3-llama-live.service` unit:

```bash
hy3
```

The console shows the unit, endpoint health, model, and GPU allocation, and
offers load, unload, restart, force-kill, log, and configuration actions. Each
action that changes the service asks for confirmation. The same operations are
available to scripts, with an explicit `--yes` acknowledgement:

```bash
hy3 status                 # read-only
hy3 unload --yes           # gracefully release the model's GPU and host memory
hy3 load --yes             # load the model now and wait for /health
hy3 restart --yes          # interrupt active requests and restart
hy3 kill --yes             # force-unload; the next inference reloads it
hy3 logs
```

By default the console controls `hy3-llama-live.service` at `:11453`. The
service is a lightweight loopback proxy: a normal non-health request loads
the model automatically, active requests drain, and the model is unloaded
with `SIGINT` after five idle minutes by default. `GET /health` reports 503
with `model_state: unloaded` while memory is released and never reloads it.
Set `HY3_IDLE_TIMEOUT_SEC` in the generated environment to change the idle
period. To
operate a separately generated Hy3 unit, set `HY3_SERVICE_NAME`; to point the
health check elsewhere use `HY3_ENDPOINT`.

For a fail-closed NCCL requirement, add `--require-nccl`. NCCL is not needed
for the default layer-split service, but it is required for future
tensor-parallel experiments. The installer uses `sudo` only for apt packages
and optional user lingering; it must retain the target user's systemd and
`XDG_RUNTIME_DIR` environment.

## Current observed deployment

The following is the verified state of the reference host as of 2026-07-11.
It is an operational snapshot, not a promise that a future automatic install
will choose the same artifact after hardware, process load, or the Hugging
Face catalog changes.

| Item | Observed value |
| --- | --- |
| Service | `hy3-llama-live.service`, on-demand proxy active |
| Endpoint | `127.0.0.1:11453` |
| Model | `/srv/hy3/hy3-1M-Q2_K.gguf` |
| Weight file | `111376119328` bytes |
| Runtime context | `262144` tokens |
| Training context | `1048576` tokens |
| Quantization | `Q2_K - Medium` |
| Parameters reported | `298786155776` |
| A100 devices | `0,1,2` |
| GPU placement | all model layers on CUDA, layer split `1,1,1` |
| KV cache | q8 for K and V |
| Service slots | `1` |
| Flash Attention | enabled |
| CPU MoE fallback | disabled |
| CUDA driver | `580.82.07` |
| CUDA toolkit | `12.0` |
| NCCL package | `2.18.5-1-2` |
| llama.cpp branch | `hy3-mtp` |
| llama.cpp checkout observed | `56142c5f8` |

When loaded, the model process holds approximately 52 GiB on each A100. The
on-demand proxy releases that memory after the configured idle period.
The host also contains a GeForce GT 1030 at CUDA index 3; it is intentionally
excluded. The service uses physical A100 ids detected by the probe rather than
assuming that every visible GPU is suitable.

The current topology is:

```text
GPU0 <-> GPU2: NV12
GPU0 <-> GPU1: NODE
GPU1 <-> GPU2: PHB
```

Layer split across all three A100s is the stable production profile for this
topology. Fragmented or alternating GPU utilization during single-token decode
is expected: layer groups take turns processing each token. The decisive
checks are model residency on all three A100s, no CPU weight fallback, no
unified-memory spill, and successful generation.

## Model and profile selection

The installer defaults to capability-aware selection:

```text
--class auto
--tier auto
--qualification auto
```

The resolver queries the live `satgeze/Hy3-1M-GGUF` catalog, with a built-in
fallback catalog if Hugging Face is temporarily unavailable. It considers the
available A100s, per-device VRAM, requested context, current service profile,
MTP support, and memory used by unrelated compute processes. The separate
`hy3-mtp-head-f16.gguf` file is not selected as a standalone model.

Available artifact classes currently include:

```text
IQ2_M
Q2_K
MTP-IQ2_M
MTP-IQ3_XXS
MTP-Q2_K
MTP-Q3_K_M
MTP-Q4_K_M
MTP-Q5_K_M
MTP-Q6_K
```

Tier ordering:

| Tier | Selection order |
| --- | --- |
| `speed` | `IQ2_M`, `Q2_K`, then small MTP candidates |
| `balanced` | fast non-MTP candidates, then `MTP-IQ2_M`, `MTP-Q2_K`, `MTP-IQ3_XXS` |
| `quality` | largest MTP candidate that qualifies, descending |
| `auto` | quality ordering on a fresh install; preserves an active qualified model unless upgraded |

Qualification modes:

| Mode | Behavior |
| --- | --- |
| `auto` | Requires a full-GPU candidate and fails rather than silently degrading |
| `full-gpu` | Uses `N_GPU_LAYERS=all`, `FIT=off`, and `CPU_MOE=0` |
| `hybrid` | Explicitly permits `N_GPU_LAYERS=auto` and `FIT=on`; still keeps `CPU_MOE=0` |

The memory check estimates q8 KV usage proportionally to the requested
context, adds a safety reserve, and subtracts memory used by other GPU
processes. This prevents a model from appearing to fit based only on total
VRAM while actually spilling to host memory at runtime.

Examples:

```bash
# Read-only plan. Does not build, download, or restart.
./scripts/install_hy3.sh --dry-run --no-build --no-pull

# Prefer the fastest artifact that qualifies.
./scripts/install_hy3.sh --class auto --tier speed

# Re-evaluate an active deployment for a higher-ranked artifact.
./scripts/install_hy3.sh --class auto --tier quality --upgrade

# Require one exact MTP artifact and full GPU residency.
./scripts/install_hy3.sh --class MTP-IQ2_M --qualification full-gpu --mtp on

# Explicitly permit host-memory layer placement for a larger artifact.
./scripts/install_hy3.sh --class auto --qualification hybrid

# Exclude MTP candidates.
./scripts/install_hy3.sh --class auto --mtp off
```

MTP candidates are accepted only when the selected `llama-server` advertises
`draft-mtp`. `--mtp on` makes missing support a hard error. MTP profiles use
`SPEC_TYPE=draft-mtp`; non-MTP profiles do not.

The resolver records its decision outside the repository:

```text
$XDG_STATE_HOME/hy3/profile.env
$XDG_STATE_HOME/hy3/profile.json
```

## Installation and deployment behavior

`scripts/install_hy3.sh` is the supported end-to-end entrypoint. It is a user
service installer, not a root installer. It performs these checks and actions:

1. Validates the user systemd session and required host commands.
2. Probes OS, NVIDIA driver, CUDA toolkit, A100 count, VRAM, topology, NCCL,
   linger state, model storage, and endpoint conflicts.
3. Installs missing Ubuntu build tools when apt and sudo are available.
4. Optionally installs `libnccl2` and `libnccl-dev`.
5. Resolves the model class, tier, MTP mode, context, and GPU qualification.
6. Checks model disk headroom before downloading.
7. Builds the custom branch with CUDA architecture 80, CUDA graphs, NCCL,
   and `GGML_CUDA_FA_ALL_QUANTS=ON`.
8. Generates a user systemd service using the detected A100 ids.
9. Restarts only the named proxy service, loads the model once for `/health`
   and the smoke test unless disabled, then leaves idle unloading enabled.
10. Writes a host-specific install manifest and profile decision.

The default minimum is three A100s:

```text
HY3_REQUIRE_A100_COUNT=3
```

Useful installer options:

```text
--class CLASS              Exact artifact class or auto
--tier auto|speed|balanced|quality
--qualification auto|full-gpu|hybrid
--upgrade                  Re-rank instead of preserving the active profile
--mtp auto|on|off
--context TOKENS           Startup context cap; default 262000
--models-dir PATH          Default /srv/hy3
--service NAME             Default hy3-llama-live
--port PORT                Default 11453
--llama-cpp-dir PATH       Default ../llama.cpp
--no-build                 Reuse existing llama-server
--no-pull                  Require the selected model to already exist
--no-restart               Generate files without touching the active process
--no-smoke                 Skip the post-deploy completion test
--update-source            Fetch the custom llama.cpp branch before building
```

The generated unit has a five-minute stop timeout so a long request can drain
during an intentional restart or idle unload. Do not restart the service
during an Omnius task unless waiting up to five minutes for that request is
acceptable. Use `--no-restart` to stage a profile safely and apply it later.

Host-specific state is stored outside git:

```text
$XDG_STATE_HOME/hy3/capabilities.env
$XDG_STATE_HOME/hy3/capabilities.json
$XDG_STATE_HOME/hy3/capabilities.md
$XDG_STATE_HOME/hy3/nvidia-topology.txt
$XDG_STATE_HOME/hy3/profile.env
$XDG_STATE_HOME/hy3/profile.json
$XDG_STATE_HOME/hy3/install.manifest
```

Generated user files are:

```text
$XDG_CONFIG_HOME/systemd/user/<service>.service
$XDG_CONFIG_HOME/hy3/<service>-llama.env
$XDG_CONFIG_HOME/hy3/<service>.log
```

On the reference host, `/srv/hy3` resolves to the model storage used by the
isolated Ollama installation. Keep model files, logs, downloaded blobs, and
`.omnius` state out of this repository.

## Context behavior

`CTX_SIZE` is a server startup cap. The current service is configured with
`262000`, and the API reports the normalized runtime value `262144`. The model
reports `1048576` training context, but the service does not reserve a 1M
token KV cache by default.

Changing the hard cap requires regenerating and restarting the service:

```bash
./scripts/install_hy3.sh --context 131072
```

A client may request a smaller effective context when its backend supports
per-request `num_ctx` or equivalent. Smaller contexts generally reduce KV
memory and improve responsiveness. Do not increase `--parallel` while
optimizing single-stream decode; the current service deliberately uses one
slot so a 262K context is not divided among multiple slots.

The endpoint's context metadata is available at (and automatically loads the
model if it is idle):

```bash
curl -fsS http://127.0.0.1:11453/v1/models | jq '.data[0].meta'
```

## Benchmarks and interpretation

The repository has an API smoke test, not a standardized sustained benchmark.
Generation speed depends on prompt length, context length, quantization,
MTP acceptance rate, competing GPU processes, and whether another request is
occupying the single server slot.

Observed results on the reference host:

| Condition | Result |
| --- | --- |
| Prior clean install smoke, Q2_K, one slot | approximately `27.5 tok/s` |
| Latest live smoke while an existing Omnius workload was active | `23` completion tokens in `156.720 s`, `0.15 tok/s` |

The `0.15 tok/s` result is a contention/queue measurement, not a clean Hy3
decode benchmark. The server was intentionally not restarted or interrupted,
and a second request had to share a one-slot service with the live workload.
Use the clean-smoke result only as an operational datapoint, not as a hardware
guarantee.

Run the smoke test only when the endpoint is available for a test request:

```bash
HY3_ENDPOINT_URL=http://127.0.0.1:11453 \
HY3_MODEL=/srv/hy3/hy3-1M-Q2_K.gguf \
HY3_EXPECTED_CTX=262000 \
./scripts/test_hy3_endpoint.sh
```

The test loads the model on demand, then checks health, model metadata, context reporting, an
OpenAI-compatible completion, token usage, timing, and GPU process residency.
It can take several minutes when another Omnius request is using the only
slot. A health-only check does not generate tokens or load an idle model:

```bash
curl -fsS http://127.0.0.1:11453/health
```

## Omnius and API usage

The Hy3 endpoint is OpenAI-compatible. Configure Omnius to use:

```text
backend URL: http://127.0.0.1:11453
model: /srv/hy3/hy3-1M-Q2_K.gguf
context: 262144 or lower
```

The exact Omnius backend adapter remains an Omnius-side setting. Existing
deployments use the vLLM-compatible adapter pointed at this URL; this repo
does not modify Omnius project state or create task folders.

Direct completion example:

```bash
curl -fsS http://127.0.0.1:11453/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "/srv/hy3/hy3-1M-Q2_K.gguf",
    "messages": [{"role": "user", "content": "Return 2 + 2 as JSON."}],
    "temperature": 0,
    "max_tokens": 32
  }' | jq
```

Thinking/reasoning is a request/template policy, not a global switch in the
systemd service. Configure it explicitly in the Omnius request or project
settings when required.

## Service operations and diagnostics

```bash
systemctl --user status hy3-llama-live.service --no-pager
systemctl --user is-active hy3-llama-live.service
journalctl --user -u hy3-llama-live.service -f
ss -ltnp | rg ':11453'
curl -fsS http://127.0.0.1:11453/health
curl -fsS http://127.0.0.1:11453/v1/models | jq
```

The first command returns `503` with an `unloaded` model state after the idle
timeout; the second is a model request and reloads it automatically. The
private llama-server backend listens on `HY3_BACKEND_PORT` (default `11454`)
and must remain loopback-only.

GPU and topology checks:

```bash
nvidia-smi --query-gpu=index,name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
nvidia-smi topo -m
```

If only one A100 is active, check the generated environment and service
journal before changing model parameters:

```bash
cat "$HOME/.config/hy3/hy3-llama-live-llama.env"
journalctl --user -u hy3-llama-live.service -b --no-pager \
  | rg -i 'cuda|gpu|layer|offload|cpu|fit|unified|flash|memory|error'
```

The expected production profile contains:

```text
CUDA_VISIBLE_DEVICES=0,1,2
--device CUDA0,CUDA1,CUDA2
--split-mode layer
--tensor-split 1,1,1
--n-gpu-layers all
--fit off
--cpu-moe off
--flash-attn on
--cache-type-k q8_0
--cache-type-v q8_0
--parallel 1
```

Do not enable `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` for a throughput target.
Unified memory can prevent an out-of-memory failure by spilling weights into
host RAM, but it recreates the CPU bottleneck this deployment is designed to
avoid. Do not use `CPU_MOE=1` for the full-GPU profile.

## Build details

The build helper uses the custom Hy3 branch and configures the server for the
reference A100 architecture:

```bash
./scripts/build_llama_cpp_hy3.sh

# Fetch the current custom branch before building.
UPDATE_SOURCE=1 ./scripts/build_llama_cpp_hy3.sh
```

Relevant build requirements:

```text
GGML_CUDA=ON
GGML_CUDA_NCCL=ON
GGML_CUDA_FA_ALL_QUANTS=ON
GGML_CUDA_GRAPHS=ON
CUDA architecture 80
Release build
targets: llama-server, llama-bench
```

The build helper verifies the CMake cache and reports whether NCCL was
actually found. Setting `GGML_CUDA_NCCL=ON` alone is not treated as proof
that NCCL is installed. Use `--require-nccl` in the installer to fail closed.

## Repository layout

```text
configs/hy3-a100-hybrid.env          Shared serving defaults
templates/llama-isolated-service.tpl Systemd unit template
run_hy3_entrypoint.sh                Foreground/manual service entrypoint
scripts/probe_hy3_host.sh            Capability and topology inventory
scripts/resolve_hy3_profile.sh       Model/tier/qualification resolver
scripts/install_hy3.sh                Supported end-to-end installer
scripts/build_llama_cpp_hy3.sh       CUDA/NCCL llama.cpp build
scripts/pull_hy3_gguf.sh              Hugging Face GGUF download helper
scripts/generate_hy3_llama_service.sh User systemd unit generator
scripts/test_hy3_endpoint.sh          API/context/GPU smoke test
scripts/deploy_hy3_llama_isolated.sh  Lower-level legacy deployment helper
deploy_hy3.sh                         Separate official Ollama helper
```

The recommended path is `scripts/install_hy3.sh`. Use the lower-level scripts
when debugging or intentionally composing a deployment outside the automatic
qualification flow.
