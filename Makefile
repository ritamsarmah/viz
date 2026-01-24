all: build

build:
	odin build . -o:speed

debug:
	odin build . -o:minimal

deploy:
	odin build . -o:speed -target=linux_arm64

clean:
	rm -f viz
