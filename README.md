# Hy3 isolated llama.cpp and Ollama deployment

This repository deploys the Hy3 GGUF weights from satgeze/Hy3-1M-GGUF as a
dedicated local llama-server endpoint. The supported production path is the
custom satindergrewal/llama.cpp hy3-mtp branch; the ordinary Ollama endpoint
is retained as a separate convenience path and is not the performance target.

The live configuration is designed for three A100 80 GB cards:

- CUDA_VISIBLE_DEVICES=0,1,2
- --device CUDA0,CUDA1,CUDA2
- --split-mode layer
- --tensor-split 1,1,1
- --n-gpu-layers all
- --ctx-size 262000
- --parallel 1
- q8 KV cache and CUDA Flash Attention
- no --cpu-moe and --fit off, so an unsafe partial/CPU fallback fails at
  startup instead of silently producing a 0.3 tok/s server

Layer split is the stable mode for the current topology. A100s 0 and 2 are
NVLinked; A100 1 is PCIe-connected. Tensor or two-card experiments should be
run as explicit profiles rather than replacing the stable three-card service.

## Repository files

- configs/hy3-a100-hybrid.env: shared three-A100 serving profile.
- run_hy3_entrypoint.sh: manual launcher and systemd foreground entrypoint.
- scripts/build_llama_cpp_hy3.sh: clones or updates the Hy3 branch and builds
  with CUDA, NCCL, CUDA graphs, A100 architecture 80, and
  GGML_CUDA_FA_ALL_QUANTS=ON.
- scripts/pull_hy3_gguf.sh: downloads and records any supported Hy3 GGUF.
- scripts/generate_hy3_llama_service.sh: generates a user systemd unit and
  environment file.
- scripts/deploy_hy3_llama_isolated.sh: pulls if needed, regenerates,
  restarts, waits for readiness, and runs the HTTP smoke test.
- scripts/test_hy3_endpoint.sh: verifies health, model metadata, context
  reporting, generation, usage, timing, and GPU processes.
- deploy_hy3.sh: separate official Ollama pull/evaluation helper.

## Build the custom server

The existing checkout can be rebuilt without fetching source:

    ./scripts/build_llama_cpp_hy3.sh

To fetch the current branch first:

    UPDATE_SOURCE=1 ./scripts/build_llama_cpp_hy3.sh

The build script refuses to reconfigure a dirty llama.cpp checkout. It also
fails if the resulting CMake cache does not show both
GGML_CUDA_FA_ALL_QUANTS=ON and GGML_CUDA_NCCL=ON.

## Pull weights

The installed host currently has the non-MTP Q2_K artifact:

    HY3_MODELS_DIR=/srv/hy3 HY3_CLASS=Q2_K ./scripts/pull_hy3_gguf.sh 0

The MTP path is supported, but it must use an MTP GGUF and the corresponding
runtime flag. The practical MTP quant is approximately 100 GB:

    HY3_MODELS_DIR=/srv/hy3 \
    HY3_CLASS=MTP-IQ2_M \
    ./scripts/pull_hy3_gguf.sh 0

Do not set SPEC_TYPE=draft-mtp for the installed non-MTP
hy3-1M-Q2_K.gguf. For an MTP artifact, use for example:

    HY3_CLASS=MTP-IQ2_M \
    HY3_FILENAME=hy3-1M-MTP-IQ2_M.gguf \
    SPEC_TYPE=draft-mtp \
    SPEC_DRAFT_N_MAX=3 \
    SPEC_DRAFT_P_MIN=0.75 \
    ./scripts/deploy_hy3_llama_isolated.sh

## Deploy the live endpoint

The default endpoint is http://127.0.0.1:11453. The deploy script must
restart an already active unit after regeneration; this is intentional because
systemctl enable --now alone does not replace an already-running process.

    HY3_MODELS_DIR=/srv/hy3 \
    HY3_CLASS=Q2_K \
    HY3_SERVICE_NAME=hy3-llama-live \
    HY3_PORT=11453 \
    ./scripts/deploy_hy3_llama_isolated.sh

For a fast smoke test without deployment:

    HY3_ENDPOINT_URL=http://127.0.0.1:11453 \
    HY3_MODEL=/srv/hy3/hy3-1M-Q2_K.gguf \
    HY3_EXPECTED_CTX=262000 \
    ./scripts/test_hy3_endpoint.sh

The generated files are:

- $XDG_CONFIG_HOME/systemd/user/<service>.service
- $XDG_CONFIG_HOME/hy3/<service>-llama.env

Useful service commands:

    systemctl --user status hy3-llama-live.service --no-pager
    systemctl --user restart hy3-llama-live.service
    journalctl --user -u hy3-llama-live.service -f

## Context and throughput

CTX_SIZE is the server hard cap and is chosen at startup. The current profile
exposes 262,000 tokens to Omnius while allocating one server slot, which
avoids dividing that capacity into eight smaller slots. A client can request a
smaller effective context where its backend supports per-request num_ctx/n_ctx;
changing the hard cap requires service restart.

The 1M model label is a maximum capability, not a sensible always-on
allocation. q8 KV memory grows approximately linearly with context, so use
32K-128K for throughput benchmarks and reserve 262K for sessions that need it.
Do not raise PARALLEL until single-stream generation is healthy.

The server's /v1/models metadata should report meta.n_ctx or meta.n_ctx_train.
Omnius should normalize that value to its contextWindowTokens field and compute
context percentage from prompt plus completion tokens. The endpoint smoke test
fails if no context field is reported, preventing a deployment that would leave
the Omnius context viewer blind.

## Hybrid mode

The default is full CUDA residency because this Q2_K artifact fits across the
three A100s and CPU execution is the known performance cliff. CPU-side
tokenization, sampling, and server threads still operate normally. If a
larger quant genuinely requires CPU weight placement, opt into a fallback
profile explicitly:

    N_GPU_LAYERS=auto FIT=on CPU_MOE=0 ./scripts/deploy_hy3_llama_isolated.sh

Do not use CPU_MOE=1 for the performance target. It keeps all expert weights
in host memory and is expected to collapse generation speed.

## Omnius integration

The Omnius project should use:

    backendType=vllm
    backendUrl=http://127.0.0.1:11453
    model=/srv/hy3/hy3-1M-Q2_K.gguf

A live task can be run against a repository without changing the global
Omnius config:

    omnius run "Inspect the repository and report the smallest safe improvement." \
      --repo /path/to/repository \
      --backend vllm \
      --backend-url http://127.0.0.1:11453 \
      --model /srv/hy3/hy3-1M-Q2_K.gguf \
      --timeout-ms 900000 \
      --verbose

Keep thinking and the requested context policy explicit in the Omnius project
settings. Thinking is an Omnius request behavior; it is not enabled by the
llama-server process unless the prompt/template asks for reasoning.

## Diagnostics

Check that all three A100s are visible and that no unrelated service is
occupying the endpoint:

    nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu --format=csv
    nvidia-smi topo -m
    ss -ltnp | rg ':11453'
    curl -fsS http://127.0.0.1:11453/health
    curl -fsS http://127.0.0.1:11453/v1/models | jq

Fragmented utilization is expected with --split-mode layer and one
single-token decode stream: each layer group takes its turn. It is not proof
that only one GPU holds the model. The acceptance checks are all three devices
visible, model load without CPU fallback, no unified-memory spill, and a
successful completion with measured tokens per second.

Keep model files, logs, .omnius state, and downloaded blobs out of git.
