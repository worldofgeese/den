#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
filter="$root/modules/agent-providers/pi-providers.jq"
primary='[{"baseUrl":"http://headroom.test","models":[{"id":"claude-test"}]}]'
direct='[{"baseUrl":"https://gateway.test/anthropic"}]'
# Pi expands this value for each request. The test must preserve the literal.
# shellcheck disable=SC2016
route='[{"baseUrl":"http://headroom.test/v1","directBaseUrl":"https://gateway.test/openai/v1","headers":{"x-headroom-cwd":"${PWD}"}}]'
input='{"keep":"root value","providers":{"custom":{"baseUrl":"https://custom.test"},"lego-openai":{"baseUrl":"https://gateway.test/openai/v1","api":"openai-responses","apiKey":"!test-key-command","authHeader":true,"headers":{"x-project":"keep"},"models":[{"id":"astra-test","contextWindow":1000000,"cost":{"input":1}}]}}}'

merge() {
  jq --argjson p "$primary" --argjson d "$direct" --argjson r "$1" -f "$filter"
}

result=$(printf '%s' "$input" | merge "$route")
jq -e '
  .keep == "root value" and
  .providers.custom.baseUrl == "https://custom.test" and
  .providers["lego-claude"].models[0].id == "claude-test" and
  .providers["lego-claude-direct"].baseUrl == "https://gateway.test/anthropic" and
  (.providers["lego-openai"] |
    .baseUrl == "http://headroom.test/v1" and
    .api == "openai-responses" and
    .apiKey == "!test-key-command" and
    .authHeader == true and
    .headers == {"x-project":"keep", "x-headroom-cwd":"${PWD}"} and
    .models == [{"id":"astra-test","contextWindow":1000000,"cost":{"input":1}}]) and
  (.providers["lego-openai-direct"] |
    .baseUrl == "https://gateway.test/openai/v1" and
    .apiKey == "!test-key-command" and
    .authHeader == true and
    .headers == {"x-project":"keep"} and
    .models == [{"id":"astra-test","contextWindow":1000000,"cost":{"input":1}}])
' <<<"$result" >/dev/null
printf '%s\n' 'PASS: proxy and direct routes preserve authentication, model metadata and unrelated providers'

again=$(printf '%s' "$result" | merge "$route")
test "$(jq -cS . <<<"$result")" = "$(jq -cS . <<<"$again")"
printf '%s\n' 'PASS: repeated activation keeps the direct escape route and is idempotent'

original=$(jq -c '.providers["lego-openai"]' <<<"$input")
unchanged=$(printf '%s' "$input" | merge '[null]' | jq -c '.providers["lego-openai"]')
test "$original" = "$unchanged"
printf '%s\n' 'PASS: an unconfigured OpenAI route preserves the complete provider'

printf '{}' | merge "$route" | jq -e '
  (.providers | has("lego-claude")) and
  (.providers | has("lego-openai") | not)
' >/dev/null
printf '%s\n' 'PASS: a new profile gets Claude without an incomplete OpenAI provider'

warning=$(mktemp)
trap 'rm -f "$warning"' EXIT
incompatible=$(jq '.providers["lego-openai"].api = "google-generative-ai"' <<<"$input")
skipped=$(printf '%s' "$incompatible" | merge "$route" 2>"$warning")
test "$(jq -cS '.providers["lego-openai"]' <<<"$incompatible")" = "$(jq -cS '.providers["lego-openai"]' <<<"$skipped")"
jq -e '.providers["lego-claude"].models[0].id == "claude-test" and (.providers | has("lego-openai-direct") | not)' <<<"$skipped" >/dev/null
grep -Fq 'pi: skipping lego-openai route: unsupported API' "$warning"
printf '%s\n' 'PASS: an incompatible OpenAI provider is preserved with a warning while Claude still updates'
