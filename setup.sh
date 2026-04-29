#!/usr/bin/env bash

set -Eeuo pipefail

# ==============================================================================
# HCD / Mission Control workshop setup on IBM Cloud IKS
#
# This script:
#   1. Checks required tools
#   2. Logs into IBM Cloud
#   3. Installs IBM Cloud plugins
#   4. Creates or reuses VPC, public gateway, subnet, IKS cluster
#   5. Configures kubectl
#   6. Disables outbound traffic protection
#   7. Installs or upgrades cert-manager
#   8. Discovers IBM COS / watsonx.data bucket
#   9. Creates or reuses COS HMAC credentials
#  10. Logs into Replicated Helm registry
#  11. Creates Mission Control Helm values with Dex username/password
#  12. Installs or upgrades Mission Control
#  13. Optionally creates a demo HCD database using MissionControlCluster YAML
#
# Re-runnable:
#   - Existing VPC/subnet/public gateway/cluster are reused.
#   - Existing COS HMAC service key is reused.
#   - Existing Helm releases are upgraded.
#   - Existing Kubernetes secrets are applied idempotently.
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh --domain banking --mission-control-license "Input"
#
# Optional:
#   ./setup.sh --phase platform --domain banking
#   ./setup.sh --phase domain --domain banking
#   CLEAN_MC=true ./setup.sh              # deletes Mission Control namespace/release first
#   CLEAN_DEMO_DB=true ./setup.sh         # deletes demo DB namespace first
#   CREATE_DEMO_DB=false ./setup.sh       # skip demo DB creation
# ==============================================================================

if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

# ------------------------------------------------------------------------------
# Defaults - override by exporting variables before running the script
# ------------------------------------------------------------------------------

REGION="${REGION:-eu-de}"
ZONE="${ZONE:-eu-de-1}"
RG="${RG:-itz-wxd-69f1c82604915752070c1b}"
PREFIX="${PREFIX:-hcd-student-69f1c82604}"

VPC_NAME="${VPC_NAME:-${PREFIX}-vpc}"
SUBNET_NAME="${SUBNET_NAME:-${PREFIX}-subnet}"
PGW_NAME="${PGW_NAME:-${PREFIX}-pgw}"
CLUSTER_NAME="${CLUSTER_NAME:-${PREFIX}-iks}"

WORKER_FLAVOR="${WORKER_FLAVOR:-bx2.4x16}"
WORKER_COUNT="${WORKER_COUNT:-3}"

BUCKET_PREFIX="${BUCKET_PREFIX:-watsonx-data-}"

MC_NAMESPACE="${MC_NAMESPACE:-mission-control}"
MC_RELEASE="${MC_RELEASE:-mission-control}"
MC_CHART="${MC_CHART:-oci://registry.replicated.com/mission-control/mission-control}"
MC_CHART_VERSION="${MC_CHART_VERSION:-}"

MC_ADMIN_USER="${MC_ADMIN_USER:-admin}"
MC_ADMIN_EMAIL="${MC_ADMIN_EMAIL:-admin@local}"
MC_ADMIN_PASSWORD="${MC_ADMIN_PASSWORD:-Password123!}"
MC_ADMIN_USER_ID="${MC_ADMIN_USER_ID:-9f35c506-cac8-4d4d-8e66-05c55624624b}"

LOKI_SECRET_NAME="${LOKI_SECRET_NAME:-loki-s3-secrets}"

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.1}"

CREATE_DEMO_DB="${CREATE_DEMO_DB:-true}"
CLEAN_MC="${CLEAN_MC:-false}"
CLEAN_DEMO_DB="${CLEAN_DEMO_DB:-false}"

DEMO_NAMESPACE="${DEMO_NAMESPACE:-sample-2p43q6vg}"
DEMO_CLUSTER_NAME="${DEMO_CLUSTER_NAME:-demo}"
DEMO_STORAGE_CLASS="${DEMO_STORAGE_CLASS:-ibmc-vpc-block-10iops-tier}"
DEMO_SUPERUSER_NAME="${DEMO_SUPERUSER_NAME:-demo-superuser}"
DEMO_SUPERUSER_PASSWORD="${DEMO_SUPERUSER_PASSWORD:-Password123!}"
DEMO_HCD_VERSION="${DEMO_HCD_VERSION:-1.2.5}"
DEMO_STORAGE_SIZE="${DEMO_STORAGE_SIZE:-2Gi}"

COS_HMAC_ROLE="${COS_HMAC_ROLE:-Writer}"
COS_HMAC_KEY_NAME="${COS_HMAC_KEY_NAME:-${PREFIX}-cos-hmac}"

ENV_FILE=".env.setup"
COS_ENV_FILE=".env.cos"
COS_HMAC_ENV_FILE=".env.cos.hmac"

