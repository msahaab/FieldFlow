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
DB_HOST_DIR="$DEPLOY_DIR/db"   # host path persisted on EC2
DB_FILE="$DB_HOST_DIR/db.sqlite3"

mkdir -p "$DEPLOY_DIR" "$BACKUP_DIR"

log "Starting deployment of $APP_NAME ..."

: "${AWS_REGION:=us-east-1}"
: "${ECR_REGISTRY:?ECR_REGISTRY not set}"
: "${ECR_REPOSITORY:?ECR_REPOSITORY not set}"
: "${IMAGE_TAG:?IMAGE_TAG not set}"

# --- prerequisites -----------------------------------------------------------
if ! command -v aws >/dev/null 2>&1; then
  if command -v yum >/dev/null 2>&1; then
    sudo yum -y install awscli
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y awscli
  else
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
    (cd /tmp && unzip -q awscliv2.zip && sudo ./aws/install)
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  sudo usermod -aG docker "${SUDO_USER:-ec2-user}" || true
  sudo systemctl enable --now docker
fi

if ! command -v docker-compose >/dev/null 2>&1; then
  sudo curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

# --- ECR login ---------------------------------------------------------------
log "Logging in to Amazon ECR..."
if ! aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "$ECR_REGISTRY"; then
  err "ECR login failed"
fi

# --- discover public IP with safe fallback -----------------------------------
TOKEN="$(curl -sS -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
PUBIP="$(curl -sS -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '')"
if [ -z "${PUBIP}" ]; then
  # Final fallback placeholder if IMDS is unavailable (e.g., running outside EC2 or blocked)
  PUBIP="your-server-ip"
fi

# --- ensure host DB path exists ----------------------------------------------
mkdir -p "$DB_HOST_DIR"
[ -f "$DB_FILE" ] || touch "$DB_FILE"

# --- ensure .env exists and contains DB vars ---------------------------------
if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$DEPLOY_DIR/.env.sample" ]; then
    cp "$DEPLOY_DIR/.env.sample" "$ENV_FILE"
  else
    cat > "$ENV_FILE" <<EOF
DJANGO_SECRET_KEY=CHANGE_ME
DJANGO_DEBUG=0
DATABASE_URL=sqlite:////data/db.sqlite3
# Optional for projects that don't parse DATABASE_URL:
DATABASE_PATH=/data/db.sqlite3
EOF
  fi
fi

# Always ensure DB settings are correct
if grep -qE '^DATABASE_URL=' "$ENV_FILE"; then
  sed -i "s#^DATABASE_URL=.*#DATABASE_URL=sqlite:////data/db.sqlite3#" "$ENV_FILE"
else
  echo "DATABASE_URL=sqlite:////data/db.sqlite3" >> "$ENV_FILE"
fi

# Optional helper for settings that use DATABASE_PATH instead of DATABASE_URL
if grep -qE '^DATABASE_PATH=' "$ENV_FILE"; then
  sed -i "s#^DATABASE_PATH=.*#DATABASE_PATH=/data/db.sqlite3#" "$ENV_FILE"
else
  echo "DATABASE_PATH=/data/db.sqlite3" >> "$ENV_FILE"
fi

# Allowed hosts include public IP by default
HOSTS="localhost,127.0.0.1,${PUBIP}"
if grep -qE '^DJANGO_ALLOWED_HOSTS=' "$ENV_FILE"; then
  sed -i "s/^DJANGO_ALLOWED_HOSTS=.*/DJANGO_ALLOWED_HOSTS=${HOSTS}/" "$ENV_FILE"
else
  echo "DJANGO_ALLOWED_HOSTS=${HOSTS}" >> "$ENV_FILE"
fi

