#!/usr/bin/env bash
# Roda NO AS5912 (via bash -s). Assume /tmp/terto-horizon-agent já copiado.
# Deploy mínimo/reversível do agent p/ testar agent->Edge->Core (sem data plane).
SERIAL="AS5912-HW01"
BROKER="nats://192.168.0.123:4222"

echo ">> [1] serial cache (/var/lib/sonic/syseeprom.json)"
sudo mkdir -p /var/lib/sonic
echo "{\"Serial Number\":\"$SERIAL\"}" | sudo tee /var/lib/sonic/syseeprom.json >/dev/null
cat /var/lib/sonic/syseeprom.json

echo ">> [2] instala binario em /usr/local/bin"
sudo install -m 0755 /tmp/terto-horizon-agent /usr/local/bin/terto-horizon-agent
/usr/local/bin/terto-horizon-agent -h 2>&1 | head -3 || true

echo ">> [3] redis TCP 127.0.0.1:6379 (n4)"
redis-cli -h 127.0.0.1 -p 6379 -n 4 ping 2>&1 | head -1

echo ">> [4] CONFIG_DB HORIZON_AGENT|global (plain: sem token/certs)"
redis-cli -n 4 hset "HORIZON_AGENT|global" \
  enabled true tenant_id acme site_id lab \
  broker_url "$BROKER" subject_prefix horizon \
  interval_heartbeat 30 interval_counters 10 >/dev/null
redis-cli -n 4 hgetall "HORIZON_AGENT|global"

echo ">> [5] mata agent anterior (se houver)"
sudo pkill -f /usr/local/bin/terto-horizon-agent 2>/dev/null || true
sleep 1

echo ">> [6] sobe agent (root, nohup, fds desanexados do ssh)"
sudo bash -c 'setsid nohup /usr/local/bin/terto-horizon-agent -redis 127.0.0.1:6379 </dev/null >/tmp/terto-agent.log 2>&1 &'
sleep 7

echo ">> [7] log do agent:"
sudo tail -n 30 /tmp/terto-agent.log
echo ">> [8] processo:"
pgrep -af terto-horizon-agent | head -2
echo ">> DONE"
