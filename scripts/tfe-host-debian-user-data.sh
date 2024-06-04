#!/bin/sh

log() {
  printf '%b%s %b%s%b %s\n' \
    "${c1}" "${3:-->}" "${c3}${2:+$c2}" "$1" "${c3}" "$2" >&2
}

upgrade_system() {
  log "  Upgrading all system packages."
  export DEBIAN_FRONTEND=noninteractive
  apt-get -yq update >/dev/null
  apt-get -yq upgrade >/dev/null
}

install_packages() {
  log "  Installing the following packages: $*"
  export DEBIAN_FRONTEND=noninteractive
  apt-get -yq update >/dev/null
  apt-get -yq install "${@}" >/dev/null
}

wait_for_network() {
  log "  Checking network connectivity."
  while ! ping -c 1 -W 1 8.8.8.8 >/dev/null; do
    log "    Waiting for the network to be available..."
    sleep 1
  done
}

get_ssm_parameter_value() {
  log "  Grabbing AWS Systems Manager Parameter Value for: ${1}"
  aws ssm get-parameter \
    --name "${1}" \
    --query "Parameter.Value" \
    --with-decryption \
    --output text
}

set_ssm_parameter_value() {
  log "  Setting AWS Systems Manager Parameter Value for: ${1}"
  aws ssm put-parameter \
    --name "${1}" \
    --value "${2}" \
    --type "SecureString" \
    --overwrite \
    >/dev/null 2>&1
}

find_secretsmanager_secret() {
  log "  Looking up an AWS SecretsManager Secret."
  log "    Query: secret name starts with '${1}'"
  aws secretsmanager list-secrets \
    --query "SecretList[?starts_with(Name, '${1}')].Name" \
    --output text
}

get_secretsmanager_secret_value() {
  log "  Grabbing AWS SecretsManager Secret value for: ${1}"
  aws secretsmanager get-secret-value \
    --secret-id "${1}" \
    --query SecretString --output text
}

set_ec2_http_put_response_hop_limit() {
  log "  Grabbing the EC2 instance metadata token."

  aws_token="$(
    curl -s -X \
      PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"
  )"

  log "  Grabbing the EC2 instance ID."

  ec2_instance_id="$(
    curl -H "X-aws-ec2-metadata-token: ${aws_token}" \
      -s http://169.254.169.254/latest/meta-data/instance-id
  )"

  log "  Setting the http-put-response-hop-limit to: ${1}"

  aws ec2 modify-instance-metadata-options \
    --instance-id "${ec2_instance_id}" \
    --http-tokens required \
    --http-endpoint enabled \
    --http-put-response-hop-limit "${1}" \
    >/dev/null 2>&1
}

wait_for_tfe_service() {
  log "  Checking the status of the TFE service."
  while ! docker compose -f /run/terraform-enterprise/docker-compose.yml exec tfe /usr/local/bin/tfectl app status >/dev/null 2>&1; do
    log "    Waiting for TFE to come online..."
    sleep 1
  done
}

wait_for_tfe_nodes() {
  log "  Checking the status of the TFE nodes."
  while docker compose -f /run/terraform-enterprise/docker-compose.yml exec tfe /usr/local/bin/tfectl node list |
    grep -q "No active nodes"; do
    log "    Waiting for an active TFE node..."
    sleep 1
  done
}

get_tfe_admin_token_url() {
  docker compose -f /run/terraform-enterprise/docker-compose.yml exec tfe /usr/local/bin/tfectl admin token --url
}

