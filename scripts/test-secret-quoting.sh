#!/bin/bash
# Round-trip tests for the secret-quoting helpers in deploy-to.sh.
#
# Each generated config file in deploy-to.sh interpolates decrypted secrets.
# These tests prove an adversarial value — containing every byte that is
# significant to one of the consumers (" $ # & / \ backtick, whitespace, and a
# newline) — survives the quote -> write -> parse round-trip byte-for-byte.
#
# Three consumers, three checks:
#   1. bash `source`            (shell_env_line / printf %q)
#   2. docker compose dotenv    (dotenv_quote)
#   3. yq YAML scalar           (yq strenv templating, used for livekit.yaml)
#
# The dotenv check uses `docker compose` when available (authoritative, reads
# the value the container actually receives). When docker is absent (e.g. CI),
# it falls back to a yamllint-free structural assertion that the line is a
# well-formed double-quoted dotenv value. Shell and yq checks need no docker.
#
# Exit non-zero on any mismatch so CI fails loudly.

set -euo pipefail

# --- The helpers under test (kept byte-identical to deploy-to.sh) -----------
# If these drift from deploy-to.sh the tests are meaningless, so they are
# duplicated deliberately and a guard below greps deploy-to.sh to confirm the
# function names still exist there.

shell_env_line() {
    printf '%s=%q\n' "$1" "$2"
}

