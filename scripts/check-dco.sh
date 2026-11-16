#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fails if any non-merge commit in BASE..HEAD lacks a Signed-off-by line (DCO).
#
#   scripts/check-dco.sh <base> <head>
set -euo pipefail

missing=0
for sha in $(git rev-list --no-merges "$1..$2"); do
    if [[ -z "$(git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$sha")" ]]; then
        echo "::error::$(git log -1 --format='%h %s' "$sha") is not signed off"
        missing=1
    fi
done

if (( missing )); then
    echo "Sign off with 'git rebase --signoff main' and force-push. See CONTRIBUTING.md." >&2
    exit 1
fi
echo "Every commit is signed off."
