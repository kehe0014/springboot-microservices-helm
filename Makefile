SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# --------------------------------------
# Global Variables
# --------------------------------------
IMAGE_REGISTRY ?= ghcr.io/kehe0014/springboot-microservices-helm
SERVICES = api-gateway user-service product-service
ENV ?= staging
GIT_SHA := $(shell git rev-parse --short=7 HEAD)
TAG ?= $(GIT_SHA)
LATEST_TAG ?= latest

LOG_DIR := logs
LOG_FILE := $(LOG_DIR)/make.log

# Security and configuration
SCAN_ENABLED ?= true
SCAN_ASYNC ?= false
CONFIRM ?= false
GIT_REPO ?= https://github.com/kehe0014/springboot-microservices-helm.git
HELM_BASE_PATH ?= helm-charts/charts

# ArgoCD configuration
ARGOCD_SERVER ?= argocd.example.com
ARGOCD_USER ?= admin
ARGOCD_NAMESPACE ?= argocd
MICROSERVICES = api-gateway user-service product-service
DEST_NAMESPACE ?= gitops-demo-staging

# Load .env file if present (for secrets and local overrides)
ifneq (,$(wildcard .env))
    include .env
    export
endif

# --------------------------------------
# Security Validation
# --------------------------------------
.PHONY: validate-env validate-credentials

validate-env: ## Validate environment variables for security
	@echo "🔒 Validating environment configuration..."
	@if [ "$(ARGOCD_PASSWORD)" = "kzqGhoKFNZqB0XhJ" ]; then \
		echo "⚠️  SECURITY WARNING: Using default ArgoCD password!"; \
		echo "   Please set ARGOCD_PASSWORD in your .env file for production"; \
		echo "   Continuing for now..."; \
	fi
	@if [ "$(ARGOCD_SERVER)" = "argocd.example.com" ]; then \
		echo "⚠️  Using default ArgoCD server. Update ARGOCD_SERVER for production."; \
	fi
	@echo "✅ Environment validation passed"

validate-credentials: ## Validate required credentials are set
	@if [ -z "$$CR_PAT" ] && [ "$(MAKECMDGOALS)" != "help" ]; then \
		echo "❌ CR_PAT is not set. Please define it in .env"; \
		exit 1; \
	fi
	@if [ -z "$(ARGOCD_PASSWORD)" ]; then \
		echo "❌ ARGOCD_PASSWORD is not set. Please define it in .env"; \
		exit 1; \
	fi


.PHONY: check-cluster

check-cluster: ## Verify Kubernetes cluster is accessible
	@echo "🔍 Checking Kubernetes cluster connectivity..."
	@if ! command -v kubectl >/dev/null 2>&1; then \
		echo "⚠️  kubectl not found, skipping cluster check"; \
		exit 0; \
	fi
	@if ! kubectl cluster-info >/dev/null 2>&1; then \
		echo "⚠️  Kubernetes cluster not reachable or not configured"; \
		echo "    This is normal if you're only building images without deploying"; \
		exit 0; \
	fi
	@echo "✅ Cluster is available"


# --------------------------------------
# Logging Helpers
# --------------------------------------
.PHONY: log-setup clean-logs

log-setup: check-cluster ## Prepare logging directory and file
	@mkdir -p $(LOG_DIR)
	@touch $(LOG_FILE)
	@echo "Logging to $(LOG_FILE)..."

clean-logs: ## Remove all generated logs
	@rm -rf $(LOG_DIR)
	@echo "Cleaned logs directory."

define logwrap
2>&1 | while read -r line; do \
    printf "\033[36m[%s]\033[0m %s\n" "$$(date +'%Y-%m-%d %H:%M:%S')" "$$line"; \
done | { mkdir -p $(LOG_DIR); touch $(LOG_FILE); tee -a $(LOG_FILE); }
endef

# --------------------------------------
# Help / Documentation
# --------------------------------------
.PHONY: help
help: ## Print available commands with descriptions
	@echo "Available commands:"
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort
	@echo ""
	@echo "Environment variables:"
	@echo "  SCAN_ENABLED=true/false  Enable/disable security scans (default: true)"
	@echo "  SCAN_ASYNC=true/false    Run scans asynchronously (default: false)"
	@echo "  CONFIRM=true             Required for production deployments"

