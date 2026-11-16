#!/usr/bin/env bash
# Run Renovate in a Docker container.
#   ./renovate.sh           open/update dependency PRs on GitHub (needs RENOVATE_TOKEN)
#   ./renovate.sh --local   dry run on the working tree: lists the updates found, changes nothing, no token
# Override with RENOVATE_IMAGE, RENOVATE_REPOSITORY (owner/name), RENOVATE_GIT_AUTHOR and LOG_LEVEL.
set -euo pipefail
cd "$(dirname "$0")"

image="${RENOVATE_IMAGE:-renovate/renovate:44.198.3}"

if [ "${1:-}" = "--local" ]; then
	exec docker run --rm \
		-v "$PWD":/usr/src/app:ro \
		-e RENOVATE_CONFIG_FILE=/usr/src/app/renovate.json \
		-e LOG_LEVEL="${LOG_LEVEL:-debug}" \
		"$image" --platform=local --dry-run=lookup
fi

if [ -z "${RENOVATE_TOKEN:-}" ]; then
	echo "Error: set RENOVATE_TOKEN to a GitHub token (see README), or use --local for a dry run" >&2
	exit 1
fi

# owner/name taken from the origin remote unless RENOVATE_REPOSITORY is set
repo="${RENOVATE_REPOSITORY:-$(git remote get-url origin | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')}"

# commit author: not Renovate's default (a Mend-owned address); override with RENOVATE_GIT_AUTHOR
exec docker run --rm \
	-e RENOVATE_TOKEN \
	-e RENOVATE_GIT_AUTHOR="${RENOVATE_GIT_AUTHOR:-Renovate Bot <${repo%%/*}@users.noreply.github.com>}" \
	-e RENOVATE_ONBOARDING=false \
	-e RENOVATE_REQUIRE_CONFIG=required \
	-e LOG_LEVEL="${LOG_LEVEL:-info}" \
	"$image" "$repo"