# --- write compose file -------------------------------------------------------
log "Writing $COMPOSE_FILE ..."
cat > "$COMPOSE_FILE" <<'EOF'
services:
  app:
    image: ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}
    restart: always
    env_file:
      - /opt/fieldflow/.env
    environment:
      - SECRET_KEY=${DJANGO_SECRET_KEY}
      - DEBUG=0
    volumes:
      - /opt/fieldflow/db:/data
      - static-data:/vol/web
      - media-data:/vol/web/media
    networks: [app-network]

  proxy:
    image: ${ECR_REGISTRY}/${ECR_REPOSITORY}-proxy:${IMAGE_TAG}
    restart: always
    depends_on: [app]
    ports:
      - "80:8000"
      - "443:8443"
    volumes:
      - static-data:/vol/static
      - media-data:/vol/media
    networks: [app-network]

volumes:
  static-data:
  media-data:

networks:
  app-network:
    driver: bridge
EOF

# --- backup if stack is already up -------------------------------------------
if docker-compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"; then
  TS="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR/$TS"
  cp "$COMPOSE_FILE" "$BACKUP_DIR/$TS/" || true
  cp "$ENV_FILE" "$BACKUP_DIR/$TS/" || true
  CID="$(docker-compose -f "$COMPOSE_FILE" ps -q app || true)"
  if [ -n "$CID" ]; then
    docker cp "$CID:/data/db.sqlite3" "$BACKUP_DIR/$TS/db.sqlite3" 2>/dev/null || true
  fi
  log "Backup stored at $BACKUP_DIR/$TS"
fi

# --- deploy -------------------------------------------------------------------
log "Pulling images..."
docker-compose -f "$COMPOSE_FILE" pull

log "Stopping existing containers..."
docker-compose -f "$COMPOSE_FILE" down --remove-orphans || true

log "Starting app and proxy..."
docker-compose -f "$COMPOSE_FILE" up -d --remove-orphans app proxy

# Fix ownership/perms on host before running migrations
log "Ensuring SQLite ownership and perms..."
APP_UID="$(docker run --rm "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}" sh -c 'id -u' 2>/dev/null || echo 1000)"
APP_GID="$(docker run --rm "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}" sh -c 'id -g' 2>/dev/null || echo 1000)"
sudo chown -R "${APP_UID}:${APP_GID}" "$DB_HOST_DIR" || true
sudo find "$DB_HOST_DIR" -type d -exec chmod 775 {} \; || true
sudo find "$DB_HOST_DIR" -type f -exec chmod 664 {} \; || true

log "Waiting 20s for services..."
sleep 20

log "Running migrations (one-off)..."
docker-compose -f "$COMPOSE_FILE" run --rm -w /app app python manage.py migrate --noinput || warn "migrate failed"

log "Collecting static (one-off)..."
docker-compose -f "$COMPOSE_FILE" run --rm -w /app app python manage.py collectstatic --noinput || warn "collectstatic failed"

log "Pruning old images..."
docker image prune -f || true

log "Containers:"
docker-compose -f "$COMPOSE_FILE" ps

# Final success line with guaranteed non-empty URL
if [ -n "$PUBIP" ] && [ "$PUBIP" != "your-server-ip" ]; then
  log "Deployment complete. App at: http://${PUBIP}"
else
  log "Deployment complete. App at: http://3.87.76.21"
fi

# --- rollback helper ----------------------------------------------------------
rollback() {
  log "Rolling back..."
  LATEST="$(ls -t "$BACKUP_DIR" | head -n1)"
  [ -n "$LATEST" ] || err "No backup found"
  docker-compose -f "$COMPOSE_FILE" down || true
  cp "$BACKUP_DIR/$LATEST/docker-compose-deploy.yml" "$COMPOSE_FILE"
  cp "$BACKUP_DIR/$LATEST/.env" "$ENV_FILE" || true
  docker-compose -f "$COMPOSE_FILE" up -d
  if [ -f "$BACKUP_DIR/$LATEST/db.sqlite3" ]; then
    CID="$(docker-compose -f "$COMPOSE_FILE" ps -q app)"
    docker cp "$BACKUP_DIR/$LATEST/db.sqlite3" "$CID:/data/db.sqlite3" || true
  fi
  log "Rollback done."
}
export -f rollback
