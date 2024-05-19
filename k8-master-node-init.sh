#!/bin/sh

# K8 Master Node Setup Script
HOSTNAME=$(hostname)
HOSTONLY_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
NAT_IP_ADDRESS=$(ip addr show eth1 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')

# Configure master node
POD_CIDR="10.13.0.0/16" # Note that the POD CIDR is an OVERLAY network that can be assigned arbitrarily!

# Install and setup CRI-O Container Runtime
apt-get update
apt-get install -y software-properties-common curl apt-transport-https ca-certificates

curl -fsSL https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/Release.key |
    gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://pkgs.k8s.io/addons:/cri-o:/prerelease:/main/deb/ /" |
    tee /etc/apt/sources.list.d/cri-o.list

apt-get update
apt-get install -y cri-o

systemctl daemon-reload
systemctl enable crio --now
systemctl start crio.service

# Install crictl utility for container maintenance
VERSION="v1.28.0"
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-$VERSION-linux-amd64.tar.gz
tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
rm -f crictl-$VERSION-linux-amd64.tar.gz


# Configure apt to pull from kubernetes repo
curl -s https://packages.cloud.google.com/apkueadmikubeadmiiiot/doc/apt-key.gpg | apt-key add -
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl


# Add default ip?...
apt-get install -y jq
local_ip="$(ip --json addr show eth1 | jq -r '.[0].addr_info[] | select(.family == "inet") | .local')"
cat > /etc/default/kubelet << EOF
KUBELET_EXTRA_ARGS=--node-ip=$local_ip
EOF


# Add the hosts entry (All hosts)
cp /etc/hosts /etc/hosts.backup
sed -i "/$HOSTNAME/d" /etc/hosts
echo "$NAT_IP_ADDRESS $HOSTNAME" >> /etc/hosts

# Configure iptables to see bridged traffic ########

# Install kernel modules
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# sysctl params required by setup, params persist across reboots
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sysctl --system


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


# Initialize the master node
kubeadm init --apiserver-advertise-address $NAT_IP_ADDRESS --pod-network-cidr=$POD_CIDR --token $CLUSTER_TOKEN --token-ttl 0 --ignore-preflight-errors Swap > /mnt/shared/master-output 2>&1 &

kubeadm_pid=$!

wait $kubeadm_pid

kubeadm token create --ttl 0 --print-join-command >| /mnt/shared/join

# Set the kubectl context auth to connect to the cluster(Only on Master node)
mkdir -p /home/vagrant/.kube
cp -i /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown 1000:1000 /home/vagrant/.kube/config # kubectl will find the apiserver ip address in this file
cat /etc/kubernetes/admin.conf >| /mnt/shared/kubeconfig


# Configure the Pod Network Plugin (Calico)
curl https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml -O

# Add our custom CIDR Pod Network to the Calico manifest
sed -i "/^[[:space:]]*# - name: CALICO_IPV4POOL_CIDR/ {
    a\\
            - name: CALICO_IPV4POOL_CIDR
    a\\
              value: \"${POD_CIDR}\"
}" calico.yaml

# Apply CNI
kubectl apply -f /calico.yaml --

# Create the startup script.
cd /usr/local/bin

sudo cat <<EOF > startup_script.sh
#!/bin/bash

# Remove after the initial boot
if [ -e "/etc/systemd/system/master-init.service" ]; then
  sudo systemctl disable master-init.service
  sudo /bin/rm /etc/systemd/system/multi-user.target.wants/master-init.service
  sudo /bin/rm /etc/systemd/system/master-init.service
  sudo /bin/rm /master-init.sh
fi

kubectl apply -f /calico.yaml --
EOF

chmod 750 startup_script.sh

# Register startup script with systemd
sudo cat <<EOF > /etc/systemd/system/startup_script.service
[Unit]
Description=Startup Script
Before=master-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/startup_script.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable startup_script.service # ln -s /../ /../


# Write to a file in the shared folder to indicate that the master node is finished being configured.
touch /mnt/shared/master-node-init-complete