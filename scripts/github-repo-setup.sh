#!/usr/bin/env bash
# Apply sane default repo policies to the GitHub mirror (branch protection,
# security features, merge/housekeeping settings, metadata). Idempotent: every
# call is a PUT/PATCH that sets absolute desired state, so re-running after a
# manual settings change just re-asserts these defaults.
#
# Requires: gh CLI, authenticated as an account with admin on the repo
#   (gh auth switch --user <you>).
#
# Usage:
#   bash scripts/github-repo-setup.sh [owner/repo]
#   (defaults to PieterPel/harnt.nvim)
set -euo pipefail

REPO="${1:-PieterPel/harnt.nvim}"
BRANCH="trunk"

echo "==> Repo metadata"
gh repo edit "$REPO" \
  --description "Drive any native-TUI coding agent in Neovim at full fidelity via reverse-MCP." \
  --homepage "https://github.com/$REPO" \
  --add-topic neovim --add-topic neovim-plugin --add-topic ai --add-topic agents --add-topic mcp \
  --enable-squash-merge=true \
  --enable-merge-commit=false \
  --enable-rebase-merge=false \
  --delete-branch-on-merge=true \
  --enable-wiki=false \
  --enable-projects=false \
  --enable-discussions=false

echo "==> Branch protection ($BRANCH)"
# required_approving_review_count=0: a PR is mandatory (no direct pushes to
# trunk) but this is a solo-maintainer repo, so we don't require a second
# approver. enforce_admins=false so the owner isn't ever locked out of their
# own repo in an emergency; that's the one deliberate soft spot in this policy.
gh api --method PUT "repos/$REPO/branches/$BRANCH/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - <<EOF
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["check (default)", "pr-title"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF

echo "==> Security features"
gh api --method PATCH "repos/$REPO" \
  -H "Accept: application/vnd.github+json" \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' \
  -f 'security_and_analysis[dependabot_security_updates][status]=enabled' \
  >/dev/null

gh api --method PUT "repos/$REPO/vulnerability-alerts" -H "Accept: application/vnd.github+json"
gh api --method PUT "repos/$REPO/private-vulnerability-reporting" -H "Accept: application/vnd.github+json"

echo "==> Actions permissions"
# release-please (and any other bot workflow) needs this to open its release PR.
gh api --method PUT "repos/$REPO/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true \
  >/dev/null

echo "==> Done. Current state:"
gh api "repos/$REPO" --jq '.security_and_analysis'
gh api "repos/$REPO/branches/$BRANCH/protection" --jq '{required_status_checks, enforce_admins: .enforce_admins.enabled, required_pull_request_reviews, allow_force_pushes: .allow_force_pushes.enabled, allow_deletions: .allow_deletions.enabled}'
