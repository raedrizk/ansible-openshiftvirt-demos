#!/bin/bash
set -e

echo "=========================================="
echo "Installing OpenShift Virtualization"
echo "=========================================="

# Prompt for OpenShift login credentials
echo ""
echo "OpenShift Login"
echo "=========================================="
read -p "Enter OpenShift API URL (e.g., https://api.cluster.example.com:6443): " OCP_API_URL
read -p "Enter username: " OCP_USERNAME
read -sp "Enter password: " OCP_PASSWORD
echo ""
read -p "Trust self-signed certificates? (y/n): " TRUST_CERT

# Build login command with appropriate flags
LOGIN_CMD="oc login $OCP_API_URL --username=$OCP_USERNAME --password=$OCP_PASSWORD"
if [[ "$TRUST_CERT" =~ ^[Yy]$ ]]; then
  LOGIN_CMD="$LOGIN_CMD --insecure-skip-tls-verify"
fi

echo ""
echo "Logging into OpenShift..."
eval $LOGIN_CMD

echo ""
echo "✓ Successfully logged into OpenShift"
echo "=========================================="

# Step 1: Create namespace
echo ""
echo "Step 1: Creating openshift-cnv namespace..."
oc apply -f cnv-namespace.yaml

# Step 2: Create OperatorGroup
echo ""
echo "Step 2: Creating OperatorGroup..."
oc apply -f cnv-operatorgroup.yaml

# Step 3: Create Subscription
echo ""
echo "Step 3: Creating Subscription..."
oc apply -f cnv-subscription.yaml

# Step 4: Wait for CSV to be ready
echo ""
echo "Step 4: Waiting for operator to install (this may take a few minutes)..."
echo "Checking for ClusterServiceVersion..."

# Wait for CSV to appear
timeout=300
elapsed=0
while [ $elapsed -lt $timeout ]; do
  CSV=$(oc get csv -n openshift-cnv -o name 2>/dev/null | grep kubevirt-hyperconverged || true)
  if [ -n "$CSV" ]; then
    echo "Found CSV: $CSV"
    break
  fi
  echo "Waiting for CSV to appear... ($elapsed/$timeout seconds)"
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ -z "$CSV" ]; then
  echo "ERROR: CSV did not appear within $timeout seconds"
  exit 1
fi

# Wait for CSV to succeed
echo "Waiting for CSV to reach Succeeded phase..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded -n openshift-cnv $CSV --timeout=600s

echo ""
echo "✓ Operator installed successfully!"

# Step 5: Create HyperConverged CR
echo ""
echo "Step 5: Deploying OpenShift Virtualization components..."
oc apply -f cnv-hyperconverged.yaml

# Step 6: Wait for HyperConverged to be ready
echo ""
echo "Step 6: Waiting for deployment to complete (this may take several minutes)..."
oc wait --for=condition=Available -n openshift-cnv hyperconverged/kubevirt-hyperconverged --timeout=1200s

echo ""
echo "=========================================="
echo "✓ OpenShift Virtualization installed successfully!"
echo "=========================================="

# Step 7: Create ansible-exec namespace and service account
echo ""
echo "Step 7: Creating ansible namespaces and service account..."
oc create namespace ansible-exec --dry-run=client -o yaml | oc apply -f -
oc create namespace ansible-demo --dry-run=client -o yaml | oc apply -f -

echo "Creating service account..."
oc create serviceaccount ansible-exec -n ansible-exec --dry-run=client -o yaml | oc apply -f -

echo "Creating admin rolebinding..."
oc create rolebinding ansible-exec-admin \
  --clusterrole=admin \
  --serviceaccount=ansible-exec:ansible-exec \
  -n ansible-exec \
  --dry-run=client -o yaml | oc apply -f -

echo "Creating service account token (1 year duration)..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ansible-exec-token
  namespace: ansible-exec
  annotations:
    kubernetes.io/service-account.name: ansible-exec
type: kubernetes.io/service-account-token
EOF

echo "Waiting for token to be generated..."
sleep 5

TOKEN=$(oc get secret ansible-exec-token -n ansible-exec -o jsonpath='{.data.token}' | base64 -d)

echo ""
echo "=========================================="
echo "✓ Setup Complete!"
echo "=========================================="
echo ""
echo "OpenShift Virtualization Status:"
echo "  oc get hco -n openshift-cnv"
echo "  oc get pods -n openshift-cnv"
echo ""
echo "=========================================="
echo "Ansible Service Account Token (ansible-exec)"
echo "=========================================="
echo ""
echo "$TOKEN"
echo ""
echo "Save this token - you'll need it for Ansible authentication!"
echo "=========================================="
