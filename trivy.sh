#!/usr/bin/env bash
# Vulnerability scan with Trivy (Aqua Security), run in Docker. The same scans run in CI (.github/workflows/trivy.yml).
#   ./trivy.sh list      the container images pinned in playbooks/templates/docker-compose.yml.j2, one per line
#   ./trivy.sh images    scan those images (pulls them from their registries, no local Docker images needed)
#   ./trivy.sh image REF scan one image, e.g. ./trivy.sh image redis:8.10.3-alpine
#   ./trivy.sh fs        scan the repository files: the npm lockfile in e2e/ and leaked secrets
#   ./trivy.sh           images and fs
# Every finding is reported; the exit code is 1 only if a CRITICAL vulnerability that has a fix (or a CRITICAL
# secret) is found. Accepted findings go in .trivyignore.yaml (with a reason and an expiry date).
# Override with TRIVY_IMAGE (the scanner image) and TRIVY_SEVERITY (what the report shows).
set -euo pipefail
cd "$(dirname "$0")"

trivy_image="${TRIVY_IMAGE:-aquasec/trivy:0.76.2}"
report_severity="${TRIVY_SEVERITY:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}"
compose=playbooks/templates/docker-compose.yml.j2

trivy() {
	# the vulnerability database is cached in a Docker volume between runs
	docker run --rm -v trivy-cache:/root/.cache -v "$PWD":/src:ro -w /src "$trivy_image" "$@"
}

list_images() {
	local images
	images="$(sed -nE "s/^[[:space:]]*image:[[:space:]]*['\"]?([^'\" #]+).*/\1/p" "$compose")"
	if [ -z "$images" ] || grep -q '[{}]' <<<"$images"; then
		echo "Error: could not read plain image references from $compose (templated image?)" >&2
		exit 1
	fi
	sort -u <<<"$images"
}

failed=()

# scan <kind> <target>: report everything, then gate on CRITICAL findings that have a fix
scan() {
	local kind="$1" target="$2"
	local common=(--quiet --ignorefile .trivyignore.yaml)
	local extra=()
	if [ "$kind" = fs ]; then
		# --include-dev-deps: everything in e2e/ (Playwright) is a devDependency, which Trivy skips by default
		extra=(--scanners vuln,secret --include-dev-deps --skip-dirs .git,e2e/node_modules,e2e/test-results,inventory,certs)
	else
		extra=(--scanners vuln)
	fi
	echo "=== $kind: $target"
	trivy "$kind" "${common[@]}" "${extra[@]}" --severity "$report_severity" "$target" || true
	trivy "$kind" "${common[@]}" "${extra[@]}" --severity CRITICAL --ignore-unfixed --exit-code 1 \
		--format json --output /dev/null "$target" || failed+=("$kind $target")
}

scan_images() {
	local image
	while read -r image; do
		scan image "$image"
	done < <(list_images)
}

case "${1:-all}" in
list)
	list_images
	;;
images)
	scan_images
	;;
image)
	[ -n "${2:-}" ] || { echo "Usage: $0 image REF" >&2; exit 1; }
	scan image "$2"
	;;
fs)
	scan fs .
	;;
all)
	scan_images
	scan fs .
	;;
*)
	echo "Usage: $0 [list|images|image REF|fs]" >&2
	exit 1
	;;
esac

if [ "${#failed[@]}" -gt 0 ]; then
	echo
	echo "CRITICAL findings with a fix in:" >&2
	printf '  %s\n' "${failed[@]}" >&2
	exit 1
fi
