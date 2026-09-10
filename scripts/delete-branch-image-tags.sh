#!/usr/bin/env bash
set -euo pipefail

: "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}"
: "${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN is required}"
: "${DOCKERHUB_REPOSITORY:?DOCKERHUB_REPOSITORY is required}"
: "${BRANCH_TAG:?BRANCH_TAG is required}"

api_base="https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${DOCKERHUB_REPOSITORY}"
login_payload="$(jq -cn \
  --arg identifier "$DOCKERHUB_USERNAME" \
  --arg secret "$DOCKERHUB_TOKEN" \
  '{identifier: $identifier, secret: $secret}')"
hub_token="$(curl --fail-with-body -sS \
  -X POST \
  -H 'Content-Type: application/json' \
  --data "$login_payload" \
  'https://hub.docker.com/v2/auth/token' | jq -er '.token')"

matches="$(mktemp)"
trap 'rm -f "$matches"' EXIT

page="${api_base}/tags?page_size=100&ordering=last_updated"
while [[ -n "$page" ]]; do
  response="$(curl --fail-with-body -sS \
    -H "Authorization: Bearer ${hub_token}" \
    "$page")"
  jq -r --arg branch "$BRANCH_TAG" '
    .results[]?.name
    | select(. == $branch or startswith($branch + "-"))
  ' <<<"$response" >>"$matches"
  page="$(jq -r '.next // empty' <<<"$response")"
done

sort -u "$matches" -o "$matches"
deleted=0
while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  encoded_tag="$(jq -nr --arg value "$tag" '$value | @uri')"
  curl --fail-with-body -sS \
    -X DELETE \
    -H "Authorization: Bearer ${hub_token}" \
    "${api_base}/tags/${encoded_tag}/" >/dev/null
  printf 'Deleted %s:%s\n' "$DOCKERHUB_REPOSITORY" "$tag"
  deleted=$((deleted + 1))
done <"$matches"

if [[ "$deleted" -eq 0 ]]; then
  printf 'No branch image tags matched %s\n' "$BRANCH_TAG"
fi
