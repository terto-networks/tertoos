set +e
echo "M1 serial-cache:"; ls -la /var/lib/sonic/syseeprom.json 2>&1 | head -1
echo "M2 serial-sudo:"; sudo -n decode-syseeprom -s 2>&1 | head -1
echo "M3 sudo-ok:"; sudo -n true 2>&1 && echo "SUDO_NOPASS" || echo "sudo-needs-pass-or-no"
echo "M4 horizon-key:"; redis-cli -n 4 hgetall "HORIZON_AGENT|global" 2>&1 | head -4
echo "M5 edge8443:"; timeout 4 bash -c 'cat </dev/null >/dev/tcp/192.168.0.123/8443' 2>&1 && echo OK_8443 || echo FAIL_8443
echo "M6 nats4222:"; timeout 4 bash -c 'cat </dev/null >/dev/tcp/192.168.0.123/4222' 2>&1 && echo OK_4222 || echo FAIL_4222
echo "M7 syncd:"; docker ps --format '{{.Names}}: {{.Status}}' 2>&1 | grep -iE 'syncd|swss|database|pmon' | head
echo "M8 agent:"; ls -la /usr/local/bin/terto-horizon-agent 2>&1 | head -1
echo "M9 END"
