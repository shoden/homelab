#!/usr/bin/env bash
# Usage: ./run.sh [playbook] [environment] [ansible-playbook args...]
#   ./run.sh deploy.yml prod          playbooks are found in playbooks/ ("deploy.yml", "deploy" or a path)
#   ./run.sh deploy dev --check       the environment is a directory of inventory/ (prod, dev, ...)
#   ./run.sh release_branch           release a branch: dev, merge into main, prod (see release_branch.sh)
# Without a playbook (or when the first argument is an option, e.g. ./run.sh -e run_repair=true) you pick
# one with fzf, if fzf and yq are installed. Without an environment you pick one the same way, unless
# inventory/ has only one.
# INVENTORY=/path/to/inventory uses that inventory instead of inventory/<environment>.
# Credentials: secretspec.toml. The playbook runs inside `secretspec run --profile <environment> --`, so the
# secrets of that environment's profile reach Ansible as environment variables. With INVENTORY set, the profile
# is SECRETSPEC_PROFILE, or the name of the inventory directory.
set -euo pipefail
cd "$(dirname "$0")"

available() { (cd playbooks && ls -- *.yml | tr '\n' ' '); }
environments() { (cd inventory 2>/dev/null && ls -d -- */ 2>/dev/null | tr -d '/' | tr '\n' ' '); }

# fzf is needed to choose interactively: say which tool is missing
require_picker() {
  local msg=$1
  shift
  for tool in fzf "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Error: $msg (the interactive picker needs fzf${*:+ and $*}; '$tool' is missing)" >&2
      exit 1
    fi
  done
  if [ ! -t 0 ]; then
    echo "Error: $msg (and you are not in a terminal, so nothing can be picked)" >&2
    exit 1
  fi
}

if ! command -v secretspec >/dev/null 2>&1; then
  echo "Error: secretspec is not installed (credentials come from it, see secretspec.toml and https://secretspec.dev)." >&2
  exit 1
fi

# ---- playbook -------------------------------------------------------------------------------------
if [ $# -eq 0 ] || [[ "$1" == -* ]]; then
  require_picker "you need to pass a playbook. Available: $(available)" yq
  # one line per playbook: "<file without .yml> - <name of its first play>", e.g. "deploy - Deploy Nextcloud stack"
  selected=$({ for f in playbooks/*.yml; do
      printf '%s|- %s\n' "$(basename "$f" .yml)" "$(yq -r '.[0].name' "$f")"
    done
    printf '%s|- %s\n' release_branch "Release a branch: dev, merge into main, push, prod"
    } | column -t -s '|' | fzf --prompt='playbook> ' --cycle --height=40% --reverse \
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

# not a playbook: a workflow of several deploys, in its own script
if [ "$playbook" = release_branch ]; then
  exec ./release_branch.sh "$@"
fi

# playbooks live in playbooks/; accept "deploy.yml", "deploy" or a path
[ -f "$playbook" ] || playbook="playbooks/${playbook%.yml}.yml"
if [ ! -f "$playbook" ]; then
  echo "Error: playbook not found. Available: $(available)" >&2
  exit 1
fi

# ---- environment ----------------------------------------------------------------------------------
if [ -n "${INVENTORY:-}" ]; then
  inventory="$INVENTORY"
  where="$INVENTORY"
else
  if [ -f inventory/hosts.ini ] || [ -d inventory/group_vars ]; then
    echo "Error: inventory/ still has the old single-environment layout. Move its contents into inventory/prod/ (see inventory.example/)." >&2
    exit 1
  fi
  envs=$(environments || true)
  if [ -z "$envs" ]; then
    echo "Error: no environments in inventory/. Copy inventory.example/prod (and dev) to inventory/ and edit them." >&2
    exit 1
  fi
  if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    env="$1"
    shift
    if [ ! -d "inventory/$env" ]; then
      echo "Error: unknown environment '$env'. Available: $envs" >&2
      exit 1
    fi
  elif [ "$(wc -w <<<"$envs")" -eq 1 ]; then
    env=${envs% }
  else
    require_picker "you need to pass an environment. Available: $envs"
    env=$(tr ' ' '\n' <<<"$envs" | grep -v '^$' | fzf --prompt='environment> ' --cycle --height=40% --reverse \
      --header='Enter: run   Esc: cancel' || true)
    if [ -z "$env" ]; then
      echo "No environment selected." >&2
      exit 1
    fi
  fi
  inventory="inventory/$env"
  where="environment '$env'"
fi
profile=${env:-${SECRETSPEC_PROFILE:-$(basename "$inventory")}}

echo "Running playbook $playbook on $where..."
secretspec run --profile "$profile" -- ansible-playbook -i "$inventory" "$playbook" "$@"
