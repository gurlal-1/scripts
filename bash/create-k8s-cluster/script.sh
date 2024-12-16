#/bin/bash

# Check memory and CPU of the system
echo "Checking memory and cpu requirements...."

cores=$(nproc)
mem=$(free -g | awk '/^Mem/ {print $2}')
if [[ "$cores" -lt 2 ]] || [[ "$mem" -lt 2 ]]; then
echo "cpu or memory is below minimum requirements"
exit 1
fi

echo "disabling swap.."
sudo swapoff -a

echo "enable port forwarding..."
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/k8s.conf
sudo sysctl --system > /dev/null
if grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.d/k8s.conf; then
echo "IP forwarding is enabled"
else
echo "IP forwarding not enabled .. quitting"
exit 1
fi

echo "checking disto type..."
if grep -iq "debian" /etc/os-release; then
echo "debain distro, continuing with the script"
else
echo "no condition for non-debian system yet...quitting"
exit 1
fi

echo "Installing containerd..."
sudo apt update -y -qq && sudo apt upgrade -y -qq
sudo apt-get install containerd -qq

if ctr --version > /dev/null 2>&1; then
    echo "containerd was installed"
else
    echo "containerd didn't get installed.. quitting"
    exit 1
fi

echo "Installing CNI plugin..."
sudo mkdir -p /opt/cni/bin

arch=$(arch)
cni_version=$(wget -qO- "https://api.github.com/repos/containernetworking/plugins/releases/latest" | jq -r '.tag_name')
if [[ -z "$cni_version" ]]; then
    echo "Failed to fetch CNI version. Exiting."
    exit 1
fi

if [[ "$arch" == "x86_64" ]]; then
    echo "This is an x86_64 system (likely Intel or AMD)"
    wget https://github.com/containernetworking/plugins/releases/download/$cni_version/cni-plugins-linux-amd64-$cni_version.tgz -q
    sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-$cni_version.tgz > /dev/null

elif [[ "$arch" == "arm64" ]]; then
    echo "This is an ARM64 system"
    wget https://github.com/containernetworking/plugins/releases/download/$cni_version/cni-plugins-linux-arm-$cni_version.tgz
    sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-arm-$cni_version.tgz > /dev/null
else
    echo "Could not determine system architecture"
    exit
fi

if [[ -d /etc/containerd ]]; then
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
else
sudo mkdir /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
fi

# sudo containerd config default > sudo /etc/containerd/config.toml -- would not work cuz redirection(>) runs as regular user
# OR sudo sh -c 'containerd config default > /etc/containerd/config.toml'

config_file="/etc/containerd/config.toml"

echo "checking if cri in disabled plugins..."
if grep -A 10 disabled_plugins $config_file | grep "cri"  ; then
echo "cri in disabled plugins removing now"
grep -A 10 disabled_plugins $config_file | sed s/cri//g $config_file
else
echo "cri is enabled.."
fi

echo "configure the systemd cgroup driver"

sudo sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]/,/^\[/ s/SystemdCgroup = false/SystemdCgroup = true/' $config_file

if [ $? -eq 0 ]; then
    echo "Updated runc to use systemd drive!"
else
    echo "systemd matching pattern not found."
fi

sudo systemctl restart containerd

echo "adding kubernetes repos"

sudo apt-get update -qq
sudo apt-get install -y apt-transport-https ca-certificates curl gpg -qq
sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "installing kubeadm and kubelet"
sudo apt-get update -qq
sudo apt-get install -y kubelet kubeadm -qq
sudo apt-mark hold kubelet kubeadm

while true; do
read -rp "Is this a control plane? Install kubectl (yes/no): " answer
case "$answer" in [Yy]|[Yy][Ee][Ss])
echo "Installing kubectl now"
sudo apt-get install -y kubectl -qq
break
;;
[Nn]|[Nn][Oo])
echo "exiting script now... your worker is setup now... make sure to run kubeadm join to join to cluster"
break
;;
*)
echo "Invalid input, please enter yes(y) or no(n)"
;;
esac
done


echo "Initializing your cluster"
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 > /dev/null

echo "configuring control plane for a regular user"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "Installing network plugin"
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml > /dev/null
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/custom-resources.yaml > /dev/null
echo
echo
echo "******************************************"
echo "            join command                 "
echo "******************************************"
sudo kubeadm token create --print-join-command
