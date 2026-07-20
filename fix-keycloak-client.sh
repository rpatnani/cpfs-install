#!/bin/sh
# Fix Keycloak SAML client to use correct SP entity ID and ACS URL

KEYCLOAK_URL="https://keycloak-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com"
KEYCLOAK_REALM="cloudpak"
KC_ADMIN_PASS="a912eadf6da041e38f1ef44a8bd33fc4"

# CPFS Liberty SP actual entity ID (from samlmetadata):
# https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idauth/ibm/saml20/defaultSP
SP_ENTITY_ID="https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idauth/ibm/saml20/defaultSP"
ACS_URL="https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idauth/ibm/saml20/defaultSP/acs"
LOGOUT_URL="https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idauth/ibm/saml20/defaultSP/slo"

echo "=== Step 1: Get Keycloak admin token ==="
KC_TOKEN=$(curl -sk -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=${KC_ADMIN_PASS}" \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "Token length: ${#KC_TOKEN}"

echo ""
echo "=== Step 2: List existing clients in cloudpak realm ==="
curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients?search=true&clientId=cpfs" \
  | grep -o '"id":"[^"]*"\|"clientId":"[^"]*"'

echo ""
echo "=== Step 3: Find our previously created client ==="
OLD_ENTITY_ID="https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/ibm/saml20/defaultSP"
# Get internal ID of old client
OLD_CLIENT_ID=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
  | grep -o '"id":"[^"]*","clientId":"[^"]*"' | grep "ibm/saml20/defaultSP" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
echo "Old client ID: $OLD_CLIENT_ID"

echo ""
echo "=== Step 4: Delete old client if found ==="
if [ -n "$OLD_CLIENT_ID" ]; then
  curl -sk -X DELETE -H "Authorization: Bearer $KC_TOKEN" \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${OLD_CLIENT_ID}" -w "\nHTTP:%{http_code}"
  echo ""
fi

echo ""
echo "=== Step 5: Create correct SAML client ==="
KC_CLIENT_PAYLOAD="{
  \"clientId\": \"${SP_ENTITY_ID}\",
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
    \"saml_name_id_format\": \"username\",
    \"saml_force_name_id_format\": \"false\"
  }
}"

echo "Creating correct Keycloak SAML client..."
CREATE_RESP=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$KC_CLIENT_PAYLOAD" -w "\nHTTP:%{http_code}")
echo "$CREATE_RESP"

echo ""
echo "=== Step 6: Get new client internal ID ==="
NEW_CLIENT_ID=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients" \
  | grep -o '"id":"[^"]*","clientId":"[^"]*"' | grep "idauth" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
echo "New client ID: $NEW_CLIENT_ID"

echo ""
echo "=== Step 7: Add protocol mappers ==="
if [ -n "$NEW_CLIENT_ID" ]; then
  echo "Adding email mapper..."
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${NEW_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"email","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"email","attribute.name":"email","attribute.nameformat":"Basic","friendly.name":"email"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
  
  echo "Adding firstName mapper..."
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${NEW_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"firstName","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"firstName","attribute.name":"givenName","attribute.nameformat":"Basic","friendly.name":"givenName"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
  
  echo "Adding lastName mapper..."
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${NEW_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"lastName","protocol":"saml","protocolMapper":"saml-user-property-mapper","config":{"user.attribute":"lastName","attribute.name":"lastName","attribute.nameformat":"Basic","friendly.name":"lastName"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
  
  echo "Adding groups mapper..."
  curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${NEW_CLIENT_ID}/protocol-mappers/models" \
    -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    -d '{"name":"groups","protocol":"saml","protocolMapper":"saml-group-membership-mapper","config":{"attribute.name":"groups","full.path":"false","single.value":"false","attribute.nameformat":"Basic","friendly.name":"groups"}}' \
    -w "\nHTTP:%{http_code}"
  echo ""
fi

echo ""
echo "=== Step 8: Create a test user in Keycloak ==="
echo "Creating test user keycloak-user1..."
USER_RESP=$(curl -sk -X POST "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_REALM}/users" \
  -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  -d '{"username":"keycloak-user1","enabled":true,"email":"keycloak-user1@example.com","firstName":"Keycloak","lastName":"User1","credentials":[{"type":"password","value":"Passw0rd!","temporary":false}]}' \
  -w "\nHTTP:%{http_code}")
echo "$USER_RESP"

echo ""
echo "=== DONE ==="
echo "SAML SSO test URL: https://cp-console-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/idauth/idprovider/v1/saml/loginwithsaml"
