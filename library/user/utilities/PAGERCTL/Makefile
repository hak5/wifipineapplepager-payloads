# pagerctl - WiFi Pineapple Pager Hardware Control Library
# Makefile for cross-compiling shared library to MIPS

# Directories
SRC_DIR = src

# Compiler flags
CFLAGS = -Wall -O2
LDFLAGS = -lm -lpthread
SO_FLAGS = -shared -fPIC

# Targets
LIB_TARGET = libpagerctl.so
DEMO_TARGET = demo

# Build library and demo with Docker (works on Linux, Mac, Windows)
all:
	docker run --rm -v $(PWD):/src -w /src \
		openwrt/sdk:mipsel_24kc-22.03.5 \
		bash -c "export PATH=/builder/staging_dir/toolchain-mipsel_24kc_gcc-11.2.0_musl/bin:\$$PATH && \
		export STAGING_DIR=/builder/staging_dir && \
		mipsel-openwrt-linux-musl-gcc $(CFLAGS) $(SO_FLAGS) -o $(LIB_TARGET) $(SRC_DIR)/pagerctl.c $(LDFLAGS) && \
		mipsel-openwrt-linux-musl-gcc $(CFLAGS) -I$(SRC_DIR) -o examples/$(DEMO_TARGET) $(SRC_DIR)/demo.c -L. -l:$(LIB_TARGET) $(LDFLAGS)"
	@echo ""
	@echo "Build complete. Deploy to Pager with:"
	@echo "  scp -r . root@172.16.52.1:/mmc/root/payloads/user/utilities/PAGERCTL"

# Clean built files
clean:
	rm -f $(LIB_TARGET) examples/$(DEMO_TARGET)

.PHONY: all clean