DOMAIN="${DOMAIN:-banking}"
PHASE="${PHASE:-all}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN_DIR=""
DOMAIN_DESCRIPTOR=""

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

log() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "================================================================================"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    echo "Please install it and re-run."
    exit 1
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  ./setup.sh --domain banking --mission-control-license "Input" [--phase all|platform|domain]

Options:
  --domain <domain>                    Domain descriptor under domains/<domain>/domain.yaml.
  --mission-control-license <license>  Mission Control / Replicated license ID.
  --phase <phase>                      all, platform, or domain. Default: all.
  -h, --help                           Show this help.

Environment variables are still supported for existing workshop settings.
Secrets belong in local .env.* files or Kubernetes Secrets, not in Git.
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --domain)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Missing value for --domain"
          usage
          exit 1
        fi
        DOMAIN="$2"
        shift 2
        ;;
      --mission-control-license)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Missing value for --mission-control-license"
          usage
          exit 1
        fi
        MC_LICENSE_ID="$2"
        export MC_LICENSE_ID
        shift 2
        ;;
      --phase)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
          echo "Missing value for --phase"
          usage
          exit 1
        fi
        PHASE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

validate_args() {
  case "$DOMAIN" in
    ""|*/*|*..*|.*)
      echo "Invalid domain: $DOMAIN"
      exit 1
      ;;
  esac

  case "$PHASE" in
    all|platform|domain)
      ;;
    *)
      echo "Invalid phase: $PHASE"
      usage
      exit 1
      ;;
  esac

  DOMAIN_DIR="$ROOT_DIR/domains/$DOMAIN"
  DOMAIN_DESCRIPTOR="$DOMAIN_DIR/domain.yaml"

  if [ ! -f "$DOMAIN_DESCRIPTOR" ]; then
    echo "Domain descriptor not found: $DOMAIN_DESCRIPTOR"
    echo "Create domains/$DOMAIN/domain.yaml or choose a supported domain."
    exit 1
  fi
}

ask_if_empty() {
  local var_name="$1"
  local prompt="$2"
  local secret="${3:-false}"
  local current_value="${!var_name:-}"

  if [ -z "$current_value" ]; then
    if [ "$secret" = "true" ]; then
      read -r -s -p "$prompt: " value
      echo
    else
      read -r -p "$prompt: " value
    fi
    export "$var_name=$value"
  fi
}

wait_for_namespace_deleted() {
  local ns="$1"
  for i in {1..60}; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      return 0
    fi
    echo "Waiting for namespace $ns to be deleted..."
    sleep 10
  done

  echo "Namespace $ns still exists after waiting."
  exit 1
}

wait_for_iks_ready() {
  log "Waiting for IKS workers to become Ready"

  for i in {1..90}; do
    ibmcloud ks cluster get --cluster "$CLUSTER_NAME" || true
    ibmcloud ks workers --cluster "$CLUSTER_NAME" || true

    local ready_count
    ready_count="$(ibmcloud ks workers --cluster "$CLUSTER_NAME" --output json 2>/dev/null \
      | jq '[.[] | select((.health.state // .health.message // .state // "") | tostring | test("normal|Ready|ready"; "i"))] | length' || echo 0)"

    if [ "$ready_count" -ge "$WORKER_COUNT" ]; then
      echo "IKS workers appear ready."
      return 0
    fi

    echo "Workers not ready yet. Sleeping 60s..."
    sleep 60
  done

  echo "Timed out waiting for IKS workers."
  exit 1
}

parse_args "$@"
validate_args

if [ "$PHASE" = "platform" ]; then
  CREATE_DEMO_DB="false"
fi

if [ "$PHASE" = "domain" ]; then
  log "Domain deployment phase"
  echo "Domain: $DOMAIN"
  echo "Descriptor: $DOMAIN_DESCRIPTOR"
  echo "Domain deployment manifests and jobs will be implemented in the next increment."
  exit 0
fi

helm_install_or_upgrade() {
  local release="$1"
  local namespace="$2"
  local chart="$3"
  local values="$4"
  local timeout="${5:-30m}"

  if helm status "$release" -n "$namespace" >/dev/null 2>&1; then
    if [ -n "${MC_CHART_VERSION:-}" ]; then
      helm upgrade "$release" "$chart" \
        --version "$MC_CHART_VERSION" \
        --namespace "$namespace" \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    else
      helm upgrade "$release" "$chart" \
        --namespace "$namespace" \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    fi
  else
    if [ -n "${MC_CHART_VERSION:-}" ]; then
      helm install "$release" "$chart" \
        --version "$MC_CHART_VERSION" \
        --namespace "$namespace" \
        --create-namespace \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    else
      helm install "$release" "$chart" \
        --namespace "$namespace" \
        --create-namespace \
        -f "$values" \
        --wait \
        --timeout "$timeout" \
        --debug
    fi
  fi
}

# ------------------------------------------------------------------------------
# 1. Check tools
# ------------------------------------------------------------------------------

log "Checking required tools"

need_cmd ibmcloud
need_cmd jq
need_cmd kubectl
need_cmd helm
need_cmd base64

# ------------------------------------------------------------------------------
# 2. Inputs
# ------------------------------------------------------------------------------

log "Collecting inputs"

ask_if_empty "MC_LICENSE_ID" "Enter Mission Control / Replicated license ID" true

echo "Using:"
echo "DOMAIN=$DOMAIN"
echo "PHASE=$PHASE"
echo "DOMAIN_DESCRIPTOR=$DOMAIN_DESCRIPTOR"
echo "REGION=$REGION"
echo "ZONE=$ZONE"
echo "RG=$RG"
echo "PREFIX=$PREFIX"
echo "VPC_NAME=$VPC_NAME"
echo "SUBNET_NAME=$SUBNET_NAME"
echo "PGW_NAME=$PGW_NAME"
echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "MC_NAMESPACE=$MC_NAMESPACE"
echo "MC_RELEASE=$MC_RELEASE"
echo "MC_ADMIN_USER=$MC_ADMIN_USER"
echo "MC_ADMIN_EMAIL=$MC_ADMIN_EMAIL"
echo "CREATE_DEMO_DB=$CREATE_DEMO_DB"
echo "DEMO_NAMESPACE=$DEMO_NAMESPACE"
echo "DEMO_STORAGE_CLASS=$DEMO_STORAGE_CLASS"

cat > "$ENV_FILE" <<ENVEOF
export DOMAIN="$DOMAIN"
export PHASE="$PHASE"
export REGION="$REGION"
export ZONE="$ZONE"
export RG="$RG"
export PREFIX="$PREFIX"
export VPC_NAME="$VPC_NAME"
export SUBNET_NAME="$SUBNET_NAME"
export PGW_NAME="$PGW_NAME"
export CLUSTER_NAME="$CLUSTER_NAME"
export WORKER_FLAVOR="$WORKER_FLAVOR"
export WORKER_COUNT="$WORKER_COUNT"
export MC_NAMESPACE="$MC_NAMESPACE"
export MC_RELEASE="$MC_RELEASE"
export MC_ADMIN_USER="$MC_ADMIN_USER"
export MC_ADMIN_EMAIL="$MC_ADMIN_EMAIL"
export DEMO_NAMESPACE="$DEMO_NAMESPACE"
export DEMO_CLUSTER_NAME="$DEMO_CLUSTER_NAME"
export DEMO_STORAGE_CLASS="$DEMO_STORAGE_CLASS"
ENVEOF

# ------------------------------------------------------------------------------
# 3. IBM Cloud login and plugins
# ------------------------------------------------------------------------------

log "Logging into IBM Cloud"

if ! ibmcloud target >/dev/null 2>&1; then
  ibmcloud login --sso -r "$REGION"
else
  ibmcloud target -r "$REGION" || ibmcloud login --sso -r "$REGION"
fi

ibmcloud target -g "$RG"
ibmcloud target
ibmcloud is target --gen 2

log "Installing IBM Cloud plugins"

ibmcloud plugin install container-service -f
ibmcloud plugin install container-registry -f
ibmcloud plugin install vpc-infrastructure -f
ibmcloud plugin install cloud-object-storage -f
ibmcloud plugin list

# ------------------------------------------------------------------------------
# 4. VPC
# ------------------------------------------------------------------------------

log "Creating or reusing VPC"

VPC_ID="$(
  ibmcloud is vpcs --output json \
    | jq -r --arg name "$VPC_NAME" '.[] | select(.name == $name) | .id' \
    | head -n 1
)"

if [ -z "$VPC_ID" ]; then
  ibmcloud is vpc-create "$VPC_NAME" --resource-group-name "$RG"
  VPC_ID="$(
    ibmcloud is vpcs --output json \
      | jq -r --arg name "$VPC_NAME" '.[] | select(.name == $name) | .id' \
      | head -n 1
  )"
fi

test -n "$VPC_ID"
echo "VPC_ID=$VPC_ID"

# ------------------------------------------------------------------------------
# 5. Public Gateway
# ------------------------------------------------------------------------------

log "Creating or reusing public gateway"

PGW_ID="$(
  ibmcloud is public-gateways --output json \
    | jq -r --arg name "$PGW_NAME" '.[] | select(.name == $name) | .id' \
    | head -n 1
)"

if [ -z "$PGW_ID" ]; then
  ibmcloud is public-gateway-create "$PGW_NAME" "$VPC_ID" "$ZONE" \
    --resource-group-name "$RG"

  PGW_ID="$(
    ibmcloud is public-gateways --output json \
      | jq -r --arg name "$PGW_NAME" '.[] | select(.name == $name) | .id' \
      | head -n 1
  )"
fi

test -n "$PGW_ID"
echo "PGW_ID=$PGW_ID"

# ------------------------------------------------------------------------------
# 6. Subnet
# ------------------------------------------------------------------------------

log "Creating or reusing subnet"

SUBNET_ID="$(
  ibmcloud is subnets --output json \
    | jq -r --arg name "$SUBNET_NAME" '.[] | select(.name == $name) | .id' \
    | head -n 1
)"

if [ -z "$SUBNET_ID" ]; then
  ibmcloud is subnet-create "$SUBNET_NAME" \
    "$VPC_ID" \
    --zone "$ZONE" \
    --ipv4-address-count 256 \
    --public-gateway-id "$PGW_ID" \
    --resource-group-name "$RG"

  SUBNET_ID="$(
    ibmcloud is subnets --output json \
      | jq -r --arg name "$SUBNET_NAME" '.[] | select(.name == $name) | .id' \
      | head -n 1
  )"
fi

test -n "$SUBNET_ID"
echo "SUBNET_ID=$SUBNET_ID"

cat >> "$ENV_FILE" <<ENVEOF
export VPC_ID="$VPC_ID"
export PGW_ID="$PGW_ID"
export SUBNET_ID="$SUBNET_ID"
ENVEOF

ibmcloud is vpcs
ibmcloud is public-gateways
ibmcloud is subnets

# ------------------------------------------------------------------------------
# 7. IKS cluster
# ------------------------------------------------------------------------------

log "Creating or reusing IKS cluster"

if ibmcloud ks cluster get --cluster "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Cluster already exists: $CLUSTER_NAME"
else
  ibmcloud ks flavors --zone "$ZONE"

  ibmcloud ks cluster create vpc-gen2 \
    --name "$CLUSTER_NAME" \
    --flavor "$WORKER_FLAVOR" \
    --workers "$WORKER_COUNT" \
    --vpc-id "$VPC_ID" \
    --subnet-id "$SUBNET_ID" \
    --zone "$ZONE"
fi

wait_for_iks_ready

# ------------------------------------------------------------------------------
# 8. kubectl config
# ------------------------------------------------------------------------------

log "Configuring kubectl"

ibmcloud ks cluster config --cluster "$CLUSTER_NAME"

kubectl get nodes -o wide

# ------------------------------------------------------------------------------
# 9. Disable outbound traffic protection
# ------------------------------------------------------------------------------

log "Disabling outbound traffic protection"

ibmcloud ks vpc outbound-traffic-protection disable --cluster "$CLUSTER_NAME" || true
ibmcloud ks cluster get --cluster "$CLUSTER_NAME" | grep -i "Outbound Traffic Protection" || true

# Optional connectivity test. Do not fail the whole script if it flakes.
kubectl run curl-test \
  --image=curlimages/curl \
  --rm -it \
  --restart=Never \
  -- curl -I https://quay.io || true

# ------------------------------------------------------------------------------
# 10. cert-manager
# ------------------------------------------------------------------------------

log "Installing or upgrading cert-manager"

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

if helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  helm upgrade cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --set 'extraArgs[0]=--enable-certificate-owner-ref=true' \
    --wait \
    --timeout 10m \
    --debug
else
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "$CERT_MANAGER_VERSION" \
    --set crds.enabled=true \
    --set 'extraArgs[0]=--enable-certificate-owner-ref=true' \
    --wait \
    --timeout 10m \
    --debug
fi

helm list -n cert-manager
kubectl get pods -n cert-manager
kubectl get jobs -n cert-manager || true

# ------------------------------------------------------------------------------
# 11. Discover COS / watsonx.data bucket
# ------------------------------------------------------------------------------

log "Discovering IBM COS / watsonx.data bucket"

ibmcloud target -g "$RG"

COS_INSTANCE_JSON="$(
  ibmcloud resource service-instances \
    --service-name cloud-object-storage \
    --output json
)"

COS_INSTANCE_NAME="$(
  echo "$COS_INSTANCE_JSON" | jq -r '.[0].name'
)"

COS_INSTANCE_CRN="$(
  echo "$COS_INSTANCE_JSON" | jq -r '.[0].crn'
)"

COS_INSTANCE_GUID="$(
  echo "$COS_INSTANCE_JSON" | jq -r '.[0].guid'
)"

test -n "$COS_INSTANCE_NAME"
test -n "$COS_INSTANCE_CRN"
test -n "$COS_INSTANCE_GUID"

ibmcloud cos config crn --crn "$COS_INSTANCE_CRN"

COS_BUCKET="$(
  ibmcloud cos buckets --output json \
    | jq -r --arg prefix "$BUCKET_PREFIX" '.Buckets[]?.Name | select(startswith($prefix))' \
    | head -n 1
)"

if [ -z "$COS_BUCKET" ]; then
  echo "Could not discover COS bucket with prefix: $BUCKET_PREFIX"
  echo "Available buckets:"
  ibmcloud cos buckets
  exit 1
fi

COS_ENDPOINT="https://s3.direct.${REGION}.cloud-object-storage.appdomain.cloud"
COS_REGION="$REGION"

cat > "$COS_ENV_FILE" <<COSEOF
export COS_INSTANCE_NAME="$COS_INSTANCE_NAME"
export COS_INSTANCE_CRN="$COS_INSTANCE_CRN"
export COS_INSTANCE_GUID="$COS_INSTANCE_GUID"
export COS_BUCKET="$COS_BUCKET"
export COS_ENDPOINT="$COS_ENDPOINT"
export COS_REGION="$COS_REGION"
COSEOF

echo "COS_INSTANCE_NAME=$COS_INSTANCE_NAME"
echo "COS_INSTANCE_CRN=$COS_INSTANCE_CRN"
echo "COS_INSTANCE_GUID=$COS_INSTANCE_GUID"
echo "COS_BUCKET=$COS_BUCKET"
echo "COS_ENDPOINT=$COS_ENDPOINT"
echo "COS_REGION=$COS_REGION"

# ------------------------------------------------------------------------------
# 12. COS HMAC credentials
# ------------------------------------------------------------------------------

log "Creating or reusing COS HMAC credentials"

if ibmcloud resource service-key "$COS_HMAC_KEY_NAME" >/dev/null 2>&1; then
  echo "Service key already exists: $COS_HMAC_KEY_NAME"
else
  ibmcloud resource service-key-create "$COS_HMAC_KEY_NAME" "$COS_HMAC_ROLE" \
    --instance-name "$COS_INSTANCE_NAME" \
    --parameters '{"HMAC":true}'
fi

COS_ACCESS_KEY_ID="$(
  ibmcloud resource service-key "$COS_HMAC_KEY_NAME" --output json \
    | jq -r '.[0].credentials.cos_hmac_keys.access_key_id'
)"

COS_SECRET_ACCESS_KEY="$(
  ibmcloud resource service-key "$COS_HMAC_KEY_NAME" --output json \
    | jq -r '.[0].credentials.cos_hmac_keys.secret_access_key'
)"

test -n "$COS_ACCESS_KEY_ID"
test -n "$COS_SECRET_ACCESS_KEY"

cat > "$COS_HMAC_ENV_FILE" <<HMACEOF
export COS_ACCESS_KEY_ID="$COS_ACCESS_KEY_ID"
export COS_SECRET_ACCESS_KEY="$COS_SECRET_ACCESS_KEY"
export COS_HMAC_KEY_NAME="$COS_HMAC_KEY_NAME"
HMACEOF

echo "COS_ACCESS_KEY_ID length: ${#COS_ACCESS_KEY_ID}"
echo "COS_SECRET_ACCESS_KEY length: ${#COS_SECRET_ACCESS_KEY}"

# ------------------------------------------------------------------------------
# 13. Namespace and reusable COS secret
# ------------------------------------------------------------------------------

log "Creating Mission Control namespace and COS secrets"

kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hcd-cos-s3-credentials \
  --namespace "$MC_NAMESPACE" \
  --from-literal=accessKeyId="$COS_ACCESS_KEY_ID" \
  --from-literal=secretAccessKey="$COS_SECRET_ACCESS_KEY" \
  --from-literal=bucket="$COS_BUCKET" \
  --from-literal=endpoint="$COS_ENDPOINT" \
  --from-literal=region="$COS_REGION" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$MC_NAMESPACE" create secret generic "$LOKI_SECRET_NAME" \
  --from-literal=s3-access-key-id="$COS_ACCESS_KEY_ID" \
  --from-literal=s3-secret-access-key="$COS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl get secret hcd-cos-s3-credentials -n "$MC_NAMESPACE"
kubectl get secret "$LOKI_SECRET_NAME" -n "$MC_NAMESPACE"

# ------------------------------------------------------------------------------
# 14. Helm registry login
# ------------------------------------------------------------------------------

log "Configuring Helm registry auth"

HELM_REGISTRY_CONFIG="$(
  helm env | awk -F= '/HELM_REGISTRY_CONFIG/ {gsub(/"/, "", $2); print $2}'
)"

mkdir -p "$(dirname "$HELM_REGISTRY_CONFIG")"

if [ ! -f "$HELM_REGISTRY_CONFIG" ] || grep -q "credsStore" "$HELM_REGISTRY_CONFIG"; then
  cat > "$HELM_REGISTRY_CONFIG" <<REGEOF
{
  "auths": {}
}
REGEOF
fi

cat "$HELM_REGISTRY_CONFIG"

printf '%s' "$MC_LICENSE_ID" | helm registry login registry.replicated.com \
  --username "$MC_LICENSE_ID" \
  --password-stdin \
  --debug

# ------------------------------------------------------------------------------
# 15. Generate Dex bcrypt hash using Kubernetes, not local Docker/Podman/Python
# ------------------------------------------------------------------------------

log "Generating Dex bcrypt hash"

kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

MC_ADMIN_HASH="$(
  kubectl run bcrypt-hash \
    -n "$MC_NAMESPACE" \
    --image=httpd:2.4-alpine \
    --restart=Never \
    --rm -i \
    --quiet \
    --command -- htpasswd -bnBC 10 "" "$MC_ADMIN_PASSWORD" \
    | tr -d ':\r\n'
)"

if [ -z "$MC_ADMIN_HASH" ]; then
  echo "Failed to generate bcrypt hash."
  exit 1
fi

echo "Generated Dex bcrypt hash length: ${#MC_ADMIN_HASH}"

# ------------------------------------------------------------------------------
# 16. Generate Mission Control Helm values
# ------------------------------------------------------------------------------

log "Generating mission-control-values.yaml"

cat > mission-control-values.yaml <<MCEOF
controlPlane: true
disableCertManagerCheck: true

ui:
  enabled: true
  https:
    enabled: true
  ingress:
    enabled: false

grafana:
  enabled: true

dex:
  config:
    enablePasswordDB: true
    staticPasswords:
      - email: ${MC_ADMIN_EMAIL}
        hash: "${MC_ADMIN_HASH}"
        username: ${MC_ADMIN_USER}
        userID: ${MC_ADMIN_USER_ID}

loki:
  enabled: true

  loki:
    commonConfig:
      replication_factor: 1

    schemaConfig:
      configs:
        - from: "2024-04-01"
          store: tsdb
          object_store: s3
          schema: v13
          index:
            prefix: index_
            period: 24h

    storage:
      type: s3
      bucketNames:
        chunks: ${COS_BUCKET}
        ruler: ${COS_BUCKET}
        admin: ${COS_BUCKET}
      s3:
        accessKeyId: "\${AWS_ACCESS_KEY_ID}"
        secretAccessKey: "\${AWS_SECRET_ACCESS_KEY}"
        endpoint: ${COS_ENDPOINT}
        region: ${COS_REGION}
        insecure: false
        s3ForcePathStyle: true

    limits_config:
      retention_period: 7d

    compactor:
      retention_enabled: true
      delete_request_store: s3
      working_directory: /var/loki/retention

  backend:
    replicas: 1
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: ""
    extraArgs:
      - "-config.expand-env=true"
    extraEnv:
      - name: AWS_ACCESS_KEY_ID
        valueFrom:
          secretKeyRef:
            name: ${LOKI_SECRET_NAME}
            key: s3-access-key-id
      - name: AWS_SECRET_ACCESS_KEY
        valueFrom:
          secretKeyRef:
            name: ${LOKI_SECRET_NAME}
            key: s3-secret-access-key

  read:
    replicas: 1
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: ""

  write:
    replicas: 1
    persistence:
      enabled: true
      size: 10Gi
      storageClassName: ""

mimir:
  enabled: false

minio:
  enabled: false
MCEOF

grep -n "dex:" -A15 mission-control-values.yaml
grep -n "loki:" -A120 mission-control-values.yaml

# ------------------------------------------------------------------------------
# 17. Optional clean Mission Control
# ------------------------------------------------------------------------------

if [ "$CLEAN_MC" = "true" ]; then
  log "Cleaning existing Mission Control deployment"

  helm uninstall "$MC_RELEASE" -n "$MC_NAMESPACE" --debug || true
  kubectl delete namespace "$MC_NAMESPACE" --ignore-not-found
  wait_for_namespace_deleted "$MC_NAMESPACE"

  kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$MC_NAMESPACE" create secret generic "$LOKI_SECRET_NAME" \
    --from-literal=s3-access-key-id="$COS_ACCESS_KEY_ID" \
    --from-literal=s3-secret-access-key="$COS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic hcd-cos-s3-credentials \
    --namespace "$MC_NAMESPACE" \
    --from-literal=accessKeyId="$COS_ACCESS_KEY_ID" \
    --from-literal=secretAccessKey="$COS_SECRET_ACCESS_KEY" \
    --from-literal=bucket="$COS_BUCKET" \
    --from-literal=endpoint="$COS_ENDPOINT" \
    --from-literal=region="$COS_REGION" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ------------------------------------------------------------------------------
# 18. Render and validate Helm chart
# ------------------------------------------------------------------------------

log "Rendering Mission Control Helm chart"

HELM_VERSION_ARG=""

if [ -n "${MC_CHART_VERSION:-}" ]; then
  HELM_VERSION_ARG="--version ${MC_CHART_VERSION}"
fi

# shellcheck disable=SC2086
helm template "$MC_RELEASE" \
  oci://registry.replicated.com/mission-control/mission-control \
  --namespace "$MC_NAMESPACE" \
  -f mission-control-values.yaml \
  $HELM_VERSION_ARG \
  --debug > mc-rendered.yaml

grep -n "enablePasswordDB\|staticPasswords" mc-rendered.yaml -A20 -B10 || true
grep -n "object_store\|storage_config\|bucketnames\|s3forcepathstyle\|retention_period\|delete_request_store\|compactor" mc-rendered.yaml | head -120 || true

if ! grep -q "admin@local\|staticPasswords\|dex" mc-rendered.yaml; then
  echo "WARNING: Dex admin password config not obviously found in rendered chart. Continuing anyway."
fi

if ! grep -q "object_store: s3" mc-rendered.yaml; then
  echo "Loki validation failed: object_store: s3 not found in rendered chart."
  exit 1
fi

if ! grep -q "delete_request_store: s3" mc-rendered.yaml; then
  echo "Loki validation failed: delete_request_store: s3 not found in rendered chart."
  exit 1
fi

# ------------------------------------------------------------------------------
# 19. Install or upgrade Mission Control
# ------------------------------------------------------------------------------

log "Installing or upgrading Mission Control"

helm_install_or_upgrade "$MC_RELEASE" "$MC_NAMESPACE" "$MC_CHART" "mission-control-values.yaml" "30m"

helm status "$MC_RELEASE" -n "$MC_NAMESPACE" --debug
kubectl get pods -n "$MC_NAMESPACE"
kubectl get svc -n "$MC_NAMESPACE"

# ------------------------------------------------------------------------------
# 20. Verify Dex config
# ------------------------------------------------------------------------------

log "Verifying Dex config"

kubectl get secret mission-control-ui-dex-config \
  -n "$MC_NAMESPACE" \
  -o jsonpath='{.data.config\.yaml}' | base64 -d || true

echo

# ------------------------------------------------------------------------------
# 21. Optional demo HCD database
# ------------------------------------------------------------------------------

if [ "$CREATE_DEMO_DB" = "true" ]; then
  log "Creating demo HCD database"

  if [ "$CLEAN_DEMO_DB" = "true" ]; then
    kubectl delete missioncontrolcluster "$DEMO_CLUSTER_NAME" \
      -n "$DEMO_NAMESPACE" \
      --ignore-not-found || true

    kubectl delete namespace "$DEMO_NAMESPACE" --ignore-not-found || true
    wait_for_namespace_deleted "$DEMO_NAMESPACE"
  fi

  cat > demo-mc-cluster.yaml <<DBEOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${DEMO_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: demo-superuser
  namespace: ${DEMO_NAMESPACE}
type: Opaque
stringData:
  username: ${DEMO_SUPERUSER_NAME}
  password: ${DEMO_SUPERUSER_PASSWORD}
---
apiVersion: missioncontrol.datastax.com/v1beta2
kind: MissionControlCluster
metadata:
  name: ${DEMO_CLUSTER_NAME}
  namespace: ${DEMO_NAMESPACE}
spec:
  createIssuer: true

  dataApi:
    enabled: false

  encryption:
    internodeEncryption:
      enabled: true
      certs:
        createCerts: true

  k8ssandra:
    auth: true

    cassandra:
      serverType: hcd
      serverVersion: ${DEMO_HCD_VERSION}
      serverImage: ""

      superuserSecretRef:
        name: demo-superuser

      resources:
        requests:
          cpu: 1000m
          memory: 4Gi

      storageConfig:
        cassandraDataVolumeClaimSpec:
          accessModes:
            - ReadWriteOnce
          storageClassName: ${DEMO_STORAGE_CLASS}
          resources:
            requests:
              storage: ${DEMO_STORAGE_SIZE}

      config:
        jvmOptions:
          gc: G1GC
          heapSize: 1Gi
        cassandraYaml: {}
        dseYaml: {}

      datacenters:
        - datacenterName: dc-1
          k8sContext: ""
          size: 1
          stopped: false

          metadata:
            name: demo-dc-1
            pods: {}
            services:
              seedService: {}
              dcService: {}
              allPodsService: {}
              additionalSeedService: {}
              nodePortService: {}

          racks:
            - name: rk-01
              nodeAffinityLabels: {}

          dseWorkloads:
            searchEnabled: false
            graphEnabled: false

          config:
            cassandraYaml: {}
            dseYaml: {}

          networking: {}
          perNodeConfigMapRef: {}
DBEOF

  kubectl apply -f demo-mc-cluster.yaml

  kubectl get missioncontrolcluster -n "$DEMO_NAMESPACE"
  kubectl get k8ssandracluster -n "$DEMO_NAMESPACE" || true
  kubectl get cassdc -n "$DEMO_NAMESPACE" || true
  kubectl get pvc -n "$DEMO_NAMESPACE" || true
  kubectl get svc -n "$DEMO_NAMESPACE" || true
  kubectl get pods -n "$DEMO_NAMESPACE" || true
fi

# ------------------------------------------------------------------------------
# 22. Final validation
# ------------------------------------------------------------------------------

log "Final validation"

ibmcloud target
ibmcloud ks cluster get --cluster "$CLUSTER_NAME"
ibmcloud ks workers --cluster "$CLUSTER_NAME"

kubectl get nodes -o wide
kubectl get pods -n cert-manager
kubectl get pods -n "$MC_NAMESPACE"
helm status "$MC_RELEASE" -n "$MC_NAMESPACE" --debug

if [ "$CREATE_DEMO_DB" = "true" ]; then
  kubectl get missioncontrolcluster -n "$DEMO_NAMESPACE" || true
  kubectl get k8ssandracluster -n "$DEMO_NAMESPACE" || true
  kubectl get cassdc -n "$DEMO_NAMESPACE" || true
  kubectl get pvc -n "$DEMO_NAMESPACE" || true
  kubectl get pods -n "$DEMO_NAMESPACE" || true
fi

# ================================================================================
# Expose HCD/Cassandra CQL externally for watsonx.data Infrastructure Manager
# ================================================================================

echo "================================================================================"
echo "Creating external LoadBalancer service for HCD CQL"
echo "================================================================================"

cat > demo-cql-lb.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: demo-cql-lb
  namespace: ${DEMO_NAMESPACE}
  labels:
    app.kubernetes.io/name: demo-cql-lb
    app.kubernetes.io/part-of: hcd-demo
spec:
  type: LoadBalancer
  selector:
    cassandra.datastax.com/cluster: demo
    cassandra.datastax.com/datacenter: demo-dc-1
    cassandra.datastax.com/rack: rk-01
  ports:
    - name: cql
      port: 9042
      targetPort: 9042
      protocol: TCP
EOF

kubectl apply -f demo-cql-lb.yaml

echo "Waiting for external LoadBalancer hostname/IP..."

for i in {1..60}; do
  DEMO_CQL_HOST=$(
    kubectl -n "${DEMO_NAMESPACE}" get svc demo-cql-lb \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
  )

  if [ -z "$DEMO_CQL_HOST" ]; then
    DEMO_CQL_HOST=$(
      kubectl -n "${DEMO_NAMESPACE}" get svc demo-cql-lb \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
    )
  fi

  if [ -n "$DEMO_CQL_HOST" ]; then
    break
  fi

  echo "Waiting for LoadBalancer endpoint... attempt $i/60"
  sleep 10
done

if [ -z "${DEMO_CQL_HOST:-}" ]; then
  echo "ERROR: LoadBalancer endpoint was not assigned."
  echo "Check with:"
  echo "  kubectl -n ${DEMO_NAMESPACE} describe svc demo-cql-lb"
  exit 1
fi

echo "HCD CQL LoadBalancer endpoint: ${DEMO_CQL_HOST}"

cat > .env.demo-db <<EOF
export DEMO_NAMESPACE="${DEMO_NAMESPACE}"
export DEMO_CQL_HOST="${DEMO_CQL_HOST}"
export DEMO_CQL_PORT="9042"
export DEMO_DB_USERNAME="demo-superuser"
export DEMO_DB_PASSWORD="${DEMO_SUPERUSER_PASSWORD}"
EOF

echo "Demo DB connection details written to .env.demo-db"

cat <<DONE

================================================================================
Setup complete.

Mission Control UI access:

  kubectl -n ${MC_NAMESPACE} port-forward svc/mission-control-ui 8080:8080

Then open:

  https://localhost:8080

If your browser complains about the certificate, accept the local/self-signed warning.

Mission Control login:

  Username: ${MC_ADMIN_USER}
  Password: ${MC_ADMIN_PASSWORD}

Demo database superuser:

  Username: ${DEMO_SUPERUSER_NAME}
  Password: ${DEMO_SUPERUSER_PASSWORD}

Generated files:

  ${ENV_FILE}
  ${COS_ENV_FILE}
  ${COS_HMAC_ENV_FILE}
  mission-control-values.yaml
  mc-rendered.yaml
  demo-mc-cluster.yaml

Security reminder:

  Do not commit these files to Git:
    - ${COS_ENV_FILE}
    - ${COS_HMAC_ENV_FILE}
    - mission-control-values.yaml

================================================================================

DONE
