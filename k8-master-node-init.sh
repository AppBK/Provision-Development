#!/bin/sh

# K8 Master Node Setup Script
HOSTNAME=$(hostname)
HOSTONLY_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_NET_IP_ADDRESS=$(ip addr show eth1 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
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

# Output IP so that worker nodes can join
echo ${POD_NET_IP_ADDRESS} >| /mnt/shared/master-ip

# Initialize the master node
kubeadm init --control-plane-endpoint $POD_NET_IP_ADDRESS:6443 --pod-network-cidr=$POD_CIDR --token $CLUSTER_TOKEN --token-ttl 0 > /mnt/shared/master-output 2>&1 &

kubeadm_pid=$!
echo "KUBEADM PID: ${kubeadm_pid}"

wait $kubeadm_pid

openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | awk '{print "sha256:" $1}' >| /mnt/shared/kube-ca-hash.txt

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

# Add the token to the environment (find it odd that we re-declare in the systemd script... do we actually need this?)
cat <<EOF > /etc/profile.d/kube_env.sh
export CLUSTER_TOKEN=5998f2.95926d993a5f99cc
EOF

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

HOSTONLY_IP_ADDRESS=$(ip addr show eth0 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_NET_IP_ADDRESS=$(ip addr show eth1 | grep -oE 'inet ([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '{print $2}')
POD_CIDR="${POD_NET_IP_ADDRESS%.*}.0/24"

sudo kubeadm init --control-plane-endpoint $HOSTONLY_IP_ADDRESS:6443 --pod-network-cidr=$POD_CIDR --token $CLUSTER_TOKEN --token-ttl 0 &

kubeadm_pid=$!

wait $kubeadm_pid

kubectl apply -f /calico.yaml --

sudo openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -pubkey | openssl rsa -pubin -outform DER 2>/dev/null | sha256sum | awk '{print "sha256:" $1}' >| /mnt/shared/kube-ca-hash.txt
sudo touch /mnt/shared/master-node-config-complete
EOF

# Register startup script with systemd
sudo cat <<EOF > /etc/systemd/system/startup_script.service
[Unit]
Description=Startup Script
Before=master-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/startup_script.sh
Environment=CLUSTER_TOKEN=5998f2.95926d993a5f99cc

[Install]
WantedBy=multi-user.target
EOF

systemctl enable startup_script.service # ln -s /../ /../

# Write to a file in the shared folder to indicate that the master node is finished being configured.
touch /mnt/shared/master-node-init-complete