#!/bin/bash
set -eux

MOUNT_POINT="/mnt/minecraft"
MAX_WAIT=120

apt-get update -y
apt-get install -y docker.io docker-compose awscli curl
usermod -aG docker ubuntu

# Wait for the EBS device to show up and determine the correct device
WAITED=0
while [ ! -b /dev/xvdb ] && [ ! -b /dev/nvme1n1 ]; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "Timed out waiting for EBS device to become available."
    exit 1
  fi
  echo "Waiting for EBS device to become available..."
  sleep 1
  WAITED=$((WAITED + 1))
done

if [ -b /dev/nvme1n1 ]; then
  DEVICE="/dev/nvme1n1"
elif [ -b /dev/xvdb ]; then
  DEVICE="/dev/xvdb"
else
  echo "No suitable EBS device found, exiting."
  exit 1
fi

# Check if the device has a filesystem
if ! blkid "$DEVICE"; then
  echo "$DEVICE is unformatted. Formatting as ext4..."
  mkfs.ext4 "$DEVICE"
fi

# Create mount point if it doesn't exist
mkdir -p "$MOUNT_POINT"

# Mount the volume
mount "$DEVICE" "$MOUNT_POINT"

# Make sure it auto-mounts on termination and reboot
if ! grep -qs "$MOUNT_POINT" /etc/fstab; then
  echo "$DEVICE $MOUNT_POINT ext4 defaults,nofail 0 2" >>/etc/fstab
fi

chown -R ubuntu:ubuntu "$MOUNT_POINT"

# Create Crafty data directories on EBS volume
for dir in backups logs servers config import; do
  mkdir -p "$MOUNT_POINT/$dir"
  chown ubuntu:ubuntu "$MOUNT_POINT/$dir"
done

# Create directory for Traefik's Let's Encrypt storage
mkdir -p /mnt/minecraft/traefik/letsencrypt
chown -R ubuntu:ubuntu /mnt/minecraft/traefik/letsencrypt

# Write docker-compose.yml for Crafty and Traefik
cat >/home/ubuntu/docker-compose.yml <<'COMPOSER'
version: "3.8"

services:
  crafty:
    image: arcadiatechnology/crafty-4:latest
    container_name: crafty_container
    restart: always
    environment:
      - TZ=Etc/UTC
    ports:
      - "8443:8443"
      - "8123:8123"
      - "19132:19132/udp"
      - "25500-25600:25500-25600"
    volumes:
      - /mnt/minecraft/backups:/crafty/backups
      - /mnt/minecraft/logs:/crafty/logs
      - /mnt/minecraft/servers:/crafty/servers
      - /mnt/minecraft/config:/crafty/app/config
      - /mnt/minecraft/import:/crafty/import
    labels:
      - "traefik.enable=true"
      - "traefik.http.middlewares.sslheader.headers.customrequestheaders.X-Forwarded-Proto=https"
      - "traefik.http.routers.crafty.entrypoints=websecure"
      - "traefik.http.routers.crafty.rule=Host(\`${domain_name}\`)"
      - "traefik.http.routers.crafty.tls.certresolver=letsencrypt"
      - "traefik.http.routers.crafty.tls=true"
      - "traefik.http.services.crafty.loadbalancer.server.port=8443"
      - "traefik.http.services.crafty.loadbalancer.server.scheme=https"
    networks:
      - webnet

  traefik:
    image: traefik:v2.11
    container_name: traefik
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--certificatesresolvers.letsencrypt.acme.tlschallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.email=${admin_email}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--serversTransport.insecureSkipVerify=true"
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /mnt/minecraft/traefik/letsencrypt:/letsencrypt
    networks:
      - webnet
networks:
  webnet:
COMPOSER

# Create Backup Script
cat >/usr/local/bin/crafty_backup.sh <<'BACKUP_SCRIPT'
#!/bin/bash
set -e
BACKUP_DIR="/mnt/minecraft/backups"
S3_BUCKET="${s3_bucket}"
S3_FOLDER_NAME="crafty-server-backups"

find "$BACKUP_DIR" -type f -name "*.zip" | while read -r ZIP_PATH; do
  BASENAME=$(basename "$ZIP_PATH")
  S3_PATH="s3://$S3_BUCKET/$S3_FOLDER_NAME/$BASENAME"
  if aws s3 cp "$ZIP_PATH" "$S3_PATH"; then
    rm "$ZIP_PATH"
  fi
done

# Delete all local files in the backup directory after S3 uploads
find "$BACKUP_DIR" -type f -delete

echo "Backup complete!"
BACKUP_SCRIPT

chmod +x /usr/local/bin/crafty_backup.sh

# Create systemd service and timer for backups
cat >/etc/systemd/system/crafty-backup.service <<'SERVICE'
[Unit]
Description=Backup Crafty Minecraft data to S3
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/crafty_backup.sh
SERVICE

# Create systemd timer to run the backup daily
cat >/etc/systemd/system/crafty-backup.timer <<'TIMER'
[Unit]
Description=Run Crafty backup daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
TIMER

# Create systemd service to run backup on shutdown
cat >/etc/systemd/system/crafty-backup-shutdown.service <<'SHUTDOWN_SERVICE'
[Unit]
Description=Backup Crafty data on shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/crafty_backup.sh
TimeoutStartSec=300

[Install]
WantedBy=shutdown.target reboot.target
SHUTDOWN_SERVICE

systemctl daemon-reload
systemctl enable crafty-backup.timer
systemctl start crafty-backup.timer
systemctl enable crafty-backup-shutdown.service

sudo -u ubuntu docker-compose -f /home/ubuntu/docker-compose.yml up -d
