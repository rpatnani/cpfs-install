#!/bin/sh
TOKEN=$(curl -sk -X POST https://platform-identity-provider:4300/v1/auth/identitytoken \
  -d 'grant_type=password&username=cpadmin&password=qGUpKwVM4tOG4AiRfXzu9E49gqE1VuGF&scope=openid' \
  | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
echo "Token length: ${#TOKEN}"
echo "Existing IDPs:"
curl -sk -H "Authorization: Bearer $TOKEN" "https://platform-identity-management:4500/idmgmt/identity/api/v1/directory/idp" 2>&1
