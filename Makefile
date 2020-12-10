# Makefile for vftool
#

FWKS = -framework Foundation \
	-framework Virtualization
CFLAGS = -O3

all:	prep build/vftool sign

.PHONY: prep
prep:
	mkdir -p build/

build/vftool:	vftool/main.m
	clang $(CFLAGS) $< -o $@ $(FWKS)

.PHONY: sign
sign:	build/vftool
	codesign --entitlements vftool/vftool.entitlements --force -s - $<
	
clean:
	rm -rf build/

