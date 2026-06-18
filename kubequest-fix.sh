#!/bin/bash

set -e

echo "🧹 Cleaning Dex + OAuth2 Proxy config..."

# Génération secret propre pour oauth2-proxy
OAUTH_SECRET=$(openssl rand -base64 32)

echo "🔐 Generated oauth2-proxy secret"

# Dex config CLEAN (GitHub ONLY, no mock)
cat > dex-values.yaml << YAML
config:
  issuer: http://dex.auth.svc.cluster.local:5556

  storage:
    type: memory

  web:
    http: 0.0.0.0:5556

  enablePasswordDB: false

  staticClients:
    - id: oauth2-proxy
      name: "oauth2-proxy"
      secret: $OAUTH_SECRET
      redirectURIs:
        - http://laravel.local/oauth2/callback

  connectors:
    - type: github
      id: github
      name: GitHub
      config:
        clientID: Ov23li732Qnk3366l1IN
        clientSecret: 7784baec4762d62220250e9c27f8ebce7c8b8209
        redirectURI: http://dex.auth.svc.cluster.local:5556/callback
        orgs:
          - name: maxiboole2

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 300m
    memory: 256Mi
YAML

echo "🚀 Upgrading Dex..."
helm upgrade dex dex/dex -n auth -f dex-values.yaml

echo "♻️ Restart Dex..."
kubectl rollout restart deployment dex -n auth

echo "🚀 Upgrading OAuth2 Proxy..."
helm upgrade oauth2-proxy oauth2-proxy/oauth2-proxy -n auth \
  --set config.clientID=oauth2-proxy \
  --set config.clientSecret=$OAUTH_SECRET \
  --set extraArgs.provider=oidc \
  --set extraArgs.oidc-issuer-url=http://dex.auth.svc.cluster.local:5556 \
  --set extraArgs.redirect-url=http://laravel.local/oauth2/callback \
  --set config.cookieSecret=0123456789abcdef0123456789abcdef \
  --set config.cookieSecure=false \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi

echo "✅ DONE - CLEAN AUTH STACK READY"
