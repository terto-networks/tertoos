#!/usr/bin/env bash
# Sobe o agent (config de enrollment ja esta no CONFIG_DB). O agent
# enrolla sozinho (token no redis), recebe ca/cert/key e conecta via mTLS.
echo ">> config atual:"
echo "  creds_file=[$(redis-cli -n 4 hget 'HORIZON_AGENT|global' creds_file)]"
echo "  token_present=$(redis-cli -n 4 hexists 'HORIZON_AGENT|global' enrollment_token)"
echo ">> mata agent anterior (se houver)"
sudo pkill -f /usr/local/bin/terto-horizon-agent 2>/dev/null || true
sleep 1
echo ">> sobe agent"
sudo bash -c 'setsid nohup /usr/local/bin/terto-horizon-agent -redis 127.0.0.1:6379 </dev/null >/tmp/terto-agent.log 2>&1 &'
sleep 12
echo ">> log do agent:"
sudo tail -n 30 /tmp/terto-agent.log
echo ">> certs apos enroll:"
ls -la /etc/tertoos/horizon/ 2>/dev/null || echo "sem certs"
echo ">> proc:"
pgrep -af /usr/local/bin/terto-horizon-agent | head -1 || echo parado
echo ">> DONE"
