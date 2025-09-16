#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# =================================================================
# Install & configure Traefik (with Basic Auth) + Portainer (Docker)
# Fully automated: install Docker, docker compose plugin, create compose,
# create htpasswd, open local firewall, start stack, wait and test.
# =================================================================

# --- Helpers (mensagens coloridas) ---
info(){ printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
ok(){ printf "\033[1;32m[OK]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[ERR]\033[0m %s\n" "$*"; }
die(){ err "$*"; exit 1; }

# ensure running as root
if [ "$EUID" -ne 0 ]; then
  die "Execute esse script como root: sudo ./install-full-traefik-portainer.sh"
fi

# --- 0. Ask user for values ---
echo "=== Instalação automática Traefik + Portainer (Ubuntu/Debian) ==="
read -r -p "Domínio para Portainer (ex: portainer.seudominio.com): " PORTAINER_DOMAIN
read -r -p "Domínio para Traefik Dashboard (ex: traefik.seudominio.com): " TRAEFIK_DOMAIN
read -r -p "E-mail para Let's Encrypt (ex: admin@seudominio.com): " LE_EMAIL
read -r -p "Usuário para Traefik Dashboard (HTTP Basic Auth) [default: admin]: " TR_USER
TR_USER=${TR_USER:-admin}
read -r -s -p "Senha para ${TR_USER}: " TR_PASS
echo
read -r -p "Diretório de instalação [default: /opt/traefik-portainer]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-/opt/traefik-portainer}

info "Resumo:"
echo "  Portainer domain : ${PORTAINER_DOMAIN}"
echo "  Traefik domain   : ${TRAEFIK_DOMAIN}"
echo "  Let's Encrypt E-mail: ${LE_EMAIL}"
echo "  Traefik user     : ${TR_USER}"
echo "  Install dir      : ${INSTALL_DIR}"
echo
read -r -p "Continuar? (y/N): " CONF
CONF=${CONF:-N}
if [[ ! "$CONF" =~ ^[Yy]$ ]]; then
  die "Operação cancelada pelo usuário."
fi

# --- 1. Install Docker Engine + Compose plugin (recommended) ---
info "Instalando Docker (repositório oficial) e plugin docker compose (se necessário)..."
apt-get update -y

# remove old packages safely (ignore errors)
apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

apt-get install -y ca-certificates curl gnupg

# Detect distro for Docker repo
DISTRO_ID=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
info "Distro detectada: ${DISTRO_ID} (repo: /linux/${DISTRO_ID})"

# add docker official key & repo
mkdir -p /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO_ID} \
 $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y

# try install official packages
if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
  ok "Docker engine + docker compose plugin instalados via apt."
else
  err "Não foi possível instalar o docker compose plugin via apt. Tentando fallback (download do plugin)..."
  # install engine, then fallback to download compose plugin binary
  apt-get install -y docker-ce docker-ce-cli containerd.io || die "Falha ao instalar docker engine."
  mkdir -p /usr/lib/docker/cli-plugins
  curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" -o /usr/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/lib/docker/cli-plugins/docker-compose
  ok "Fallback: docker compose plugin instalado em /usr/lib/docker/cli-plugins/docker-compose"
fi

systemctl enable --now docker

# check docker compose availability
if ! docker compose version >/dev/null 2>&1; then
  die "Comando 'docker compose' não está disponível após instalação. Verifique manualmente."
fi
ok "Docker e docker compose prontos."

# --- 2. Prepare install dir and files ---
info "Criando diretórios em ${INSTALL_DIR} ..."
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}" || die "Não foi possível mudar para ${INSTALL_DIR}"

# create letsencrypt folder
mkdir -p "${INSTALL_DIR}/letsencrypt"
touch "${INSTALL_DIR}/letsencrypt/acme.json"
chmod 600 "${INSTALL_DIR}/letsencrypt/acme.json"

# --- 3. Generate htpasswd (bcrypt) using docker httpd image to avoid package dependency) ---
info "Gerando htpasswd (bcrypt) para Traefik user..."
# Using httpd image to generate bcrypt hash; result is "user:hash"
HTLINE=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "${TR_USER}" "${TR_PASS}" | tr -d '\r\n') || die "Falha ao gerar htpasswd com httpd image."
echo "${HTLINE}" > "${INSTALL_DIR}/traefik_usersfile"
chmod 400 "${INSTALL_DIR}/traefik_usersfile"
ok "Arquivo traefik_usersfile criado em ${INSTALL_DIR}/traefik_usersfile"

# --- 4. Create docker-compose.yml (robust, explicit) ---
info "Escrevendo docker-compose.yml ..."
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
version: "3.9"

