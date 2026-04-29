# Platform Setup

This document sets up the IBM Cloud VPC, IKS cluster, cert-manager, IBM COS discovery, COS HMAC credentials, and Mission Control Helm deployment for an HCD demo/workshop environment.

---

## 0. Assumptions

This guide assumes:

- You are using macOS.
- You have access to the IBM Cloud TechZone account/resource group.
- `jq`, `kubectl`, and `helm` are installed.
- You are using IBM Cloud VPC Gen 2.
- The watsonx.data bucket already exists in IBM Cloud Object Storage.
- You are deploying Mission Control using Helm from the Replicated registry.
- You may not have Docker installed; Podman-only setup is handled below.
- You have a valid Mission Control license ID for the Replicated registry.

---

## 1. Install IBM Cloud CLI

```bash
curl -fsSL https://clis.cloud.ibm.com/install/osx | sh
```

Verify:

```bash
ibmcloud version
```

---

## 2. IBM Cloud login

```bash
ibmcloud login --sso -r eu-de
```

Target the TechZone resource group:

```bash
ibmcloud target -g itz-wxd-69f1c82604915752070c1b
```

Verify target:

```bash
ibmcloud target
```

---

## 3. Install required IBM Cloud plugins

```bash
ibmcloud plugin install container-service -f
ibmcloud plugin install container-registry -f
ibmcloud plugin install vpc-infrastructure -f
ibmcloud plugin install cloud-object-storage -f
```

Verify plugins:

```bash
ibmcloud plugin list
```

---

## 4. Export environment variables

Update these values for your own TechZone reservation if needed.

```bash
export REGION="eu-de"
export ZONE="eu-de-1"
export RG="itz-wxd-69f1c82604915752070c1b"

export PREFIX="hcd-student-69f1c82604"

export VPC_NAME="${PREFIX}-vpc"
export SUBNET_NAME="${PREFIX}-subnet"
export PGW_NAME="${PREFIX}-pgw"
export CLUSTER_NAME="${PREFIX}-iks"
```

Target the resource group again:

```bash
ibmcloud target -g "$RG"
```

Set VPC generation:

```bash
ibmcloud is target --gen 2
```

---

## 5. Create VPC

```bash
ibmcloud is vpc-create "$VPC_NAME" --resource-group-name "$RG"
```

Capture the VPC ID:

```bash
export VPC_ID=$(
  ibmcloud is vpcs --output json \
    | jq -r ".[] | select(.name==\"$VPC_NAME\") | .id"
)

echo "$VPC_ID"
```

Verify:

```bash
ibmcloud is vpcs
```

---

## 6. Create public gateway

```bash
ibmcloud is public-gateway-create "$PGW_NAME" "$VPC_ID" "$ZONE" \
  --resource-group-name "$RG"
```

Capture the public gateway ID:

```bash
export PGW_ID=$(
  ibmcloud is public-gateways --output json \
    | jq -r ".[] | select(.name==\"$PGW_NAME\") | .id"
)

echo "$PGW_ID"
```

Verify:

```bash
ibmcloud is public-gateways
```

---

## 7. Create subnet

```bash
ibmcloud is subnet-create "$SUBNET_NAME" \
  "$VPC_ID" \
  --zone "$ZONE" \
  --ipv4-address-count 256 \
  --public-gateway-id "$PGW_ID" \
  --resource-group-name "$RG"
```

Capture the subnet ID:

```bash
export SUBNET_ID=$(
  ibmcloud is subnets --output json \
    | jq -r ".[] | select(.name==\"$SUBNET_NAME\") | .id"
)

echo "$SUBNET_ID"
```

Verify:

```bash
ibmcloud is subnets
```

---

## 8. Verify infrastructure

```bash
ibmcloud is vpcs
ibmcloud is subnets
ibmcloud is public-gateways
```

---

## 9. Check available IKS worker flavors

```bash
ibmcloud ks flavors --zone "$ZONE"
```

For this workshop, use:

```text
bx2.4x16
```

This provides 4 vCPU and 16 GB RAM per worker node.

---

## 10. Create IKS cluster

```bash
ibmcloud ks cluster create vpc-gen2 \
  --name "$CLUSTER_NAME" \
  --flavor bx2.4x16 \
  --workers 3 \
  --vpc-id "$VPC_ID" \
  --subnet-id "$SUBNET_ID" \
  --zone "$ZONE"
```

Check cluster list:

```bash
ibmcloud ks clusters
```

Check cluster status:

