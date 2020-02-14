#!/bin/bash

# Runs a semi-realistic integration test with two servers, a stub authorization server, a 
# prometheus that scrapes from them, and a single client that fetches "cluster" metrics.
# If no arguments are passed an integration test scenario is run. Otherwise $1 becomes 
# the upstream prometheus server to test against and $2 is an optional bearer token to 
# authenticate the request.

set -euo pipefail
if [[ -n "${1-}" ]]; then
  echo "Starting the integration test against the provided server"
  server="${1}"
  token="${2-}"
  test="${TEST-}"
else
  echo "Running integration test"
  server="http://[::1]:9005"
  token=""
  test="${TEST:-1}"
fi

result=1
trap 'kill $(jobs -p); exit $result' EXIT

( ./authorization-server [::]:9001 ./test/tokens.json ) &

( 
  sleep 5
  exec ./telemeter-client \
    --from "${server}" --from-token "${token}" \
    --to "http://[::1]:9003" \
    --id "test" \
    --to-token a \
    --interval 15s \
    --anonymize-labels "instance" --anonymize-salt "a-unique-value" \
    --rename ALERTS=alerts --rename openshift_build_info=build_info --rename scrape_samples_scraped=scraped \
    --match '{__name__="ALERTS",alertstate="firing"}' \
    --match '{__name__="scrape_samples_scraped"}'
  echo "Telemeter client finished"
) &

( 
echo "Starting telemeter server at 9003"
./telemeter-server \
    --ttl=24h \
    --ratelimit=15s \
    --authorize http://[::1]:9001 \
    --name instance-0 \
    --shared-key=test/test.key \
    --listen [::1]:9003 \
    --listen-internal [::1]:9004 \
    --listen-cluster [::1]:9006 \
    --join [::1]:9016 \
    --whitelist '{_id="test"}' \
    --elide-label '_elide' \
    -v
  echo "Finishing telemeter server at 9003"
) &
( 
sleep 1
echo "Starting telemeter server at 9013"
./telemeter-server \
    --ttl=24h \
    --ratelimit=15s \
    --authorize http://[::1]:9001 \
    --name instance-1 \
    --shared-key=test/test.key \
    --listen [::1]:9013 \
    --listen-internal [::1]:9014 \
    --listen-cluster [::1]:9016 \
    --join [::1]:9006 \
    --whitelist '{_id="test"}' \
    --elide-label '_elide' \
    -v
  echo "Finishing telemeter server at 9013"
) &

( 
  prometheus --config.file=./test/prom-local.conf --web.listen-address=[::1]:9005 "--storage.tsdb.path=$(mktemp -d)" --log.level=debug --web.enable-admin-api
  echo "Finishing prometheus"
) &

sleep 1

echo "What test says"
echo "${test-}"

if [[ -n "${test-}" ]]; then
  retries=200
  while true; do 
    if [[ "${retries}" -lt 0 ]]; then
      echo "error: Did not successfully retrieve cluster metrics from the local Prometheus server" 1>&2
      echo "Waiting for keypress"
      read -n 1 k <&1
      #exit 1
    fi
    # verify we scrape metrics from the test cluster and give it _id test
    if [[ "$( curl http://[::1]:9005/api/v1/query --data-urlencode 'query=count({_id="test"})' -G 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"]["result"][0]["value"][1])' 2>/dev/null )" -eq 0 ]]; then
      echo "1 retries: $retries"
      retries=$((retries-1))
      sleep 1
      continue
    fi
    # verify we rename scrape_samples_scraped to scraped
    if [[ "$( curl http://[::1]:9005/api/v1/query --data-urlencode 'query=count(scraped{_id="test"})' -G 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"]["result"][0]["value"][1])' 2>/dev/null )" -eq 0 ]]; then
      echo "2 retries: $retries"
      retries=$((retries-1))
      sleep 1
      continue
    fi
    # verify we got alerts as remapped from ALERTS
    if [[ "$( curl http://[::1]:9005/api/v1/query --data-urlencode 'query=count(alerts{_id="test"})' -G 2>/dev/null | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"]["result"][0]["value"][1])' 2>/dev/null )" -eq 0 ]]; then
      echo "3 retries: $retries"
      retries=$((retries-1))
      sleep 1
      continue
    fi
    # verify we don't get elided labels
    if [[ "$( curl http://[::1]:9005/api/v1/query --data-urlencode 'query=count(alerts{_id="test",_elide=~".+"})' -G 2>/dev/null | python3 -c 'import sys, json; print(len(json.load(sys.stdin)["data"]["result"]))' 2>/dev/null )" -gt 0 ]]; then
      echo "4 retries: $retries"
      retries=$((retries-1))
      sleep 1
      continue
    fi
    break
  done
  echo "tests: ok"
  result=0
  exit 0
fi

echo "tests: failed" 1>&2
result=1
exit 1
