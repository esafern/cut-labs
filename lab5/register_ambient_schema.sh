#!/bin/bash
SR_URL="${1:?Usage: $0 <schema-registry-url> <sr-api-key> <sr-api-secret>}"
SR_KEY="${2:?Usage: $0 <schema-registry-url> <sr-api-key> <sr-api-secret>}"
SR_SECRET="${3:?Usage: $0 <schema-registry-url> <sr-api-key> <sr-api-secret>}"
DIR="$(dirname "$0")"

TOPIC="ambient-telemetry"

echo "Registering key schema for $TOPIC-key..." >&2
KEY_SCHEMA=$(python3 -c "import json; print(json.dumps(json.dumps(json.load(open('$DIR/schemas/ambient-telemetry-key-v1.json')))))")
curl -s -X POST "$SR_URL/subjects/$TOPIC-key/versions" \
  -u "$SR_KEY:$SR_SECRET" \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d "{\"schemaType\": \"JSON\", \"schema\": $KEY_SCHEMA}"
echo "" >&2

echo "Registering value schema for $TOPIC-value..." >&2
VALUE_SCHEMA=$(python3 -c "import json; print(json.dumps(json.dumps(json.load(open('$DIR/schemas/ambient-telemetry-value-v1.json')))))")
curl -s -X POST "$SR_URL/subjects/$TOPIC-value/versions" \
  -u "$SR_KEY:$SR_SECRET" \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d "{\"schemaType\": \"JSON\", \"schema\": $VALUE_SCHEMA}"
echo "" >&2

echo "Verifying..." >&2
curl -s "$SR_URL/subjects/$TOPIC-key/versions/latest" -u "$SR_KEY:$SR_SECRET" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  Key: id={d.get(\"id\")} version={d.get(\"version\")}')"
curl -s "$SR_URL/subjects/$TOPIC-value/versions/latest" -u "$SR_KEY:$SR_SECRET" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  Value: id={d.get(\"id\")} version={d.get(\"version\")}')"
