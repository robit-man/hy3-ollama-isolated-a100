[Unit]
Description=Hy3 isolated llama-server endpoint (%i)
StartLimitIntervalSec=60
StartLimitBurst=10
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=%h/.config/hy3/%i.env
WorkingDirectory=%h/Documents/Projects/Adjacent/hy3
ExecStart=%h/Documents/Projects/Adjacent/hy3/scripts/hy3_on_demand_proxy.py
Restart=always
RestartSec=5
TimeoutStopSec=300
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
