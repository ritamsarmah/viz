.PHONY: all debug release clean

OUT := build/

all: debug

debug:
	mkdir -p $(OUT)
	odin build . -debug -o:none -out:$(OUT)/viz

# Build viz for Raspberry Pi (ARM Linux)
release:
	cd musl && \
		mkdir -p build && cd build && \
		CC="clang --target=aarch64-linux-gnu" \
		AR=llvm-ar \
		RANLIB=llvm-ranlib \
		../configure --host=aarch64-linux-gnu --disable-shared && \
		make

	cd ..
	odin build .  -target=linux_arm64 -build-mode=object -out:$(build)
	ld.lld viz-*.o musl/build/lib/libc.a musl/build/lib/crt1.o SDL3

clean:
	rm -rf $(OUT)
