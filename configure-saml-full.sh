#!/bin/sh
# Full SAML IDP configuration script for CPFS 4.x with Keycloak
# This runs inside platform-auth-service pod

KEYCLOAK_URL="https://keycloak-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com"
KEYCLOAK_REALM="cloudpak"
CP_CONSOLE_URL="https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com"
CPADMIN_PASS="qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF"

echo "=== Step 1: Get CPFS IAM token ==="
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d "grant_type=password&username=cpadmin&password=${CPADMIN_PASS}&scope=openid" \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "Token length: ${#TOKEN}"
if [ ${#TOKEN} -lt 100 ]; then
  echo "ERROR: Failed to get IAM token"
  exit 1
fi

echo ""
echo "=== Step 2: Check current SAML IDPs ==="
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v3/auth/idsource/?protocol=saml"

echo ""
echo "=== Step 3: Get Keycloak SAML IDP metadata and base64 encode it ==="
SAML_META=$(curl -sk "${KEYCLOAK_URL}/realms/${KEYCLOAK_REALM}/protocol/saml/descriptor")
SAML_META_B64=$(echo "$SAML_META" | base64 | tr -d '\n')
echo "Metadata B64 length: ${#SAML_META_B64}"

echo ""
echo "=== Step 4: Get Keycloak admin token ==="
KC_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=a912eadf6da041e38f1ef44a8bd33fc4" \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "Keycloak token length: ${#KC_TOKEN}"

echo ""
echo "=== Step 5: Create SAML client in Keycloak for CPFS SP ==="
# CPFS Liberty SP ACS URL:
# https://cp-console.../ibm/saml20/defaultSP/acs
ACS_URL="${CP_CONSOLE_URL}/ibm/saml20/defaultSP/acs"
ENTITY_ID="${CP_CONSOLE_URL}/ibm/saml20/defaultSP"
LOGOUT_URL="${CP_CONSOLE_URL}/ibm/saml20/defaultSP/slo"

KC_CLIENT_PAYLOAD="{
  \"clientId\": \"${ENTITY_ID}\",
  \"name\": \"cpfs-saml-sp\",
  \"description\": \"CPFS IAM SAML Service Provider\",
  \"protocol\": \"saml\",
  \"enabled\": true,
  \"publicClient\": false,
  \"frontchannelLogout\": true,
  \"redirectUris\": [\"${ACS_URL}\"],
  \"attributes\": {
    \"saml.assertion.signature\": \"true\",
    \"saml.authnstatement\": \"true\",
    \"saml.client.signature\": \"false\",
    \"saml.encrypt\": \"false\",
    \"saml.force.post.binding\": \"true\",
    \"saml.multivalued.roles\": \"false\",
    \"saml.onetimeuse.condition\": \"false\",
    \"saml.server.signature\": \"true\",
    \"saml.server.signature.keyinfo.ext\": \"false\",
    \"saml_assertion_consumer_url_post\": \"${ACS_URL}\",
    \"saml_assertion_consumer_url_redirect\": \"${ACS_URL}\",
    \"saml_single_logout_service_url_post\": \"${LOGOUT_URL}\",
    \"saml_single_logout_service_url_redirect\": \"${LOGOUT_URL}\",
    \"saml.signature.algorithm\": \"RSA_SHA256\",
    \"saml.force.name.id.format\": \"false\",
    \"saml.user.attribute\": \"sub\",
    \"saml_name_id_format\": \"username\",
    \"saml_force_name_id_format\": \"false\"
  }
}"

echo "Creating Keycloak SAML client..."
KC_CREATE_RESP=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$KC_CLIENT_PAYLOAD" -w "\nHTTP:%{http_code}")
echo "$KC_CREATE_RESP"

echo ""
echo "=== Step 6: Add protocol mappers to Keycloak SAML client ==="
# Get client ID
KC_CLIENT_ID=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=$(echo -n "${ENTITY_ID}" | sed 's/ /%20/g')" \
  | sed 's/.*"id":"\([^"]*\)".*/\1/' | head -1)
echo "Keycloak client internal ID: $KC_CLIENT_ID"

if [ -n "$KC_CLIENT_ID" ] && [ "$KC_CLIENT_ID" != "$KC_CREATE_RESP" ]; then
  # Add email mapper
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"email","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"email","attribute.name":"email","attribute.nameformat":"Basic","friendly.name":"email"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
  
  # Add firstName mapper
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"firstName","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"firstName","attribute.name":"givenName","attribute.nameformat":"Basic","friendly.name":"givenName"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
  
  # Add lastName mapper
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"lastName","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"lastName","attribute.name":"lastName","attribute.nameformat":"Basic","friendly.name":"lastName"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
  
  # Add groups mapper
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${KC_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"groups","protocol":"saml","protocolMapper":"saml-group-membership-mapper","config":{"attribute.name":"groups","full.path":"false","single.value":"false","attribute.nameformat":"Basic","friendly.name":"groups"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
fi

echo ""
echo "=== Step 7: Register Keycloak as SAML IDP in CPFS ==="
SAML_IDP_PAYLOAD="{
  \"name\": \"keycloak-saml\",
  \"description\": \"Keycloak SAML SSO Identity Provider\",
  \"protocol\": \"saml\",
  \"type\": \"Keycloak\",
  \"jit\": true,
  \"enabled\": true,
  \"idp_config\": {
    \"idp_metadata\": \"${SAML_META_B64}\",
    \"want_assertions_signed\": true,
    \"token_attribute_mappings\": {
      \"sub\": \"NameID\",
      \"given_name\": \"givenName\",
      \"family_name\": \"lastName\",
      \"groups\": \"groups\",
      \"email\": \"email\"
    }
  }
}"

echo "Registering SAML IDP in CPFS..."
SAML_RESP=$(curl -sk -X POST "https://platform-identity-provider:4300/v3/auth/idsource" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$SAML_IDP_PAYLOAD" -w "\nHTTP:%{http_code}")
echo "$SAML_RESP"

echo ""
echo "=== Step 8: Verify SAML IDP registered ==="
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://platform-identity-provider:4300/v3/auth/idsource/?protocol=saml"

echo ""
echo "=== DONE ==="
