# TertoOS — Horizon NOS-side agent
#
# Constroi terto-horizon-agent_<ver>_<arch>.deb a partir de
# src/terto-horizon/agent/. Binario Go estatico (sem CGO) instalado em
# /usr/bin/terto-horizon-agent + servico systemd no host.
# Deployment: host/systemd (decisao 2026-05-18). Gated no mesmo flag
# do CLI (INCLUDE_TERTOOS_CLI) — ambos sao terto-horizon.

ifeq ($(INCLUDE_TERTOOS_CLI),y)

TERTOOS_AGENT_VERSION = 0.1.0
TERTOOS_AGENT = terto-horizon-agent_$(TERTOOS_AGENT_VERSION)_$(CONFIGURED_ARCH).deb
$(TERTOOS_AGENT)_SRC_PATH = $(SRC_PATH)/terto-horizon/agent
$(TERTOOS_AGENT)_DEPENDS  =
$(TERTOOS_AGENT)_RDEPENDS =
SONIC_DPKG_DEBS += $(TERTOOS_AGENT)

endif
