#!/usr/bin/env bash
# Usage: ./run.sh [playbook] [ansible-playbook args...]   e.g. ./run.sh setup.yml (found in playbooks/)
# Without a playbook (or when the first argument is an option, e.g. ./run.sh -e run_repair=true)
# you pick one with fzf, if it is installed.
# Uses ./inventory by default; override with INVENTORY=/path/to/inventory.
# Vault password: ./.vault_pass if present, otherwise you are prompted.
set -euo pipefail
cd "$(dirname "$0")"

available() { (cd playbooks && ls -- *.yml | tr '\n' ' '); }

inventory="${INVENTORY:-inventory}"
if [ ! -e "$inventory" ]; then
	echo "Error: inventory '$inventory' not found. Copy inventory.example/ to inventory/ and edit it." >&2
	exit 1
fi

vault_args=(--ask-vault-pass)
[ -f .vault_pass ] && vault_args=(--vault-password-file .vault_pass)

if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
	# no playbook given: choose one interactively
	if ! command -v fzf >/dev/null 2>&1; then
		echo "Error: you need to pass a playbook (install fzf to pick one interactively). Available: $(available)" >&2
		exit 1
	fi
	if [ ! -t 0 ]; then
		echo "Error: you need to pass a playbook when not running in a terminal. Available: $(available)" >&2
		exit 1
	fi
	# preview with syntax highlighting if bat is installed (called batcat on Debian/Ubuntu)
	preview='sed -n "1,40p" {}'
	for bat in batcat bat; do
		if command -v "$bat" >/dev/null 2>&1; then
			preview="$bat --style=plain --color=always --language=yaml --line-range=:40 {}"
			break
		fi
	done
	playbook=$(cd playbooks && ls -- *.yml | fzf --prompt='playbook> ' --height=40% --reverse \
		--header='Enter: run   Esc: cancel' --preview="$preview" --preview-window=right,60% || true)
	if [ -z "$playbook" ]; then
		echo "No playbook selected." >&2
		exit 1
	fi
else
	playbook="$1"
	shift
fi

# playbooks live in playbooks/; accept "setup.yml", "setup" or a path
[ -f "$playbook" ] || playbook="playbooks/${playbook%.yml}.yml"
if [ ! -f "$playbook" ]; then
	echo "Error: playbook not found. Available: $(available)" >&2
	exit 1
fi
echo "Running playbook $playbook..."
ansible-playbook -i "$inventory" "${vault_args[@]}" "$playbook" "$@"
