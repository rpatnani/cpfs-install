#!/bin/sh
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d 'grant_type=password&username=cpadmin&password=qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF&scope=openid' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "=== Token length: ${#TOKEN} ==="

echo ""
echo "=== GET /v3/auth/idsource/ ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v3/auth/idsource/"

echo ""
echo "=== GET /v3/auth/idsource (no slash) ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v3/auth/idsource"

echo ""
echo "=== GET /v3/auth/idsource/?protocol=saml ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v3/auth/idsource/?protocol=saml"

echo ""
echo "=== via cp-console route ==="
curl -sk -w "\nHTTP:%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idprovider/v3/auth/idsource"

echo ""
echo "=== DONE ==="
