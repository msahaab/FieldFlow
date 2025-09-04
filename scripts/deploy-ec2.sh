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

: "${AWS_REGION:=us-east-1}"
: "${ECR_REGISTRY:?ECR_REGISTRY not set}"
: "${ECR_REPOSITORY:?ECR_REPOSITORY not set}"
: "${IMAGE_TAG:?IMAGE_TAG not set}"

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

TOKEN="$(curl -sS -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
PUBIP="$(curl -sS -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 || true)"

mkdir -p /opt/fieldflow/db
if [ ! -f /opt/fieldflow/db/db.sqlite3 ]; then
  log "Creating empty SQLite DB file at /opt/fieldflow/db/db.sqlite3"
  touch /opt/fieldflow/db/db.sqlite3
  chmod 664 /opt/fieldflow/db/db.sqlite3 || true
fi

if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$DEPLOY_DIR/.env.sample" ]; then
    log "Creating .env from .env.sample ..."
    cp "$DEPLOY_DIR/.env.sample" "$ENV_FILE"
  else
    log "Creating minimal .env ..."
    cat > "$ENV_FILE" <<EOF
DJANGO_SECRET_KEY=CHANGE_ME
DJANGO_DEBUG=0
DATABASE_URL=sqlite:////app/db.sqlite3
EOF
  fi
  HOSTS="localhost,127.0.0.1,${PUBIP:-your-domain.com}"
  if grep -qE '^DJANGO_ALLOWED_HOSTS=' "$ENV_FILE"; then
    sed -i "s/^DJANGO_ALLOWED_HOSTS=.*/DJANGO_ALLOWED_HOSTS=${HOSTS}/" "$ENV_FILE"
  else
    echo "DJANGO_ALLOWED_HOSTS=${HOSTS}" >> "$ENV_FILE"
  fi
  log "Wrote $ENV_FILE (DJANGO_ALLOWED_HOSTS=${HOSTS})"
fi

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
      - /opt/fieldflow/db/db.sqlite3:/app/db.sqlite3
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

if docker-compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -q "Up"; then
  TS="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR/$TS"
  cp "$COMPOSE_FILE" "$BACKUP_DIR/$TS/" || true
  cp "$ENV_FILE" "$BACKUP_DIR/$TS/" || true
  CID="$(docker-compose -f "$COMPOSE_FILE" ps -q app || true)"
  if [ -n "$CID" ]; then
    docker cp "$CID:/app/db.sqlite3" "$BACKUP_DIR/$TS/db.sqlite3" 2>/dev/null || true
  fi
  log "Backup stored at $BACKUP_DIR/$TS"
fi

log "Pulling images..."
docker-compose -f "$COMPOSE_FILE" pull

log "Stopping existing containers..."
docker-compose -f "$COMPOSE_FILE" down || true

log "Starting app and proxy..."
docker-compose -f "$COMPOSE_FILE" up -d app proxy

log "Waiting 20s for services..."
sleep 20

log "Running migrations (one-off)..."
docker-compose -f "$COMPOSE_FILE" run --rm app python manage.py migrate --noinput || warn "migrate failed"

log "Collecting static (one-off)..."
docker-compose -f "$COMPOSE_FILE" run --rm app python manage.py collectstatic --noinput || warn "collectstatic failed"

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

log "Deployment complete. App at: http://${PUBIP:-your-server-ip}"

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
    docker cp "$BACKUP_DIR/$LATEST/db.sqlite3" "$CID:/app/db.sqlite3" || true
  fi
  log "Rollback done."
}
export -f rollback
