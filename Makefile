BASE_DIRECTORY=$(shell git rev-parse --show-toplevel)
RELEASE_BRANCH?=$(shell cat $(BASE_DIRECTORY)/release/DEFAULT_RELEASE_BRANCH)
RELEASE_ENVIRONMENT?=development
RELEASE?=$(shell cat $(BASE_DIRECTORY)/release/$(RELEASE_BRANCH)/$(RELEASE_ENVIRONMENT)/RELEASE)
ARTIFACT_BUCKET?=my-s3-bucket

AWS_ACCOUNT_ID?=$(shell aws sts get-caller-identity --query Account --output text)
AWS_REGION?=us-west-2
IMAGE_REPO?=$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
RELEASE_AWS_PROFILE?=default

IS_BOT?=false
USE_PREV_RELEASE_MANIFEST?=true
OPEN_PR?=true

RELEASE_GIT_TAG?=v$(RELEASE_BRANCH)-eks-$(RELEASE)
RELEASE_GIT_COMMIT_HASH?=$(shell git rev-parse @)

ifdef MAKECMDGOALS
TARGET=$(MAKECMDGOALS)
else
TARGET=$(DEFAULT_GOAL)
endif

presubmit-cleanup = \
	if [ `echo $(1)|awk '{$1==$1};1'` == "build" ]; then \
		make -C $(2) clean; \
	fi

.PHONY: setup
setup:
	development/ecr/ecr-command.sh install-ecr-public
	development/ecr/ecr-command.sh login-ecr-public

.PHONY: build
build:
	go vet cmd/main_postsubmit.go
	go run cmd/main_postsubmit.go \
		--target=build \
		--release-branch=${RELEASE_BRANCH} \
		--release=${RELEASE} \
		--region=${AWS_REGION} \
		--account-id=${AWS_ACCOUNT_ID} \
		--image-repo=${IMAGE_REPO} \
		--dry-run=true
	@echo 'Done' $(TARGET)

.PHONY: postsubmit-build
postsubmit-build: setup
	go vet cmd/main_postsubmit.go
	go run cmd/main_postsubmit.go \
		--target=release \
		--release-branch=${RELEASE_BRANCH} \
		--release=${RELEASE} \
		--region=${AWS_REGION} \
		--account-id=${AWS_ACCOUNT_ID} \
		--image-repo=${IMAGE_REPO} \
		--artifact-bucket=$(ARTIFACT_BUCKET) \
		--dry-run=false

.PHONY: kops-prow-arm
kops-prow-arm: export NODE_INSTANCE_TYPE=t4g.medium
kops-prow-arm: export NODE_ARCHITECTURE=arm64
kops-prow-arm: postsubmit-build
	$(eval MINOR_VERSION=$(subst 1-,,$(RELEASE_BRANCH)))
	if [[ $(MINOR_VERSION) -ge 21 ]]; then \
		development/kops/prow.sh; \
	fi;

.PHONY: kops-prow-amd
kops-prow-amd: postsubmit-build
	development/kops/prow.sh

.PHONY: kops-prow
kops-prow: kops-prow-amd kops-prow-arm
	@echo 'Done kops-prow'

.PHONT: kops-prereqs
kops-prereqs: 
	ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N ""
	cd development/kops && ./install_requirements.sh

.PHONY: postsubmit-conformance
postsubmit-conformance: postsubmit-build kops-prereqs kops-prow 
	@echo 'Done postsubmit-conformance'

.PHONY: tag
tag:
	git tag --a $(RELEASE_GIT_TAG) -m $(RELEASE_GIT_TAG) $(RELEASE_GIT_COMMIT_HASH)
	git push upstream $(RELEASE_GIT_TAG)

.PHONY: upload
upload:
	release/generate_crd.sh $(RELEASE_BRANCH) $(RELEASE) $(IMAGE_REPO)
	release/s3_sync.sh $(RELEASE_BRANCH) $(RELEASE) $(ARTIFACT_BUCKET)
	@echo 'Done' $(TARGET)

.PHONY: release
release: makes upload
	@echo 'Done' $(TARGET)

.PHONY: binaries
binaries: makes
	@echo 'Done' $(TARGET)

.PHONY: run-target-in-docker
run-target-in-docker:
	build/lib/run_target_docker.sh $(PROJECT) $(MAKE_TARGET) $(RELEASE_BRANCH) $(IMAGE_REPO)