# --------------------------------------
# Docker Authentication
# --------------------------------------
.PHONY: login-ghcr

login-ghcr: validate-credentials log-setup ## Login to GitHub Container Registry
	@echo "🔑 Logging in to GHCR..." $(call logwrap)
	@echo $$CR_PAT | docker login ghcr.io -u ${GITHUB_USER} --password-stdin $(call logwrap)
	@echo "✅ GHCR login successful" $(call logwrap)

# --------------------------------------
# Maven Build and Test
# --------------------------------------
.PHONY: compile test package

compile: log-setup ## Compile Java code with Maven
	@echo "🔨 Compiling with Maven..." $(call logwrap)
	@for svc in $(SERVICES); do \
		echo "Compiling $$svc..."; \
		cd services/$$svc && mvn compile || exit 1; \
		cd - > /dev/null; \
	done $(call logwrap)

test: log-setup ## Run Spring Boot unit tests with Maven (staging by default)
	@echo "🧪 Running unit tests ..." $(call logwrap)
	@for svc in $(SERVICES); do \
		echo "Testing $$svc..."; \
		cd services/$$svc && mvn test || exit 1; \
		cd - > /dev/null; \
	done $(call logwrap)

package: log-setup ## Package JAR files with Maven
	@echo "📦 Packaging JAR files..." $(call logwrap)
	@for svc in $(SERVICES); do \
		echo "Packaging $$svc..."; \
		cd services/$$svc && mvn package -DskipTests || exit 1; \
		cd - > /dev/null; \
	done $(call logwrap)

