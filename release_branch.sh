#!/usr/bin/env bash
# Usage: ./run.sh release_branch
# Releases a branch: pick it (fzf), rebase it onto main if it is behind, deploy it to dev with the end-to-end test,
# fast-forward main to it, push main to origin and deploy it to prod. It stops at the first thing that fails.
# Everything is inside functions and the last line exits: this script switches branches, which can rewrite this
# very file while bash is still reading it.
set -euo pipefail

main_branch=main

die() { echo "Error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
confirm() {
  local answer
  read -r -p "$1 [y/N] " answer || return 1
  [[ "$answer" == [yY] ]]
}

require_clean() {
  [ -z "$(git status --porcelain --untracked-files=no)" ] ||
    die "the workspace has uncommitted changes. Commit or stash them first (git status)."
}

has_ref() { git show-ref --verify --quiet "$1"; }

# local branches and branches that only exist on origin, without main
branches() {
  git for-each-ref --format='%(refname)' refs/heads refs/remotes/origin |
    sed -e 's|^refs/heads/||' -e 's|^refs/remotes/origin/||' |
    grep -vxE "$main_branch|HEAD" | sort -u
}

fetch_origin() {
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch --prune origin || die "cannot fetch from origin."
  fi
}

# fast-forward the checked out branch to its copy on origin, if there is one
update_from_origin() {
  local branch=$1 remote="refs/remotes/origin/$1"
  has_ref "$remote" || return 0
  if git merge-base --is-ancestor HEAD "$remote"; then
    git merge --ff-only --quiet "$remote"
  elif ! git merge-base --is-ancestor "$remote" HEAD; then
    # diverged. Harmless if every commit on origin is also here (a branch rebased by an earlier run)
    if git cherry HEAD "$remote" | grep -q '^+'; then
      [ "$branch" != "$main_branch" ] || die "$main_branch and origin/$main_branch have diverged. Sort that out first."
      echo "origin/$branch has commits that are not in your local $branch:"
      git --no-pager log --oneline --cherry-pick --right-only "HEAD...$remote"
      confirm "Release the LOCAL branch, without them?" || die "stopped. Update $branch and run again."
    fi
  fi
}

rebase_on_main() {
  local branch=$1 answer
  if git merge-base --is-ancestor "$main_branch" HEAD; then
    echo "$branch is up to date with $main_branch."
    return 0
  fi
  step "Rebasing $branch onto $main_branch"
  git rebase "$main_branch" && return 0

  echo
  echo "The rebase stopped. Files with conflicts:"
  git --no-pager diff --name-only --diff-filter=U
  read -r -p "[a]bort the rebase (default) or [k]eep it to resolve by hand? " answer || answer=a
  if [[ "$answer" == [kK] ]]; then
    die "resolve the conflicts, 'git add' the files, 'git rebase --continue' until it finishes, then run ./run.sh release_branch again."
  fi
  git rebase --abort
  die "rebase aborted, $branch is as it was. Nothing was deployed."
}

release() {
  [ $# -eq 0 ] || die "release_branch takes no arguments."
  [ -z "${INVENTORY:-}" ] || die "unset INVENTORY: release_branch uses inventory/dev and inventory/prod."
  [ -d inventory/dev ] && [ -d inventory/prod ] || die "release_branch needs inventory/dev and inventory/prod."
  command -v fzf >/dev/null 2>&1 || die "fzf is not installed."
  [ -t 0 ] || die "release_branch is interactive, run it in a terminal."
  require_clean

  step "Fetching"
  fetch_origin

  local branch list
  list=$(branches || true)
  [ -n "$list" ] || die "there are no branches to release besides $main_branch."
  branch=$(fzf --prompt='branch> ' --cycle --height=40% --reverse \
    --header='Branch to release   Enter: select   Esc: cancel' <<<"$list" || true)
  [ -n "$branch" ] || die "no branch selected."

  step "Updating $main_branch"
  git switch "$main_branch"
  update_from_origin "$main_branch"

  step "Checking out $branch"
  if has_ref "refs/heads/$branch"; then
    git switch "$branch"
  else
    git switch --create "$branch" --track "origin/$branch"
  fi
  update_from_origin "$branch"
  rebase_on_main "$branch"

  [ "$(git rev-parse HEAD)" != "$(git rev-parse "$main_branch")" ] ||
    die "$branch has nothing that is not already in $main_branch."
  step "Commits to release"
  git --no-pager log --oneline "$main_branch..HEAD"

  local tested
  tested=$(git rev-parse HEAD)

  step "Deploying $branch to dev (with the end-to-end test)"
  ./run.sh deploy.yml dev -e e2e_force=true ||
    die "the dev deploy or its end-to-end test failed. $main_branch and prod are untouched; you are on $branch."

  # what goes to main must be exactly what was tested on dev, on top of the current main
  require_clean
  [ "$(git rev-parse HEAD)" = "$tested" ] || die "HEAD changed during the dev deploy. Run again."
  fetch_origin
  if has_ref "refs/remotes/origin/$main_branch"; then
    git merge-base --is-ancestor "origin/$main_branch" "$tested" ||
      die "origin/$main_branch got new commits during the dev deploy. Run again to test them with $branch."
  fi

  step "Merging $branch into $main_branch"
  git switch "$main_branch"
  git merge --ff-only "$tested" ||
    die "$main_branch changed during the dev deploy. Run again."

  # push before prod, so what prod runs is always on origin
  if git remote get-url origin >/dev/null 2>&1; then
    step "Pushing $main_branch to origin"
    git push origin "$main_branch" ||
      die "the push failed, so prod was not deployed. $branch is already merged into your local $main_branch."
  fi

  step "Deploying $main_branch to prod"
  ./run.sh deploy.yml prod ||
    die "the prod deploy FAILED. $branch is already merged into $main_branch and pushed; retry with ./run.sh deploy.yml prod."

  step "Released $branch"
}

cd "$(dirname "$0")"
release "$@"; exit
