# Eloquence V6.1 ARM-to-Any-Arch Bridge
# Builds: eci-bridge (ARM), libeci.so (native shim), eloquence (native CLI),
#         sd_eloquence (speech-dispatcher module)

# The bridge is always a 32-bit ARM (armhf) program.
#   x86_64            : cross-compile against the bundled Debian sysroot, run via qemu-arm
#   armv6l/armv7l     : (32-bit Raspberry Pi OS) plain native build, runs natively
#   aarch64           : (64-bit Raspberry Pi OS) armhf cross-compiler from the distro
#                       (gcc-arm-linux-gnueabihf), runs natively through the kernel's
#                       32-bit compat mode; needs libc6:armhf at run time
# Override with BRIDGE_MODE=qemu or BRIDGE_MODE=native.
HOST_ARCH  := $(shell uname -m)
ifndef BRIDGE_MODE
  ifneq (,$(filter arm% aarch64,$(HOST_ARCH)))
    BRIDGE_MODE = native
  else
    BRIDGE_MODE = qemu
  endif
endif

ifeq ($(BRIDGE_MODE),native)
  # dpkg knows the userland architecture; uname -m reports the kernel's (a 32-bit
  # Raspberry Pi OS on a 64-bit kernel says aarch64 but is armhf).
  DEB_ARCH := $(shell dpkg --print-architecture 2>/dev/null)
  ifeq ($(DEB_ARCH),arm64)
    ARM_CC = arm-linux-gnueabihf-gcc
  else ifeq ($(DEB_ARCH),armhf)
    ARM_CC = gcc
  else ifneq (,$(filter aarch64 arm64,$(HOST_ARCH)))
    ARM_CC = arm-linux-gnueabihf-gcc
  else
    ARM_CC = gcc
  endif
  ARM_SYSROOT =
  ARM_CFLAGS  = -Wall -Wextra -O2 -g -Iinclude -Iproto
  ARM_LDFLAGS = -lpthread -ldl
else
  ARM_CC      = arm-linux-gnueabihf-gcc
  ARM_SYSROOT = $(CURDIR)/sysroot/armhf
  ARM_CFLAGS  = -Wall -Wextra -O2 -g -Iinclude -Iproto --sysroot=$(ARM_SYSROOT)
  ARM_LDFLAGS = --sysroot=$(ARM_SYSROOT) -lpthread -ldl
endif

# Native compiler for host shim + CLI
CC          = gcc
CFLAGS      = -Wall -Wextra -O2 -g -Iinclude -Iproto
LDFLAGS     = -lpthread -ldl

BUILDDIR    = build

# Source files
PROTO_SRC   = proto/rpc_io.c proto/rpc_msg.c
ARM_SRC     = arm/bridge_main.c arm/bridge_dispatch.c arm/bridge_handle.c arm/bridge_callback.c
SHIM_SRC    = host/shim_libeci.c host/shim_connection.c host/shim_callback.c host/shim_launch.c
CLI_SRC     = cli/eloquence.c
SPD_SRC     = spd/sd_eloquence.c

# Object files
PROTO_ARM_OBJ = $(patsubst proto/%.c,$(BUILDDIR)/arm/proto_%.o,$(PROTO_SRC))
ARM_OBJ       = $(patsubst arm/%.c,$(BUILDDIR)/arm/%.o,$(ARM_SRC))
PROTO_HOST_OBJ = $(patsubst proto/%.c,$(BUILDDIR)/host/proto_%.o,$(PROTO_SRC))
SHIM_OBJ      = $(patsubst host/%.c,$(BUILDDIR)/host/%.o,$(SHIM_SRC))
CLI_OBJ        = $(patsubst cli/%.c,$(BUILDDIR)/cli/%.o,$(CLI_SRC))

# Targets
BRIDGE      = $(BUILDDIR)/eci-bridge
SHIM_LIB    = $(BUILDDIR)/libeci.so
CLI_BIN     = $(BUILDDIR)/eloquence
SPD_BIN     = $(BUILDDIR)/sd_eloquence

# Install paths
PREFIX     = /usr
# Debian multiarch triplet (x86_64-linux-gnu, aarch64-linux-gnu, arm-linux-gnueabihf, ...)
MULTIARCH  := $(shell dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || $(CC) -dumpmachine)
LIBDIR     = $(PREFIX)/lib/$(MULTIARCH)
DATADIR    = $(PREFIX)/share/eloquence
BINDIR     = $(PREFIX)/bin
MANDIR     = $(PREFIX)/share/man/man1
SPDMODDIR  = $(PREFIX)/lib/speech-dispatcher-modules
SPDCONFDIR = /etc/speech-dispatcher/modules

.PHONY: all clean sysroot sd_eloquence install

all: $(BRIDGE) $(SHIM_LIB) $(CLI_BIN) $(BUILDDIR)/sysroot

# Create build directories
$(BUILDDIR)/arm $(BUILDDIR)/host $(BUILDDIR)/cli:
	mkdir -p $@

