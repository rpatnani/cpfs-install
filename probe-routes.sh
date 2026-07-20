#!/bin/sh
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d 'grant_type=password&username=cpadmin&password=qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF&scope=openid' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "=== Token length: ${#TOKEN} ==="

echo ""
echo "=== platform-identity-management:4500 routes ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/management/idps"

echo ""
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/scim/attributemappings"

echo ""
echo "=== Check platform-identity-provider:4300 full paths ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/idps"

echo ""
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/saml/idps"

echo ""
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/idmgmt"

echo ""
echo "=== Check platform-auth-service:9443 idp paths ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:9443/idprovider/v1/auth/idps"

echo ""
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:9443/v1/auth/idps"

echo ""
echo "=== via cp-console route ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idprovider/v1/auth/idps"

echo ""
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idmgmt/identity/api/v1/management/idps"

echo ""
echo "=== Check what paths work on platform-identity-management ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/users"

echo ""
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/scim/users"

echo ""
echo "=== Check for saml in platform-identity-provider ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/oidc/keys"

echo ""
echo "=== DONE ==="
