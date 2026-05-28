# TertoOS — KLISH IOS-XR helper binary
#
# Constrói terto-horizon-cli_<ver>_<arch>.deb a partir de
# src/terto-horizon/cli/. O binário Go (estático, sem CGO) é instalado em
# /usr/sbin/tertoos-cli no host e também montado no container
# mgmt-framework (via base_image_files) para ser invocado pelas <ACTION>
# dos XMLs KLISH.
#
# Também instala o wrapper /usr/bin/tertoos que faz `docker exec` na
# mgmt-framework — é o login shell IOS-XR para o admin.

ifeq ($(INCLUDE_TERTOOS_CLI),y)

TERTOOS_CLI_VERSION = 0.1.2
TERTOOS_CLI = terto-horizon-cli_$(TERTOOS_CLI_VERSION)_$(CONFIGURED_ARCH).deb
$(TERTOOS_CLI)_SRC_PATH = $(SRC_PATH)/terto-horizon/cli
$(TERTOOS_CLI)_DEPENDS  =
$(TERTOOS_CLI)_RDEPENDS =
SONIC_DPKG_DEBS += $(TERTOOS_CLI)

# Disponibilizar o .deb para o container mgmt-framework (instalação dentro
# do container) — o XML aciona /usr/sbin/tertoos-cli em ambos os lados.
$(DOCKER_MGMT_FRAMEWORK)_DEPENDS += $(TERTOOS_CLI)

endif
