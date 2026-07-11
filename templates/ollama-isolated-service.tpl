[Unit]
Description=Hy3 isolated Ollama endpoint (%i)
StartLimitIntervalSec=60
StartLimitBurst=10
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/hy3/%i.env
ExecStart=%h/.local/bin/ollama-placeholder serve
Restart=always
RestartSec=2
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
