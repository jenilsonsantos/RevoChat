#!/usr/bin/env bash
#
# RevoChat (Chatwoot) - Instalação automatizada em Ubuntu VPS
# ------------------------------------------------------------
# O que este script faz:
#   1. Instala Docker + Docker Compose plugin, Nginx, Certbot e UFW
#   2. Clona (ou atualiza) o repositório RevoChat
#   3. Gera automaticamente todos os segredos (SECRET_KEY_BASE, senhas do
#      Postgres/Redis, chaves de criptografia) - nada fica com valor padrão
#   4. Builda a imagem Docker a partir do próprio código do repositório
#   5. Prepara o banco de dados (rails db:chatwoot_prepare)
#   6. Sobe os containers (rails, sidekiq, postgres, redis)
#   7. Configura o Nginx como proxy reverso para o seu domínio
#   8. Emite certificado SSL via Let's Encrypt (Certbot) e configura renovação automática
#   9. Habilita o firewall (UFW) liberando apenas SSH, HTTP e HTTPS
#
# Requisitos antes de rodar:
#   - Ubuntu 22.04/24.04 (VPS limpa, de preferência)
#   - Acesso root (rode com sudo ou como root)
#   - Um domínio (ex: chat.seudominio.com) com registro A apontando para o IP da VPS
#
# Como usar:
#   wget -O install-vps.sh https://raw.githubusercontent.com/jenilsonsantos/RevoChat/main/scripts/install-vps.sh
#   chmod +x install-vps.sh
#   sudo ./install-vps.sh
#
set -euo pipefail

REPO_URL="https://github.com/jenilsonsantos/RevoChat.git"
INSTALL_DIR="/opt/revochat"

