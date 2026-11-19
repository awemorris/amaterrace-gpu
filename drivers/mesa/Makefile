# GHCI GPU Driver
# Copyright (C) 2026 Awe Morris
# SPDX-License-Identifier: Zlib
#
# Builds Mesa with the GHCI Vulkan driver, Zink (GL, GLES, EGL, GBM and GLX
# on top of Vulkan) and the GHCI tools.  The Mesa release is downloaded and
# checked against the checksum in mesa.version; the source is never kept in
# this tree.  The build:
#
#   1. fetch: downloads the release tarball into $(DL) and checks it;
#   2. source: unpacks it into $(SRC), applies patches/$(MESA_VERSION)/ and
#      links this tree in: ghci/ as src/ghci, the kernel's ghci_drm.h into
#      include/drm-uapi/ and the GHCI headers (../../include) as
#      include/ghci;
#   3. setup: builds wayland-scanner for the build host (mesa.version says
#      why) and configures Mesa with meson in $(OBJ);
#   4. all: builds it with ninja;
#   5. install: installs it into $(PREFIX) (with DESTDIR if given).
#
# `make env` prints the variables that select the build tree's drivers
# without installing them; `make test` runs the GHCI unit tests.

TOP := $(abspath $(CURDIR)/../..)

include mesa.version

BUILD ?= $(TOP)/build/mesa
DL ?= $(BUILD)/dl
SRC := $(BUILD)/mesa-$(MESA_VERSION)
OBJ := $(BUILD)/obj-$(MESA_VERSION)
PREFIX ?= /opt/ghci-mesa
JOBS ?= 4
BUILDTYPE ?= debugoptimized

TARBALL := $(DL)/mesa-$(MESA_VERSION).tar.xz
WAYLAND_TARBALL := $(DL)/wayland-$(WAYLAND_VERSION).tar.xz
HOST_TOOLS := $(BUILD)/host-tools
SCANNER := $(HOST_TOOLS)/bin/wayland-scanner
PATCHES := $(sort $(wildcard patches/$(MESA_VERSION)/*.patch))
PREPARED := $(SRC)/.ghci-prepared

# Zink is the only Gallium driver: the loader picks it for the ghci kernel
# driver (ghci/drirc/00-ghci-loader.conf).  libglvnd lets the system's GL
# libraries choose this Mesa through __EGL_VENDOR_LIBRARY_FILENAMES and
# __GLX_VENDOR_LIBRARY_NAME.
MESON_OPTIONS := \
	--prefix=$(PREFIX) \
	--buildtype=$(BUILDTYPE) \
	-Dvulkan-drivers=ghci \
	-Dgallium-drivers=zink \
	-Dplatforms=wayland,x11 \
	-Degl=enabled \
	-Dgbm=enabled \
	-Dglx=dri \
	-Dglvnd=enabled \
	-Dllvm=disabled \
	-Dvideo-codecs= \
	-Dtools=drm-shim,ghci \
	-Dbuild-tests=true \
	-Dpkg_config_path=$(HOST_TOOLS)/lib/pkgconfig \
	$(EXTRA_MESON_OPTIONS)

.PHONY: all fetch source setup install test env clean distclean

all: $(OBJ)/build.ninja
	ninja -C $(OBJ) -j$(JOBS)

fetch: $(TARBALL)

source: $(PREPARED)

setup: $(OBJ)/build.ninja

$(TARBALL):
	mkdir -p $(DL)
	curl -fL --proto '=https' --retry 3 -o $@.part $(MESA_URL)
	echo '$(MESA_SHA256)  $@.part' | sha256sum -c -
	mv $@.part $@

# The tarball is unpacked once.  A new patch needs a new source tree: the
# rule refuses to patch a tree it has already patched.
$(PREPARED): $(TARBALL) $(PATCHES)
	@if [ -e $@ ]; then \
		echo 'drivers/mesa: $(SRC) is already patched;' \
		     'run make distclean to unpack it again' >&2; \
		exit 1; \
	fi
	echo '$(MESA_SHA256)  $(TARBALL)' | sha256sum -c -
	mkdir -p $(BUILD)
	tar -C $(BUILD) -xJf $(TARBALL)
	for p in $(PATCHES); do \
		patch -d $(SRC) -p1 --forward --batch < $(CURDIR)/$$p || exit 1; \
	done
	ln -sfn $(CURDIR)/ghci $(SRC)/src/ghci
	ln -sfn $(TOP)/drivers/linux/include/uapi/drm/ghci_drm.h \
		$(SRC)/include/drm-uapi/ghci_drm.h
	ln -sfn $(TOP)/include $(SRC)/include/ghci
	touch $@

$(WAYLAND_TARBALL):
	mkdir -p $(DL)
	curl -fL --proto '=https' --retry 3 -o $@.part $(WAYLAND_URL)
	echo '$(WAYLAND_SHA256)  $@.part' | sha256sum -c -
	mv $@.part $@

# wayland-scanner alone, installed under $(HOST_TOOLS) with its .pc file.
$(SCANNER): $(WAYLAND_TARBALL)
	echo '$(WAYLAND_SHA256)  $(WAYLAND_TARBALL)' | sha256sum -c -
	tar -C $(BUILD) -xJf $(WAYLAND_TARBALL)
	meson setup $(BUILD)/obj-wayland-$(WAYLAND_VERSION) \
		$(BUILD)/wayland-$(WAYLAND_VERSION) \
		--prefix=$(HOST_TOOLS) --libdir=lib -Dlibraries=false \
		-Ddocumentation=false -Dtests=false -Ddtd_validation=true
	ninja -C $(BUILD)/obj-wayland-$(WAYLAND_VERSION) -j$(JOBS) install

$(OBJ)/build.ninja: $(PREPARED) $(SCANNER)
	meson setup $(OBJ) $(SRC) $(MESON_OPTIONS)

install: all
	meson install -C $(OBJ) --no-rebuild

test: all
	meson test -C $(OBJ) --no-rebuild --suite ghci --num-processes $(JOBS)

# The variables that make the loaders use the build tree's drivers.
env: all
	@echo 'export VK_DRIVER_FILES=$(OBJ)/src/ghci/vulkan/ghci_devenv_icd.$(shell uname -m).json'
	@echo 'export DRIRC_CONFIGDIR=$(CURDIR)/ghci/drirc'
	@echo 'export LD_LIBRARY_PATH=$(OBJ)/src/gallium/targets/dri:$(OBJ)/src/egl:$(OBJ)/src/gbm:$(OBJ)/src/glx$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}'
	@echo 'export GHCI_DRM_SHIM=$(OBJ)/src/ghci/drm-shim/libghci_noop_drm_shim.so'

clean:
	rm -rf $(OBJ)

distclean:
	rm -rf $(OBJ) $(SRC) $(HOST_TOOLS) $(BUILD)/obj-wayland-$(WAYLAND_VERSION) \
		$(BUILD)/wayland-$(WAYLAND_VERSION)
