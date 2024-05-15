#!/bin/sh

# K8 Master Node Setup Script
HOSTNAME=$(hostname)
HOSTONLY_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_NET_IP_ADDRESS=$(ip addr show eth1 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_CIDR="${POD_NET_IP_ADDRESS%.*}.0/24"
CLUSTER_TOKEN=5998f2.95926d993a5f99cc


sudo apt-get update
sudo apt-get install -y docker.io
curl -s https://packages.cloud.google.com/apkueadmikubeadmiiiot/doc/apt-key.gpg | sudo apt-key add -
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable docker.service # ln -s /../ /../

# Add the hosts entry (All hosts)
sudo cp /etc/hosts /etc/hosts.backup
sudo sed -i "/$HOSTNAME/d" /etc/hosts
sudo echo "$HOSTONLY_IP_ADDRESS $HOSTNAME" >> /etc/hosts

# Disable SWAP (All hosts)
sudo swapoff -a # Turn it off
sudo cp /etc/fstab /etc/fstab.backup
sudo sed -i '/^\/swap/d' /etc/fstab # Keep it off!

# Setup the shared folder for passing the join command credentials
sudo mkdir /mnt/shared
sudo mount -t vboxsf share /mnt/shared
sudo chmod 777 /mnt/shared
# Add the shared folder to fstab
sudo sed -i '$ a share    /mnt/shared    vboxsf    defaults    0    0' /etc/fstab


# Initialize the master node
sudo kubeadm init --control-plane-endpoint $HOSTONLY_IP_ADDRESS:6443 --pod-network-cidr=$POD_CIDR --token $CLUSTER_TOKEN --token-ttl 0 &

kubeadm_pid=$!
echo "KUBEADM PID: ${kubeadm_pid}"

wait $kubeadm_pid

sha256sum /etc/kubernetes/pki/ca.crt | awk '{print $1}' >| /mnt/shared/kube-ca-hash.txt

# Set the kubectl context auth to connect to the cluster(Only on Master node)
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config # kubectl will find the apiserver ip address in this file
cat /etc/kubernetes/admin.conf >| /mnt/shared/kubeconfig


# Configure the Pod Network Plugin (Calico)
curl https://raw.githubusercontent.com/projectcalico/calico/v3.27.3/manifests/calico.yaml -O

# Add our custom CIDR Pod Network to the Calico manifest
sed -i "/^[[:space:]]*# - name: CALICO_IPV4POOL_CIDR/ {
    a\
            - name: CALICO_IPV4POOL_CIDR
    a\
              value: \"${POD_CIDR}\"
}" calico.yaml

# Add the token to the environment (find it odd that we re-declare in the systemd script... do we actually need this?)
sudo cat <<EOF > /etc/profile.d/kube_env.sh
export CLUSTER_TOKEN=5998f2.95926d993a5f99cc
EOF

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

HOSTONLY_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_NET_IP_ADDRESS=$(ip addr show eth1 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_CIDR="${POD_NET_IP_ADDRESS%.*}.0/24"

sudo kubeadm init --control-plane-endpoint $HOSTONLY_IP_ADDRESS:6443 --pod-network-cidr=$POD_CIDR --token $CLUSTER_TOKEN --token-ttl 0 &

kubeadm_pid=$!

wait $kubeadm_pid

kubectl apply -f /calico.yaml --

sha256sum /etc/kubernetes/pki/ca.crt | awk '{print $1}' >| /mnt/shared/kube-ca-hash.txt
sudo touch /mnt/shared/master-node-config-complete
EOF

# Register startup script with systemd
sudo cat <<EOF > /etc/systemd/system/startup_script.service
[Unit]
Description=Startup Script

[Service]
Type=oneshot
ExecStart=/usr/local/bin/startup_script.sh
Environment=CLUSTER_TOKEN=5998f2.95926d993a5f99cc

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable startup_script.service # ln -s /../ /../

# Write to a file in the shared folder to indicate that the master node is finished being configured.
touch /mnt/shared/master-node-init-complete