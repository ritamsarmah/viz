.PHONY: all debug release clean

OUT := viz

all: debug

debug:
	odin build . -debug -o:none -out:$(OUT)

release:
	odin build . -o:speed -out:$(OUT)

clean:
	rm -f $(OUT)
