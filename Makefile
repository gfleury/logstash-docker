SHELL=/bin/bash
ELASTIC_REGISTRY ?= docker.elastic.co

export PATH := ./bin:./venv/bin:$(PATH)

# Determine the version to build. Override by setting ELASTIC_VERSION env var.
ELASTIC_VERSION := $(shell ./bin/elastic-version)

ifdef STAGING_BUILD_NUM
  VERSION_TAG := $(ELASTIC_VERSION)-$(STAGING_BUILD_NUM)
else
  VERSION_TAG := $(ELASTIC_VERSION)
endif

IMAGE_FLAVORS ?= oss x-pack
DEFAULT_IMAGE_FLAVOR ?= x-pack

IMAGE_TAG := $(ELASTIC_REGISTRY)/logstash/logstash
HTTPD ?= logstash-docker-artifact-server

FIGLET := pyfiglet -w 160 -f puffy

all: build test

test: lint docker-compose
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  $(FIGLET) "test: $(FLAVOR)"; \
	  ./bin/pytest tests --image-flavor=$(FLAVOR); \
	)

lint: venv
	flake8 tests

build: dockerfile docker-compose env2yaml
	docker pull centos:7
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  docker build -t $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) \
	  -f build/logstash/Dockerfile-$(FLAVOR) build/logstash; \
	  if [[ $(FLAVOR) == $(DEFAULT_IMAGE_FLAVOR) ]]; then \
	    docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) $(IMAGE_TAG):$(VERSION_TAG); \
	  fi; \
	)

release-manager-snapshot: clean
	ARTIFACTS_DIR=$(ARTIFACTS_DIR) ELASTIC_VERSION=$(ELASTIC_VERSION)-SNAPSHOT make build-from-local-artifacts

release-manager-release: clean
	ARTIFACTS_DIR=$(ARTIFACTS_DIR) ELASTIC_VERSION=$(ELASTIC_VERSION) make build-from-local-artifacts

# Build from artifacts on the local filesystem, using an http server (running
# in a container) to provide the artifacts to the Dockerfile.
build-from-local-artifacts: venv dockerfile docker-compose env2yaml
	docker run --rm -d --name=$(HTTPD) \
	           --network=host -v $(ARTIFACTS_DIR):/mnt \
	           python:3 bash -c 'cd /mnt && python3 -m http.server'
	timeout 120 bash -c 'until curl -s localhost:8000 > /dev/null; do sleep 1; done'
	-$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  pyfiglet -f puffy -w 160 "Building: $(FLAVOR)"; \
	  docker build --network=host -t $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) -f build/logstash/Dockerfile-$(FLAVOR) build/logstash || \
	    (docker kill $(HTTPD); false); \
	  if [[ $(FLAVOR) == $(DEFAULT_IMAGE_FLAVOR) ]]; then \
	    docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) $(IMAGE_TAG):$(VERSION_TAG); \
	  fi; \
	)
	-docker kill $(HTTPD)

demo: docker-compose clean-demo
	docker-compose up

# Push the image to the dedicated push endpoint at "push.docker.elastic.co"
push: test
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  docker tag $(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG) push.$(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG); \
	  docker push push.$(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG); \
	  docker rmi push.$(IMAGE_TAG)-$(FLAVOR):$(VERSION_TAG); \
	)
	# Also push the default version, with no suffix like '-oss' or '-x-pack'
	docker tag $(IMAGE_TAG):$(VERSION_TAG) push.$(IMAGE_TAG):$(VERSION_TAG);
	docker push push.$(IMAGE_TAG):$(VERSION_TAG);
	docker rmi push.$(IMAGE_TAG):$(VERSION_TAG);

# The tests are written in Python. Make a virtualenv to handle the dependencies.
venv: requirements.txt
	test -d venv || virtualenv --python=python3 venv
	pip install -r requirements.txt
	touch venv

# Make a Golang container that can compile our env2yaml tool.
golang:
	docker build -t golang:env2yaml build/golang

# Compile "env2yaml", the helper for configuring logstash.yml via environment
# variables.
env2yaml: golang
	docker run --rm -i \
	  -v ${PWD}/build/logstash/env2yaml:/usr/local/src/env2yaml \
	  golang:env2yaml

# Generate the Dockerfiles from Jinja2 templates.
dockerfile: venv templates/Dockerfile.j2
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  jinja2 \
	    -D elastic_version='$(ELASTIC_VERSION)' \
	    -D staging_build_num='$(STAGING_BUILD_NUM)' \
	    -D version_tag='$(VERSION_TAG)' \
	    -D image_flavor='$(FLAVOR)' \
	    -D artifacts_dir='$(ARTIFACTS_DIR)' \
	    templates/Dockerfile.j2 > build/logstash/Dockerfile-$(FLAVOR); \
	)


# Generate docker-compose files from Jinja2 templates.
docker-compose: venv
	$(foreach FLAVOR, $(IMAGE_FLAVORS), \
	  jinja2 \
	    -D version_tag='$(VERSION_TAG)' \
	    -D image_flavor='$(FLAVOR)' \
	    templates/docker-compose.yml.j2 > docker-compose-$(FLAVOR).yml; \
	)
	ln -sf docker-compose-$(DEFAULT_IMAGE_FLAVOR).yml docker-compose.yml

clean: clean-demo
	rm -f build/logstash/env2yaml/env2yaml build/logstash/Dockerfile
	rm -rf venv

clean-demo: docker-compose
	docker-compose down
	docker-compose rm --force

.PHONY: build clean clean-demo demo push test
