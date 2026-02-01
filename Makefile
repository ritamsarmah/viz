.PHONY: all debug run compile clean

OUT := build/

all: debug

debug:
	mkdir -p $(OUT)
	odin build . -debug -o:none -out:$(OUT)/viz

run: debug
	./build/viz

# Compile only producing object files to link on Raspberry Pi
compile:
	odin build .  -target=linux_arm64 -build-mode=object -out:$(OUT)

clean:
	rm -rf $(OUT)
