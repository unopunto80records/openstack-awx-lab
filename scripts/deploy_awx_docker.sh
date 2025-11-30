#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# SCRIPT DE DESPLIEGUE DE AWX 17.1.0 (VERSIÓN LIMPIA PARA CENTOS 9)
# ==============================================================================

# Protección: Asegurar que NO estamos dentro del venv de OpenStack
if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    echo "[ERROR] Estás dentro de un entorno virtual ($VIRTUAL_ENV)."
    echo "Ejecuta 'deactivate' antes de lanzar este script."
    exit 1
fi

AWX_VERSION="17.1.0"
AWX_GIT_TAG="c1ab815c80cac96508d9779d92bc1280d0347627"
AWX_BASE_DIR="/opt/awx"
AWX_SRC_DIR="/opt/awx-src"
AWX_PG_DIR="$AWX_BASE_DIR/pgdocker"
AWX_COMPOSE_DIR="$AWX_BASE_DIR/compose"
AWX_PROJECTS_DIR="$AWX_BASE_DIR/projects"
VENV_DIR="/opt/awx-venv"
PYTHON_BIN="/opt/awx-venv/bin/python"

info() { echo "[INFO] $*"; }
run_sudo() { if [ "$EUID" -ne 0 ]; then sudo "$@"; else "$@"; fi; }

# ===== 1. Dependencias del Sistema =====
info "Instalando dependencias base..."
# En CentOS 9 esto funciona directo sin CRB raros
run_sudo dnf install -y epel-release
run_sudo dnf install -y curl jq git gcc python3-pip openssl tar yum-utils python3-libsemanage python3-libselinux python3-devel libyaml-devel

# ===== 2. Seguridad Docker (NO TOCAR) =====
# Verificamos que Docker existe (puesto por OpenStack) pero NO lo reinstalamos
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker no está instalado. ¿Seguro que OpenStack se instaló bien?" >&2
  exit 1
else
  info "Docker detectado correctamente. Usaremos la instalación existente."
fi

# ===== 3. Wrapper Docker Compose =====
# AWX 17 usa comandos viejos, creamos un puente al plugin nuevo
info "Creando compatibilidad docker-compose..."
run_sudo bash -lc 'cat >/usr/bin/docker-compose << "EOF"
#!/usr/bin/env bash
exec docker compose "$@"
EOF
chmod +x /usr/bin/docker-compose'

# ===== 4. Entorno Virtual Aislado para AWX =====
info "Creando entorno virtual en $VENV_DIR..."
run_sudo rm -rf "$VENV_DIR"
run_sudo mkdir -p "$VENV_DIR"
run_sudo chown -R "$USER:$USER" "$VENV_DIR"

python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1090
source "$VENV_DIR/bin/activate"

info "Instalando librerías Python para AWX..."
pip install --upgrade pip >/dev/null

# Instalamos versiones compatibles con AWX 17 (Ansible 2.9)
pip install "urllib3<2" "requests<2.29" "docker==6.1.3" "docker-compose==1.29.2" >/dev/null

# Módulo SELinux para que Ansible pueda gestionar ficheros
if ! "$PYTHON_BIN" -c "import selinux" >/dev/null 2>&1; then
  pip install selinux >/dev/null
fi

info "Instalando Ansible 2.9 (Motor de AWX)..."
pip install "ansible==2.9.27" >/dev/null

# ===== 5. Despliegue AWX =====
info "Limpiando contenedores antiguos de AWX..."
for c in awx awx_task awx_web awx_postgres awx_redis awx_rabbitmq awx-postgres awx-redis; do
  run_sudo docker rm -f "$c" >/dev/null 2>&1 || true
done

info "Preparando directorios..."
run_sudo mkdir -p "$AWX_PG_DIR" "$AWX_COMPOSE_DIR" "$AWX_PROJECTS_DIR" "$AWX_SRC_DIR"
run_sudo chown -R "$USER:$USER" "$AWX_BASE_DIR" "$AWX_SRC_DIR"

if [ ! -d "$AWX_SRC_DIR/.git" ]; then
  info "Descargando código fuente de AWX..."
  git clone https://github.com/ansible/awx.git "$AWX_SRC_DIR"
  (cd "$AWX_SRC_DIR" && git checkout "$AWX_GIT_TAG")
else
  (cd "$AWX_SRC_DIR" && git fetch --all --prune && git reset --hard "$AWX_GIT_TAG")
fi

# Generar clave secreta
SECRET_FILE="$AWX_BASE_DIR/.secret_key"
[ ! -f "$SECRET_FILE" ] && run_sudo bash -lc "umask 077 && openssl rand -base64 48 > '$SECRET_FILE'" && run_sudo chown "$USER:$USER" "$SECRET_FILE"
SECRET_KEY="$(cat "$SECRET_FILE")"

# Crear Inventario
INSTALLER_DIR="$AWX_SRC_DIR/installer"
INVENTORY_FILE="$INSTALLER_DIR/inventory"

cat > "$INVENTORY_FILE" <<EOF
[all]
localhost ansible_connection=local ansible_python_interpreter="$PYTHON_BIN"

[all:vars]
dockerhub_base=ansible
awx_task_hostname=awx
awx_web_hostname=awxweb
postgres_data_dir="$AWX_PG_DIR"
docker_compose_dir="$AWX_COMPOSE_DIR"
project_data_dir="$AWX_PROJECTS_DIR"
# Puerto 8080 para no chocar con OpenStack (Puerto 80)
host_port=8080
host_port_ssl=443
pg_username=awx
pg_password=awxpass
pg_database=awx
pg_port=5432
admin_user=admin
admin_password=awxadmin
create_preload_data=True
secret_key=$SECRET_KEY
awx_official=true
EOF

# ===== 6. Ejecución =====
info "Ejecutando Playbook de instalación..."
cd "$INSTALLER_DIR"
set +e
# Ejecutamos el playbook pero NO iniciamos los contenedores aún
run_sudo "$VENV_DIR/bin/ansible-playbook" -i "$INVENTORY_FILE" -e compose_start_containers=false install.yml
if [ $? -ne 0 ]; then echo "[ERROR] El playbook falló."; exit 1; fi
set -e

info "Arrancando contenedores..."
if [ -f "$AWX_COMPOSE_DIR/docker-compose.yml" ]; then
  run_sudo bash -lc "cd '$AWX_COMPOSE_DIR' && docker compose -f docker-compose.yml up -d"
else
  echo "[ERROR] No se generó docker-compose.yml" >&2; exit 1
fi

info "Esperando a la Base de Datos..."
for i in {1..30}; do
  if run_sudo docker exec awx_postgres pg_isready -U awx -d awx >/dev/null 2>&1; then break; fi
  sleep 5
done

info "Migrando base de datos (Esto tarda un poco)..."
run_sudo docker exec awx_task bash -c "awx-manage migrate --noinput && awx-manage"

info "Esperando a que AWX responda en el puerto 8080..."
HOST_IP=$(hostname -I | awk '{print $1}')
for i in {1..90}; do
  if [ "$(curl -sk -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/api/v2/ping/)" = "200" ]; then
    echo ""
    echo "=========================================="
    echo "   ¡AWX INSTALADO CON ÉXITO! 🚀"
    echo "=========================================="
    echo " URL:         http://${HOST_IP}:8080"
    echo " Usuario:     admin"
    echo " Contraseña:  awxadmin"
    echo "=========================================="
    exit 0
  fi
  sleep 10
done

echo "[WARN] AWX está tardando mucho en arrancar. Revisa: sudo docker logs awx_web"
