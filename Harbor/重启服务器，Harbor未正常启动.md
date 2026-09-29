# 手动docker compose restart -d
# 使用 systemd 托管harbor,配置开机自启动  -f  指定compose.yaml文件
[root@nfs-harbor01 bin]# vim /etc/systemd/system/harbor.service
[Unit]
Description=Harbor
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-compose -f /usr/local/harbor/docker-compose.yml up -d
ExecStop=/usr/local/bin/docker-compose -f /usr/local/harbor/docker-compose.yml down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
