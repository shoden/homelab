#!/usr/bin/env bash
# Usage: ./run.sh <playbook.yml> [ansible-playbook args...]
# Uses ./inventory by default; override with INVENTORY=/path/to/inventory.
# Vault password: ./.vault_pass if present, otherwise you are prompted.
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -eq 0 ]; then
	echo "Error: You need to pass a playbook file" >&2
	exit 1
fi

inventory="${INVENTORY:-inventory}"
if [ ! -e "$inventory" ]; then
	echo "Error: inventory '$inventory' not found. Copy inventory.example/ to inventory/ and edit it." >&2
	exit 1
fi

vault_args=(--ask-vault-pass)
[ -f .vault_pass ] && vault_args=(--vault-password-file .vault_pass)

playbook="$1"
shift
echo "Running playbook $playbook..."
ansible-playbook -i "$inventory" "${vault_args[@]}" "$playbook" "$@"
