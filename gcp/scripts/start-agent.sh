#!/usr/bin/env bash
# Start the local formae agent with the GCP service-account credentials.
# The agent MUST have GOOGLE_APPLICATION_CREDENTIALS set, otherwise the GCP
# plugin falls back to gcloud user ADC (whose reauth expires -> invalid_rapt)
# and every GCP call fails. Always start the agent via this script.
set -euo pipefail
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-/Users/stheno/git/pel/formae-tester.json}"
exec /opt/pel/bin/formae agent start "$@"
