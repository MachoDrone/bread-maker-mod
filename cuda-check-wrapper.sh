#!/bin/bash
# cuda-check-wrapper.sh — Drop-in replacement for /cuda_check
# Runs the real cuda_check binary and patches the GPU UUID in its JSON output.
# Requires: jq (already in the stats image)
#
# Version: 0.02.1

REAL_UUID="GPU-2e5ea51a-0412-b51e-3328-e80ed2fab5d4"
FAKE_UUID="GPU-a7f3e920-4b1c-9d82-e6f0-38c5d7b2a149"

# Run real binary, pass through all args
OUTPUT=$(/cuda_check_real "$@" 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "$OUTPUT"
    exit $EXIT_CODE
fi

# Patch UUID in JSON output
echo "$OUTPUT" | jq --arg real "$REAL_UUID" --arg fake "$FAKE_UUID" \
    'walk(if type == "string" and . == $real then $fake else . end)'
