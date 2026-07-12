#!/usr/bin/env bash
# Fail when two open pull requests claim the same monotonic Bridge counter.
#
# Live mode reads open PR diffs through GitHub CLI. Fixture mode is network-free:
#   COUNTER_COLLISION_FIXTURE_DIR=/path/to/diffs ./scripts/check-counter-collisions.sh
# Fixture files must be named <pr-number>-<title>.diff.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/TheBridge/Config/Version.swift"
FLOOR_FILE="$ROOT_DIR/scripts/test-floor-gate.sh"
FIXTURE_DIR="${COUNTER_COLLISION_FIXTURE_DIR:-}"

warn() {
    printf 'warning: check-counter-collisions: %s\n' "$*" >&2
}

fail() {
    printf 'error: check-counter-collisions: %s\n' "$*" >&2
    exit 2
}

is_ci() {
    [ "${GITHUB_ACTIONS:-}" = "true" ] || [ "${CI:-}" = "true" ]
}

# Fail loudly if the declarations this guard parses drift away from its regexes.
tool_count_matches="$(grep -Ec '^[[:space:]]*public static let staticFeatureModuleToolCount[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$' "$VERSION_FILE" || true)"
family_count_matches="$(grep -Ec '^[[:space:]]*public static let staticFeatureModuleFamilyCount[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$' "$VERSION_FILE" || true)"
floor_matches="$(grep -Ec '^FLOOR="\$\{BRIDGE_TEST_FLOOR:-[0-9]+\}"[[:space:]]*$' "$FLOOR_FILE" || true)"

[ "$tool_count_matches" -eq 1 ] || fail "Version.swift tool-count declaration format drifted (expected exactly one regex match, found $tool_count_matches)"
[ "$family_count_matches" -eq 1 ] || fail "Version.swift family-count declaration format drifted (expected exactly one regex match, found $family_count_matches)"
[ "$floor_matches" -ge 1 ] || fail "test-floor-gate.sh FLOOR declaration format drifted (expected at least one regex match)"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bridge-counter-collisions.XXXXXX")" || fail "could not create temporary directory"
trap 'rm -rf "$TMP_DIR"' EXIT
CLAIMS_FILE="$TMP_DIR/claims.tsv"
: > "$CLAIMS_FILE"

collect_claims() {
    pr_number="$1"
    pr_title="$2"
    diff_file="$3"
    parsed_file="$TMP_DIR/parsed-$pr_number.tsv"

    # Titles are display-only; keep the TSV record shape stable.
    pr_title="$(printf '%s' "$pr_title" | tr '\t\r\n' '   ')"

    sed -nE 's/^\+[[:space:]]*public static let (staticFeatureModule(Tool|Family)Count)[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1\t\3/p' "$diff_file" > "$parsed_file" || fail "could not parse PR #$pr_number counter diff"
    sed -nE 's/^\+[[:space:]]*FLOOR="\$\{BRIDGE_TEST_FLOOR:-([0-9]+)\}"[[:space:]]*$/FLOOR\t\1/p' "$diff_file" >> "$parsed_file" || fail "could not parse PR #$pr_number FLOOR diff"

    while IFS="$(printf '\t')" read -r counter value; do
        [ -n "$counter" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$counter" "$value" "$pr_number" "$pr_title" >> "$CLAIMS_FILE"
    done < "$parsed_file"
}

if [ -n "$FIXTURE_DIR" ]; then
    [ -d "$FIXTURE_DIR" ] || fail "fixture directory does not exist: $FIXTURE_DIR"
    fixture_count=0
    for diff_file in "$FIXTURE_DIR"/*.diff; do
        [ -e "$diff_file" ] || continue
        fixture_count=$((fixture_count + 1))
        fixture_name="$(basename "$diff_file" .diff)"
        pr_number="${fixture_name%%-*}"
        case "$pr_number" in
            ''|*[!0-9]*) fail "fixture must start with a numeric PR id: $diff_file" ;;
        esac
        pr_title="${fixture_name#"$pr_number"}"
        pr_title="${pr_title#-}"
        [ -n "$pr_title" ] || pr_title="fixture"
        collect_claims "$pr_number" "$pr_title" "$diff_file"
    done
    [ "$fixture_count" -gt 0 ] || fail "fixture directory contains no .diff files: $FIXTURE_DIR"
else
    if ! command -v gh >/dev/null 2>&1; then
        if is_ci; then
            fail "gh is required in CI but was not found"
        fi
        warn "gh is not installed; skipping live open-PR collision check locally"
        exit 0
    fi

    if ! gh auth status >/dev/null 2>&1; then
        if is_ci; then
            fail "gh is unauthenticated in CI; refusing to skip the collision check"
        fi
        warn "gh is not authenticated; skipping live open-PR collision check locally"
        exit 0
    fi

    prs_file="$TMP_DIR/open-prs.tsv"
    if ! gh pr list --state open --limit 1000 --json number,title --jq '.[] | [.number, .title] | @tsv' > "$prs_file"; then
        fail "gh pr list failed or its JSON schema changed"
    fi

    while IFS="$(printf '\t')" read -r pr_number pr_title; do
        [ -n "$pr_number" ] || continue
        case "$pr_number" in
            *[!0-9]*) fail "gh pr list returned a non-numeric PR id (schema drift): $pr_number" ;;
        esac
        diff_file="$TMP_DIR/pr-$pr_number.diff"
        if ! gh pr diff "$pr_number" > "$diff_file"; then
            fail "gh pr diff failed for PR #$pr_number"
        fi
        collect_claims "$pr_number" "$pr_title" "$diff_file"
    done < "$prs_file"
fi

unique_claims="$TMP_DIR/claims-unique.tsv"
LC_ALL=C sort -u "$CLAIMS_FILE" > "$unique_claims"

if awk -F '\t' '
function flush_group(    i) {
    if (group_count < 2) return
    if (!collision_seen) {
        print "counter collision(s) detected across open pull requests:" > "/dev/stderr"
    }
    printf "  %s = %s\n", group_counter, group_value > "/dev/stderr"
    for (i = 1; i <= group_count; i++) {
        printf "    - PR #%s (%s)\n", group_pr[i], group_title[i] > "/dev/stderr"
    }
    collision_seen = 1
}
{
    current_group = $1 SUBSEP $2
    if (NR == 1 || current_group != prior_group) {
        if (NR != 1) flush_group()
        group_count = 0
        group_counter = $1
        group_value = $2
        prior_group = current_group
    }
    group_count++
    group_pr[group_count] = $3
    group_title[group_count] = $4
}
END {
    if (NR > 0) flush_group()
    exit collision_seen ? 1 : 0
}
' "$unique_claims"; then
    claim_count="$(wc -l < "$unique_claims" | tr -d ' ')"
    printf 'check-counter-collisions: no duplicate claims across %s parsed counter claim(s)\n' "$claim_count"
    exit 0
else
    status=$?
    [ "$status" -eq 1 ] || fail "collision analysis failed with status $status"
    exit 1
fi
