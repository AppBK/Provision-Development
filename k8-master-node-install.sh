#!/bin/bash

# Download the init script and install on target system
wget -O /target/master-init.sh https://raw.githubusercontent.com/AppBK/Provision-Development/main/k8-master-node-init.sh

chmod 755 /target/master-init.sh

cat <<EOF > /target/etc/systemd/system/master-init.service
[Unit]
Description=Will install all necessary Kubernetes packages on initial boot

[Service]
Type=oneshot
ExecStart=/master-init.sh
Environment=CLUSTER_TOKEN=5998f2.95926d993a5f99cc

[Install]
WantedBy=multi-user.target
EOF

# Move into the installation system and enable the service
cd /target
chroot .
systemctl enable master-init.service
exit

# Back to installation environment
cd -
