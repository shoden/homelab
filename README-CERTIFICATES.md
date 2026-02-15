# Certificate Management

## Fetching Certificates

To fetch the Caddy SSL certificates for installation on your devices:

```bash
ansible-playbook -i inventory.ini fetch-certificate.yml
```

This will:
1. Connect to your Nextcloud server
2. Locate the Caddy-generated certificates
3. Download them to `./certificates/` directory
4. Create installation instructions

## What Gets Downloaded

- **caddy-root-ca.crt** - The root CA certificate (MOST IMPORTANT)
  - Install this once on each device
  - Allows device to trust all Caddy-issued certificates
  
- **\*.crt / \*.pem** - Domain-specific certificates
  - Usually not needed if you install the root CA
  - Useful for debugging certificate chains

## Quick Start

After running the playbook:

```bash
cd certificates/
cat INSTALL-INSTRUCTIONS.txt  # Read platform-specific installation steps
```

## Why This Is Needed

Your Nextcloud uses `myhost.local` (a local domain). Caddy generates **self-signed certificates** for local domains since Let's Encrypt doesn't support `.local` TLDs.

By installing the Caddy root CA on your devices, you:
- ✅ Eliminate browser SSL warnings
- ✅ Enable mobile app connections
- ✅ Allow desktop client sync
- ✅ Enable API/WebDAV access

## Troubleshooting

### No certificates found
- Ensure Nextcloud stack is running: `docker ps`
- Check if you've accessed Nextcloud via HTTPS at least once
- Caddy generates certificates on first request

### Browser still shows warning
- Verify you installed the **root CA** certificate
- Restart browser after installation
- Clear browser SSL cache (Chrome: `chrome://restart`)

### Mobile app won't connect
- iOS: Enable "Full Trust" in Certificate Trust Settings
- Android: Ensure certificate installed as "VPN and apps"

## Security Note

The root CA private key remains on the server. Only the public certificate is downloaded, which is safe to distribute to your devices.

## Re-running

You can re-run this playbook anytime to fetch updated certificates. Caddy may regenerate certificates periodically or after configuration changes.
