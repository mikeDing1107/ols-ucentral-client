
.ONESHELL:
SHELL = /bin/bash
.SHELLFLAGS += -e

IMG_ID := "ucentral-client-build-env"
IMG_TAG := $(shell cat Dockerfile | sha1sum | awk '{print substr($$1,0,11);}')
CONTAINER_NAME := "ucentral_client_build_env"

# ---------------------------------------------------------------------------
# ucentral version derivation (mirrors SONiC sonic_get_version() logic):
# version file + docker tag are based on the REMOTE branch head commit at
# build time; fall back to the local HEAD commit if the remote is unavailable.
# ---------------------------------------------------------------------------
UCENTRAL_BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
UCENTRAL_REMOTE := $(shell git remote 2>/dev/null | head -n1)
UCENTRAL_COMMIT := $(shell timeout 10 git ls-remote --heads $(UCENTRAL_REMOTE) $(UCENTRAL_BRANCH) 2>/dev/null | cut -c1-7)
ifeq ($(strip $(UCENTRAL_COMMIT)),)
UCENTRAL_COMMIT := $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
endif
UCENTRAL_VERSION := $(UCENTRAL_BRANCH).$(UCENTRAL_COMMIT)
BUILD_TIME := $(shell date +%Y%m%dT%H%M%S)

.PHONY: all clean build-host-env build-final-deb build-ucentral-docker-img run-host-env run-ucentral-docker-img

all: build-host-env build-ucentral-app build-ucentral-docker-img build-final-deb

build-host-env:
	@mkdir output 2>/dev/null || true
	@mkdir docker 2>/dev/null || true
	cp version.json docker/version.json
	# Build docker img if not exists already, do nothing otherwise;
	@echo Checking / building docker build env img;
	docker inspect --type=image ${IMG_ID}:${IMG_TAG} >/dev/null 2>&1 || \
		docker build --file Dockerfile --tag ${IMG_ID}:${IMG_TAG} docker
	@echo Docker build done;
	@echo Saving docker img to local archive...;
	if [ ! -f output/docker-ucentral-client-build-env-${IMG_TAG}.gz ] ; then \
		docker save ${IMG_ID}:${IMG_TAG} | gzip -c -  > \
			output/docker-ucentral-client-build-env-${IMG_TAG}.gz; \
	fi
	@echo Docker save done...;

run-host-env: build-host-env
	docker container stop ${CONTAINER_NAME} > /dev/null 2>&1 || true;
	docker container rm ${CONTAINER_NAME} > /dev/null 2>&1 || true;
	docker run -d -t --name ${CONTAINER_NAME} \
		-v $(realpath ./):/root/ols-nos \
		--env UCENTRAL_PLATFORM=$(UCENTRAL_PLATFORM) \
		--env PLATFORM_REVISION="$(PLATFORM_REVISION)" \
		${IMG_ID}:${IMG_TAG} \
		bash

run-ucentral-docker-img: build-ucentral-docker-img
	mkdir ./tip-certs 2>/dev/null || true;
	docker container stop ucentral_client > /dev/null 2>&1 || true;
	docker container rm ucentral_client > /dev/null 2>&1 || true;
	docker run -d -i -t --name ucentral_client --network=host \
		-v `realpath ./tip-certs`:/etc/ucentral \
		--env UCENTRAL_PLATFORM=$(UCENTRAL_PLATFORM) \
		ucentral-client:latest
	docker logs -f ucentral_client || true;

build-ucentral-app: run-host-env
	@echo Running ucentralclient docker-build-env container to build ucentral-client...;
	docker exec -t ${CONTAINER_NAME} /root/ols-nos/docker-build-client.sh
	docker cp ${CONTAINER_NAME}:/root/deliverables/ src/docker/
	# copy the schema version, if it is there
	docker cp ${CONTAINER_NAME}:/root/ucentral-external-libs/ols-ucentral-schema/schema.json src/docker/ || true
	docker container stop ${CONTAINER_NAME} > /dev/null 2>&1 || true;
	docker container rm ${CONTAINER_NAME} > /dev/null 2>&1 || true;
	if [ -f version.json ]; then \
	    cp version.json src/docker/; \
	fi
	# embed ucentral source version + build time into the runtime image
	printf '%s\n' "$(UCENTRAL_VERSION)" > src/docker/ucentral-client.version
	printf '%s\n' "$(BUILD_TIME)" > src/docker/buildtime

build-ucentral-docker-img: build-ucentral-app
	pushd src
	cp docker/deliverables/lib* docker/
	cp docker/deliverables/ucentral-client docker/
	cp docker/deliverables/rtty docker/
	OLDIMG=$$(docker images --format "{{.ID}}" ucentral-client:latest)
	docker build --file docker/Dockerfile --tag ucentral-client:latest docker
	NEWIMG=$$(docker images --format "{{.ID}}" ucentral-client:latest)
	if [ -n "$$OLDIMG" ] && [ ! "$$OLDIMG" = "$$NEWIMG" ]; then \
		docker image rm $$OLDIMG; \
	fi
	# extra tag with the ucentral source version <branch>.<commit> (runtime still uses :latest)
	docker tag ucentral-client:latest ucentral-client:$(UCENTRAL_VERSION)
	docker save ucentral-client:latest ucentral-client:$(UCENTRAL_VERSION) |gzip -c -  > docker-ucentral-client.gz
	popd

build-final-deb: build-ucentral-docker-img
	pushd src
	# uCentral client is compiled at this stage, just copy it (libs are also copied)
	mv -f docker/deliverables/* docker/

	# Build the final deb file
	dpkg-buildpackage -rfakeroot -b -us -uc -j

	popd
	mv ucentral-client*deb ./output/
	mv src/docker-ucentral-client.gz ./output/
	@echo
	@echo "ucentral client deb pkg is available under ./output/ dir"

clean:
	docker container stop ${CONTAINER_NAME} > /dev/null 2>&1 || true;
	docker container rm ${CONTAINER_NAME} > /dev/null 2>&1 || true;
	docker rmi ucentral-client 2>/dev/null || true;
	docker rmi ${IMG_ID}:${IMG_TAG} 2>/dev/null || true;
	rm -rf output 2>/dev/null || true;
	rm -rf docker 2>/dev/null || true;
	rm -rf src/docker/deliverables || true;
	rm -rf src/docker/lib* || true;
	rm -rf src/docker/ucentral-client || true;
	rm -rf src/docker/version.json || true;
	rm -rf src/docker/ucentral-client.version || true;
	rm -rf src/docker/buildtime || true;
	rm -rf src/docker/schema.json || true;
	rm -rf src/debian/ucentral-client.substvars 2>/dev/null || true;
	rm -rf src/debian/shasta-ucentral-client.debhelper.log 2>/dev/null || true;
	rm -rf src/debian/.debhelper src/debian/ucentral-client 2>/dev/null || true;
	rm -rf src/debian/shasta-ucentral-client* 2>/dev/null || true;
	rm -rf src/debian/debhelper-build-stamp* 2>/dev/null || true;
	rm -rf src/debian/files shasta_1.0_amd64.changes shasta_1.0_amd64.buildinfo 2>/dev/null || true;