log()  { echo -e "\e[1;32m[revochat]\e[0m $*"; }
warn() { echo -e "\e[1;33m[revochat]\e[0m $*"; }
die()  { echo -e "\e[1;31m[revochat]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Execute este script como root (sudo ./install-vps.sh)."

# ---------------------------------------------------------------------------
# 1. Coleta de informações
# ---------------------------------------------------------------------------
read -rp "Informe o domínio que vai apontar para o RevoChat (ex: chat.seudominio.com): " DOMAIN
[[ -n "$DOMAIN" ]] || die "Domínio é obrigatório."

read -rp "Informe um e-mail válido (usado pelo Let's Encrypt para avisos de expiração): " CERTBOT_EMAIL
[[ -n "$CERTBOT_EMAIL" ]] || die "E-mail é obrigatório."

log "Verifique se o registro DNS tipo A de $DOMAIN já aponta para o IP público desta VPS."
read -rp "Confirma que o DNS já está configurado? (s/N): " DNS_OK
[[ "$DNS_OK" =~ ^[sS]$ ]] || die "Configure o DNS antes de continuar e rode o script novamente."

# ---------------------------------------------------------------------------
# 2. Dependências do sistema
# ---------------------------------------------------------------------------
log "Atualizando pacotes do sistema..."
apt-get update -y
apt-get upgrade -y

log "Instalando dependências básicas (curl, git, ufw)..."
apt-get install -y curl git ufw ca-certificates gnupg

if ! command -v docker &>/dev/null; then
  log "Instalando Docker..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
else
  log "Docker já instalado, pulando."
fi

apt-get install -y docker-compose-plugin

if ! command -v nginx &>/dev/null; then
  log "Instalando Nginx..."
  apt-get install -y nginx
else
  log "Nginx já instalado, pulando."
fi

if ! command -v certbot &>/dev/null; then
  log "Instalando Certbot..."
  apt-get install -y certbot python3-certbot-nginx
else
  log "Certbot já instalado, pulando."
fi

# ---------------------------------------------------------------------------
# 3. Firewall (UFW) - libera apenas SSH, HTTP e HTTPS
# ---------------------------------------------------------------------------
log "Configurando firewall (UFW)..."
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ---------------------------------------------------------------------------
# 4. Clona ou atualiza o repositório
# ---------------------------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
  log "Repositório já existe em $INSTALL_DIR, atualizando..."
  git -C "$INSTALL_DIR" pull
else
  log "Clonando repositório em $INSTALL_DIR..."
  git clone "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# ---------------------------------------------------------------------------
# 5. Geração do .env com segredos únicos
# ---------------------------------------------------------------------------
if [[ -f .env ]]; then
  warn ".env já existe, mantendo o arquivo atual (não será sobrescrito)."
else
  log "Gerando .env com segredos aleatórios..."
  cp .env.example .env

  SECRET_KEY_BASE=$(openssl rand -hex 64)
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  REDIS_PASSWORD=$(openssl rand -hex 24)
  ENC_PRIMARY_KEY=$(openssl rand -hex 32)
  ENC_DETERMINISTIC_KEY=$(openssl rand -hex 32)
  ENC_SALT=$(openssl rand -hex 32)

  sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=${SECRET_KEY_BASE}|" .env
  sed -i "s|^FRONTEND_URL=.*|FRONTEND_URL=https://${DOMAIN}|" .env
  sed -i "s|^FORCE_SSL=.*|FORCE_SSL=true|" .env
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${REDIS_PASSWORD}|" .env
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" .env
  sed -i "s|^RAILS_ENV=.*|RAILS_ENV=production|" .env
  sed -i "s|^# ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=|ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${ENC_PRIMARY_KEY}|" .env
  sed -i "s|^# ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=|ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${ENC_DETERMINISTIC_KEY}|" .env
  sed -i "s|^# ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=|ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${ENC_SALT}|" .env

  chmod 600 .env
  log "Arquivo .env criado com sucesso (permissão restrita a root)."
  warn "Guarde uma cópia segura do .env fora da VPS (contém senhas e segredos)."
fi

# ---------------------------------------------------------------------------
# 6. Build e preparação do banco de dados
# ---------------------------------------------------------------------------
log "Buildando a imagem Docker do RevoChat (isso pode levar alguns minutos)..."
docker compose -f docker-compose.production.yaml build

log "Preparando o banco de dados..."
docker compose -f docker-compose.production.yaml run --rm rails bundle exec rails db:chatwoot_prepare

log "Subindo os containers..."
docker compose -f docker-compose.production.yaml up -d

# ---------------------------------------------------------------------------
# 7. Configuração do Nginx (proxy reverso)
# ---------------------------------------------------------------------------
log "Configurando Nginx para o domínio $DOMAIN..."
mkdir -p /var/www/ssl-proof/revochat/.well-known

cat > "/etc/nginx/sites-available/${DOMAIN}.conf" <<NGINX_EOF
server {
  listen 80;
  server_name ${DOMAIN};

  set \$upstream 127.0.0.1:3000;

  underscores_in_headers on;

  location /.well-known {
    alias /var/www/ssl-proof/revochat/.well-known;
  }

  location / {
    proxy_pass_header Authorization;
    proxy_pass http://\$upstream;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Ssl on;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

    proxy_http_version 1.1;
    proxy_buffering off;

    client_max_body_size 50M;
    proxy_read_timeout 36000s;
    proxy_redirect off;
  }
}
NGINX_EOF

ln -sf "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

nginx -t
systemctl reload nginx

# ---------------------------------------------------------------------------
# 8. Certificado SSL via Let's Encrypt
# ---------------------------------------------------------------------------
log "Emitindo certificado SSL para $DOMAIN via Let's Encrypt..."
certbot --nginx -d "$DOMAIN" -m "$CERTBOT_EMAIL" --agree-tos --redirect --non-interactive

log "Certbot instalado. A renovação automática já é configurada via systemd timer (certbot.timer)."
systemctl enable --now certbot.timer 2>/dev/null || true

# ---------------------------------------------------------------------------
# 9. Finalização
# ---------------------------------------------------------------------------
log "----------------------------------------------------------------------"
log "Instalação concluída!"
log "Acesse: https://${DOMAIN}"
log "Diretório da aplicação: ${INSTALL_DIR}"
log "Arquivo de configuração: ${INSTALL_DIR}/.env"
log ""
log "Comandos úteis:"
log "  Ver logs do Rails:    cd ${INSTALL_DIR} && docker compose -f docker-compose.production.yaml logs -f rails"
log "  Ver logs do Sidekiq:  cd ${INSTALL_DIR} && docker compose -f docker-compose.production.yaml logs -f sidekiq"
log "  Reiniciar tudo:       cd ${INSTALL_DIR} && docker compose -f docker-compose.production.yaml restart"
log "  Atualizar RevoChat:   cd ${INSTALL_DIR} && git pull && docker compose -f docker-compose.production.yaml build && docker compose -f docker-compose.production.yaml run --rm rails bundle exec rails db:chatwoot_prepare && docker compose -f docker-compose.production.yaml up -d"
log "----------------------------------------------------------------------"
