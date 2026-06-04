NAME    ?= nmos-cpp-registry
TAG     ?= latest
IMAGE    = $(NAME):$(TAG)

# Override the upstream versions on the command line if needed, e.g.
#   make build NMOS_CPP_VERSION=<sha>
NMOS_CPP_VERSION ?=
NMOS_JS_VERSION  ?=

BUILD_ARGS =
ifneq ($(NMOS_CPP_VERSION),)
	BUILD_ARGS += --build-arg NMOS_CPP_VERSION=$(NMOS_CPP_VERSION)
endif
ifneq ($(NMOS_JS_VERSION),)
	BUILD_ARGS += --build-arg NMOS_JS_VERSION=$(NMOS_JS_VERSION)
endif

.PHONY: build run logs stop shell buildx

build:
	docker build $(BUILD_ARGS) -t $(IMAGE) .

# Host networking is required for mDNS discovery.
run: build
	docker run -d --network host --name $(NAME) --restart unless-stopped $(IMAGE)

logs:
	docker logs -f $(NAME)

stop:
	-docker rm -f $(NAME)

shell:
	docker run --rm -it --network host $(IMAGE) bash

# Multi-arch build & push (amd64 + arm64). Set NAME to your registry path first.
buildx:
	docker buildx build --platform linux/amd64,linux/arm64 $(BUILD_ARGS) -t $(IMAGE) --push .
