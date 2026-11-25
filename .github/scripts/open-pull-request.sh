#!/usr/bin/env bash
#
# Commits working-tree changes to a branch and opens or updates its pull
# request. Used by the scheduled maintenance workflows.
#
# Required environment:
#   GH_TOKEN    Token with contents:write and pull-requests:write.
#   PR_BRANCH   Branch that carries the change.
#   PR_TITLE    Pull request title, also used as the commit message.
#   PR_BODY     Pull request description.
#   PR_PATHS    Comma-separated paths to commit.
#
# Optional environment:
#   PR_LABELS   Comma-separated labels for a newly opened pull request.
set -Eeuo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${PR_BRANCH:?PR_BRANCH is required}"
: "${PR_TITLE:?PR_TITLE is required}"
: "${PR_BODY:?PR_BODY is required}"
: "${PR_PATHS:?PR_PATHS is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"

readonly BASE_BRANCH="${GITHUB_REF_NAME}"
readonly REMOTE_REF="refs/heads/${PR_BRANCH}"

[[ "${PR_BRANCH}" != "${BASE_BRANCH}" ]] || {
    echo "Refusing to push to the base branch: ${BASE_BRANCH}" >&2
    exit 1
}

IFS=',' read -r -a paths <<< "${PR_PATHS}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git switch --quiet --force-create "${PR_BRANCH}"
git add -- "${paths[@]}"

if git diff --cached --quiet; then
    echo "Nothing to commit."
    exit 0
fi

git commit --quiet --message "${PR_TITLE}"

# Skip the push when the branch already holds this change, so an open pull
# request is not given a new commit (and a new CI run) on every schedule.
if git fetch --quiet origin "${REMOTE_REF}" 2>/dev/null &&
    [[ "$(git rev-parse 'FETCH_HEAD^{tree}')" == "$(git rev-parse 'HEAD^{tree}')" ]]; then
    echo "Branch ${PR_BRANCH} already contains this change."
else
    git push --quiet --force origin "HEAD:${REMOTE_REF}"
    echo "Pushed ${PR_BRANCH}."
fi

pr_number="$(
    gh api --method GET "repos/${GITHUB_REPOSITORY}/pulls" \
        -f state=open \
        -f head="${GITHUB_REPOSITORY_OWNER}:${PR_BRANCH}" \
        -f base="${BASE_BRANCH}" \
        --jq '.[0].number // empty'
)"

if [[ -n "${pr_number}" ]]; then
    gh api --silent --method PATCH "repos/${GITHUB_REPOSITORY}/pulls/${pr_number}" \
        -f title="${PR_TITLE}" \
        -f body="${PR_BODY}"
    echo "Updated pull request #${pr_number}."
    exit 0
fi

pr_number="$(
    gh api --method POST "repos/${GITHUB_REPOSITORY}/pulls" \
        -f title="${PR_TITLE}" \
        -f body="${PR_BODY}" \
        -f head="${PR_BRANCH}" \
        -f base="${BASE_BRANCH}" \
        --jq '.number'
)"
echo "Opened pull request #${pr_number}."

if [[ -n "${PR_LABELS:-}" ]]; then
    IFS=',' read -r -a labels <<< "${PR_LABELS}"
    label_args=()
    for label in "${labels[@]}"; do
        label_args+=(-f "labels[]=${label}")
    done

    # Labels are cosmetic; a labelling failure must not fail the run.
    gh api --silent --method POST "repos/${GITHUB_REPOSITORY}/issues/${pr_number}/labels" \
        "${label_args[@]}" ||
        echo "::warning::Could not label pull request #${pr_number}."
fi
