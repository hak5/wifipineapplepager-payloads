# Build for MIPS 24KEc soft-float (OpenWRT)
BINARY = Mobile2GPS

# MIPS little-endian, soft-float for 24KEc
GOOS = linux
GOARCH = mipsle
GOMIPS = softfloat

# Shrink binary size
LDFLAGS = -s -w

.PHONY: build clean

build:
	GOOS=$(GOOS) GOARCH=$(GOARCH) GOMIPS=$(GOMIPS) go build -ldflags="$(LDFLAGS)" -o $(BINARY) .

clean:
	rm -f $(BINARY)
