[Unit]
Description=Hy3 isolated llama-server endpoint (%i)
StartLimitIntervalSec=60
StartLimitBurst=10
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/hy3/%i.env
ExecStart=%h/.config/hy3/%i.bin --log-file %h/.config/hy3/%i.log --host %i.host --port %i.port --model %i.model --ctx-size %i.ctx --n-gpu-layers %i.gpul --split-mode %i.splitmode --tensor-split %i.tsplit --device %i.devices --threads %i.threads --batch-size %i.batch --ubatch-size %i.ubatch --parallel %i.parallel --threads-batch %i.threads_batch --poll-batch %i.poll_batch --cont-batching --fit %i.fit
Restart=always
RestartSec=2
LimitNOFILE=65535
EnvironmentFile=%h/.config/hy3/%i.env
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