# ARM bridge
$(BUILDDIR)/arm/proto_%.o: proto/%.c | $(BUILDDIR)/arm
	$(ARM_CC) $(ARM_CFLAGS) -c -o $@ $<

$(BUILDDIR)/arm/%.o: arm/%.c | $(BUILDDIR)/arm
	$(ARM_CC) $(ARM_CFLAGS) -c -o $@ $<

$(BRIDGE): $(PROTO_ARM_OBJ) $(ARM_OBJ)
	$(ARM_CC) -o $@ $^ $(ARM_LDFLAGS)

# Host shim library (shared .so)
$(BUILDDIR)/host/proto_%.o: proto/%.c | $(BUILDDIR)/host
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

$(BUILDDIR)/host/%.o: host/%.c | $(BUILDDIR)/host
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

$(SHIM_LIB): $(PROTO_HOST_OBJ) $(SHIM_OBJ)
	$(CC) -shared -o $@ $^ $(LDFLAGS) -Wl,-soname,libeci.so

# CLI
$(BUILDDIR)/cli/%.o: cli/%.c | $(BUILDDIR)/cli
	$(CC) $(CFLAGS) -c -o $@ $<

$(CLI_BIN): $(CLI_OBJ) $(SHIM_LIB)
	$(CC) -o $@ $(CLI_OBJ) -L$(BUILDDIR) -leci -Wl,-rpath,'$$ORIGIN' $(LDFLAGS)

# Speech-dispatcher module.
# Debian/Ubuntu/Raspberry Pi OS do not package speech-dispatcher's module helper
# library (spd_module_main.h / libspeechd_module), so the three small BSD-licensed
# sources it is made of are vendored in spd/vendor and built here.
SPDVENDOR_SRC = spd/vendor/module_main.c spd/vendor/module_readline.c spd/vendor/module_process.c
SPDVENDOR_OBJ = $(patsubst spd/vendor/%.c,$(BUILDDIR)/spd/%.o,$(SPDVENDOR_SRC))
SPDVENDOR_LIB = $(BUILDDIR)/libspeechd_module.a
SPD_PKGCFLAGS = $(shell pkg-config --cflags speech-dispatcher glib-2.0)

sd_eloquence: $(SPD_BIN)

$(BUILDDIR)/spd:
	mkdir -p $@

$(BUILDDIR)/spd/%.o: spd/vendor/%.c | $(BUILDDIR)/spd
	$(CC) $(CFLAGS) -Ispd/vendor $(SPD_PKGCFLAGS) -c -o $@ $<

$(SPDVENDOR_LIB): $(SPDVENDOR_OBJ)
	$(AR) rcs $@ $^

$(SPD_BIN): $(SPD_SRC) $(SPDVENDOR_LIB) $(SHIM_LIB)
	$(CC) $(CFLAGS) -Ispd/vendor $(SPD_PKGCFLAGS) \
		-o $@ $(SPD_SRC) $(SPDVENDOR_LIB) -L$(BUILDDIR) -leci \
		$(shell pkg-config --libs speech-dispatcher glib-2.0) -lpthread \
		-Wl,-rpath,'$$ORIGIN'

# Symlink sysroot into build dir so shim can find it relative to libeci.so
$(BUILDDIR)/sysroot:
	ln -sf ../sysroot $(BUILDDIR)/sysroot

# Sysroot setup
sysroot:
	bash sysroot/setup-sysroot.sh

# Install target (used by dpkg-buildpackage via pkg/debian/rules)
install:
	install -Dm755 $(BRIDGE)    $(DESTDIR)$(DATADIR)/eci-bridge
	install -Dm755 $(SHIM_LIB)  $(DESTDIR)$(LIBDIR)/libeci.so
	install -Dm755 $(CLI_BIN)   $(DESTDIR)$(BINDIR)/eloquence
	install -Dm755 scripts/eloquence-setup $(DESTDIR)$(BINDIR)/eloquence-setup
	install -Dm644 man/eloquence.1 $(DESTDIR)$(MANDIR)/eloquence.1
	# speech-dispatcher module (only if built)
	test ! -f $(SPD_BIN) || \
		install -Dm755 $(SPD_BIN) $(DESTDIR)$(SPDMODDIR)/sd_eloquence
	test ! -f $(SPD_BIN) || \
		install -Dm644 spd/eloquence.conf $(DESTDIR)$(SPDCONFDIR)/eloquence.conf
	# Support files needed by eloquence-setup
	install -Dm644 sysroot/patch-glibc-versions.py $(DESTDIR)$(DATADIR)/patch-glibc-versions.py
	install -Dm644 arm/sjlj_compat.c  $(DESTDIR)$(DATADIR)/arm/sjlj_compat.c
	install -Dm644 arm/sjlj_compat.map $(DESTDIR)$(DATADIR)/arm/sjlj_compat.map

clean:
	rm -rf $(BUILDDIR)