```bash
ibmcloud ks cluster get --cluster "$CLUSTER_NAME"
```

Check worker status:

```bash
ibmcloud ks workers --cluster "$CLUSTER_NAME"
```

Wait until the cluster is deployed and workers are ready.

---

## 11. Configure kubectl

```bash
ibmcloud ks cluster config --cluster "$CLUSTER_NAME"
```

Verify nodes:

```bash
kubectl get nodes
```

Expected output should show three ready nodes.

Example:

```text
NAME         STATUS   ROLES    AGE   VERSION
10.243.0.4   Ready    <none>   1m    v1.34.x+IKS
10.243.0.5   Ready    <none>   1m    v1.34.x+IKS
10.243.0.6   Ready    <none>   1m    v1.34.x+IKS
```

---

## 12. Disable outbound traffic protection

IKS secure-by-default networking may block image pulls from public registries such as:

- `quay.io`
- `docker.io`
- `registry.replicated.com`

Disable outbound traffic protection for this workshop cluster:

```bash
ibmcloud ks vpc outbound-traffic-protection disable --cluster "$CLUSTER_NAME"
```

Confirm:

```bash
ibmcloud ks cluster get --cluster "$CLUSTER_NAME" | grep -i "Outbound Traffic Protection"
```

Expected:

```text
Outbound Traffic Protection:    disabled
```

Test outbound connectivity from the cluster:

```bash
kubectl run curl-test \
  --image=curlimages/curl \
  --rm -it \
  --restart=Never \
  -- curl -I https://quay.io
```

---

## 13. Install cert-manager

Add the Jetstack Helm repo:

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update
```

Install cert-manager:

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.1 \
  --set crds.enabled=true \
  --set 'extraArgs[0]=--enable-certificate-owner-ref=true' \
  --wait \
  --timeout 10m
```

Verify:

```bash
helm list -n cert-manager
kubectl get pods -n cert-manager
kubectl get jobs -n cert-manager
```

Expected pods:

```text
cert-manager
cert-manager-cainjector
cert-manager-webhook
```

All should be running.

---

## 14. Discover IBM COS / watsonx.data bucket details

This discovers the COS instance and watsonx.data bucket and writes values to `.env.cos`.

```bash
# ============================================================
# Discover IBM COS / watsonx.data bucket details
# Assumes REGION, RG, and PREFIX are already exported.
# ============================================================

set -euo pipefail

export BUCKET_PREFIX="watsonx-data-"

ibmcloud target -g "$RG"

if ! ibmcloud plugin list | grep -q "cloud-object-storage"; then
  ibmcloud plugin install cloud-object-storage -f
fi

export COS_INSTANCE_NAME=$(
  ibmcloud resource service-instances \
    --service-name cloud-object-storage \
    --output json | jq -r '.[0].name'
)

export COS_INSTANCE_CRN=$(
  ibmcloud resource service-instances \
    --service-name cloud-object-storage \
    --output json | jq -r '.[0].crn'
)

export COS_INSTANCE_GUID=$(
  ibmcloud resource service-instances \
    --service-name cloud-object-storage \
    --output json | jq -r '.[0].guid'
)

echo "COS_INSTANCE_NAME=$COS_INSTANCE_NAME"
echo "COS_INSTANCE_CRN=$COS_INSTANCE_CRN"
echo "COS_INSTANCE_GUID=$COS_INSTANCE_GUID"

ibmcloud cos config crn --crn "$COS_INSTANCE_CRN"

export COS_BUCKET=$(
  ibmcloud cos buckets --output json \
    | jq -r --arg prefix "$BUCKET_PREFIX" '.Buckets[]?.Name | select(startswith($prefix))' \
    | head -n 1
)

export COS_ENDPOINT="https://s3.direct.${REGION}.cloud-object-storage.appdomain.cloud"
export COS_REGION="$REGION"

echo "COS_BUCKET=$COS_BUCKET"
echo "COS_ENDPOINT=$COS_ENDPOINT"
echo "COS_REGION=$COS_REGION"

cat > .env.cos <<EOF
export COS_INSTANCE_NAME="$COS_INSTANCE_NAME"
export COS_INSTANCE_CRN="$COS_INSTANCE_CRN"
export COS_INSTANCE_GUID="$COS_INSTANCE_GUID"
export COS_BUCKET="$COS_BUCKET"
export COS_ENDPOINT="$COS_ENDPOINT"
export COS_REGION="$COS_REGION"
EOF

echo "COS environment written to .env.cos"
echo "Reload later with: source .env.cos"
```

