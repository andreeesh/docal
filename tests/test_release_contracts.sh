#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import ast
from pathlib import Path
import re
import sys
from urllib.parse import unquote

root = Path(sys.argv[1]).resolve()
scripts = sorted((root / 'scripts').glob('*.py'))
assert scripts, 'No Python source files found'
for script in scripts:
    ast.parse(script.read_text(encoding='utf-8'), filename=str(script))

# Catch broken local documentation links without making any network requests.
docs = [root / 'README.md', root / 'CONTRIBUTING.md']
docs += sorted((root / 'docs').rglob('*.md'))
assert all(p.is_file() for p in docs)
problems = []
link_pattern = re.compile(r'\]\(([^)]+)\)')
for document in docs:
    for target in link_pattern.findall(document.read_text(encoding='utf-8')):
        value = target.strip()
        if value.startswith(('https://', 'http://', 'mailto:', '#', 'data:')):
            continue
        if value.startswith('<') and '>' in value:
            value = value[1:value.index('>')]
        else:
            value = value.split(' "', 1)[0]
        path = unquote(value.split('#', 1)[0].split('?', 1)[0])
        if not path:
            continue
        resolved = (document.parent / path).resolve()
        if not resolved.is_relative_to(root) or not resolved.exists():
            problems.append(f'{document.relative_to(root)} -> {target}')
assert not problems, 'Broken local documentation links:\n' + '\n'.join(problems)

# Guard against merging stale feature-branch release disclaimers back into
# the main user-facing instructions. More specific status lives in changelog.
user_docs = [root / 'README.md'] + [root / 'docs' / name for name in (
    'commands.md', 'import-ssh.md', 'import-zip-sql-design.md',
    'safe-start.md', 'importing-sites.md', 'security.md',
)]
stale = (
    'experimental in PR #6',
    'experimental PR #7',
    'experimental on the development branch',
    'real remote end-to-end tests are still pending',
    'real SSH E2E test is still pending',
    'not yet connected to Docal CLI',
    'no real end-to-end Docker/MySQL restoration has been confirmed',
)
for document in user_docs:
    data = document.read_text(encoding='utf-8').lower()
    for phrase in stale:
        assert phrase.lower() not in data, f'{document.name}: obsolete claim: {phrase}'

safe_doc = (root / 'docs/safe-start.md').read_text(encoding='utf-8')
assert 'already-running' in safe_doc
assert 'disposable' in safe_doc.lower()
assert '--safe' in (root / 'README.md').read_text(encoding='utf-8')
assert '--ssh' in (root / 'docs/import-ssh.md').read_text(encoding='utf-8')

release_workflow = (root / '.github/workflows/publish-release.yml').read_text(encoding='utf-8')
assert re.search(r'(?ms)^on:\n  workflow_dispatch:', release_workflow), (
    'Release publication must remain manual via workflow_dispatch'
)
workflow_triggers = release_workflow.split('permissions:', 1)[0]
assert not re.search(r'(?m)^  (push|pull_request):', workflow_triggers), (
    'Release publication must not be triggered automatically'
)
assert 'refs/remotes/origin/main' in release_workflow, (
    'The release workflow must verify the exact current main SHA'
)
assert '== "$(tr -d' in release_workflow, 'The requested version must match VERSION'
assert 'gh release view "$TAG"' in release_workflow, 'Existing releases must be rejected'
assert 'git tag -a' in release_workflow, 'Release tags must remain annotated'
assert 'gh release create' in release_workflow
assert re.search(r'for job in tests shell-checks mailpit-docker;', release_workflow), (
    'The release gate must require Mailpit Docker integration on the exact release SHA'
)
mailpit_workflow = (root / '.github/workflows/mailpit-integration.yml').read_text(encoding='utf-8')
push = re.search(r'(?ms)^  push:\n(.*?)(?=^\S|\Z)', mailpit_workflow)
assert push and re.search(r'(?m)^    branches: \[main\]$', push.group(1)), (
    'Mailpit Docker integration must run on pushes to main'
)
assert not re.search(r'(?m)^    paths:', push.group(1)), (
    'Push path filters can skip mailpit-docker on a release-only main commit'
)
assert (root / 'VERSION').read_text(encoding='utf-8').strip() == '0.4.0'
assert re.search(r'(?m)^## \[0\.4\.0\]$', (root / 'CHANGELOG.md').read_text(encoding='utf-8'))
assert (root / 'docs/releases/v0.4.0.md').is_file(), 'Missing v0.4.0 release notes'

print(f'Release contract checks passed: {len(scripts)} Python parsers, '
      f'{len(docs)} documentation files, no stale import claims')
PY