services:
  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: always
    command:
      - --api.dashboard=true
      - --api.insecure=false
      - --providers.docker=true
      - --providers.docker.network=traefik
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entryPoint.to=websecure
      - --entrypoints.web.http.redirections.entryPoint.scheme=https
      - --certificatesresolvers.myresolver.acme.tlschallenge=true
      - --certificatesresolvers.myresolver.acme.email=${LE_EMAIL}
      - --certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt
      - ./traefik_usersfile:/traefik_usersfile:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(\`${TRAEFIK_DOMAIN}\`)"
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=myresolver"
      - "traefik.http.routers.traefik.service=api@internal"
      - "traefik.http.middlewares.traefik-auth.basicauth.usersfile=/traefik_usersfile"
      - "traefik.http.routers.traefik.middlewares=traefik-auth"
    networks:
      - traefik

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./portainer_data:/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_DOMAIN}\`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=myresolver"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"
    networks:
      - traefik

volumes:
  portainer_data:

networks:
  traefik:
    driver: bridge
EOF

ok "docker-compose.yml criado em ${INSTALL_DIR}/docker-compose.yml"

# --- 5. Open local firewall (ufw) for 80/443 (if ufw exists) ---
if command -v ufw >/dev/null 2>&1; then
  info "Configurando UFW (abrindo 80 e 443)..."
  if ufw status | grep -qi inactive; then
    info "UFW está inativo. Vou apenas adicionar regras (não habilitar)."
  fi
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw reload || true
  ok "Regras UFW atualizadas (80/443)."
else
  info "UFW não encontrado — pulei configuração de firewall local. Certifique-se de que portas 80/443 estão liberadas no provedor (Oracle)."
fi

# --- 6. Remove possible conflicting containers & start stack ---
info "Removendo containers antigos (se existirem) e subindo stack..."
docker rm -f traefik portainer 2>/dev/null || true

cd "${INSTALL_DIR}" || die "Não foi possível mudar para ${INSTALL_DIR}"
docker compose up -d --remove-orphans || die "Falha ao iniciar stack com docker compose. Verifique logs: docker compose logs"

# Verifica se containers estão rodando
if docker compose ps | grep -q "Up"; then
  ok "Containers traefik e portainer estão UP."
else
  err "Containers não estão rodando. Exibindo status:"
  docker compose ps
  exit 1
fi

# --- 7. Wait helper and log checks ---
ok "Serviços iniciados. Aguardando Traefik detectar rota e emitir certificado (pode levar até 4 minutos)..."

# Get public IP for user reference
PUBLIC_IP=$(curl -4 -s ifconfig.co || curl -4 -s ifconfig.me || echo "Não detectado")
info "Seu IP público é: ${PUBLIC_IP} - Certifique-se que seus domínios apontam para este IP"

wait_for() {
  local service_name="$1"
  local pattern="$2"
  local timeout=${3:-240}
  local start
  start=$(date +%s)
  while true; do
    if docker compose logs --tail=200 traefik 2>/dev/null | grep -qi -- "$pattern"; then
      return 0
    fi
    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      return 1
    fi
    sleep 5
  done
}

# wait for route to be added for portainer
if wait_for "traefik" "Adding route.*portainer" 120; then
  ok "Traefik adicionou rota para portainer."
else
  err "Traefik não adicionou rota para portainer em 120s. Exibindo logs (últimas linhas):"
  docker compose logs --tail=200 traefik || true
fi

# wait for ACME success (or timeout)
info "Aguardando resultado ACME (Let's Encrypt) (até 240s)..."
if wait_for "traefik" "ACME:.*obtained certificate" 240 || wait_for "traefik" "Certificate obtained" 240; then
  ok "Certificado ACME obtido (Let's Encrypt)."
else
  err "Não encontrei confirmação de certificado ACME nos logs do Traefik (pode demorar mais ou ter bloqueio)."
  # Check for ACME errors
  if docker compose logs --tail=200 traefik | grep -i "acme.*error"; then
      err "Foram encontrados erros de ACME. Verifique acima."
  fi
  docker compose logs --tail=200 traefik || true
fi

# --- 8. Quick connectivity tests ---
info "Testes rápidos:"

info "Verificando DNS local do servidor:"
dig_out_portainer=$(dig +short "$PORTAINER_DOMAIN" || true)
dig_out_traefik=$(dig +short "$TRAEFIK_DOMAIN" || true)
echo "  DNS $PORTAINER_DOMAIN -> ${dig_out_portainer:-(nenhum retorno)}"
echo "  DNS $TRAEFIK_DOMAIN -> ${dig_out_traefik:-(nenhum retorno)}"

info "Fazendo curl de teste (http e https) -- saídas abaixo:"
echo ">>> http://$PORTAINER_DOMAIN (espera 301/redirect ou 200)"
curl -I --max-time 10 "http://$PORTAINER_DOMAIN" || true
echo ">>> https://$PORTAINER_DOMAIN (pode falhar se ACME ainda não pronto)"
curl -I --max-time 10 -k "https://$PORTAINER_DOMAIN" || true

# final status
echo
docker compose ps
echo
docker compose logs --tail=100 traefik | sed -n '1,200p'

ok "Script finalizado. Se ainda aparecer 'Not Found' no navegador, verifique os pontos descritos abaixo."
info "Nota: Para upgrade futuro para Traefik v3, consulte https://doc.traefik.io/traefik/migration/v2-to-v3/ (mudanças em labels/config)."

cat <<'MSG'

Possíveis causas e correções:
  * DNS não propagou para o IP público da VPS (verifique no seu provedor DNS).
  * Regras de firewall da Oracle Cloud (VCN / Security Lists) não estão liberando 80/443 -> abra 0.0.0.0/0.
  * Se Traefik não conseguiu emitir ACME, veja logs do Traefik:
      docker compose logs -f traefik
  * Verifique se está acessando exatamente o Host configurado (Host header). Ex.: 'portainer.darkhub.space' deve ser igual ao label Host() no docker-compose.

Comandos úteis:
  cd "${INSTALL_DIR}"
  docker compose ps
  docker compose logs -f traefik
  docker compose logs -f portainer

MSG

exit 0