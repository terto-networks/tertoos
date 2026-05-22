#!/usr/bin/env bash
# Força conexão NATS plain (esvazia creds/TLS) e reinicia o agent.
echo ">> esvazia creds_file/ca_file/client_cert_file/client_key_file"
redis-cli -n 4 hset "HORIZON_AGENT|global" \
  creds_file "" ca_file "" client_cert_file "" client_key_file "" >/dev/null
echo ">> CONFIG_DB atual:"
redis-cli -n 4 hgetall "HORIZON_AGENT|global"
echo ">> restart agent"
sudo pkill -f /usr/local/bin/terto-horizon-agent 2>/dev/null || true
sleep 1
sudo bash -c 'setsid nohup /usr/local/bin/terto-horizon-agent -redis 127.0.0.1:6379 </dev/null >/tmp/terto-agent.log 2>&1 &'
sleep 8
echo ">> log do agent:"
sudo tail -n 25 /tmp/terto-agent.log
echo ">> DONE"
