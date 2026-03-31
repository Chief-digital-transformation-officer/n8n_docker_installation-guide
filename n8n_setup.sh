#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="$HOME/n8n"

step() { echo -e "\n${BLUE}▶ $1${NC}"; }
ok()   { echo -e "  ${GREEN}✔ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }

[ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root: sudo bash n8n_setup.sh${NC}"; exit 1; }

echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}       n8n — автоматическая установка    ${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

read -rp "  Домен (например, n8n.example.com): " N8N_DOMAIN
[[ -z "$N8N_DOMAIN" ]] && { echo -e "${RED}Домен не указан${NC}"; exit 1; }

read -rp "  Email для SSL (Let's Encrypt): " ACME_EMAIL
[[ -z "$ACME_EMAIL" ]] && { echo -e "${RED}Email не указан${NC}"; exit 1; }

echo ""

# ── Docker ────────────────────────────────────────────────────────────────────
step "Проверка Docker"
if ! command -v docker &>/dev/null; then
  warn "Docker не найден, устанавливаю..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  ok "Docker установлен"
else
  ok "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

if ! docker compose version &>/dev/null 2>&1; then
  warn "Устанавливаю docker-compose-plugin..."
  apt-get install -y docker-compose-plugin
  ok "Compose plugin установлен"
else
  ok "Docker Compose: $(docker compose version --short 2>/dev/null || echo OK)"
fi

# ── Secrets ───────────────────────────────────────────────────────────────────
step "Генерация секретов"
PG_ROOT_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
PG_USER_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)
N8N_ENC_KEY=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)
N8N_ADMIN_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$' | head -c 20)
ok "Секреты сгенерированы"

# ── Directories ───────────────────────────────────────────────────────────────
step "Создание директорий: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"/{traefik_data,n8n_storage,db_storage,redis_storage}
touch "$INSTALL_DIR/traefik_data/acme.json"
chmod 600 "$INSTALL_DIR/traefik_data/acme.json"
chown -R 1000:1000 "$INSTALL_DIR/n8n_storage"
chown -R 999:999   "$INSTALL_DIR/db_storage"
chown -R 999:999   "$INSTALL_DIR/redis_storage"
ok "Директории созданы"

# ── .env ──────────────────────────────────────────────────────────────────────
step "Создание .env"
cat > "$INSTALL_DIR/.env" << EOF
# Database access settings
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=user
DB_POSTGRESDB_PASSWORD=${PG_USER_PASS}
DB_TYPE=postgresdb

# n8n and n8n-worker settings
N8N_BLOCK_ENV_ACCESS_IN_NODE=True
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_ENCRYPTION_KEY=${N8N_ENC_KEY}
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=True
N8N_GIT_NODE_DISABLE_BARE_REPOS=True
N8N_HOST=${N8N_DOMAIN}
N8N_PERSONALIZATION_ENABLED=False
N8N_PORT=5678
N8N_PROTOCOL=https
N8N_PROXY_HOPS=1
N8N_RUNNERS_ENABLED=True

# postgres settings
POSTGRES_USER=root
POSTGRES_PASSWORD=${PG_ROOT_PASS}
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=user
POSTGRES_NON_ROOT_PASSWORD=${PG_USER_PASS}

# other settings
EXECUTIONS_MODE=regular
GENERIC_TIMEZONE=Europe/Moscow
NODE_ENV=production
QUEUE_BULL_REDIS_HOST=redis
QUEUE_HEALTH_CHECK_ACTIVE=True
WEBHOOK_URL=https://${N8N_DOMAIN}/

# traefik
ACME_EMAIL=${ACME_EMAIL}
EOF
chmod 600 "$INSTALL_DIR/.env"
ok ".env создан"

# ── docker-compose.yml ────────────────────────────────────────────────────────
step "Создание docker-compose.yml"
cat > "$INSTALL_DIR/docker-compose.yml" << COMPOSE_EOF
x-shared: &shared
  restart: always
  image: docker.n8n.io/n8nio/n8n:latest
  env_file: .env
  links:
    - postgres
    - redis
  volumes:
    - $INSTALL_DIR/n8n_storage:/home/node/.n8n
    - ./healthcheck.js:/healthcheck.js
  depends_on:
    redis:
      condition: service_healthy
    postgres:
      condition: service_healthy

