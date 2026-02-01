.PHONY: build clean

build:
	swiftc -O -o ipguard ipguard.swift

run: build
	. ./.env && ./ipguard

clean:
	rm -f ipguard
