.PHONY: all build test clean

all: build

build:
	@./Scripts/build.sh

test:
	@./Scripts/run_tests.sh

clean:
	@swift package clean