# --------------------------------------
# Helm Lint
# --------------------------------------
.PHONY: lint
lint: log-setup ## Lint Helm charts
	@echo "🔎 Linting Helm charts..." $(call logwrap)
	@for chart in helm-charts/charts/*; do \
		echo "Linting $$chart..."; \
		helm lint "$$chart" || exit 1; \
	done $(call logwrap)

# --------------------------------------
# Docker Build & Push
# --------------------------------------
.PHONY: build push

.PHONY: build-single
build-single: login-ghcr log-setup
	@for service in $(SERVICES); do \
		echo "Building $$service -> $(IMAGE_REGISTRY)/$$service:$(GIT_SHA)"; \
		docker build \
			-t $(IMAGE_REGISTRY)/$$service:$(GIT_SHA) \
			-t $(IMAGE_REGISTRY)/$$service:$(LATEST_TAG) \
			-f services/$$service/Dockerfile \
			services/$$service || { echo "❌ Docker build failed for $$service"; exit 1; }; \
	done

push: build ## Push Docker images to registry
	@echo "📤 Pushing Docker images..." $(call logwrap)
	@for service in $(SERVICES); do \
		echo "Pushing $(IMAGE_REGISTRY)/$$service:$(GIT_SHA)"; \
		docker push $(IMAGE_REGISTRY)/$$service:$(GIT_SHA) || { echo "❌ Docker push failed for $$service"; exit 1; }; \
		docker push $(IMAGE_REGISTRY)/$$service:$(LATEST_TAG) || { echo "❌ Docker push failed for $$service:latest"; exit 1; }; \
	done $(call logwrap)

# --------------------------------------
# Security Scan (Trivy) - Intelligent
# --------------------------------------
.PHONY: scan scan-async scan-sync check-trivy

check-trivy: ## Check if Trivy is installed
	@if ! command -v trivy >/dev/null 2>&1; then \
		echo "❌ Trivy is not installed. Install with: brew install trivy or sudo apt-get install trivy"; \
		exit 1; \
	fi

scan: check-trivy log-setup ## Scan Docker images for vulnerabilities (intelligent)
	@if [ "$(SCAN_ENABLED)" = "false" ]; then \
		echo "⚠️  Security scans disabled (SCAN_ENABLED=false)"; \
		exit 0; \
	fi
	@echo "🔐 Running Trivy scans..." $(call logwrap)
	@if [ "$(SCAN_ASYNC)" = "true" ]; then \
		echo "🚀 Starting async scans in background..."; \
		$(MAKE) scan-async & \
		echo "✅ Scans running in background. Check logs for results."; \
	else \
		$(MAKE) scan-sync; \
	fi

scan-sync: check-trivy ## Synchronous security scan
	@echo "⏱️  Running synchronous scans..." $(call logwrap)
	@for svc in $(SERVICES); do \
		IMAGE=$(IMAGE_REGISTRY)/$$svc:$(TAG); \
		echo "Scanning $$IMAGE..."; \
		trivy image --exit-code 1 --severity HIGH,CRITICAL $$IMAGE || exit 1; \
	done $(call logwrap)
	@echo "✅ All security scans completed successfully!" $(call logwrap)

scan-async: check-trivy ## Asynchronous security scan (for background execution)
	@echo "🌙 Starting async security scans at $$(date)" $(call logwrap)
	@for svc in $(SERVICES); do \
		IMAGE=$(IMAGE_REGISTRY)/$$svc:$(TAG); \
		echo "Async scan: $$IMAGE"; \
		trivy image --exit-code 0 --severity HIGH,CRITICAL --format sarif -o $(LOG_DIR)/trivy-scan-$$svc-$$(date +%Y%m%d-%H%M%S).sarif $$IMAGE & \
	done
	@wait
	@echo "✅ Async scans completed at $$(date)" $(call logwrap)

# --------------------------------------
# ArgoCD Utilities
# --------------------------------------
.PHONY: wait-argocd argocd-login check-argocd-cli

check-argocd-cli: ## Check if ArgoCD CLI is installed
	@which argocd > /dev/null 2>&1 || { \
		echo "[❌] ArgoCD CLI is not installed. Please install it first."; \
		echo "     Installation: https://argo-cd.readthedocs.io/en/stable/cli_installation/"; \
		exit 1; \
	}

wait-argocd: ## Wait for ArgoCD server to be ready
	@echo "[⏱️] Waiting for ArgoCD server to be ready..."
	@until kubectl get pods -n $(ARGOCD_NAMESPACE) 2>/dev/null | grep argocd-server | grep Running >/dev/null 2>&1; do \
		echo "[...] waiting 5s"; sleep 5; \
	done
	@echo "[✅] ArgoCD server is ready"

argocd-login: check-argocd-cli wait-argocd validate-credentials ## Login to ArgoCD
	@echo "[🔐] Logging in to ArgoCD..."
	@argocd login $(ARGOCD_SERVER) \
		--username $(ARGOCD_USER) \
		--password $(ARGOCD_PASSWORD) \
		--insecure \
		--grpc-web \
		$(call logwrap) && \
	echo "[✅] ArgoCD login successful"

# --------------------------------------
# Bootstrap microservices in ArgoCD (Enhanced)
# --------------------------------------
.PHONY: bootstrap-apps bootstrap-apps-dry-run bootstrap-apps-delete

bootstrap-apps: argocd-login log-setup ## Bootstrap applications in ArgoCD
	@echo "[🚀] Bootstrap des applications ArgoCD depuis le repo..." $(call logwrap)
	@FAILED=0
	@for app in $(MICROSERVICES); do \
		helm_path="$(HELM_BASE_PATH)/$$app"; \
		if [ -d "$$helm_path" ]; then \
			echo "[ℹ️] Creating ArgoCD app for $$app using $$helm_path"; \
			argocd app create $$app \
				--repo $(GIT_REPO) \
				--path "$$helm_path" \
				--dest-namespace $(DEST_NAMESPACE) \
				--dest-server https://kubernetes.default.svc \
				--sync-policy automated \
				--auto-prune \
				--self-heal \
				--grpc-web \
				--server $(ARGOCD_SERVER) \
				--insecure \
				$(call logwrap) && \
			echo "[✅] Application $$app created successfully"; \
		else \
			echo "[⚠️] Helm chart path $$helm_path not found, skipping"; \
			FAILED=1; \
		fi \
	done
	@if [ "$$FAILED" -eq 1 ]; then \
		echo "[❌] Some applications failed to bootstrap"; \
		exit 1; \
	else \
		echo "[✅] Bootstrap terminé avec succès"; \
	fi

bootstrap-apps-dry-run: ## Dry run to check what would be created
	@echo "[🔍] Dry run: Applications that would be created:"
	@for app in $(MICROSERVICES); do \
		helm_path="$(HELM_BASE_PATH)/$$app"; \
		if [ -d "$$helm_path" ]; then \
			echo "[ℹ️] Would create: $$app"; \
			echo "     Repo: $(GIT_REPO)"; \
			echo "     Path: $$helm_path"; \
			echo "     Namespace: $(DEST_NAMESPACE)"; \
		else \
			echo "[⚠️] Would skip: $$app (chart not found)"; \
		fi \
	done

bootstrap-apps-delete: argocd-login ## Delete all bootstrapped applications
	@echo "[🗑️] Deleting all ArgoCD applications..."
	@for app in $(MICROSERVICES); do \
		echo "[ℹ️] Deleting application $$app..."; \
		argocd app delete $$app \
			--grpc-web \
			--server $(ARGOCD_SERVER) \
			--yes \
			--insecure \
			$(call logwrap) || echo "[⚠️] Failed to delete $$app (might not exist)"; \
	done
	@echo "[✅] Deletion process completed"

# --------------------------------------
# Full bootstrap pipeline
# --------------------------------------
.PHONY: full-bootstrap reset-argocd verify-argocd

reset-argocd: argocd-login log-setup ## Reset ArgoCD applications
	@echo "[🔄] Resetting ArgoCD..." $(call logwrap)
	@echo "[🗑️] Deleting existing ArgoCD applications..." $(call logwrap)
	@for app in $(MICROSERVICES)-staging staging-apps; do \
		argocd app delete $$app --grpc-web --yes 2>/dev/null || true; \
	done
	@echo "[🧹] Cleaning Kubernetes resources in namespace $(DEST_NAMESPACE)..." $(call logwrap)
	@kubectl delete all --all -n $(DEST_NAMESPACE) --wait=false 2>/dev/null || true
	@echo "[✅] ArgoCD reset completed"

verify-argocd: argocd-login log-setup ## Verify ArgoCD status
	@echo "[🔍] Vérification du cluster et des apps ArgoCD..." $(call logwrap)
	@kubectl get pods,svc,deploy,statefulset,rs -n $(DEST_NAMESPACE) $(call logwrap)
	@argocd app list --grpc-web --server $(ARGOCD_SERVER) --insecure $(call logwrap)
	@echo "[✅] Vérification terminée"

full-bootstrap: validate-env reset-argocd bootstrap-apps verify-argocd ## Full bootstrap pipeline
	@echo "[✅] Full bootstrap pipeline terminée!" $(call logwrap)

# --------------------------------------
# CI/CD Orchestration
# --------------------------------------
.PHONY: ci ci-fast ci-nightly

ci: validate-env log-setup lint test build scan bootstrap-apps ## Full CI pipeline
	@echo "✅ CI/CD pipeline completed successfully!" $(call logwrap)

ci-fast: validate-env log-setup lint test build bootstrap-apps ## Fast CI pipeline (no scans)
	@echo "✅ Fast CI/CD pipeline completed successfully!"

ci-nightly: validate-env log-setup lint test build nightly-scan ## Nightly CI pipeline with comprehensive scans
	@echo "✅ Nightly CI/CD pipeline completed successfully!" $(call logwrap)

# --------------------------------------
# Clean Targets
# --------------------------------------
.PHONY: clean clean-maven clean-scans
clean: clean-logs clean-maven clean-scans ## Clean all generated files

clean-maven: ## Clean Maven target directories
	@echo "🧹 Cleaning Maven target directories..."
	@find . -name target -type d -exec rm -rf {} + 2>/dev/null || true
	@for svc in $(SERVICES); do \
		echo "Cleaning $$svc..."; \
		cd services/$$svc && mvn clean 2>/dev/null || true; \
		cd - > /dev/null; \
	done

clean-scans: ## Clean scan reports
	@echo "🧹 Cleaning scan reports..."
	@rm -f $(LOG_DIR)/trivy-scan-*.sarif $(LOG_DIR)/nightly-scan-*.sarif 2>/