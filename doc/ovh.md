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

## Store the credentials in SecretSpec

Put the three values in SecretSpec, one set per environment (they are declared in `secretspec.toml`):

```bash
secretspec set OVH_APPLICATION_KEY --profile dev
secretspec set OVH_APPLICATION_SECRET --profile dev
secretspec set OVH_CONSUMER_KEY --profile dev
```

`deploy.yml` hands them to Nginx Proxy Manager (as `dns_ovh_endpoint`, `dns_ovh_application_key`,
`dns_ovh_application_secret` and `dns_ovh_consumer_key`) when it requests the certificate, so there is nothing to
paste in the NPM UI. The endpoint (`ovh-eu` by default) is the `ovh_endpoint` setting.

The credentials are permanent until revoked: create them once and reuse them.
