#!/bin/sh

# K8 Master Node Setup Script
HOSTNAME=$(hostname)
HOSTONLY_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_NET_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_CIDR="${POD_NET_IP_ADDRESS%.*}.0/24"
CLUSTER_TOKEN=5998f2.95926d993a5f99cc


apt-get update
apt-get install -y docker.io
curl -s https://packages.cloud.google.com/apkueadmikubeadmiiiot/doc/apt-key.gpg | apt-key add -
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable docker.service # ln -s /../ /../

# Add the hosts entry (All hosts)
cp /etc/hosts /etc/hosts.backup
sed -i "/$HOSTNAME/d" /etc/hosts
echo "$POD_NET_IP_ADDRESS $HOSTNAME" >> /etc/hosts

# Disable SWAP (All hosts)
swapoff -a # Turn it off
cp /etc/fstab /etc/fstab.backup
sed -i '/^\/swap/d' /etc/fstab # Keep it off!

# Setup the shared folder for passing the join command credentials
mkdir /mnt/shared
mount -t vboxsf share /mnt/shared
chmod 777 /mnt/shared
# Add the shared folder to fstab
sed -i '$ a share    /mnt/shared    vboxsf    defaults    0    0' /etc/fstab

MASTER_NODE_IP=$(cat /mnt/shared/master-ip)
CA_HASH=$(cat /mnt/shared/kube-ca-hash.txt)
# Add the token to the environment (find it odd that we re-declare in the systemd script... do we actually need this?)
cat <<EOF > /etc/profile.d/kube_env.sh
export CLUSTER_TOKEN=5998f2.95926d993a5f99cc
EOF

# Join the cluster!
kubeadm join $MASTER_NODE_IP:6443 --token $CLUSTER_TOKEN --discovery-token-ca-cert-hash $CA_HASH

# Create the startup script.
cd /usr/local/bin

cat <<EOF > startup_script.sh
#!/bin/bash

# Remove after the initial boot
if [ -e "/etc/systemd/system/worker-init.service" ]; then
  systemctl disable worker-init.service
  /bin/rm /etc/systemd/system/multi-user.target.wants/worker-init.service
  /bin/rm /etc/systemd/system/worker-init.service
  /bin/rm /worker-init.sh
fi

HOSTONLY_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_NET_IP_ADDRESS=$(ip addr show eth1 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_CIDR="${POD_NET_IP_ADDRESS%.*}.0/24"

MASTER_NODE_IP=$(cat /mnt/shared/master-ip)
CA_HASH=$(cat /mnt/shared/kube-ca-hash.txt)

kubeadm join $MASTER_NODE_IP:6443 --token $CLUSTER_TOKEN --discovery-token-ca-cert-hash $CA_HASH
EOF

# Register startup script with systemd
cat <<EOF > /etc/systemd/system/startup_script.service
[Unit]
Description=Startup Script
Before=worker-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/startup_script.sh
Environment=CLUSTER_TOKEN=5998f2.95926d993a5f99cc

[Install]
WantedBy=multi-user.target
EOF

systemctl enable startup_script.service # ln -s /../ /../