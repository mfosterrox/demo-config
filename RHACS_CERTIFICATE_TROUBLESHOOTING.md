# RHACS Certificate Troubleshooting Guide

## Problem: NET::ERR_CERT_AUTHORITY_INVALID

If you're seeing "Your connection is not private" with error `NET::ERR_CERT_AUTHORITY_INVALID`, this means the browser doesn't trust the certificate being used by the RHACS route.

## Why This Happens

The default OpenShift router certificate is typically **self-signed**, which means browsers don't recognize it as trusted. This is normal for development/testing environments.

## Solutions

### Option 1: Accept the Self-Signed Certificate (Development/Testing)

**This is safe for development and testing environments.**

1. Navigate to `https://central-tssc-acs.apps.cluster-*.dynamic.redhatworkshops.io`
2. Click the **"Advanced"** button
3. Click **"Proceed to [hostname] (unsafe)"** or **"Accept the Risk and Continue"**
4. The browser will remember this exception for this session

**Note:** You'll need to do this once per browser session. For production, use a trusted certificate.

### Option 2: Use a Custom Trusted Certificate

If you have a certificate from a trusted Certificate Authority (CA):

```bash
# Configure route with your trusted certificate
./scripts/06-configure-rhacs-tls.sh --custom-cert /path/to/certificate.crt /path/to/private.key

# Example with Let's Encrypt certificate
./scripts/06-configure-rhacs-tls.sh --custom-cert /etc/letsencrypt/live/yourdomain.com/fullchain.pem /etc/letsencrypt/live/yourdomain.com/privkey.pem
```

### Option 3: Configure Let's Encrypt Certificate (Recommended for Production)

Use cert-manager to automatically obtain and renew Let's Encrypt certificates:

```bash
# Install cert-manager (if not already installed)
oc apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Create ClusterIssuer for Let's Encrypt
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: openshift-default
EOF

# Create Certificate resource for your route
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rhacs-central-cert
  namespace: tssc-acs
spec:
  secretName: central-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - central-tssc-acs.apps.cluster-*.dynamic.redhatworkshops.io
EOF

# Update route to use the certificate secret
oc patch route central -n tssc-acs --type='merge' -p '{
  "spec": {
    "tls": {
      "termination": "edge",
      "insecureEdgeTerminationPolicy": "Redirect",
      "key": "",
      "certificate": ""
    }
  }
}'

# Annotate route to use the secret
oc annotate route central -n tssc-acs cert-manager.io/cluster-issuer=letsencrypt-prod
```

### Option 4: Use OpenShift's Default Wildcard Certificate

If your OpenShift cluster has a trusted wildcard certificate configured:

```bash
# Check if default router certificate is trusted
oc get configmap default-ingress-cert -n openshift-config -o jsonpath='{.data}' 2>/dev/null

# If a trusted certificate is configured, the route should automatically use it
# No additional configuration needed
```

## Verify Certificate Configuration

Check the current route TLS configuration:

```bash
# Get route details
oc get route central -n tssc-acs -o yaml

# Check certificate details
echo | openssl s_client -connect central-tssc-acs.apps.cluster-*.dynamic.redhatworkshops.io:443 -servername central-tssc-acs.apps.cluster-*.dynamic.redhatworkshops.io 2>/dev/null | openssl x509 -noout -text
```

## Check Certificate Status

```bash
# Check if certificate is self-signed
openssl s_client -connect central-tssc-acs.apps.cluster-*.dynamic.redhatworkshops.io:443 -servername central-tssc-acs.apps.cluster-*.dynamic.redhatworkshops.io < /dev/null 2>/dev/null | openssl x509 -noout -subject -issuer

# If subject matches issuer, it's self-signed
```

## Browser-Specific Instructions

### Chrome/Edge
1. Click "Advanced"
2. Click "Proceed to [hostname] (unsafe)"

### Firefox
1. Click "Advanced"
2. Click "Accept the Risk and Continue"

### Safari
1. Click "Show Details"
2. Click "visit this website"
3. Click "Visit Website"

## For Production Environments

**Always use a trusted certificate from:**
- Let's Encrypt (free, automated)
- Commercial CA (DigiCert, GlobalSign, etc.)
- Your organization's internal CA (if trusted by browsers)

**Never use self-signed certificates in production** - they will always show warnings and reduce user trust.

## Quick Fix Commands

```bash
# Check current TLS configuration
oc get route central -n tssc-acs -o jsonpath='{.spec.tls}' | jq .

# Remove TLS (if needed)
oc patch route central -n tssc-acs --type='json' -p '[{"op": "remove", "path": "/spec/tls"}]'

# Re-apply TLS with default certificate
./scripts/06-configure-rhacs-tls.sh
```

## Additional Resources

- [OpenShift Route TLS Documentation](https://docs.openshift.com/container-platform/latest/networking/routes/secured-routes.html)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)

