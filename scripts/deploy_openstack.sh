#!/bin/bash
set -euo pipefail

# =============== UTIL ===============
log() { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

# =============== CONFIGURACIÓN AUTOMÁTICA VMWARE ===============
log "Detectando configuración de red..."

# Detectar la interfaz que sale a internet (normalmente ens33) y su IP
MGMT_IF=$(ip route get 8.8.8.8 | awk -- '{print $5}')
CURRENT_IP=$(ip -4 addr show "$MGMT_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

# Asumimos que la otra interfaz es la siguiente (ens34)
PROV_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo\|$MGMT_IF" | head -n 1)

log "Interfaz de Gestión detectada: $MGMT_IF ($CURRENT_IP)"
log "Interfaz de Proveedor (Interna) detectada: $PROV_IF"

HOSTNAME_FQDN="opkhost.localdomain"
MGMT_IP="${CURRENT_IP}/24"
# Usamos el gateway actual
MGMT_GW=$(ip route | grep default | awk '{print $3}')
MGMT_DNS="8.8.8.8"

# Red interna para tráfico de VMs (Rango seguro)
PROV_IP="192.168.100.20/24"
FIP_CIDR="192.168.100.0/24"

# =============== CONFIGURACIÓN HOST ===============
sudo hostnamectl set-hostname "$HOSTNAME_FQDN"
if ! grep -q "$CURRENT_IP" /etc/hosts; then
  echo "$CURRENT_IP  $HOSTNAME_FQDN opkhost" | sudo tee -a /etc/hosts >/dev/null
fi

# NetworkManager
if ! command -v nmcli >/dev/null 2>&1; then
  sudo dnf -y install NetworkManager || true
fi

# Configurar Interfaz Gestión (ens33) - Manteniendo IP actual estática
if nmcli -t -f NAME con show | grep -q "^$MGMT_IF$"; then
  sudo nmcli con mod "$MGMT_IF" ipv4.addresses "$MGMT_IP" ipv4.gateway "$MGMT_GW" ipv4.dns "$MGMT_DNS" ipv4.method manual
else
  sudo nmcli con add type ethernet ifname "$MGMT_IF" con-name "$MGMT_IF" ipv4.addresses "$MGMT_IP" ipv4.gateway "$MGMT_GW" ipv4.dns "$MGMT_DNS" ipv4.method manual
fi
sudo nmcli con up "$MGMT_IF" || true

# Configurar Interfaz Proveedor (ens34) - Sin Gateway, solo IP interna
if [ -n "$PROV_IF" ]; then
    if nmcli -t -f NAME con show | grep -q "^$PROV_IF$"; then
      sudo nmcli con mod "$PROV_IF" ipv4.addresses "$PROV_IP" ipv4.method manual
    else
      sudo nmcli con add type ethernet ifname "$PROV_IF" con-name "$PROV_IF" ipv4.addresses "$PROV_IP" ipv4.method manual
    fi
    sudo nmcli con up "$PROV_IF" || true
else
    log "ADVERTENCIA: No se detectó segunda tarjeta de red. OpenStack funcionará, pero las redes provider pueden fallar."
fi

# NAT y Forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-forward.conf >/dev/null

# Reglas iptables básicas para salida a internet de las VMs
sudo dnf install -y iptables-services
sudo iptables -t nat -C POSTROUTING -s "$FIP_CIDR" -o "$MGMT_IF" -j MASQUERADE 2>/dev/null || \
sudo iptables -t nat -A POSTROUTING -s "$FIP_CIDR" -o "$MGMT_IF" -j MASQUERADE
sudo service iptables save

# =============== BASE DEL SISTEMA ===============
log "Actualizando sistema..."
sudo dnf -y update
sudo dnf install -y git python3-devel libffi-devel gcc openssl-devel python3-libselinux python3-setuptools net-tools \
                    lvm2 device-mapper-persistent-data targetcli iscsi-initiator-utils

# =============== DOCKER ===============
log "Instalando Docker..."
sudo dnf -y remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true

# =============== ENTORNOS VIRTUALES Y KOLLA ===============
log "Preparando entorno virtual Kolla..."
VENV_DIR="kolla-venv"
[ -d "$VENV_DIR" ] || python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"
pip install -U pip wheel

# Versiones compatibles con CentOS 9
ANSIBLE_CORE_VERSION_MIN=2.15
ANSIBLE_CORE_VERSION_MAX=2.16
KOLLA_BRANCH_NAME="stable/2024.1"

log "Instalando Ansible y Kolla..."
pip install "ansible-core>=$ANSIBLE_CORE_VERSION_MIN,<${ANSIBLE_CORE_VERSION_MAX}.99"
pip install "git+https://github.com/openstack/kolla-ansible@$KOLLA_BRANCH_NAME"

log "Configurando..."
sudo mkdir -p /etc/ansible /etc/kolla
sudo chown -R "$USER:$USER" /etc/kolla
sudo tee /etc/ansible/ansible.cfg >/dev/null <<EOF
[defaults]
host_key_checking=False
pipelining=True
forks=100
EOF

if [ -d "$HOME/$VENV_DIR/share/kolla-ansible/etc_examples/kolla" ]; then
  cp -r "$HOME/$VENV_DIR/share/kolla-ansible/etc_examples/kolla/"* /etc/kolla
  cp "$HOME/$VENV_DIR/share/kolla-ansible/ansible/inventory/"* . 
else
  fail "No se encontraron los archivos de ejemplo de Kolla."
fi

# =============== CONFIGURACIÓN KOLLA ===============
kolla-genpwd
sed -i 's#^keystone_admin_password:.*#keystone_admin_password: kolla#g' /etc/kolla/passwords.yml

log "Escribiendo globals.yml..."
sudo tee /etc/kolla/globals.yml >/dev/null <<EOF
---
workaround_ansible_issue_8743: yes
kolla_base_distro: "rocky"
openstack_release: "2024.1"
network_interface: "$MGMT_IF"
neutron_external_interface: "$PROV_IF"
kolla_internal_vip_address: "$CURRENT_IP"
enable_haproxy: "no"
nova_compute_virt_type: "qemu"
kolla_enable_tls_internal: "no"
kolla_enable_tls_external: "no"
kolla_certificates_dir: "/etc/kolla/certificates"
kolla_admin_openrc_cacert: "/etc/pki/tls/certs/ca-bundle.crt"
kolla_copy_ca_into_containers: "yes"
openstack_cacert: "/etc/pki/tls/certs/ca-bundle.crt"
kolla_enable_tls_backend: "no"
kolla_verify_tls_backend: "no"
neutron_plugin_agent: "openvswitch"
neutron_type_drivers: "flat,vlan,vxlan"
neutron_tenant_network_types: "vxlan"
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder-volumes"
enable_iscsid: "yes"
cinder_default_volume_type: "lvm"
EOF

# =============== CINDER LVM ===============
log "Configurando disco Cinder (/dev/sdb)..."
DISK_CINDER="/dev/sdb"
if [ -b "$DISK_CINDER" ]; then
    sudo pvcreate -ff -y "$DISK_CINDER" || true
    sudo vgremove -ff -y cinder-volumes 2>/dev/null || true
    sudo vgcreate -ff -y cinder-volumes "$DISK_CINDER"
else
    log "ADVERTENCIA: No se encontró /dev/sdb. Cinder podría fallar."
fi

# =============== DESPLIEGUE ===============
log "Instalando dependencias de Kolla..."
kolla-ansible install-deps

log "Limpiando despliegues previos..."
# Prevenir error de certificados
sudo mkdir -p /etc/kolla/certificates/ca
sudo chown -R $USER:$USER /etc/kolla

log "Generando certificados..."
kolla-ansible certificates -i ./all-in-one

log "Bootstrapping..."
kolla-ansible bootstrap-servers -i ./all-in-one

log "Prechecks..."
kolla-ansible prechecks -i ./all-in-one

log "Deploying (Paciencia)..."
kolla-ansible deploy -i ./all-in-one

log "Post-deploy..."
kolla-ansible post-deploy -i ./all-in-one

pip install python-openstackclient python-neutronclient -c https://releases.openstack.org/constraints/upper/2024.1

echo
echo "================= INSTALACIÓN FINALIZADA ================="
echo " Horizon: http://$CURRENT_IP"
echo " Admin:   admin / kolla"
echo "=========================================================="