.PHONY: update-attribution-checksums-docker
update-attribution-checksums-docker:
	build/lib/update_checksum_docker.sh $(PROJECT) $(RELEASE_BRANCH)

.PHONY: stop-docker-builder
stop-docker-builder:
	docker rm -f -v eks-d-builder

.PHONY: run-buildkit-and-registry
run-buildkit-and-registry:
	docker run -d --name buildkitd --net host --privileged moby/buildkit:v0.9.0-rootless
	docker run -d --name registry  --net host registry:2

.PHONY: stop-buildkit-and-registry
stop-buildkit-and-registry:
	docker rm -v --force buildkitd
	docker rm -v --force registry

.PHONY: clean
clean: makes
	@echo 'Done' $(TARGET)
	rm -rf _output

.PHONY: makes
makes:
	make -C projects/kubernetes/release $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes/release")
	make -C projects/kubernetes/kubernetes $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes/kubernetes")
	make -C projects/containernetworking/plugins $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/containernetworking/plugins")
	make -C projects/coredns/coredns $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/coredns/coredns")
	make -C projects/etcd-io/etcd $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/etcd-io/etcd")
	make -C projects/kubernetes-csi/external-attacher $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-csi/external-attacher")
	make -C projects/kubernetes-csi/external-resizer $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-csi/external-resizer")
	make -C projects/kubernetes-csi/livenessprobe $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-csi/livenessprobe")
	make -C projects/kubernetes-csi/node-driver-registrar $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-csi/node-driver-registrar")
	make -C projects/kubernetes-sigs/aws-iam-authenticator $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-sigs/aws-iam-authenticator")
	make -C projects/kubernetes-sigs/metrics-server $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-sigs/metrics-server")
	make -C projects/kubernetes-csi/external-snapshotter $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-csi/external-snapshotter")
	make -C projects/kubernetes-csi/external-provisioner $(TARGET)
	$(call presubmit-cleanup, $(TARGET), "projects/kubernetes-csi/external-provisioner")

.PHONY: attribution-files
attribution-files:
	build/update-attribution-files/make_attribution.sh projects/containernetworking/plugins
	build/update-attribution-files/make_attribution.sh projects/coredns/coredns
	build/update-attribution-files/make_attribution.sh projects/etcd-io/etcd
	build/update-attribution-files/make_attribution.sh projects/kubernetes-csi/external-attacher
	build/update-attribution-files/make_attribution.sh projects/kubernetes-csi/external-resizer
	build/update-attribution-files/make_attribution.sh projects/kubernetes-csi/livenessprobe
	build/update-attribution-files/make_attribution.sh projects/kubernetes-csi/node-driver-registrar
	build/update-attribution-files/make_attribution.sh projects/kubernetes-sigs/aws-iam-authenticator
	build/update-attribution-files/make_attribution.sh projects/kubernetes-sigs/metrics-server
	build/update-attribution-files/make_attribution.sh projects/kubernetes-csi/external-snapshotter
	build/update-attribution-files/make_attribution.sh projects/kubernetes-csi/external-provisioner
	build/update-attribution-files/make_attribution.sh projects/kubernetes/release
	build/update-attribution-files/make_attribution.sh projects/kubernetes/kubernetes

	cat _output/total_summary.txt

.PHONY: update-attribution-files
update-attribution-files: attribution-files
	build/update-attribution-files/create_pr.sh

.PHONY: update-release-number
update-release-number:
	go vet ./cmd/release/number
	go run ./cmd/release/number/main.go \
		--branch=$(RELEASE_BRANCH) \
		--isBot=$(IS_BOT)

.PHONY: release-docs
release-docs:
	go vet ./cmd/release/docs
	go run ./cmd/release/docs/main.go \
		--branch=$(RELEASE_BRANCH) \
		--isBot=$(IS_BOT) \
		--usePrevReleaseManifestForComponentTable=$(USE_PREV_RELEASE_MANIFEST) \
		--openPR=$(OPEN_PR)

.PHONY: only-index-md-from-existing-release-manifest
only-index-md-from-existing-release-manifest:
	go vet ./cmd/release/docs
	go run ./cmd/release/docs/main.go \
		--branch=$(RELEASE_BRANCH) \
		--includeIndex=true \
		--includeIndexComponentTable=true \
		--usePrevReleaseManifestForComponentTable=false \
		--includeChangelog=false \
		--includeAnnouncement=false \
		--includeREADME=false \
		--includeDocsIndex=false \
		--force=true
