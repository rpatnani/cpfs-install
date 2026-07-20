#!/bin/sh
KC_TOKEN=$(curl -sk -X POST 'https://keycloak-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/realms/master/protocol/openid-connect/token' \
  -d 'grant_type=password&client_id=admin-cli&username=admin&password=a912eadf6da041e38f1ef44a8bd33fc4' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "Token length: ${#KC_TOKEN}"

echo "Creating test user keycloak-user1..."
curl -sk -X POST 'https://keycloak-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/admin/realms/cloudpak/users' \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"username":"keycloak-user1","enabled":true,"email":"keycloak-user1@example.com","firstName":"Keycloak","lastName":"User1","credentials":[{"type":"password","value":"KeycloakUser1Pass@2026","temporary":false}]}' \
  -w '\nHTTP:%{http_code}'
echo ""

echo "Creating kc-admin user..."
curl -sk -X POST 'https://keycloak-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/admin/realms/cloudpak/users' \
  -H "Authorization: Bearer $KC_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"username":"kc-admin","enabled":true,"email":"kc-admin@example.com","firstName":"KC","lastName":"Admin","credentials":[{"type":"password","value":"KcAdmin2026@Pass","temporary":false}]}' \
  -w '\nHTTP:%{http_code}'
echo ""

echo "Listing users in cloudpak realm..."
curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  'https://keycloak-ibm-operators.apps.rpatnani2026.cp.fyre.ibm.com/admin/realms/cloudpak/users' \
  | grep -o '"username":"[^"]*"'