main() {
  # Globally disable globbing and enable exit-on-error.
  set -ef

  # Colors are automatically disabled if output is being used in a
  # pipe/redirection.
  ! [ -t 2 ] || {
    c1='\033[1;33m'
    c2='\033[1;34m'
    c3='\033[m'
  }

  # The default username assigned to UID 1000 in AWS EC2 instances.
  username="admin"

  log "Populating configuration variables."

  # FQDNs
  rds_fqdn="$(get_ssm_parameter_value "/TFE/RDS-FQDN")"
  tfe_fqdn="$(get_ssm_parameter_value "/TFE/TFE-FQDN")"

  # S3 Configuration
  s3_region="$(get_ssm_parameter_value "/TFE/S3-Region")"
  s3_bucket_id="$(get_ssm_parameter_value "/TFE/S3-Bucket-ID")"

  # TFE Database Configuration
  tfe_db_name="$(get_ssm_parameter_value "/TFE/DB-Name")"
  tfe_db_username="$(get_ssm_parameter_value "/TFE/DB-Username")"
  tfe_db_password="$(get_ssm_parameter_value "/TFE/DB-Password")"
  postgresql_major_version="$(get_ssm_parameter_value "/TFE/PostgreSQL-Major-Version")"

  # TFE Application Configuration
  tfe_license="$(get_ssm_parameter_value "/TFE/License")"
  tfe_version="$(get_ssm_parameter_value "/TFE/Version")"
  tfe_encryption_password="$(get_ssm_parameter_value "/TFE/Encryption-Password")"

  # Wait for the network to be available.
  wait_for_network

  # Update the system and install required utilities.
  upgrade_system
  install_packages apt-transport-https ca-certificates curl gnupg unzip jq

  log "Setting up the PostgreSQL client."

  # Setup Postgres' APT repository.
  curl -fsSL "https://www.postgresql.org/media/keys/ACCC4CF8.asc" |
    gpg --yes --dearmor -o "/usr/share/keyrings/postgresql.gpg"

  chmod a+r /usr/share/keyrings/postgresql.gpg

  cat <<'EOF' >/etc/apt/sources.list.d/postgresql.sources
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: bookworm-pgdg
Components: main
arch: amd64
signed-by: /usr/share/keyrings/postgresql.gpg
EOF

  # Install the PostgreSQL CLI tool.
  install_packages "postgresql-client-${postgresql_major_version}"

  log "Preparing to connect to the RDS instance."

  # Grab the RDS credentials and configuration.
  rds_master_password_secret="$(find_secretsmanager_secret "rds!")"

  rds_master_username="$(
    get_secretsmanager_secret_value "${rds_master_password_secret}" |
      jq -r '.username'
  )"

  rds_master_password="$(
    get_secretsmanager_secret_value "${rds_master_password_secret}" |
      jq -r '.password'
  )"

  # Convenience function to execute SQL queries against the RDS instance, within
  # main() to use the configuration already captured.
  execute_sql() {
    PGPASSWORD="${rds_master_password}" psql \
      -h "${rds_fqdn}" \
      -p 5432 \
      -U "${rds_master_username}" \
      -d "${tfe_db_name}" \
      -c "${1}" \
      >/dev/null 2>&1
  }

  log "Checking RDS connectivity."

  while ! execute_sql "SHOW server_version;" >/dev/null 2>&1; do
    log "  Waiting for the RDS database to come online..."
    sleep 1
  done

  log "Configuring a regular user for the TFE PostgreSQL database."

  execute_sql "CREATE USER ${tfe_db_username} WITH PASSWORD '${tfe_db_password}'" || true
  execute_sql "GRANT ALL PRIVILEGES ON DATABASE ${tfe_db_name} TO ${tfe_db_username}" || true
  execute_sql "ALTER DATABASE ${tfe_db_name} OWNER TO ${tfe_db_username}" || true

  log "Setting up Docker."

  # Setup Docker's APT repository.
  curl -fsSL "https://download.docker.com/linux/debian/gpg" |
    gpg --yes --dearmor -o "/usr/share/keyrings/docker.gpg"

  chmod a+r /usr/share/keyrings/docker.gpg

  cat <<'EOF' >/etc/apt/sources.list.d/docker.sources
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: bookworm
Components: stable
arch: amd64
signed-by: /usr/share/keyrings/docker.gpg
EOF

  # Enable ipv4 forwarding, required on CIS hardened machines.
  sysctl net.ipv4.conf.all.forwarding=1 >/dev/null 2>&1
  # Persist this configuration after reboot.
  cat <<'EOF' >/etc/sysctl.d/enabled_ipv4_forwarding.conf
