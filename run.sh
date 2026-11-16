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
  for tool in fzf yq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Error: you need to pass a playbook (the interactive picker needs fzf and yq, '$tool' is missing). Available: $(available)" >&2
      exit 1
    fi
  done
  if [ ! -t 0 ]; then
    echo "Error: you need to pass a playbook when not running in a terminal. Available: $(available)" >&2
    exit 1
  fi
  # one line per playbook: "<file without .yml> - <name of its first play>", e.g. "setup - Deploy Nextcloud stack"
  selected=$(for f in playbooks/*.yml; do
      printf '%s|- %s\n' "$(basename "$f" .yml)" "$(yq -r '.[0].name' "$f")"
    done | column -t -s '|' | fzf --prompt='playbook> ' --cycle --height=40% --reverse \
      --header='Enter: run   Esc: cancel' || true)
  if [ -z "$selected" ]; then
    echo "No playbook selected." >&2
    exit 1
  fi
  playbook=${selected%% *}
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
