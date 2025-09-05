#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +'%F %T')] $*${NC}"; }
err(){ echo -e "${RED}[$(date +'%F %T')] ERROR: $*${NC}"; exit 1; }
warn(){ echo -e "${YELLOW}[$(date +'%F %T')] WARNING: $*${NC}"; }

ensure_free_space() {
  DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
  FREE_MB="$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
  THRESH_MB="${1:-4096}"
  if [ "${FREE_MB:-0}" -ge "$THRESH_MB" ]; then
    log "Disk OK at $DOCKER_ROOT: ${FREE_MB}MB free"
    return 0
  fi
  warn "Low space on $DOCKER_ROOT: ${FREE_MB:-0}MB free; running cleanup…"
  docker system prune -af --volumes || true
  docker builder prune -af || true
  docker image prune -af || true
  docker volume ls -qf dangling=true | xargs -r docker volume rm || true
  if [ -d "$DOCKER_ROOT/containers" ]; then
    find "$DOCKER_ROOT/containers" -name "*-json.log" -type f -size +50M -exec truncate -s 0 {} \; 2>/dev/null || true
  fi
  if command -v journalctl >/dev/null 2>&1; then
    sudo journalctl --vacuum-size=100M || true
  fi
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get clean || true
  elif command -v yum >/dev/null 2>&1; then
    sudo yum clean all || true
  fi
  BACKUP_KEEP="${BACKUP_KEEP:-3}"
  if [ -d "$BACKUP_DIR" ]; then
    ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) | xargs -r rm -rf || true
  fi
  FREE_MB="$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ "${FREE_MB:-0}" -lt "$THRESH_MB" ]; then
    err "Not enough disk after cleanup (${FREE_MB:-0}MB free at $DOCKER_ROOT). Increase EBS size or free space manually, then rerun."
  fi
  log "Cleanup done: ${FREE_MB}MB free at $DOCKER_ROOT"
}

APP_NAME="fieldflow"
DEPLOY_DIR="/opt/fieldflow"
BACKUP_DIR="/opt/fieldflow-backups"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose-deploy.yml"
ENV_FILE="$DEPLOY_DIR/.env"
DB_HOST_DIR="$DEPLOY_DIR/db"
DB_FILE="$DB_HOST_DIR/db.sqlite3"

mkdir -p "$DEPLOY_DIR" "$BACKUP_DIR"

log "Starting deployment of $APP_NAME ..."

: "${AWS_REGION:=us-east-1}"
: "${ECR_REGISTRY:?ECR_REGISTRY not set}"
: "${ECR_REPOSITORY:?ECR_REPOSITORY not set}"
: "${IMAGE_TAG:?IMAGE_TAG not set}"

# --- Tooling bootstrap ---
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

log "Logging in to Amazon ECR..."
if ! aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "$ECR_REGISTRY"; then
  err "ECR login failed"
fi

# --- Instance public IP for allowed hosts ---
TOKEN="$(curl -sS -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
PUBIP="$(curl -sS -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '')"
if [ -z "${PUBIP}" ]; then
  PUBIP="your-server-ip"
fi

mkdir -p "$DB_HOST_DIR"
[ -f "$DB_FILE" ] || touch "$DB_FILE"

# --- .env management ---
if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$DEPLOY_DIR/.env.sample" ]; then
    cp "$DEPLOY_DIR/.env.sample" "$ENV_FILE"
  else
    cat > "$ENV_FILE" <<EOF
DJANGO_SECRET_KEY=CHANGE_ME
DJANGO_DEBUG=0
DATABASE_URL=sqlite:////data/db.sqlite3
DATABASE_PATH=/data/db.sqlite3
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,${PUBIP}
EOF
  fi
fi

# enforce sqlite settings & allowed hosts
if grep -qE '^DATABASE_URL=' "$ENV_FILE"; then
  sed -i "s#^DATABASE_URL=.*#DATABASE_URL=sqlite:////data/db.sqlite3#" "$ENV_FILE"
else
  echo "DATABASE_URL=sqlite:////data/db.sqlite3" >> "$ENV_FILE"
fi

if grep -qE '^DATABASE_PATH=' "$ENV_FILE"; then
  sed -i "s#^DATABASE_PATH=.*#DATABASE_PATH=/data/db.sqlite3#" "$ENV_FILE"
else
  echo "DATABASE_PATH=/data/db.sqlite3" >> "$ENV_FILE"
fi

HOSTS="localhost,127.0.0.1,${PUBIP}"
if grep -qE '^DJANGO_ALLOWED_HOSTS=' "$ENV_FILE"; then
  sed -i "s/^DJANGO_ALLOWED_HOSTS=.*/DJANGO_ALLOWED_HOSTS=${HOSTS}/" "$ENV_FILE"
else
  echo "DJANGO_ALLOWED_HOSTS=${HOSTS}" >> "$ENV_FILE"
fi

# --- Write deploy compose with correct env mapping ---
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
      - ALLOWED_HOSTS=${DJANGO_ALLOWED_HOSTS}
      - DATABASE_PATH=/data/db.sqlite3
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
      - static-data:/vol/web/static
      - media-data:/vol/web/media
    networks: [app-network]

volumes:
  static-data:
  media-data:

networks:
  app-network:
    driver: bridge
EOF

# --- Back up current state if already running ---
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

ensure_free_space 4096

log "Pulling images..."
docker-compose -f "$COMPOSE_FILE" pull

log "Stopping existing containers..."
docker-compose -f "$COMPOSE_FILE" down --remove-orphans || true

log "Starting app and proxy..."
docker-compose -f "$COMPOSE_FILE" up -d --remove-orphans app proxy

# --- Health check: fail fast if app didn't stay up ---
sleep 5
if ! docker-compose -f "$COMPOSE_FILE" ps | awk '/app/ {print $4 $5 $6}' | grep -q 'Up'; then
  warn "app did not report 'Up' immediately; showing recent logs:"
  docker-compose -f "$COMPOSE_FILE" logs --tail=200 app || true
fi

# --- Ensure SQLite file ownership & perms ---
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

log "Restarting app server..."
docker-compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate app

log "Ensure server process present (non-fatal)..."
docker-compose -f "$COMPOSE_FILE" exec -d app sh -lc '
pgrep -f "gunicorn|daphne|uvicorn|manage.py runserver" >/dev/null && exit 0
if command -v gunicorn >/dev/null 2>&1; then
  exec gunicorn config.wsgi:application --bind 0.0.0.0:${PORT:-8000} --workers ${WEB_CONCURRENCY:-2} --timeout ${WEB_TIMEOUT:-60} --log-file -
else
  exec python manage.py runserver 0.0.0.0:8000
fi
' || true

log "Pruning old images..."
docker image prune -f || true

log "Containers:"
docker-compose -f "$COMPOSE_FILE" ps

if [ -n "$PUBIP" ] && [ "$PUBIP" != "your-server-ip" ]; then
  log "Deployment complete. App at: http://${PUBIP}"
else
  log "Deployment complete. App at: http://3.87.76.21"
fi

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
