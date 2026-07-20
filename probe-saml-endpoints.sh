#!/bin/sh
# Probe all possible SAML IDP endpoints in CPFS 4.x
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d 'grant_type=password&username=cpadmin&password=qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF&scope=openid' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "=== Token length: ${#TOKEN} ==="

echo ""
echo "=== 1. platform-identity-management:4500 /idmgmt/identity/api/v1/directory/idp ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/directory/idp"

echo ""
echo "=== 2. platform-identity-management:4500 /idmgmt/identity/api/v1/saml/idps ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/saml/idps"

echo ""
echo "=== 3. platform-identity-provider:4300 /idmgmt/identity/api/v1/directory/idp ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/idmgmt/identity/api/v1/directory/idp"

echo ""
echo "=== 4. platform-identity-provider:4300 /idmgmt/identity/api/v1/saml/idps ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/idmgmt/identity/api/v1/saml/idps"

echo ""
echo "=== 5. platform-auth-service:9443 /v1/auth/configure/saml ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:9443/v1/auth/configure/saml"

echo ""
echo "=== 6. platform-auth-service:9443 /idauth/saml ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-auth-service:9443/idauth/saml"

echo ""
echo "=== 7. platform-identity-provider:4300 /v1/auth/idps ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/idps"

echo ""
echo "=== 8. platform-identity-provider:4300 /v1/auth/idsource ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/idsource"

echo ""
echo "=== 9. platform-identity-management:4500 /idmgmt/identity/api/v1/idsource ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/idsource"

echo ""
echo "=== 10. Check platform-identity-provider routes/swagger ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/swagger"

echo ""
echo "=== DONE ==="