net.ipv4.conf.all.forwarding=1
EOF

  install_packages docker-ce docker-ce-cli

  # Add the admin user to the docker group (created automatically as part of install).
  usermod -aG docker "${username}"

  log "Setting up a TLS certificate."

  # A TLS certificate is generated to satisfy TFE startup requirements, however the
  # main TLS termination is done at the load balancer with a certificate managed by
  # AWS.
  mkdir -p /etc/ssl/private/terraform-enterprise

  if [ ! -f "/etc/ssl/private/terraform-enterprise/cert.pem" ]; then
    openssl req -x509 \
      -nodes \
      -newkey rsa:4096 \
      -keyout /etc/ssl/private/terraform-enterprise/key.pem \
      -out /etc/ssl/private/terraform-enterprise/cert.pem \
      -sha256 -days 365 \
      -subj "/C=CA/O=HashiCorp/CN=${tfe_fqdn}" \
      >/dev/null 2>&1
  fi

  cp /etc/ssl/private/terraform-enterprise/cert.pem /etc/ssl/private/terraform-enterprise/bundle.pem

  log "Setting the EC2 HTTP PUT response hop limit."

  # Set the `http-put-response-hop-limit` option to a value of 2 or greater.
  #
  # This is to facilitate Terraform Enterprise running in a containter since
  # it looks up the instance profile on startup when external object storage
  # has been configured.
  set_ec2_http_put_response_hop_limit 2

  log "Generating the /run/terraform-enterprise/docker-compose.yml file."

  mkdir -p /var/lib/terraform-enterprise
  mkdir -p /run/terraform-enterprise

  cat <<EOF >/run/terraform-enterprise/docker-compose.yml
---
name: terraform-enterprise
services:
  tfe:
    image: "images.releases.hashicorp.com/hashicorp/terraform-enterprise:${tfe_version}"
    environment:
      TFE_LICENSE: "${tfe_license}"
      TFE_HOSTNAME: "${tfe_fqdn}"
      TFE_ENCRYPTION_PASSWORD: "${tfe_encryption_password}"
      TFE_OPERATIONAL_MODE: "external"
      TFE_DISK_CACHE_VOLUME_NAME: "terraform-enterprise-cache"
      TFE_TLS_CERT_FILE: "/etc/ssl/private/terraform-enterprise/cert.pem"
      TFE_TLS_KEY_FILE: "/etc/ssl/private/terraform-enterprise/key.pem"
      TFE_TLS_CA_BUNDLE_FILE: "/etc/ssl/private/terraform-enterprise/bundle.pem"
      TFE_IACT_SUBNETS: "10.0.0.0/16"
      # Database
      TFE_DATABASE_HOST: "${rds_fqdn}"
      TFE_DATABASE_NAME: "${tfe_db_name}"
      TFE_DATABASE_USER: "${tfe_db_username}"
      TFE_DATABASE_PASSWORD: "${tfe_db_password}"
      # Object Storage
      TFE_OBJECT_STORAGE_TYPE: "s3"
      TFE_OBJECT_STORAGE_S3_USE_INSTANCE_PROFILE: "true"
      TFE_OBJECT_STORAGE_S3_REGION: "${s3_region}"
      TFE_OBJECT_STORAGE_S3_BUCKET: "${s3_bucket_id}"
    cap_add:
      - IPC_LOCK
    read_only: true
    tmpfs:
      - /tmp:mode=01777
      - /run
      - /var/log/terraform-enterprise
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /run/docker.sock
      - type: bind
        source: /etc/ssl/private/terraform-enterprise
        target: /etc/ssl/private/terraform-enterprise
      - type: bind
        source: /var/lib/terraform-enterprise
        target: /var/lib/terraform-enterprise
      - type: volume
        source: terraform-enterprise-cache
        target: /var/cache/tfe-task-worker/terraform
volumes:
  terraform-enterprise-cache:
EOF

  log "Pulling Terraform Enterprise ${tfe_version} from the HashiCorp Docker registry."

  printf '%s\n' "${tfe_license}" |
    docker login --username terraform images.releases.hashicorp.com --password-stdin \
      >/dev/null 2>&1

  docker pull "images.releases.hashicorp.com/hashicorp/terraform-enterprise:${tfe_version}" \
    >/dev/null 2>&1

  log "Generating the /etc/systemd/system/terraform-enterprise.service file."

  cat <<'EOF' >/etc/systemd/system/terraform-enterprise.service
[Unit]
Description=Terraform Enterprise Service
Requires=docker.service
After=docker.service network.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/run/terraform-enterprise
ExecStart=/usr/bin/docker compose up --detach
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  log "Starting terraform-enterprise.service."

  systemctl daemon-reload
  systemctl enable --now terraform-enterprise.service

  # Wait for TFE to come online.
  wait_for_tfe_service
  wait_for_tfe_nodes

  # Put the Admin Token URL in the Parameter Store for convenience.
  set_ssm_parameter_value "/TFE/Admin-Token-URL" get_tfe_admin_token_url
}

main "$@"
