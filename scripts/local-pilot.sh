#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="tcbhagat/challanse"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}/challanse-local"
ENV_FILE="$CONFIG_ROOT/local.env"
EDGE_VARS="$CONFIG_ROOT/edge.dev.vars"
REVIEWER_VARS="$CONFIG_ROOT/reviewer.dev.vars"
TLS_DIR="$CONFIG_ROOT/tls"
RESTIC_PASSWORD_FILE="$CONFIG_ROOT/restic-password"
DATA_ROOT="/mnt/challanse-data"
LEGACY_DATA_ROOT="/srv/challanse"
CONTAINER_DATA_ROOT="/srv/challanse"
COMPOSE_FILE="$ROOT/deploy/local/docker-compose.yml"
SNAP_COMPOSE_FILE="$ROOT/deploy/local/docker-compose.snap.yml"
RUNTIME_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/challanse-local-runtime"
HOST_DEVICE="/dev/sda2"
HOST_MOUNT="/mnt/challanse-host"
CONTAINER_FILE="$HOST_MOUNT/challanse-local.luks"
CONTAINER_SIZE="20G"
CONTAINER_SIZE_BYTES="21474836480"
MAPPER_NAME="challanse-local"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
confirm_phrase() {
  local prompt="$1" expected="$2" answer
  read -r -p "$prompt Type $expected: " answer
  [[ "$answer" == "$expected" ]] || die "Cancelled. Nothing was changed."
}
repo_var() { gh variable get "$1" --repo "$REPO" 2>/dev/null || true; }
require_aws_freeze() {
  need gh
  [[ "$(repo_var AWS_DEPLOYMENT_FROZEN)" == "true" ]] || die "AWS_DEPLOYMENT_FROZEN must equal true. Local pilot startup is blocked."
  [[ "$(repo_var PILOT_DEPLOY_ENABLED)" == "false" ]] || die "PILOT_DEPLOY_ENABLED must equal false."
}
local_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}
load_env() {
  [[ -f "$ENV_FILE" ]] || die "Local pilot is not provisioned. Run: ./scripts/local-pilot.sh provision"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  export CHALLANSE_CONFIG_ROOT="$CONFIG_ROOT" CHALLANSE_DATA_ROOT="$DATA_ROOT" CHALLANSE_RUNTIME_ROOT="$RUNTIME_ROOT"
  mkdir -p "$RUNTIME_ROOT/tls"
  chmod 700 "$RUNTIME_ROOT" "$RUNTIME_ROOT/tls"
  cp "$EDGE_VARS" "$RUNTIME_ROOT/edge.dev.vars"
  cp "$REVIEWER_VARS" "$RUNTIME_ROOT/reviewer.dev.vars"
  cp "$TLS_DIR"/*.crt "$TLS_DIR"/*.key "$RUNTIME_ROOT/tls/"
  chmod 600 "$RUNTIME_ROOT"/*.vars "$RUNTIME_ROOT/tls"/*.key
}
compose() {
  load_env
  local compose_files=(-f "$COMPOSE_FILE") docker_root
  docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  if [[ "$docker_root" == /var/snap/docker/* ]]; then
    docker info --format '{{json .SecurityOptions}}' | grep -q 'name=apparmor' \
      || die "Snap Docker must retain AppArmor before using its compatibility override."
    docker info --format '{{json .SecurityOptions}}' | grep -q 'name=seccomp' \
      || die "Snap Docker must retain the built-in seccomp profile before using its compatibility override."
    compose_files+=(-f "$SNAP_COMPOSE_FILE")
  fi
  docker compose "${compose_files[@]}" "$@"
}
require_encrypted_storage() {
  local source type
  [[ -d "$DATA_ROOT" ]] || die "$DATA_ROOT does not exist. Run storage-audit, then storage-prepare only after backup approval."
  source="$(findmnt -n -o SOURCE --mountpoint "$DATA_ROOT" 2>/dev/null || true)"
  [[ "$source" == "/dev/mapper/$MAPPER_NAME" ]] || die "$DATA_ROOT is not mounted from /dev/mapper/$MAPPER_NAME."
  type="$(lsblk -dn -o TYPE "$source" 2>/dev/null || true)"
  [[ "$type" == "crypt" ]] || die "$DATA_ROOT is not backed by an active LUKS mapping."
}
require_docker_storage_visibility() {
  docker image inspect challanse-local-pilot-api >/dev/null 2>&1 \
    || die "Local pilot images are missing. Run provision before start."
  docker run --rm --network none --read-only \
    --mount "type=bind,src=$DATA_ROOT,dst=/host-data,readonly" \
    --entrypoint python challanse-local-pilot-api \
    -c 'from pathlib import Path; raise SystemExit(0 if Path("/host-data").is_dir() else 1)' >/dev/null 2>&1 \
    || die "Docker cannot access $DATA_ROOT. For Snap Docker, restart its service after opening storage, then retry."
}
mount_host_storage() {
  local current_mount expected_uuid mounted_uuid
  expected_uuid="$(lsblk -dn -o UUID "$HOST_DEVICE" | tr -d ' ')"
  [[ -n "$expected_uuid" ]] || die "The UUID for $HOST_DEVICE could not be read safely."
  if mountpoint -q "$HOST_MOUNT"; then
    mounted_uuid="$(findmnt -rn -o UUID --target "$HOST_MOUNT" 2>/dev/null || true)"
    [[ "$mounted_uuid" == "$expected_uuid" ]] || die "$HOST_MOUNT is already used by a different filesystem."
    return
  fi
  current_mount="$(findmnt -rn -S "$HOST_DEVICE" -o TARGET 2>/dev/null | head -n 1 || true)"
  sudo mkdir -p "$HOST_MOUNT"
  if [[ -z "$current_mount" ]]; then
    sudo mount "$HOST_DEVICE" "$HOST_MOUNT"
  elif [[ "$current_mount" != "$HOST_MOUNT" ]]; then
    sudo mount --bind "$current_mount" "$HOST_MOUNT"
  fi
  mounted_uuid="$(findmnt -rn -o UUID --target "$HOST_MOUNT" 2>/dev/null || true)"
  [[ "$mounted_uuid" == "$expected_uuid" ]] || die "$HOST_MOUNT is not backed by $HOST_DEVICE."
}
recover_incomplete_container() {
  local luks_status metadata
  [[ -e "$CONTAINER_FILE" ]] || return
  if sudo cryptsetup isLuks "$CONTAINER_FILE"; then
    die "$CONTAINER_FILE is a valid encrypted container. Run storage-open instead."
  else
    luks_status=$?
    [[ "$luks_status" -eq 1 ]] || die "The existing container could not be validated safely; it was not changed."
  fi
  sudo test -f "$CONTAINER_FILE" || die "The incomplete container path is not a regular file; it was not changed."
  sudo test ! -L "$CONTAINER_FILE" || die "The incomplete container path is a symbolic link; it was not changed."
  metadata="$(sudo stat -c '%s:%U:%G:%a:%h' "$CONTAINER_FILE")"
  [[ "$metadata" == "$CONTAINER_SIZE_BYTES:root:root:600:1" ]] \
    || die "The incomplete container metadata is unexpected; it was not changed."
  confirm_phrase "Remove only the invalid container left by the failed passphrase attempt. " "RECOVER-INCOMPLETE-CHALLANSE-CONTAINER"
  sudo rm -- "$CONTAINER_FILE"
  printf 'Incomplete container removed. Existing files elsewhere on %s were unchanged.\n' "$HOST_DEVICE"
}
require_firewall() {
  grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null || die "UFW is not active. Run firewall-prepare after reviewing its rules."
  local subnet
  subnet="$(ip -4 route show scope link | awk '$1 ~ /^[0-9]+\./ && $1 !~ /^172\./ {print $1; exit}')"
  [[ -n "$subnet" ]] || die "Local subnet could not be detected."
  local status
  status="$(sudo ufw status)"
  grep -F "$subnet" <<<"$status" | grep -q '8443' || die "UFW has no port 8443 rule for subnet $subnet. Run firewall-prepare."
  grep -F "$subnet" <<<"$status" | grep -q '8444' || die "UFW has no port 8444 rule for subnet $subnet. Run firewall-prepare."
}
check_port_free() {
  local port="$1"
  if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
    die "Port $port is already in use. Stop the conflicting service first."
  fi
}
preflight() {
  require_aws_freeze
  local command
  for command in docker curl jq openssl python3 npm ip ss lsblk findmnt mountpoint sha256sum keytool ufw cryptsetup mkfs.ext4 fallocate; do need "$command"; done
  docker info >/dev/null 2>&1 || die "Docker is not running or your user cannot access it."
  curl -fsS http://127.0.0.1:11434/api/tags | jq -e '.models[] | select(.name == "qwen2.5:7b")' >/dev/null \
    || die "Ollama model qwen2.5:7b is not available. Run: ollama pull qwen2.5:7b"
  need tesseract
  tesseract --list-langs 2>/dev/null | grep -qx eng || die "Tesseract English language data is missing."
  if ! tesseract --list-langs 2>/dev/null | grep -qx hin; then
    printf 'WARNING: Host Hindi Tesseract data is missing; the local container includes it.\n' >&2
  fi
  [[ "$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)" -ge 24 ]] || die "At least 24 GB RAM is required for this supervised pilot."
  local android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
  [[ -d "$android_sdk/platforms/android-36" && -d "$android_sdk/build-tools/36.0.0" && -d "$android_sdk/ndk/27.1.12297006" ]] \
    || die "Android SDK 36, Build Tools 36.0.0, and NDK 27.1.12297006 are required before provisioning."
  export ANDROID_HOME="$android_sdk" ANDROID_SDK_ROOT="$android_sdk"
  check_port_free 8443
  check_port_free 8444
  if ! grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    printf 'WARNING: UFW is disabled. Startup will remain blocked until firewall-prepare succeeds.\n' >&2
  fi
  printf 'Preflight passed. AWS deployment is frozen and the approved local model is available.\n'
}
firewall_prepare() {
  require_aws_freeze
  need ufw; need ip
  local subnet
  subnet="$(ip -4 route show scope link | awk '$1 ~ /^[0-9]+\./ && $1 !~ /^172\./ {print $1; exit}')"
  [[ -n "$subnet" ]] || die "Local subnet could not be detected."
  printf 'This will deny unsolicited inbound traffic, preserve outbound traffic, and allow pilot ports only from %s.\n' "$subnet"
  confirm_phrase "Review existing firewall rules before continuing. " "CONFIGURE-LOCAL-PILOT-FIREWALL"
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  if [[ -n "${SSH_CONNECTION:-}" ]]; then sudo ufw allow from "$subnet" to any port 22 proto tcp; fi
  sudo ufw allow from "$subnet" to any port 8443 proto tcp
  sudo ufw allow from "$subnet" to any port 8444 proto tcp
  sudo ufw --force enable
  sudo ufw status numbered
}
storage_audit() {
  need lsblk; need findmnt; need blkid
  [[ -b "$HOST_DEVICE" ]] || die "$HOST_DEVICE was not found. No storage action was taken."
  printf 'Read-only storage inventory for %s:\n' "$HOST_DEVICE"
  lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINTS "$HOST_DEVICE"
  blkid "$HOST_DEVICE" || true
  if findmnt -rn -S "$HOST_DEVICE" >/dev/null 2>&1; then
    printf '%s is mounted. Existing files will be preserved.\n' "$HOST_DEVICE"
  else
    printf '%s is not mounted. No filesystem content was opened or changed.\n' "$HOST_DEVICE"
  fi
  printf 'ChallanSe uses a separate %s LUKS2 container file; it never formats %s.\n' "$CONTAINER_SIZE" "$HOST_DEVICE"
  if mountpoint -q "$DATA_ROOT"; then
    findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS --mountpoint "$DATA_ROOT"
  fi
}
storage_prepare() {
  require_aws_freeze
  need cryptsetup; need mkfs.ext4; need lsblk; need findmnt; need mount; need mountpoint; need blkid; need fallocate; need df
  [[ -b "$HOST_DEVICE" ]] || die "$HOST_DEVICE was not found."
  [[ "$(findmnt -rn -o SOURCE / 2>/dev/null)" != "$HOST_DEVICE" ]] || die "Refusing to use the root filesystem device."
  [[ "$(lsblk -dn -o FSTYPE "$HOST_DEVICE")" == "ext4" ]] || die "$HOST_DEVICE must remain an existing ext4 data partition."
  storage_audit
  printf '%s\n' "Existing files on $HOST_DEVICE will not be erased or reformatted."
  confirm_phrase "Create a new $CONTAINER_SIZE encrypted container file for synthetic ChallanSe data. " "CREATE-20GB-ENCRYPTED-CHALLANSE-CONTAINER"
  mount_host_storage
  recover_incomplete_container
  local available_bytes
  available_bytes="$(df -B1 --output=avail "$HOST_MOUNT" | tail -n 1 | tr -d ' ')"
  [[ "$available_bytes" -ge 25000000000 ]] || die "At least 25 GB free space is required before creating the encrypted container."
  sudo fallocate -l "$CONTAINER_SIZE_BYTES" "$CONTAINER_FILE"
  sudo chmod 600 "$CONTAINER_FILE"
  sudo cryptsetup luksFormat --type luks2 "$CONTAINER_FILE"
  sudo cryptsetup open "$CONTAINER_FILE" "$MAPPER_NAME"
  sudo mkfs.ext4 -L challanse-local "/dev/mapper/$MAPPER_NAME"
  sudo mkdir -p "$DATA_ROOT"
  sudo mount "/dev/mapper/$MAPPER_NAME" "$DATA_ROOT"
  sudo chown "$USER":"$(id -gn)" "$DATA_ROOT"
  printf 'Encrypted container storage is mounted at %s. Existing files on %s were preserved.\n' "$DATA_ROOT" "$HOST_DEVICE"
}
storage_open() {
  require_aws_freeze
  need cryptsetup; need findmnt; need mount; need mountpoint; need blkid; need lsblk
  mount_host_storage
  [[ -f "$CONTAINER_FILE" ]] || die "$CONTAINER_FILE does not exist. Run storage-prepare once."
  if [[ ! -e "/dev/mapper/$MAPPER_NAME" ]]; then
    sudo cryptsetup open "$CONTAINER_FILE" "$MAPPER_NAME"
  fi
  if mountpoint -q "$LEGACY_DATA_ROOT"; then
    [[ "$(findmnt -n -o SOURCE --mountpoint "$LEGACY_DATA_ROOT" 2>/dev/null || true)" == "/dev/mapper/$MAPPER_NAME" ]] \
      || die "$LEGACY_DATA_ROOT is mounted from an unexpected source; it was not changed."
    sudo umount "$LEGACY_DATA_ROOT"
  fi
  sudo mkdir -p "$DATA_ROOT"
  if ! mountpoint -q "$DATA_ROOT"; then
    sudo mount "/dev/mapper/$MAPPER_NAME" "$DATA_ROOT"
  fi
  sudo chown "$USER":"$(id -gn)" "$DATA_ROOT"
  require_encrypted_storage
  printf 'Encrypted ChallanSe container is open at %s.\n' "$DATA_ROOT"
}
storage_close() {
  require_aws_freeze
  need cryptsetup; need findmnt
  if mountpoint -q "$DATA_ROOT"; then
    sudo umount "$DATA_ROOT"
  fi
  if mountpoint -q "$LEGACY_DATA_ROOT"; then
    sudo umount "$LEGACY_DATA_ROOT"
  fi
  if [[ -e "/dev/mapper/$MAPPER_NAME" ]]; then
    sudo cryptsetup close "$MAPPER_NAME"
  fi
  printf 'Encrypted ChallanSe container is closed. Existing host files remain mounted and unchanged.\n'
}
write_secret_files() {
  local lan_ip="$1"
  mkdir -p "$CONFIG_ROOT" "$TLS_DIR"
  chmod 700 "$CONFIG_ROOT" "$TLS_DIR"
  local admin_password app_password system_password minio_password pepper tenant_key hmac_key gateway_secret auth_key
  admin_password="$(openssl rand -hex 24)"
  app_password="$(openssl rand -hex 24)"
  system_password="$(openssl rand -hex 24)"
  minio_password="$(openssl rand -hex 24)"
  pepper="$(openssl rand -hex 32)"
  tenant_key="$(openssl rand -hex 32)"
  hmac_key="$(openssl rand -hex 32)"
  gateway_secret="$(openssl rand -hex 32)"
  auth_key="$(openssl rand -hex 32)"
  cat >"$ENV_FILE" <<EOF
AWS_DEPLOYMENT_FROZEN=true
ENVIRONMENT=local-pilot
SYNTHETIC_MODE=true
POSTGRES_DB=challanse_local
POSTGRES_USER=challanse_admin
POSTGRES_ADMIN_PASSWORD=$admin_password
DATABASE_ADMIN_URL=postgresql://challanse_admin:$admin_password@postgres:5432/challanse_local
DATABASE_URL=postgresql://challanse_app:$app_password@postgres:5432/challanse_local
SYSTEM_DATABASE_URL=postgresql://challanse_system:$system_password@postgres:5432/challanse_local
DATABASE_APP_PASSWORD=$app_password
DATABASE_SYSTEM_PASSWORD=$system_password
TENANT_CONTEXT_HMAC_KEY=$tenant_key
DEVICE_TOKEN_PEPPER=$pepper
EDGE_TO_ENRICHMENT_HMAC_KEY_ID=local-current
EDGE_TO_ENRICHMENT_HMAC_KEY=$hmac_key
RECEIPT_BUCKET=challanse-receipts
OBJECT_STORE_ENDPOINT=http://minio:9000
OBJECT_STORE_ACCESS_KEY=challanse-local
OBJECT_STORE_SECRET_KEY=$minio_password
OBJECT_STORE_SSE_MODE=none
MINIO_ROOT_USER=challanse-local
MINIO_ROOT_PASSWORD=$minio_password
EVENT_QUEUE_PROVIDER=postgres
OCR_PROVIDER=local
GST_PROVIDER=disabled
NOTIFICATION_PROVIDER=disabled
CREDIT_PROVIDER=disabled
SLACK_PROVIDER=disabled
OLLAMA_URL=http://ollama:11434
OLLAMA_MODEL=qwen2.5:7b
OLLAMA_TIMEOUT_SECONDS=90
TESSERACT_LANGUAGES=eng+hin
LOCAL_DATA_ROOT=$CONTAINER_DATA_ROOT
LOCAL_STORAGE_LIMIT_BYTES=20000000000
LOCAL_AUTH_ENCRYPTION_KEY=$auth_key
LOCAL_SESSION_TTL_MINUTES=480
LOCAL_REVIEWER_GATEWAY_SECRET=$gateway_secret
LOCAL_REVIEWER_EMAIL=admin@constrovet.com
LOCAL_REVIEWER_EMAILS=admin@constrovet.com,bhagat.taran@gmail.com
CHALLANSE_LAN_IP=$lan_ip
PUBLIC_API_URL=https://$lan_ip:8443
REVIEW_DASHBOARD_URL=https://$lan_ip:8444
PLAY_INTEGRITY_PROVIDER=disabled
EOF
  cat >"$EDGE_VARS" <<EOF
ALLOWED_ORIGINS=https://$lan_ip:8444
ACCESS_TEAM_DOMAIN=
ACCESS_AUD=
TURNSTILE_SECRET=
ENVIRONMENT=local-pilot
ENRICHMENT_URL=http://api:8080
EDGE_TO_ENRICHMENT_HMAC_KEY_ID=local-current
EDGE_TO_ENRICHMENT_HMAC_KEY=$hmac_key
LOCAL_REVIEWER_GATEWAY_SECRET=$gateway_secret
LOCAL_REVIEWER_EMAILS=admin@constrovet.com,bhagat.taran@gmail.com
EOF
  printf 'API_ORIGIN=http://edge:8787\n' >"$REVIEWER_VARS"
  chmod 600 "$ENV_FILE" "$EDGE_VARS" "$REVIEWER_VARS"
}
ensure_local_auth_key() {
  [[ -f "$ENV_FILE" ]] || return
  if ! grep -q '^LOCAL_AUTH_ENCRYPTION_KEY=' "$ENV_FILE"; then
    printf 'LOCAL_AUTH_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" >>"$ENV_FILE"
    printf 'LOCAL_SESSION_TTL_MINUTES=480\n' >>"$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
}
ensure_private_ollama_url() {
  [[ -f "$ENV_FILE" ]] || return
  local configured_url
  configured_url="$(sed -n 's/^OLLAMA_URL=//p' "$ENV_FILE")"
  if [[ "$configured_url" == "http://host.docker.internal:11434" ]]; then
    sed -i 's|^OLLAMA_URL=.*|OLLAMA_URL=http://ollama:11434|' "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  elif [[ "$configured_url" != "http://ollama:11434" ]]; then
    die "Unexpected Ollama endpoint in the frozen local configuration. It was not changed."
  fi
}
connect_private_ollama() {
  local network_name="challanse-local-pilot_ocr-egress"
  docker inspect -f '{{.State.Running}}' ollama 2>/dev/null | grep -qx true \
    || die "The existing Ollama container is not running. Start it before ChallanSe."
  docker network inspect "$network_name" >/dev/null 2>&1 \
    || die "The private OCR network was not created."
  if ! docker inspect ollama --format '{{json .NetworkSettings.Networks}}' | jq -e --arg network "$network_name" 'has($network)' >/dev/null; then
    docker network connect --alias ollama "$network_name" ollama
  fi
}
require_external_backup_mount() {
  local backup_root="$1" source parent transport
  [[ -d "$backup_root" ]] || die "Backup mount does not exist: $backup_root"
  source="$(findmnt -rn -o SOURCE --target "$backup_root" 2>/dev/null || true)"
  [[ "$source" == /dev/* ]] || die "Backup destination must be a separately mounted block device."
  parent="$(lsblk -ndo PKNAME "$source" 2>/dev/null | head -n 1)"
  [[ -n "$parent" ]] || parent="$(basename "$source")"
  transport="$(lsblk -dn -o TRAN "/dev/$parent" 2>/dev/null | tr -d ' ')"
  [[ "$transport" == "usb" ]] || die "Backup destination must be an external USB device."
  [[ "/dev/$parent" != "/dev/sda" && "/dev/$parent" != "/dev/sdb" ]] || die "Backup destination cannot use an internal ChallanSe or system disk."
}
ensure_restic_password() {
  if [[ ! -f "$RESTIC_PASSWORD_FILE" ]]; then
    umask 077
    openssl rand -base64 48 >"$RESTIC_PASSWORD_FILE"
    chmod 600 "$RESTIC_PASSWORD_FILE"
    printf 'A new Restic password file was created. Back it up separately in an approved password manager before client activation.\n'
  fi
  [[ "$(stat -c '%a' "$RESTIC_PASSWORD_FILE")" == "600" ]] || die "Restic password file must have mode 600."
}
backup_repository_details() {
  local backup_root="$1" repository uuid
  repository="$backup_root/challanse-restic"
  uuid="$(findmnt -rn -o UUID --target "$backup_root" 2>/dev/null || true)"
  [[ -n "$uuid" ]] || die "Backup filesystem UUID could not be determined."
  printf '%s\n%s\n' "$repository" "$(printf '%s' "$uuid" | sha256sum | awk '{print $1}')"
}
record_backup_run() {
  local status="$1" repository_id="$2" snapshot_id="$3" manifest_sha256="$4" payload
  payload="$(jq -nc --arg status "$status" --arg repositoryId "$repository_id" --arg snapshotId "$snapshot_id" --arg manifestSha256 "$manifest_sha256" '{status:$status,repositoryId:$repositoryId,snapshotId:$snapshotId,manifestSha256:$manifestSha256}')"
  printf '%s' "$payload" | compose exec -T api python -m app.local_backup record
}
backup_pilot() {
  require_encrypted_storage
  load_env
  need restic
  local backup_root="${1:-}" details repository repository_id staging timestamp manifest snapshot_json snapshot_id manifest_sha256
  [[ -n "$backup_root" ]] || die "Use: ./scripts/local-pilot.sh backup /media/USER/CLIENT-BACKUP"
  require_external_backup_mount "$backup_root"
  ensure_restic_password
  mapfile -t details < <(backup_repository_details "$backup_root")
  repository="${details[0]}"; repository_id="${details[1]}"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  staging="$DATA_ROOT/backups/backup-$timestamp"
  mkdir -p "$staging"
  chmod 700 "$staging"
  compose exec -T postgres pg_dump -U challanse_admin -d challanse_local -Fc >"$staging/postgres.dump"
  jq -n --arg commit "$(git rev-parse HEAD)" --arg createdAt "$timestamp" --arg awsFrozen "$(repo_var AWS_DEPLOYMENT_FROZEN)" \
    '{schemaVersion:"1.0",commitSha:$commit,createdAt:$createdAt,awsDeploymentFrozen:($awsFrozen=="true"),containsSecrets:false}' >"$staging/metadata.json"
  manifest="$staging/manifest.sha256"
  (cd "$DATA_ROOT" && find images exports "backups/backup-$timestamp" -type f -print0 | sort -z | xargs -0 sha256sum) >"$manifest"
  export RESTIC_REPOSITORY="$repository" RESTIC_PASSWORD_FILE
  if ! restic snapshots >/dev/null 2>&1; then restic init >/dev/null; fi
  snapshot_json="$(restic backup --json "$DATA_ROOT/images" "$DATA_ROOT/exports" "$staging" | tail -n 1)"
  snapshot_id="$(jq -r '.snapshot_id // empty' <<<"$snapshot_json")"
  [[ "$snapshot_id" =~ ^[a-f0-9]+$ ]] || die "Restic did not return a valid snapshot ID."
  manifest_sha256="$(sha256sum "$manifest" | awk '{print $1}')"
  record_backup_run "SUCCEEDED" "$repository_id" "$snapshot_id" "$manifest_sha256"
  printf 'Encrypted backup completed and verified by snapshot ID. Disconnect the USB drive after running backup-verify.\n'
}
backup_verify() {
  require_encrypted_storage
  load_env
  need restic
  local backup_root="${1:-}" details repository repository_id restore_root snapshot_id evidence manifest_sha256
  [[ -n "$backup_root" ]] || die "Use: ./scripts/local-pilot.sh backup-verify /media/USER/CLIENT-BACKUP"
  require_external_backup_mount "$backup_root"
  ensure_restic_password
  mapfile -t details < <(backup_repository_details "$backup_root")
  repository="${details[0]}"; repository_id="${details[1]}"
  export RESTIC_REPOSITORY="$repository" RESTIC_PASSWORD_FILE
  restic check --read-data-subset=10% >/dev/null
  snapshot_id="$(restic snapshots --json | jq -r 'sort_by(.time) | last | .short_id')"
  [[ "$snapshot_id" =~ ^[a-f0-9]+$ ]] || die "No valid Restic snapshot was found."
  restore_root="$DATA_ROOT/backups/restore-check-$snapshot_id"
  [[ ! -e "$restore_root" ]] || die "Restore test directory already exists: $restore_root"
  mkdir -p "$restore_root"
  restic restore "$snapshot_id" --target "$restore_root" >/dev/null
  find "$restore_root" -name postgres.dump -type f -size +0c -print -quit | grep -q . || die "Restored PostgreSQL dump is missing."
  evidence="$DATA_ROOT/exports/backup-restore-$snapshot_id.json"
  jq -n --arg snapshotId "$snapshot_id" --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion:"1.0",snapshotId:$snapshotId,verifiedAt:$verifiedAt,postgresDumpPresent:true,resticCheckPassed:true}' >"$evidence"
  manifest_sha256="$(sha256sum "$evidence" | awk '{print $1}')"
  record_backup_run "RESTORE_VERIFIED" "$repository_id" "$snapshot_id" "$manifest_sha256"
  rm -rf -- "$restore_root"
  printf 'Restore verification passed. Evidence: %s\n' "$evidence"
}
generate_server_certificate() {
  local lan_ip="$1"
  openssl genrsa -out "$TLS_DIR/pilot.key" 3072 >/dev/null 2>&1
  openssl req -new -key "$TLS_DIR/pilot.key" -subj '/CN=ChallanSe Local Pilot' -out "$TLS_DIR/pilot.csr"
  cat >"$TLS_DIR/pilot.ext" <<EOF
subjectAltName=IP:$lan_ip,DNS:api.local.challanse.test,DNS:review.local.challanse.test
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
  openssl x509 -req -in "$TLS_DIR/pilot.csr" -CA "$TLS_DIR/pilot-ca.crt" -CAkey "$TLS_DIR/pilot-ca.key" \
    -CAcreateserial -out "$TLS_DIR/pilot.crt" -days 365 -sha256 -extfile "$TLS_DIR/pilot.ext" >/dev/null 2>&1
  rm -f "$TLS_DIR/pilot.csr" "$TLS_DIR/pilot-ca.srl" "$TLS_DIR/pilot.ext"
  chmod 600 "$TLS_DIR"/*.key
  chmod 644 "$TLS_DIR"/*.crt
}
generate_ca() {
  local lan_ip="$1"
  openssl genrsa -out "$TLS_DIR/pilot-ca.key" 4096 >/dev/null 2>&1
  openssl req -x509 -new -key "$TLS_DIR/pilot-ca.key" -sha256 -days 365 \
    -subj '/CN=ChallanSe Synthetic Pilot CA' -out "$TLS_DIR/pilot-ca.crt"
  generate_server_certificate "$lan_ip"
}
refresh_lan_configuration() {
  require_aws_freeze
  require_encrypted_storage
  need openssl; need sed; need ip; need docker
  [[ -f "$ENV_FILE" && -f "$EDGE_VARS" && -f "$TLS_DIR/pilot-ca.key" && -f "$TLS_DIR/pilot-ca.crt" ]] \
    || die "Existing local pilot configuration and CA are required before refreshing the LAN address."
  if docker ps --filter label=com.docker.compose.project=challanse-local-pilot --format '{{.ID}}' | grep -q .; then
    die "Stop the local pilot containers before refreshing the LAN address."
  fi
  local lan_ip
  lan_ip="$(local_ip)"
  [[ -n "$lan_ip" ]] || die "A current LAN IPv4 address could not be detected."
  confirm_phrase "Preserve all secrets and the pilot CA, then reissue the server certificate for $lan_ip. " "REFRESH-LOCAL-PILOT-LAN"
  sed -i \
    -e "s|^CHALLANSE_LAN_IP=.*|CHALLANSE_LAN_IP=$lan_ip|" \
    -e "s|^PUBLIC_API_URL=.*|PUBLIC_API_URL=https://$lan_ip:8443|" \
    -e "s|^REVIEW_DASHBOARD_URL=.*|REVIEW_DASHBOARD_URL=https://$lan_ip:8444|" \
    -e '/^LOCAL_REVIEWER_.*PASSWORD.*=/d' \
    "$ENV_FILE"
  sed -i "s|^ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=https://$lan_ip:8444|" "$EDGE_VARS"
  chmod 600 "$ENV_FILE" "$EDGE_VARS"
  generate_server_certificate "$lan_ip"
  cp "$TLS_DIR/pilot-ca.crt" "$ROOT/apps/mobile/android/app/src/localPilot/res/raw/challanse_pilot_ca.crt"
  validate_existing_provision_state "$lan_ip"
  printf 'Local pilot LAN configuration now matches %s. Existing credentials and the pilot CA were preserved.\n' "$lan_ip"
}
validate_existing_provision_state() {
  local lan_ip="$1" required_file private_file
  for required_file in \
    "$ENV_FILE" \
    "$EDGE_VARS" \
    "$REVIEWER_VARS" \
    "$TLS_DIR/pilot-ca.crt" \
    "$TLS_DIR/pilot-ca.key" \
    "$TLS_DIR/pilot.crt" \
    "$TLS_DIR/pilot.key"; do
    [[ -f "$required_file" ]] || die "Provisioning is incomplete: missing $required_file. Existing secrets were not changed."
  done
  for private_file in "$ENV_FILE" "$EDGE_VARS" "$REVIEWER_VARS" "$TLS_DIR/pilot-ca.key" "$TLS_DIR/pilot.key"; do
    [[ "$(stat -c '%a' "$private_file")" == "600" ]] || die "Unsafe permissions on $private_file; expected mode 600."
  done
  (
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
    [[ "${AWS_DEPLOYMENT_FROZEN:-}" == "true" ]]
    [[ "${SYNTHETIC_MODE:-}" == "true" ]]
    [[ "${CHALLANSE_LAN_IP:-}" == "$lan_ip" ]]
  ) || die "Existing local pilot configuration does not match the frozen synthetic environment or current LAN IP."
  openssl verify -CAfile "$TLS_DIR/pilot-ca.crt" "$TLS_DIR/pilot.crt" >/dev/null \
    || die "Existing pilot TLS certificate does not validate against its local CA."
  cmp -s \
    <(openssl x509 -in "$TLS_DIR/pilot.crt" -pubkey -noout) \
    <(openssl pkey -in "$TLS_DIR/pilot.key" -pubout) \
    || die "Existing pilot TLS certificate and private key do not match."
}
provision() {
  preflight
  require_encrypted_storage
  local lan_ip
  lan_ip="$(local_ip)"
  [[ -n "$lan_ip" ]] || die "A fixed LAN IPv4 address could not be detected."
  mkdir -p "$DATA_ROOT"/{postgres,images,exports,backups,fixtures}
  if [[ "$(stat -c '%u:%g' "$DATA_ROOT/postgres")" != "999:999" ]]; then
    sudo chown -R 999:999 "$DATA_ROOT/postgres"
  fi
  if [[ "$(stat -c '%u:%g' "$DATA_ROOT/images")" != "$(id -u):$(id -g)" ]]; then
    sudo chown -R "$(id -u):$(id -g)" "$DATA_ROOT/images"
  fi
  chown -R "$USER":"$(id -gn)" "$DATA_ROOT"/{exports,backups,fixtures}
  if [[ -e "$ENV_FILE" ]]; then
    ensure_local_auth_key
    validate_existing_provision_state "$lan_ip"
    printf 'Validated existing local secrets and pilot CA; resuming provisioning without rotation.\n'
  else
    write_secret_files "$lan_ip"
    generate_ca "$lan_ip"
  fi
  cp "$TLS_DIR/pilot-ca.crt" "$ROOT/apps/mobile/android/app/src/localPilot/res/raw/challanse_pilot_ca.crt"
  python3 "$ROOT/scripts/generate-local-fixtures.py" "$DATA_ROOT/fixtures"
  (cd "$ROOT" && CI=true npm run build --workspace @challanse/reviewer)
  (cd "$ROOT" && CI=true npm run build:local-pilot --workspace @challanse/mobile)
  compose build
  printf 'Provisioning complete. Secrets are stored with mode 600 under %s.\n' "$CONFIG_ROOT"
}
reviewer_enroll() {
  require_encrypted_storage
  load_env
  local email password password_confirm payload
  read -r -p 'Reviewer email: ' email
  read -r -s -p 'Create a reviewer password (minimum 14 characters): ' password; printf '\n'
  read -r -s -p 'Repeat the reviewer password: ' password_confirm; printf '\n'
  [[ -n "$email" && "$password" == "$password_confirm" ]] || die "Reviewer enrollment input did not match."
  payload="$(jq -nc --arg email "$email" --arg password "$password" '{email:$email,password:$password}')"
  unset password password_confirm
  printf '%s' "$payload" | compose exec -T api python -m app.local_reviewer
}
prepare_client_pilot() {
  require_encrypted_storage
  load_env
  local configuration_file="${1:-}"
  [[ -n "$configuration_file" && -f "$configuration_file" ]] || die "Use: ./scripts/local-pilot.sh prepare-client /secure/client-pilot.json"
  confirm_phrase "This deletes all synthetic server records and prepares one client configuration. " "PREPARE-CONTROLLED-CLIENT-PILOT"
  compose exec -T api python -m app.local_pilot_control_cli prepare <"$configuration_file"
  printf 'Client configuration prepared. Enroll exactly two reviewers, complete backup restore and security evidence, then activate.\n'
}
activate_client_pilot() {
  require_encrypted_storage
  load_env
  local approval_file="${1:-}" security_file="${2:-}" restore_file="${3:-}"
  local operator_email retention_days payload
  [[ -f "$approval_file" && -f "$security_file" && -f "$restore_file" ]] \
    || die "Use: ./scripts/local-pilot.sh activate-client-pilot CLIENT_APPROVAL SECURITY_REVIEW RESTORE_EVIDENCE"
  read -r -p 'Activating reviewer email: ' operator_email
  read -r -p 'Retention days [30, maximum 30]: ' retention_days
  retention_days="${retention_days:-30}"
  [[ "$retention_days" =~ ^[0-9]+$ && "$retention_days" -ge 1 && "$retention_days" -le 30 ]] || die "Retention must be between 1 and 30 days."
  confirm_phrase "Activate real client data mode with no uptime SLA? " "ACTIVATE-CONTROLLED-CLIENT-PILOT"
  payload="$(jq -nc \
    --arg operatorEmail "$operator_email" \
    --argjson retentionDays "$retention_days" \
    --arg clientApprovalSha256 "$(sha256sum "$approval_file" | awk '{print $1}')" \
    --arg securityReviewSha256 "$(sha256sum "$security_file" | awk '{print $1}')" \
    --arg backupRestoreSha256 "$(sha256sum "$restore_file" | awk '{print $1}')" \
    '{operatorEmail:$operatorEmail,retentionDays:$retentionDays,clientApprovalSha256:$clientApprovalSha256,securityReviewSha256:$securityReviewSha256,backupRestoreSha256:$backupRestoreSha256}')"
  printf '%s' "$payload" | compose exec -T api python -m app.local_pilot_control_cli activate
}
end_client_pilot() {
  require_encrypted_storage
  load_env
  local operator_email payload
  read -r -p 'Ending reviewer email: ' operator_email
  [[ -n "$operator_email" ]] || die "A reviewer email is required."
  confirm_phrase "End client capture and begin the configured deletion waiting period? " "END-CONTROLLED-CLIENT-PILOT"
  payload="$(jq -nc --arg operatorEmail "$operator_email" '{operatorEmail:$operatorEmail}')"
  printf '%s' "$payload" | compose exec -T api python -m app.local_pilot_control_cli end
  printf 'Client pilot ended. Data remains encrypted and inaccessible to new capture until the retention period expires.\n'
}
purge_ended_client_pilot() {
  require_encrypted_storage
  load_env
  confirm_phrase "Permanently delete ended client records and active image objects after retention? " "PURGE-ENDED-CLIENT-PILOT"
  compose exec -T api python -m app.local_pilot_control_cli purge-ended
  find "$DATA_ROOT/images" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  printf 'Ended client records and image objects were purged after the enforced retention period.\n'
}
prewarm() {
  load_env
  curl -fsS --max-time 120 "http://127.0.0.1:11434/api/generate" \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg model "$OLLAMA_MODEL" '{model:$model,prompt:"Reply with exactly READY.",stream:false,keep_alive:"30m",options:{temperature:0,num_predict:4}}')" \
    | jq -e '.model != null' >/dev/null
}
start_stack() {
  require_aws_freeze
  require_encrypted_storage
  require_firewall
  require_docker_storage_visibility
  local mode="${1:---lan}"
  ensure_private_ollama_url
  load_env
  [[ "$(local_ip)" == "$CHALLANSE_LAN_IP" ]] || die "LAN IP changed. Reissue the pilot certificate before startup."
  if [[ "$mode" == "--both" ]]; then
    if [[ -z "${TUNNEL_TOKEN:-}" ]]; then
      read -r -s -p 'Cloudflare pilot tunnel token: ' TUNNEL_TOKEN; printf '\n'
      [[ -n "$TUNNEL_TOKEN" ]] || die "Tunnel token is required for --both."
      printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" >>"$ENV_FILE"
      chmod 600 "$ENV_FILE"
      export TUNNEL_TOKEN
    fi
    if [[ -z "${ACCESS_TEAM_DOMAIN:-}" ]]; then
      read -r -p 'Cloudflare Access team domain (for example team.cloudflareaccess.com): ' ACCESS_TEAM_DOMAIN
      [[ -n "$ACCESS_TEAM_DOMAIN" ]] || die "Access team domain is required for remote reviewer mode."
      printf 'ACCESS_TEAM_DOMAIN=%s\n' "$ACCESS_TEAM_DOMAIN" >>"$ENV_FILE"
    fi
    if [[ -z "${PILOT_ACCESS_AUD:-}" ]]; then
      read -r -s -p 'Cloudflare Access application audience: ' PILOT_ACCESS_AUD; printf '\n'
      [[ -n "$PILOT_ACCESS_AUD" ]] || die "Access audience is required for remote reviewer mode."
      printf 'PILOT_ACCESS_AUD=%s\n' "$PILOT_ACCESS_AUD" >>"$ENV_FILE"
    fi
    sed -i "s|^ACCESS_TEAM_DOMAIN=.*|ACCESS_TEAM_DOMAIN=$ACCESS_TEAM_DOMAIN|; s|^ACCESS_AUD=.*|ACCESS_AUD=$PILOT_ACCESS_AUD|" "$EDGE_VARS"
    chmod 600 "$ENV_FILE" "$EDGE_VARS"
    compose --profile remote up -d --force-recreate
  elif [[ "$mode" == "--lan" ]]; then
    compose up -d --force-recreate
  else
    die "Use start --lan or start --both."
  fi
  connect_private_ollama
  prewarm
  for _ in $(seq 1 60); do
    if curl -fsS --cacert "$TLS_DIR/pilot-ca.crt" "https://$CHALLANSE_LAN_IP:8443/health" >/dev/null 2>&1; then
      printf 'GREEN: ChallanSe synthetic pilot is ready on LAN.\nReviewer: https://%s:8444\n' "$CHALLANSE_LAN_IP"
      return
    fi
    sleep 2
  done
  compose ps
  die "Local pilot did not become ready. Run: ./scripts/local-pilot.sh status"
}
seed() {
  require_encrypted_storage
  compose exec -T api python -m app.local_seed
  printf 'Synthetic site, four vendors, two reviewers, and Tally data are seeded.\n'
}
test_data() {
  require_encrypted_storage
  python3 "$ROOT/scripts/generate-local-fixtures.py" "$DATA_ROOT/fixtures"
  jq -e 'length == 5 and all(.synthetic == true)' "$DATA_ROOT/fixtures/manifest.json" >/dev/null
  printf 'Synthetic test data refreshed:\n  Images: %s/*.webp\n  Tally CSV: %s/synthetic-tally.csv\n' \
    "$DATA_ROOT/fixtures" "$DATA_ROOT/fixtures"
}
enroll() {
  require_encrypted_storage
  load_env
  local output code api_base link device_name
  read -r -p 'Device name [Synthetic Pilot Device]: ' device_name
  device_name="${device_name:-Synthetic Pilot Device}"
  output="$(compose exec -T -e LOCAL_DEVICE_NAME="$device_name" api python -m app.local_enroll)"
  code="$(sed -n 's/^enrollment_code=\([^ ]*\).*/\1/p' <<<"$output")"
  [[ -n "$code" ]] || die "Enrollment code could not be generated."
  api_base="https://$CHALLANSE_LAN_IP:8443"
  link="challanse-local://enroll?api=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$api_base")&code=$code"
  printf 'Enrollment expires in 10 minutes. Open this link on the pilot device:\n%s\n' "$link"
}
status_cmd() {
  require_aws_freeze
  require_encrypted_storage
  load_env
  local failed=0 status_json pilot_mode
  compose ps
  printf '\nLocal service status:\n'
  status_json="$(compose exec -T api python -c 'import json; from app.config import get_settings; from app.local_admin import local_status; print(json.dumps(local_status(get_settings())))')" || failed=1
  jq . <<<"$status_json"
  pilot_mode="$(jq -r '.pilotMode // "unknown"' <<<"$status_json")"
  jq -e '
    .database == "ready" and .objectStore == "ready" and .ollama == "ready" and
    .tesseract == "ready" and .terminalFailures == 0 and
    (.storage.uploadsPaused | not) and .auditChain.valid == true
  ' <<<"$status_json" >/dev/null || failed=1
  if [[ "$pilot_mode" == "controlled-client-pilot" ]]; then
    jq -e '.backup.status == "RESTORE_VERIFIED"' <<<"$status_json" >/dev/null || failed=1
  fi
  openssl x509 -checkend 2592000 -noout -in "$TLS_DIR/pilot.crt" >/dev/null || failed=1
  if [[ "$failed" -eq 0 ]]; then
    printf 'GREEN: %s services and integrity gates are ready.\n' "$pilot_mode"
  else
    printf 'RED: one or more local pilot checks failed.\n' >&2
    return 1
  fi
}
config_check() {
  require_aws_freeze
  require_encrypted_storage
  load_env
  compose config --quiet
  printf 'Local Compose configuration is valid with frozen AWS controls.\n'
}
download_apk() {
  local apk="$ROOT/apps/mobile/android/app/build/outputs/apk/localPilot/app-localPilot.apk"
  [[ -f "$apk" ]] || die "Local pilot APK is not built yet."
  mkdir -p "$ROOT/artifacts/local-pilot"
  cp "$apk" "$ROOT/artifacts/local-pilot/ChallanSe-Local-Pilot.apk"
  sha256sum "$ROOT/artifacts/local-pilot/ChallanSe-Local-Pilot.apk"
}
acceptance() {
  require_encrypted_storage
  load_env
  local output code report run_status cleanup_status
  python3 "$ROOT/scripts/generate-local-fixtures.py" "$DATA_ROOT/fixtures"
  output="$(compose exec -T api python -m app.local_acceptance prepare)"
  code="$(sed -n 's/^enrollment_code=\([^ ]*\).*/\1/p' <<<"$output")"
  [[ -n "$code" ]] || die "Acceptance enrollment code could not be generated."
  report="$DATA_ROOT/exports/local-acceptance-$(date -u +%Y%m%dT%H%M%SZ).json"
  set +e
  LOCAL_API_BASE_URL="https://$CHALLANSE_LAN_IP:8443" \
  LOCAL_ENROLLMENT_CODE="$code" \
  LOCAL_FIXTURE_DIR="$DATA_ROOT/fixtures" \
  LOCAL_CA_FILE="$TLS_DIR/pilot-ca.crt" \
  LOCAL_ACCEPTANCE_OUTPUT="$report" \
    python3 "$ROOT/scripts/run-local-acceptance.py"
  run_status=$?
  compose exec -T api python -m app.local_acceptance cleanup
  cleanup_status=$?
  set -e
  [[ "$cleanup_status" -eq 0 ]] || die "Acceptance tenant cleanup failed. Do not use this run as evidence."
  [[ "$run_status" -eq 0 ]] || die "Synthetic acceptance failed. The temporary acceptance tenant was removed."
  printf 'Acceptance report: %s\n' "$report"
}
evidence() {
  require_encrypted_storage
  load_env
  local timestamp directory apk status_json pilot_mode backup_status acceptance_report
  compose exec -T api python -m app.local_acceptance verify-clean >/dev/null \
    || die "Temporary acceptance data remains. Run acceptance cleanup before creating evidence."
  acceptance_report="$(find "$DATA_ROOT/exports" -maxdepth 1 -type f -name 'local-acceptance-*.json' -mmin -1440 -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
  [[ -n "$acceptance_report" ]] || die "No successful acceptance report from the last 24 hours exists. Run acceptance first."
  jq -e '.synthetic == true and .receiptCount == 50 and .uniqueReceiptCount == 50 and .passed == true' "$acceptance_report" >/dev/null \
    || die "The latest acceptance report did not pass. Evidence was not created."
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  directory="$DATA_ROOT/exports/evidence-$timestamp"
  mkdir -p "$directory"
  git rev-parse HEAD >"$directory/commit-sha.txt"
  docker compose -f "$COMPOSE_FILE" images --format json >"$directory/container-images.json"
  ollama list >"$directory/ollama-models.txt"
  tesseract --version >"$directory/tesseract-version.txt" 2>&1
  compose exec -T api tesseract --list-langs >"$directory/container-ocr-languages.txt" 2>&1
  status_json="$(compose exec -T api python -c 'import json; from app.config import get_settings; from app.local_admin import local_status; print(json.dumps(local_status(get_settings())))')"
  jq . <<<"$status_json" >"$directory/runtime-status.json"
  cp "$ROOT/quality/gates.json" "$directory/standards-gates.json"
  cp "$acceptance_report" "$directory/acceptance-report.json"
  pilot_mode="$(jq -r '.pilotMode' <<<"$status_json")"
  backup_status="$(jq -r '.backup.status' <<<"$status_json")"
  apk="$ROOT/apps/mobile/android/app/build/outputs/apk/localPilot/app-localPilot.apk"
  if [[ -f "$apk" ]]; then sha256sum "$apk" >"$directory/apk-sha256.txt"; fi
  cat >"$directory/limitations.txt" <<EOF
Pilot mode: $pilot_mode.
Supervised demonstration only; no uptime SLA or unattended availability.
Local OCR and normalization results are not statutory validation.
Real client data is prohibited unless mode is controlled-client-pilot and all activation evidence remains valid.
Latest recorded backup status: $backup_status.
AWS deployment remains frozen.
EOF
  printf 'Evidence pack created: %s\n' "$directory"
}
stop_stack() {
  compose --profile remote stop
  printf 'Local services stopped. Mobile queues and synthetic data were preserved.\n'
}
reset_stack() {
  require_encrypted_storage
  confirm_phrase "Delete and recreate all server-side synthetic records? " "RESET-SYNTHETIC-DATA"
  compose exec -T api python -c 'from app.config import get_settings; from app.local_admin import reset_synthetic_data; reset_synthetic_data(get_settings(), "RESET SYNTHETIC DATA")'
  seed
}
destroy_stack() {
  require_encrypted_storage
  confirm_phrase "Delete local containers, secrets, and all synthetic server data? " "DESTROY-LOCAL-PILOT"
  if [[ -f "$ENV_FILE" ]]; then
    docker network disconnect challanse-local-pilot_ocr-egress ollama 2>/dev/null || true
    compose --profile remote down --remove-orphans
  fi
  sudo rm -rf "$DATA_ROOT/postgres" "$DATA_ROOT/images" "$DATA_ROOT/exports" "$DATA_ROOT/backups" "$DATA_ROOT/fixtures"
  rm -rf "$CONFIG_ROOT"
  rm -rf "$RUNTIME_ROOT"
  printf 'Local synthetic pilot data and secrets were destroyed. The encrypted disk itself was preserved.\n'
}
usage() {
  cat <<'EOF'
Usage: ./scripts/local-pilot.sh COMMAND

Commands:
  preflight          Verify zero-budget local prerequisites
  storage-audit      Inspect /dev/sda2 metadata read-only
  storage-prepare    Create a separate 20 GB encrypted container without erasing files
  storage-open       Open the encrypted container after reboot
  storage-close      Close the encrypted container after stopping services
  refresh-lan        Preserve secrets and CA while updating the local IP certificate
  firewall-prepare   Restrict pilot ports to the detected local subnet
  provision          Create local secrets, CA, fixtures, and containers
  start --lan        Start LAN-only supervised pilot
  start --both       Start LAN and preconfigured Cloudflare Tunnel
  seed               Seed synthetic site, vendors, reviewers, and Tally data
  test-data          Refresh five WebP fixtures and the compatible Tally CSV
  enroll             Create a ten-minute device enrollment link
  reviewer-enroll    Create or rotate one reviewer's password and MFA
  backup PATH        Create an encrypted Restic backup on an external USB mount
  backup-verify PATH Verify repository data and restore the latest snapshot
  prepare-client     Replace synthetic records using an approved client JSON file
  activate-client-pilot  Enable real data only after evidence and backup gates pass
  end-client-pilot   End capture and start the configured deletion waiting period
  purge-ended-client-pilot  Delete ended client data only after retention expires
  status             Show one local readiness summary
  config-check       Validate Compose and local secret bindings without starting
  download-apk       Copy the local pilot APK and print SHA-256
  acceptance         Upload and process 50 synthetic receipts
  evidence           Export commit, image, model, OCR, APK, and limits evidence
  stop               Stop services without deleting data
  reset              Reset server-side synthetic data
  destroy            Delete local synthetic data and secrets
EOF
}

cd "$ROOT"
case "${1:-}" in
  preflight) preflight ;;
  storage-audit) storage_audit ;;
  storage-prepare) storage_prepare ;;
  storage-open) storage_open ;;
  storage-close) storage_close ;;
  refresh-lan) refresh_lan_configuration ;;
  firewall-prepare) firewall_prepare ;;
  provision) provision ;;
  start) start_stack "${2:---lan}" ;;
  seed) seed ;;
  test-data) test_data ;;
  enroll) enroll ;;
  reviewer-enroll) reviewer_enroll ;;
  backup) backup_pilot "${2:-}" ;;
  backup-verify) backup_verify "${2:-}" ;;
  prepare-client) prepare_client_pilot "${2:-}" ;;
  activate-client-pilot) activate_client_pilot "${2:-}" "${3:-}" "${4:-}" ;;
  end-client-pilot) end_client_pilot ;;
  purge-ended-client-pilot) purge_ended_client_pilot ;;
  status) status_cmd ;;
  config-check) config_check ;;
  download-apk) download_apk ;;
  acceptance) acceptance ;;
  evidence) evidence ;;
  stop) stop_stack ;;
  reset) reset_stack ;;
  destroy) destroy_stack ;;
  *) usage; exit 2 ;;
esac
