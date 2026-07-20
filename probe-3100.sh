#!/bin/sh
# Probe platform-auth-service port 3100 - the internal auth directory service
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d 'grant_type=password&username=cpadmin&password=qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF&scope=openid' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "=== Token length: ${#TOKEN} ==="

echo ""
echo "=== 1. port 3100 /idmgmt/identity/api/v1/directory/idp ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:3100/idmgmt/identity/api/v1/directory/idp"

echo ""
echo "=== 2. port 3100 /idmgmt/identity/api/v1/saml/idps ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:3100/idmgmt/identity/api/v1/saml/idps"

echo ""
echo "=== 3. port 3100 / (root) ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:3100/"

echo ""
echo "=== 4. port 3100 /idmgmt/identity/api/v1/ ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:3100/idmgmt/identity/api/v1/"

echo ""
echo "=== 5. via MASTER_HOST - directory/idp ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idmgmt/identity/api/v1/directory/idp"

echo ""
echo "=== 6. via MASTER_HOST - saml ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idmgmt/identity/api/v1/saml/idps"

echo ""
echo "=== 7. Check what is on port 3100 - no auth ==="
curl -sk -w "\nHTTP:%{http_code}" \
  "https://platform-auth-service:3100/idmgmt/identity/api/v1/directory/idp"

echo ""
echo "=== 8. platform-identity-management port 4500 with v2 API ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v2/idps"

echo ""
echo "=== 9. List routes/paths on platform-identity-management ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/"

echo ""
echo "=== DONE ==="