Verify:

```bash
cat .env.cos
```

Confirm the bucket is not empty:

```bash
source .env.cos

test -n "$COS_BUCKET" && echo "COS_BUCKET discovered: $COS_BUCKET"
```

---

## 15. Create IBM COS HMAC credentials

Mission Control / Loki needs S3-compatible credentials for IBM COS.

This creates an HMAC service key and writes values to `.env.cos.hmac`.

```bash
# ============================================================
# Create IBM COS HMAC credentials for S3-compatible access
# Assumes .env.cos exists.
# ============================================================

set -euo pipefail

source .env.cos

export COS_HMAC_KEY_NAME="${PREFIX}-cos-hmac"
export COS_HMAC_ROLE="Writer"

if ibmcloud resource service-key "$COS_HMAC_KEY_NAME" >/dev/null 2>&1; then
  echo "Service key already exists: $COS_HMAC_KEY_NAME"
else
  ibmcloud resource service-key-create "$COS_HMAC_KEY_NAME" "$COS_HMAC_ROLE" \
    --instance-name "$COS_INSTANCE_NAME" \
    --parameters '{"HMAC":true}'
fi

export COS_ACCESS_KEY_ID=$(
  ibmcloud resource service-key "$COS_HMAC_KEY_NAME" --output json \
    | jq -r '.[0].credentials.cos_hmac_keys.access_key_id'
)

export COS_SECRET_ACCESS_KEY=$(
  ibmcloud resource service-key "$COS_HMAC_KEY_NAME" --output json \
    | jq -r '.[0].credentials.cos_hmac_keys.secret_access_key'
)

cat > .env.cos.hmac <<EOF
export COS_ACCESS_KEY_ID="$COS_ACCESS_KEY_ID"
export COS_SECRET_ACCESS_KEY="$COS_SECRET_ACCESS_KEY"
EOF

echo "HMAC credentials written to .env.cos.hmac"
echo "Reload later with: source .env.cos.hmac"
```

Verify without printing the secret value:

```bash
source .env.cos
source .env.cos.hmac

echo "COS_BUCKET=$COS_BUCKET"
echo "COS_ENDPOINT=$COS_ENDPOINT"
echo "COS_REGION=$COS_REGION"
echo "COS_ACCESS_KEY_ID length: ${#COS_ACCESS_KEY_ID}"
echo "COS_SECRET_ACCESS_KEY length: ${#COS_SECRET_ACCESS_KEY}"
```

Expected:

```text
COS_ACCESS_KEY_ID length: 32
COS_SECRET_ACCESS_KEY length: 48
```

---

## 16. Create namespace and COS test secret

This creates a generic COS credential secret that can be reused later by HCD examples or workshop workloads.

```bash
source .env.cos
source .env.cos.hmac

export MC_NAMESPACE="mission-control"
export HCD_CLUSTER_NAME="hcd-demo"
export HCD_PROJECT_NAMESPACE="mission-control"

kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hcd-cos-s3-credentials \
  --namespace "$MC_NAMESPACE" \
  --from-literal=accessKeyId="$COS_ACCESS_KEY_ID" \
  --from-literal=secretAccessKey="$COS_SECRET_ACCESS_KEY" \
  --from-literal=bucket="$COS_BUCKET" \
  --from-literal=endpoint="$COS_ENDPOINT" \
  --from-literal=region="$COS_REGION" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl get secret hcd-cos-s3-credentials -n "$MC_NAMESPACE"
```

---

## 18. Configure Helm registry login for Replicated registry

Export the Mission Control license ID.

Do not commit a real license ID into a public repository.

```bash
export MC_LICENSE_ID="<your-mission-control-license-id>"
```

Example placeholder:

```bash
export MC_LICENSE_ID="REPLACE_WITH_REAL_LICENSE_ID"
```

---

## 19. Fix Helm registry login when Docker is not installed

On macOS, Helm may try to use Docker credential helpers such as `docker-credential-osxkeychain`.

If Docker is not installed and you are using Podman only, check Helm registry config:

```bash
cat "$(helm env | grep HELM_REGISTRY_CONFIG | cut -d'"' -f2)"
```

If you see this:

```json
{
  "auths": {},
  "credsStore": "osxkeychain"
}
```

replace it with a plain Helm registry config:

```bash
export HELM_REGISTRY_CONFIG="$(helm env | grep HELM_REGISTRY_CONFIG | cut -d'"' -f2")"

mkdir -p "$(dirname "$HELM_REGISTRY_CONFIG")"

cat > "$HELM_REGISTRY_CONFIG" <<EOF
{
  "auths": {}
}
EOF

cat "$HELM_REGISTRY_CONFIG"
```

