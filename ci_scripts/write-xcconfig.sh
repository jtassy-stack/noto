#!/bin/sh
# Writes Config.xcconfig (gitignored) with the build-time API keys.
#
#   ci_scripts/write-xcconfig.sh            # local: pulls from Infisical (`infisical login` once)
#   ci_scripts/write-xcconfig.sh --from-env # CI: uses DIRECTORY_API_KEY / CULTURE_API_KEY already in env
#
# Missing keys are written empty: the app builds and the clients log + fall back.
set -eu
cd "$(dirname "$0")/.."
ENV_SLUG="${INFISICAL_ENV:-dev}"

if [ "${1:-}" != "--from-env" ]; then
  if ! command -v infisical >/dev/null 2>&1; then
    echo "infisical CLI not found (npm i -g @infisical/cli) — writing empty keys" >&2
  else
    # export → eval only the two keys we expect, never the whole env
    eval "$(infisical export --env "$ENV_SLUG" --format=dotenv 2>/dev/null \
      | grep -E '^(DIRECTORY_API_KEY|CULTURE_API_KEY)=' | sed 's/^/export /')" || true
  fi
fi

printf 'DIRECTORY_API_KEY = %s\nCULTURE_API_KEY = %s\n' \
  "${DIRECTORY_API_KEY:-}" "${CULTURE_API_KEY:-}" > Config.xcconfig

for k in DIRECTORY_API_KEY CULTURE_API_KEY; do
  eval "v=\${$k:-}"
  [ -z "$v" ] && echo "warning: $k is empty in Config.xcconfig" >&2
done
echo "Config.xcconfig written"
