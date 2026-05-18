#!/bin/bash
# TertoOS: habilita o FRR management framework (frrcfgd).
#
# O container docker-fpm-frr (bgp) le DEVICE_METADATA.frr_mgmt_framework_config
# do CONFIG_DB no docker_init.sh para decidir o supervisord: com "true" ele
# sobe frrcfgd + ospfd/ospf6d/ldpd/bfdd/isisd/pimd/pathd. Sem o flag, sobe
# so bgpd/zebra/staticd+bgpcfgd e a gerencia S15 nao funciona.
#
# Roda como oneshot ANTES de bgp.service.
for i in $(seq 1 90); do
    hw=$(sonic-db-cli CONFIG_DB HGET 'DEVICE_METADATA|localhost' hwsku 2>/dev/null || true)
    [ -n "$hw" ] && break
    sleep 1
done
sonic-db-cli CONFIG_DB HSET 'DEVICE_METADATA|localhost' frr_mgmt_framework_config true
