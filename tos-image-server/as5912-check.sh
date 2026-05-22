#!/usr/bin/env bash
# Checagens read-only no AS5912 antes do deploy do agent.
echo "=== host ==="; hostname
echo "=== serial (syseeprom) ==="
(decode-syseeprom -s 2>/dev/null || grep -i '"Serial' /var/lib/sonic/syseeprom.json 2>/dev/null) | head -1
echo "=== redis CONFIG_DB (n4) ping ==="; redis-cli -n 4 ping 2>&1 | head -1
echo "=== HORIZON_AGENT|global ja existe? ==="; redis-cli -n 4 hgetall "HORIZON_AGENT|global" 2>&1 | head -6
echo "=== alcanca build server :8443 (edge enroll)? ==="
(timeout 4 bash -c "cat </dev/null >/dev/tcp/192.168.0.123/8443" 2>/dev/null && echo OK_8443) || echo FAIL_8443
echo "=== alcanca build server :4222 (nats)? ==="
(timeout 4 bash -c "cat </dev/null >/dev/tcp/192.168.0.123/4222" 2>/dev/null && echo OK_4222) || echo FAIL_4222
echo "=== syncd/swss/database ==="
docker ps --format "{{.Names}}: {{.Status}}" 2>/dev/null | grep -iE "syncd|swss|database|pmon" | head
echo "=== agent ja presente? ==="
ls -la /usr/sbin/terto-horizon-agent /usr/local/bin/terto-horizon-agent 2>/dev/null || echo "nenhum agent ainda"
echo "=== done ==="