Now log in to the Replicated registry:

```bash
printf '%s' "$MC_LICENSE_ID" | helm registry login registry.replicated.com \
  --username "$MC_LICENSE_ID" \
  --password-stdin
```

Verify login by rendering the Helm template later.

---

## 20. Create Mission Control Helm values

This configuration deploys Mission Control with:

- Mission Control UI enabled
- Grafana enabled
- Loki enabled
- Loki using IBM Cloud Object Storage as S3-compatible storage
- Loki retention enabled correctly with `delete_request_store: s3`
- Mimir disabled
- MinIO disabled
- Dex password database enabled for the built-in workshop login flow

Create the values file:

```bash
# -------------------------------------------------------------------
# Mission Control Helm values using IBM COS for Loki S3 storage
# Assumes:
#   - .env.cos exists
#   - .env.cos.hmac exists
#   - MC_LICENSE_ID is already exported
# -------------------------------------------------------------------

set -euo pipefail

source .env.cos
source .env.cos.hmac

export MC_NAMESPACE="mission-control"
export MC_RELEASE="mission-control"

export MC_ADMIN_USER="admin"
export MC_ADMIN_EMAIL="admin@local"
export MC_ADMIN_PASSWORD='Password123!'
export MC_ADMIN_USER_ID="9f35c506-cac8-4d4d-8e66-05c55624624b"

export LOKI_SECRET_NAME="loki-s3-secrets"

export MC_ADMIN_HASH=$(
  kubectl run bcrypt-hash \
    -n "$MC_NAMESPACE" \
    --image=httpd:2.4-alpine \
    --restart=Never \
    --rm -i \
    --quiet \
    --command -- htpasswd -bnBC 10 "" "$MC_ADMIN_PASSWORD" \
    | tr -d ':\r\n'
)

echo "$MC_ADMIN_HASH"

kubectl create namespace "$MC_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$MC_NAMESPACE" create secret generic "$LOKI_SECRET_NAME" \
  --from-literal=s3-access-key-id="$COS_ACCESS_KEY_ID" \
  --from-literal=s3-secret-access-key="$COS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

cat > mission-control-values.yaml <<EOF
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
        userID: 9f35c506-cac8-4d4d-8e66-05c55624624b

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
EOF

echo "Generated mission-control-values.yaml"
```

Verify the important parts:

```bash
grep -n "dex:" -A5 mission-control-values.yaml
grep -n "loki:" -A90 mission-control-values.yaml
```

Expected Dex value:

```yaml
dex:
  config:
    enablePasswordDB: true
```

Expected Loki retention values:

```yaml
limits_config:
  retention_period: 7d

compactor:
  retention_enabled: true
  delete_request_store: s3
```

---

## 21. Validate Helm template before install

Render the chart before installing:

```bash
helm template "$MC_RELEASE" \
  oci://registry.replicated.com/mission-control/mission-control \
  --namespace "$MC_NAMESPACE" \
  -f mission-control-values.yaml \
  --debug > mc-rendered.yaml
```

Check the rendered Loki configuration:

```bash
grep -n "object_store\|storage_config\|bucketnames\|s3forcepathstyle\|retention_period\|delete_request_store\|compactor" mc-rendered.yaml | head -120
```

You should see values similar to:

```yaml
object_store: s3
bucketnames: <your-watsonx-data-bucket>
s3forcepathstyle: true
retention_period: 7d
delete_request_store: s3
retention_enabled: true
```

Check the rendered Dex configuration:

```bash
grep -n "enablePasswordDB\|staticPasswords" mc-rendered.yaml -A20 -B10
```

You should see:

```yaml
enablePasswordDB: true
```

This avoids the Dex error:

```text
cannot specify static passwords without enabling password db
```

---

## 22. Install Mission Control

For a clean install:

```bash
helm install "$MC_RELEASE" \
  oci://registry.replicated.com/mission-control/mission-control \
  --namespace "$MC_NAMESPACE" \
  --create-namespace \
  -f mission-control-values.yaml \
  --wait \
  --timeout 30m
```

Verify the release:

```bash
helm status "$MC_RELEASE" -n "$MC_NAMESPACE"
```

Verify pods:

```bash
kubectl get pods -n "$MC_NAMESPACE"
```

Expected result:

