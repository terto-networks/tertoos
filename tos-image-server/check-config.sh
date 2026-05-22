#!/usr/bin/env bash
for f in ca_file client_cert_file client_key_file creds_file enrollment_token; do
  v="$(redis-cli -n 4 hget 'HORIZON_AGENT|global' "$f")"
  if [ "$f" = "enrollment_token" ]; then
    [ -n "$v" ] && echo "$f=<present>" || echo "$f=<empty>"
  else
    echo "$f=[$v]"
  fi
done
echo -n "agent_running: "; pgrep -x terto-horizon-agent >/dev/null && echo SIM || echo NAO
