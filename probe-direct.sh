#!/bin/sh
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d 'grant_type=password&username=cpadmin&password=qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF&scope=openid' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "=== Token length: ${#TOKEN} ==="

echo ""
echo "=== /identity/api/v1/zeninstance ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/identity/api/v1/zeninstance"

echo ""
echo "=== /v1/zeninstance ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/v1/zeninstance"

echo ""
echo "=== Check EXPOSE_ADDITIONAL_PATHS env ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/zeninstance"

echo ""
echo "=== /identity/api/v1/users ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/identity/api/v1/users?limit=1"

echo ""
echo "=== /v1/auth/idsource via platform-identity-provider ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/idsource"

echo ""
echo "=== /v1/auth/idsource/types ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/idsource/types"

echo ""
echo "=== check platform-identity-provider routes ==="
# Look at the node process itself to find routes
echo "=== /v1/auth/providers ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v1/auth/providers"

echo ""
echo "=== DONE ==="
