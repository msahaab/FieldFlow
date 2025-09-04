#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +'%F %T')] $*${NC}"; }
err(){ echo -e "${RED}[$(date +'%F %T')] ERROR: $*${NC}"; exit 1; }
warn(){ echo -e "${YELLOW}[$(date +'%F %T')] WARNING: $*${NC}"; }

APP_NAME="fieldflow"
DEPLOY_DIR="/opt/fieldflow"
BACKUP_DIR="/opt/fieldflow-backups"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose-deploy.yml"
ENV_FILE="$DEPLOY_DIR/.env"

mkdir -p "$DEPLOY_DIR" "$BACKUP_DIR"

log "Starting deployment of $APP_NAME ..."

: "${ECR_REGISTRY:?ECR_REGISTRY not set}"
: "${ECR_REPOSITORY:?ECR_REPOSITORY not set}"
: "${IMAGE_TAG:?IMAGE_TAG not set}"

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  sudo usermod -aG docker ec2-user
  rm -f get-docker.sh
  sudo systemctl enable --now docker
fi

if ! command -v docker-compose >/dev/null 2>&1; then
  log "Installing docker-compose standalone..."
  sudo curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

log "Logging in to Amazon ECR..."
aws ecr get-login-password --region "${AWS_REGION:-us-east-1}" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

if [ ! -f "$ENV_FILE" ]; then
  log "Creating initial $ENV_FILE ..."
  PUBIP="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  cat > "$ENV_FILE" <<EOF
DJANGO_SECRET_KEY=CHANGE_ME
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,${PUBIP:-your-domain.com}

POSTGRES_DB=fieldflow
POSTGRES_USER=fieldflow
POSTGRES_PASSWORD=change_me

AWS_REGION=${AWS_REGION:-us-east-1}
ECR_REGISTRY=$ECR_REGISTRY
ECR_REPOSITORY=$ECR_REPOSITORY
EOF
  warn "Update $ENV_FILE with real secrets after this run."
fi

log "Writing $COMPOSE_FILE ..."
cat > "$COMPOSE_FILE" <<EOF
version: "3.9"

services:
  app:
    image: $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
    restart: always
    env_file:
      - $ENV_FILE
    environment:
      - SECRET_KEY=\${DJANGO_SECRET_KEY}
      - ALLOWED_HOSTS=\${DJANGO_ALLOWED_HOSTS}
      - DEBUG=0
    volumes:
      - static-data:/vol/web
      - media-data:/vol/web/media
    depends_on:
      - db
    networks: [app-network]

  proxy:
    image: $ECR_REGISTRY/$ECR_REPOSITORY-proxy:$IMAGE_TAG
    restart: always
    depends_on: [app]
    ports:
      - "80:8000"
      - "443:8443"
    volumes:
      - static-data:/vol/static
      - media-data:/vol/media
    networks: [app-network]

  db:
    image: postgres:13-alpine
    restart: always
    environment:
      - POSTGRES_DB=\${POSTGRES_DB:-fieldflow}
      - POSTGRES_USER=\${POSTGRES_USER:-fieldflow}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-please-set}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks: [app-network]

  redis:
    image: redis:6-alpine
    restart: always
    networks: [app-network]

volumes:
  static-data:
  media-data:
  postgres-data:

networks:
  app-network:
    driver: bridge
EOF

if docker-compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"; then
  log "Backing up current deployment..."
  TS="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR/$TS"
  docker-compose -f "$COMPOSE_FILE" exec -T db pg_dump -U "${POSTGRES_USER:-fieldflow}" "${POSTGRES_DB:-fieldflow}" \
    > "$BACKUP_DIR/$TS/database.sql" 2>/dev/null || true
  cp "$COMPOSE_FILE" "$BACKUP_DIR/$TS/" || true
  cp "$ENV_FILE" "$BACKUP_DIR/$TS/" || true
  log "Backup stored at $BACKUP_DIR/$TS"
fi

log "Pulling images..."
docker-compose -f "$COMPOSE_FILE" pull

log "Stopping existing containers..."
docker-compose -f "$COMPOSE_FILE" down || true

log "Starting new containers..."
docker-compose -f "$COMPOSE_FILE" up -d

log "Waiting 30s for services..."
sleep 30

log "Running migrations..."
docker-compose -f "$COMPOSE_FILE" exec -T app python manage.py migrate --noinput || warn "migrate failed"

log "Collecting static..."
docker-compose -f "$COMPOSE_FILE" exec -T app python manage.py collectstatic --noinput || warn "collectstatic failed"

log "Health check..."
for i in {1..10}; do
  if curl -fsS http://localhost/health/ >/dev/null 2>&1 || curl -fsS http://localhost:8000/health/ >/dev/null 2>&1; then
    log "Health check passed"; break
  fi
  if [ "$i" -eq 10 ]; then err "Health check failed after 10 attempts"; fi
  log "Retry $i/10 ..."; sleep 10
done

log "Pruning old images..."
docker image prune -f || true

log "Containers:"
docker-compose -f "$COMPOSE_FILE" ps

PUBIP="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
log "Deployment complete. App at: http://${PUBIP:-your-server-ip}"

rollback() {
  log "Rolling back..."
  LATEST="$(ls -t "$BACKUP_DIR" | head -n1)"
  [ -n "$LATEST" ] || err "No backup found"
  docker-compose -f "$COMPOSE_FILE" down || true
  cp "$BACKUP_DIR/$LATEST/docker-compose-deploy.yml" "$COMPOSE_FILE"
  docker-compose -f "$COMPOSE_FILE" up -d
  if [ -f "$BACKUP_DIR/$LATEST/database.sql" ]; then
    log "Restoring DB..."
    docker-compose -f "$COMPOSE_FILE" exec -T db psql -U "${POSTGRES_USER:-fieldflow}" -d "${POSTGRES_DB:-fieldflow}" < "$BACKUP_DIR/$LATEST/database.sql" || true
  fi
  log "Rollback done."
}
export -f rollback
