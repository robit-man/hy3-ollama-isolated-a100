#!/usr/bin/env bash
set -euo pipefail

REPO_NAME="${1:-hy3-ollama-a100-setup}"
VISIBILITY="${2:-private}"
DESCRIPTION="${3:-Publishing Hy3 isolated Ollama + A100 deployment scripts and service generator.}"

if [[ -n "${GITHUB_OWNER:-}" ]]; then
  OWNER_REPO="${GITHUB_OWNER}/${REPO_NAME}"
else
  OWNER_REPO="$(gh api user -q .login)/${REPO_NAME}"
fi

if [[ -f .git/config ]]; then
  echo "Repo already initialized."
else
  git init
fi

cat > .gitignore <<'EOF2'
node_modules/
.omnius/
.vscode/
.DS_Store
*.log
*.tmp
omnius-nextjs-geospatial/node_modules/
EOF2


git add README.md scripts/ configs/ templates/ run_hy3_entrypoint.sh deploy_hy3.sh .gitignore

git commit -m "Add Hy3 isolated Ollama build, A100 config, service generator, and publish tooling" || true

gh repo view "${OWNER_REPO}" --json nameWithOwner >/dev/null 2>&1 || gh repo create "${REPO_NAME}" --private --description "$DESCRIPTION" --source=. --remote origin

gh repo set-default "${OWNER_REPO}" >/dev/null 2>&1 || true

git push -u origin HEAD

echo "Published to https://github.com/${OWNER_REPO}"
