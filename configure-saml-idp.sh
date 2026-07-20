#!/bin/sh
# Get IAM admin token
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d 'grant_type=password&username=cpadmin&password=qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF&scope=openid' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "Token length: ${#TOKEN}"

# Fetch Keycloak SAML metadata
SAML_META=$(curl -sk "https://keycloak-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/realms/cloudpak/protocol/saml/descriptor")
echo "SAML meta length: ${#SAML_META}"

# Check existing SAML IDPs
echo "--- Existing SAML IDPs ---"
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/saml/idps"

# Create SAML IDP config
echo ""
echo "--- Creating SAML IDP ---"
curl -sk -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://platform-identity-management:4500/idmgmt/identity/api/v1/saml/idps" \
  -d "{
    \"protocol\": \"saml\",
    \"type\": \"external\",
    \"name\": \"keycloak-saml\",
    \"description\": \"Keycloak SAML SSO\",
    \"idp_metadata\": $(echo "$SAML_META" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
    \"enabled\": true,
    \"jit_enabled\": true,
    \"fieldMapping\": {
      \"uid\": \"email\",
      \"givenName\": \"given_name\",
      \"familyName\": \"family_name\",
      \"email\": \"email\"
    }
  }"
echo ""
echo "--- Done ---"
