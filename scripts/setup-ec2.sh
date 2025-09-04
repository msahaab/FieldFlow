#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +'%F %T')] $*${NC}"; }
err(){ echo -e "${RED}[$(date +'%F %T')] ERROR: $*${NC}"; exit 1; }
info(){ echo -e "${BLUE}[$(date +'%F %T')] INFO: $*${NC}"; }
warn(){ echo -e "${YELLOW}[$(date +'%F %T')] WARNING: $*${NC}"; }

[ "$EUID" -eq 0 ] && err "Do not run as root. Run as ec2-user."

source /etc/os-release
ALVER="AL2"
if [[ "${VERSION_ID:-}" == "2023" ]]; then ALVER="AL2023"; fi
log "Detected Amazon Linux: ${ALVER}"

if [[ "$ALVER" == "AL2023" ]]; then
  sudo dnf -y update
else
  sudo yum -y update
fi

log "Installing base packages..."
if [[ "$ALVER" == "AL2023" ]]; then
  sudo dnf -y install curl wget git unzip htop vim jq awscli
else
  sudo yum -y install curl wget git unzip htop vim jq awscli
fi

log "Installing Docker..."
if ! command -v docker >/dev/null 2>&1; then
  if [[ "$ALVER" == "AL2023" ]]; then
    sudo dnf -y install docker
  else
    sudo amazon-linux-extras install -y docker
  fi
fi
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

if ! command -v docker-compose >/dev/null 2>&1; then
  log "Installing docker-compose standalone..."
  sudo curl -fsSL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
fi

if [[ "$ALVER" == "AL2023" ]]; then
  sudo dnf -y install fail2ban || true
else
  sudo amazon-linux-extras install -y epel || true
  sudo yum -y install fail2ban || true
fi
sudo systemctl enable --now fail2ban || true

sudo mkdir -p /opt/fieldflow /opt/fieldflow-backups
sudo chown ec2-user:ec2-user /opt/fieldflow /opt/fieldflow-backups

log "Configuring Docker log rotation..."
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
sudo systemctl restart docker

log "Creating systemd service..."
sudo tee /etc/systemd/system/fieldflow.service >/dev/null <<'EOF'
[Unit]
Description=FieldFlow Application
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/fieldflow
ExecStart=/usr/local/bin/docker-compose -f docker-compose-deploy.yml up -d
ExecStop=/usr/local/bin/docker-compose -f docker-compose-deploy.yml down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable fieldflow.service

log "Adding monitoring/cleanup cron jobs..."
cat > /opt/fieldflow/monitor.sh <<'EOS'
#!/bin/bash
LOG_FILE="/opt/fieldflow/monitor.log"
echo "[$(date +'%F %T')] monitor tick" >> "$LOG_FILE"
if ! docker-compose -f /opt/fieldflow/docker-compose-deploy.yml ps | grep -q "Up"; then
  echo "[$(date +'%F %T')] WARNING: Some containers are not running" >> "$LOG_FILE"
fi
DISK=$(df / | awk 'NR==2{print $5}' | tr -d '%'); if [ "$DISK" -gt 85 ]; then
  echo "[$(date +'%F %T')] WARNING: Disk usage ${DISK}%" >> "$LOG_FILE"
fi
MEM=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}'); if [ "$MEM" -gt 85 ]; then
  echo "[$(date +'%F %T')] WARNING: Memory usage ${MEM}%" >> "$LOG_FILE"
fi
EOS
chmod +x /opt/fieldflow/monitor.sh
( crontab -l 2>/dev/null; echo "*/5 * * * * /opt/fieldflow/monitor.sh" ) | crontab -

cat > /opt/fieldflow/.env.template <<'EOF'
# Django
DJANGO_SECRET_KEY=your-super-secret-key
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,your-ec2-dns-or-ip

# Database
POSTGRES_DB=fieldflow
POSTGRES_USER=fieldflow
POSTGRES_PASSWORD=your-strong-password

# AWS / ECR
AWS_REGION=us-east-1
ECR_REGISTRY=YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
ECR_REPOSITORY=fieldflow-app
EOF

cat > /opt/fieldflow/cleanup.sh <<'EOS'
#!/bin/bash
docker system prune -f
find /opt/fieldflow-backups -type d -mtime +30 -exec rm -rf {} +
EOS
chmod +x /opt/fieldflow/cleanup.sh
( crontab -l 2>/dev/null; echo "0 2 * * 0 /opt/fieldflow/cleanup.sh" ) | crontab -

log "Setup complete. Log out & back in so Docker group takes effect."