```text
loki-backend-0                                      1/1   Running
loki-read-...                                      1/1   Running
loki-write-0                                       1/1   Running
mission-control-aggregator-0                       1/1   Running
mission-control-cass-operator-...                  1/1   Running
mission-control-crd-patcher-...                    0/1   Completed
mission-control-dex-...                            1/1   Running
mission-control-grafana-...                        3/3   Running
mission-control-k8ssandra-operator-...             1/1   Running
mission-control-kube-state-metrics-...             1/1   Running
mission-control-loki-gateway-...                   1/1   Running
mission-control-operator-...                       1/1   Running
mission-control-ui-...                             1/1   Running
replicated-...                                     1/1   Running
```

---

## 27. Clean-up commands

Use only if you want to remove the deployment.

Remove Mission Control:

```bash
helm uninstall mission-control -n mission-control
```

Delete Mission Control namespace:

```bash
kubectl delete namespace mission-control
```

Remove cert-manager:

```bash
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
```

Delete IKS cluster:

```bash
ibmcloud ks cluster rm --cluster "$CLUSTER_NAME"
```

Delete subnet:

```bash
ibmcloud is subnet-delete "$SUBNET_ID" -f
```

Delete public gateway:

```bash
ibmcloud is public-gateway-delete "$PGW_ID" -f
```

Delete VPC:

```bash
ibmcloud is vpc-delete "$VPC_ID" -f
```

---

## 28. Security note

Do not commit the following files to Git:

```text
.env.cos
.env.cos.hmac
mission-control-values.yaml
```

These files may contain environment details or secrets.

If real COS HMAC keys were pasted into a terminal transcript, chat, document, or repository, rotate/delete that IBM Cloud service key and create a fresh one before using the environment for anything beyond a temporary workshop.

```bash
ibmcloud resource service-key-delete "$COS_HMAC_KEY_NAME" -f
```

Then recreate the HMAC key using Section 16.

---

For default database:
cat > demo-mc-cluster.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: sample-2p43q6vg
---
apiVersion: v1
kind: Secret
metadata:
  name: demo-superuser
  namespace: sample-2p43q6vg
type: Opaque
stringData:
  username: demo-superuser
  password: Password123!
---
apiVersion: missioncontrol.datastax.com/v1beta2
kind: MissionControlCluster
metadata:
  name: demo
  namespace: sample-2p43q6vg
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
      serverVersion: 1.2.5
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
          storageClassName: ""
          resources:
            requests:
              storage: 2Gi

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
EOF

kubectl apply -f demo-mc-cluster.yaml



kubectl get k8ssandracluster -n sample-2p43q6vg
kubectl get cassdc -n sample-2p43q6vg
kubectl get pvc -n sample-2p43q6vg
kubectl get svc -n sample-2p43q6vg

## 29. Final validation checklist

Before starting the workshop, confirm:

```bash
ibmcloud target
ibmcloud ks cluster get --cluster "$CLUSTER_NAME"
kubectl get nodes
kubectl get pods -n cert-manager
kubectl get pods -n mission-control
helm status mission-control -n mission-control
```

Expected:

- IBM Cloud target is the correct region and resource group.
- IKS cluster is deployed.
- All worker nodes are `Ready`.
- cert-manager pods are running.
- Mission Control pods are running.
- `mission-control-crd-patcher` may show `Completed`.
- Loki backend, read, and write pods are running.
- Dex is running.
- UI is running.
- Helm status is `deployed`.

Example successful Mission Control pod state:

```text
loki-backend-0                                        1/1     Running
loki-read-xxxxxxxxxx-xxxxx                            1/1     Running
loki-write-0                                          1/1     Running
mission-control-aggregator-0                          1/1     Running
mission-control-cass-operator-xxxxxxxxxx-xxxxx        1/1     Running
mission-control-crd-patcher-xxxxx                     0/1     Completed
mission-control-dex-xxxxxxxxxx-xxxxx                  1/1     Running
mission-control-grafana-xxxxxxxxxx-xxxxx              3/3     Running
mission-control-k8ssandra-operator-xxxxxxxxxx-xxxxx   1/1     Running
mission-control-kube-state-metrics-xxxxxxxxxx-xxxxx   1/1     Running
mission-control-loki-gateway-xxxxxxxxxx-xxxxx         1/1     Running
mission-control-operator-xxxxxxxxxx-xxxxx             1/1     Running
mission-control-ui-xxxxxxxxxx-xxxxx                   1/1     Running
replicated-xxxxxxxxxx-xxxxx                           1/1     Running
```