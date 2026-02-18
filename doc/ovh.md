# Create API credentials for the DNS01 challenge

## Create OVH API Application (one-time setup)

- Visit: https://eu.api.ovh.com/createApp/ (or your region: ca, us, etc.)
- Log in with your OVH account
- Fill in application name and description
- You'll receive:
  - `application_key`
  - `application_secret`

## Generate Consumer Key (with DNS permissions)

```bash
OVH_APPLICATION_KEY="APPLICATION_KEY"

curl -X POST https://eu.api.ovh.com/1.0/auth/credential \
	-H "X-Ovh-Application: $OVH_APPLICATION_KEY" \
	-H "Content-Type: application/json" \
	-d '{
    "accessRules": [
      {"method": "GET", "path": "/domain/zone/*"},
      {"method": "POST", "path": "/domain/zone/*"},
      {"method": "DELETE", "path": "/domain/zone/*"},
      {"method": "PUT", "path": "/domain/zone/*"}
    ]
  }'
```

This returns a `validationUrl` - visit it to authorize and get your `consumer_key`.

## Store credentials securely

```bash
# In a protected file
cat > ~/.ovh_credentials << EOF
dns_ovh_endpoint = ovh-eu
dns_ovh_application_key = YOUR_APP_KEY
dns_ovh_application_secret = YOUR_APP_SECRET
dns_ovh_consumer_key = YOUR_CONSUMER_KEY
EOF
chmod 600 ~/.ovh_credentials
```

## Use in Nginx Proxy Manager
Paste these values into the DNS challenge configuration when creating/renewing certificates with the OVH DNS provider option.

The credentials are permanent until revoked - create them once, store securely, reuse programmatically.