services:
  traefik:
    image: traefik:3.6.10
    restart: always
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=\${ACME_EMAIL}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - $INSTALL_DIR/traefik_data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro

  postgres:
    image: postgres:16
    restart: always
    env_file: .env
    volumes:
      - $INSTALL_DIR/db_storage:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -h localhost -U \${POSTGRES_USER} -d \${POSTGRES_DB}']
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    restart: always
    volumes:
      - $INSTALL_DIR/redis_storage:/data
    healthcheck:
      test: ['CMD', 'redis-cli', 'ping']
      interval: 5s
      timeout: 5s
      retries: 10

  n8n:
    <<: *shared
    labels:
      - traefik.enable=true
      - "traefik.http.routers.n8n.rule=Host(\`\${N8N_HOST}\`)"
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.entrypoints=web,websecure
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
      - traefik.http.middlewares.n8n.headers.SSLRedirect=true
      - traefik.http.middlewares.n8n.headers.STSSeconds=315360000
      - traefik.http.middlewares.n8n.headers.browserXSSFilter=true
      - traefik.http.middlewares.n8n.headers.contentTypeNosniff=true
      - traefik.http.middlewares.n8n.headers.forceSTSHeader=true
      - "traefik.http.middlewares.n8n.headers.SSLHost=\${N8N_HOST}"
      - traefik.http.middlewares.n8n.headers.STSIncludeSubdomains=true
      - traefik.http.middlewares.n8n.headers.STSPreload=true
      - traefik.http.routers.n8n.middlewares=n8n@docker
    ports:
      - "127.0.0.1:5678:5678"
    healthcheck:
      test: ["CMD", "node", "/healthcheck.js"]
      interval: 5s
      timeout: 5s
      retries: 10

  n8n-worker:
    <<: *shared
    command: worker
    depends_on:
      - n8n
    healthcheck:
      test: ["CMD-SHELL", "exit 0"]
      interval: 30s
      timeout: 5s
      retries: 3
COMPOSE_EOF
ok "docker-compose.yml создан"

# ── healthcheck.js ────────────────────────────────────────────────────────────
step "Создание healthcheck.js"
cat > "$INSTALL_DIR/healthcheck.js" << 'HC_EOF'
var http = require('http');

var options = {
  host: '127.0.0.1',
  port: 5678,
  path: '/',
  method: 'GET',
  headers: { 'Host': process.env.N8N_HOST || 'localhost', 'Accept': '*/*' }
};

var req = http.request(options, function(res) {
  process.exit(res.statusCode === 200 ? 0 : 1);
});
req.on('error', function() { process.exit(1); });
req.end();
HC_EOF
ok "healthcheck.js создан"

# ── init-data.sh ──────────────────────────────────────────────────────────────
step "Создание init-data.sh"
cat > "$INSTALL_DIR/init-data.sh" << 'INIT_EOF'
#!/bin/bash
set -e

if [ -n "${POSTGRES_NON_ROOT_USER:-}" ] && [ -n "${POSTGRES_NON_ROOT_PASSWORD:-}" ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS "pgcrypto";
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE USER "${POSTGRES_NON_ROOT_USER}" WITH PASSWORD '${POSTGRES_NON_ROOT_PASSWORD}';
    GRANT ALL PRIVILEGES ON DATABASE "${POSTGRES_DB}" TO "${POSTGRES_NON_ROOT_USER}";
    GRANT CREATE ON SCHEMA public TO "${POSTGRES_NON_ROOT_USER}";
EOSQL
else
  echo "SETUP INFO: No Environment variables given!"
fi
INIT_EOF
chmod +x "$INSTALL_DIR/init-data.sh"
ok "init-data.sh создан"

# ── Launch ────────────────────────────────────────────────────────────────────
step "Запуск стека"
cd "$INSTALL_DIR"
docker compose pull --quiet
docker compose up -d
sleep 3
docker compose ps

# ── Сохранить учётные данные ──────────────────────────────────────────────────
cat > "$INSTALL_DIR/credentials.txt" << EOF
n8n credentials
───────────────
URL:    https://${N8N_DOMAIN}
Login:  ${ACME_EMAIL}
Pass:   ${N8N_ADMIN_PASS}

Введите эти данные при первом открытии n8n в браузере.
EOF
chmod 600 "$INSTALL_DIR/credentials.txt"

echo -e "\n${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✓  n8n установлен и запущен                     ${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "\n  ${BOLD}Войдите в n8n — введите эти данные при первом открытии в браузере:${NC}\n"
echo -e "  URL:    ${BOLD}${YELLOW}https://${N8N_DOMAIN}${NC}"
echo -e "  Пример логина:  ${BOLD}${YELLOW}${ACME_EMAIL}${NC}"
echo -e "  Пример пароля: ${BOLD}${YELLOW}${N8N_ADMIN_PASS}${NC}"

echo -e "\n  ${BOLD}Этот логин и пароль также сохранены в:${NC} ${INSTALL_DIR}/credentials.txt файле"
echo -e "\n  SSL-сертификат выдаётся автоматически (1–2 мин)\n, если вы видит ошибку в браузере, подождите 1–2 минуты и обновите страницу"
echo -e "  Посмотреть логи n8n:      cd ${INSTALL_DIR} && docker compose logs -f n8n"
echo -e "  Рестарт:   cd ${INSTALL_DIR} && docker compose restart"
echo -e "  Остановка: cd ${INSTALL_DIR} && docker compose down\n"
