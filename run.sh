#!/usr/bin/env bash
# Usage: ./run.sh <playbook> [ansible-playbook args...]   e.g. ./run.sh setup.yml (found in playbooks/)
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
# playbooks live in playbooks/; accept "setup.yml", "setup" or a path
[ -f "$playbook" ] || playbook="playbooks/${playbook%.yml}.yml"
if [ ! -f "$playbook" ]; then
	echo "Error: playbook not found. Available: $(cd playbooks && ls *.yml | tr '\n' ' ')" >&2
	exit 1
fi
echo "Running playbook $playbook..."
ansible-playbook -i "$inventory" "${vault_args[@]}" "$playbook" "$@"