dotenv_quote() {
    local v=$1
    v=${v//\\/\\\\}
    v=${v//\"/\\\"}
    v=${v//\$/\\\$}
    v=${v//$'\n'/\\n}
    printf '"%s"' "$v"
}

# --- Adversarial fixture ----------------------------------------------------
# Every byte here is significant to at least one consumer.
ADV=$'a"b$c#d&e/f\\g`h i: literal\nsecond-line*x'

# REQUIRE_ALL=1 (set by CI) forbids vacuous passes: if docker or yq is missing,
# their checks fail instead of degrading to a structural-only / skipped check.
# This keeps CI from silently going green on a runner image that drops a tool.
REQUIRE_ALL=${REQUIRE_ALL:-0}

PASS=0
FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }
# Either skip (local convenience) or hard-fail (REQUIRE_ALL, i.e. CI).
skip_or_fail() {
    if [ "$REQUIRE_ALL" = "1" ]; then bad "$1 (REQUIRE_ALL set — tool must be present in CI)";
    else echo "  skip - $1"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- 1. Shell-source round-trip --------------------------------------------
echo "[1] bash source round-trip (shell_env_line / printf %q)"
shell_env_line SECRET "$ADV" > "$WORK/shell.env"
# Source in a clean subshell and compare exact bytes.
# shellcheck disable=SC1091  # runtime-generated path, nothing to follow
GOT=$(set -e; . "$WORK/shell.env"; printf '%s' "$SECRET")
if [ "$GOT" = "$ADV" ]; then ok "sourced value matches original"; else
    bad "sourced value differs"; printf '    exp: %q\n    got: %q\n' "$ADV" "$GOT"
fi

# --- 2. dotenv round-trip ---------------------------------------------------
echo "[2] docker compose dotenv round-trip (dotenv_quote)"
printf 'VAL=%s\n' "$(dotenv_quote "$ADV")" > "$WORK/.env"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    cat > "$WORK/docker-compose.yml" <<'YML'
services:
  t:
    image: alpine
    environment:
      VAL: ${VAL}
YML
    # Authoritative: run the container and read the raw bytes it receives.
    if (cd "$WORK" && docker compose run --rm -T t sh -c 'printf "%s" "$VAL"' 2>/dev/null) > "$WORK/got.bin"; then
        (cd "$WORK" && docker compose down >/dev/null 2>&1 || true)
        if cmp -s "$WORK/got.bin" <(printf '%s' "$ADV"); then
            ok "container runtime value matches original"
        else
            bad "container runtime value differs"
        fi
    else
        skip_or_fail "docker present but 'compose run' failed (no daemon?); structural check only"
        # Structural fallback.
        if grep -q '^VAL=".*"$' "$WORK/.env"; then
            ok "dotenv line is well-formed double-quoted"
        else
            bad "dotenv line malformed"
        fi
    fi
else
    skip_or_fail "docker unavailable; structural check only"
    # Without docker we can still assert the quoting is well-formed: the value
    # is wrapped in double quotes and contains no UNescaped " inside.
    line=$(cat "$WORK/.env")
    body=${line#VAL=}
    if [ "${body:0:1}" = '"' ] && [ "${body: -1}" = '"' ]; then
        inner=${body:1:${#body}-2}
        # No bare (unescaped) double-quote should remain in the inner body.
        if printf '%s' "$inner" | grep -qP '(?<!\\)"'; then
            bad "dotenv inner body has an unescaped double-quote"
        else
            ok "dotenv line is well-formed double-quoted"
        fi
    else
        bad "dotenv value is not double-quoted"
    fi
fi

# --- 3. yq YAML round-trip (livekit templating) ----------------------------
echo "[3] yq strenv YAML round-trip"
if command -v yq >/dev/null 2>&1; then
    cat > "$WORK/livekit.yaml" <<'YML'
keys:
  LIVEKIT_API_KEY: LIVEKIT_API_SECRET
rtc:
  use_external_ip: true
YML
    LK_KEY="key-${ADV}" LK_SECRET="$ADV" yq eval '
        .keys = {} |
        .keys[strenv(LK_KEY)] = strenv(LK_SECRET)
    ' "$WORK/livekit.yaml" > "$WORK/livekit-gen.yaml"
    GOT_SECRET=$(yq -r '.keys.[]' "$WORK/livekit-gen.yaml")
    GOT_KEY=$(yq -r '.keys | keys | .[0]' "$WORK/livekit-gen.yaml")
    if [ "$GOT_SECRET" = "$ADV" ]; then ok "yq secret value round-trips"; else bad "yq secret differs"; fi
    if [ "$GOT_KEY" = "key-${ADV}" ]; then ok "yq key name round-trips"; else bad "yq key differs"; fi
else
    skip_or_fail "yq unavailable"
fi

# --- 3b. Generator code-path round-trip ------------------------------------
# Sections [1]-[3] test the helpers in isolation. This section proves the
# ACTUAL pattern the deploy_* .env generators now use end-to-end:
#
#     field() { echo "$PLAINTEXT" | yq -r '.key // ""'; }
#     printf 'KEY=%s\n' "$(dotenv_quote "$(field '.key')")"
#
# i.e. the adversarial value passes through a real `yq -r '.key // ""'`
# extraction (as if freshly decrypted by sops) AND `dotenv_quote`, then through
# docker compose's dotenv parser — the same composition deploy_outline /
# deploy_claudius / deploy_matrix / etc. run in production. A regression in
# either the yq extraction or the quoting would surface here.
echo "[3b] generator code-path round-trip (yq extract -> dotenv_quote -> compose)"
if command -v yq >/dev/null 2>&1; then
    # Emulate a decrypted secrets.yaml. yq -o=json/-r reads scalar values back
    # verbatim, so we build the doc with yq itself to guarantee the stored value
    # is exactly $ADV (no hand-rolled YAML escaping to get wrong).
    GEN_PLAINTEXT=$(ADV_ENV="$ADV" yq -n '.adversarial_secret = strenv(ADV_ENV)')
    # The exact extraction helper the generators define.
    gen_field() { echo "$GEN_PLAINTEXT" | yq -r "$1 // \"\""; }
    EXTRACTED=$(gen_field '.adversarial_secret')
    if [ "$EXTRACTED" = "$ADV" ]; then
        ok "yq extraction (.key // \"\") preserves the value"
    else
        bad "yq extraction altered the value"; printf '    exp: %q\n    got: %q\n' "$ADV" "$EXTRACTED"
    fi

    printf 'GENVAL=%s\n' "$(dotenv_quote "$EXTRACTED")" > "$WORK/gen.env"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        cat > "$WORK/gen-compose.yml" <<'YML'
services:
  t:
    image: alpine
    environment:
      GENVAL: ${GENVAL}
YML
        if (cd "$WORK" && docker compose --env-file gen.env -f gen-compose.yml run --rm -T t sh -c 'printf "%s" "$GENVAL"' 2>/dev/null) > "$WORK/gen-got.bin"; then
            (cd "$WORK" && docker compose -f gen-compose.yml down >/dev/null 2>&1 || true)
            if cmp -s "$WORK/gen-got.bin" <(printf '%s' "$ADV"); then
                ok "generator path container value matches original"
            else
                bad "generator path container value differs"
            fi
        else
            skip_or_fail "docker present but 'compose run' failed; structural check only"
            if grep -q '^GENVAL=".*"$' "$WORK/gen.env"; then ok "generator dotenv line well-formed"; else bad "generator dotenv line malformed"; fi
        fi
    else
        skip_or_fail "docker unavailable; structural check only"
        line=$(cat "$WORK/gen.env"); body=${line#GENVAL=}
        if [ "${body:0:1}" = '"' ] && [ "${body: -1}" = '"' ]; then
            inner=${body:1:${#body}-2}
            if printf '%s' "$inner" | grep -qP '(?<!\\)"'; then
                bad "generator dotenv inner body has an unescaped double-quote"
            else
                ok "generator dotenv line is well-formed double-quoted"
            fi
        else
            bad "generator dotenv value is not double-quoted"
        fi
    fi
else
    skip_or_fail "yq unavailable; cannot exercise generator extraction path"
fi

# --- 4. Drift guard: the helpers must still exist in deploy-to.sh -----------
echo "[4] deploy-to.sh still defines the helpers"
DEPLOY="$(cd "$(dirname "$0")" && pwd)/deploy-to.sh"
for fn in shell_env_line dotenv_quote; do
    if grep -qE "^${fn}\(\) \{" "$DEPLOY"; then ok "$fn defined in deploy-to.sh"; else
        bad "$fn missing from deploy-to.sh (tests would be stale)"
    fi
done

echo ""
echo "secret-quoting tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
