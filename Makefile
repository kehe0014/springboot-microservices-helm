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

# Scan options
SCAN_ENABLED ?= true
SCAN_ASYNC ?= false

# Load .env file if present (for secrets and local overrides)
ifneq (,$(wildcard .env))
    include .env
    export
endif

# --------------------------------------
# Logging Helpers
# --------------------------------------
.PHONY: log-setup clean-logs

log-setup: ## Prepare logging directory and file
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
	@echo "  SKIP_SCAN=true           Skip scans entirely in CI pipeline"

# --------------------------------------
# Docker Authentication
# --------------------------------------
.PHONY: login-ghcr

login-ghcr: log-setup ## Login to GitHub Container Registry
	@echo "🔑 Logging in to GHCR..." $(call logwrap)
	@if [ -z "$$CR_PAT" ]; then \
		echo "❌ CR_PAT is not set. Please define it in .env"; \
		exit 1; \
	fi
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
# Docker Build & Push (no multi-arch)
# --------------------------------------
.PHONY: build

docker-build:
	@echo "🐳 Building Docker images (single-arch, classic)..."
	@for service in $(SERVICES); do \
		echo "Building $$service -> $(REGISTRY)/$$service:$(GIT_SHA)"; \
		docker build \
			-t $(REGISTRY)/$$service:$(GIT_SHA) \
			-f services/$$service/Dockerfile \
			services/$$service || { echo "❌ Docker build failed for $$service"; exit 1; }; \
		docker push $(REGISTRY)/$$service:$(GIT_SHA) || { echo "❌ Docker push failed for $$service"; exit 1; }; \
	done


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
	@echo "⏱️  Running synchronous scans (this may take several minutes)..." $(call logwrap)
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
# Scheduled Nightly Scan
# --------------------------------------
.PHONY: nightly-scan

nightly-scan: check-trivy log-setup ## Run comprehensive nightly security scan
	@echo "🌙 Starting nightly comprehensive security scan..." $(call logwrap)
	@echo "This may take 10-30 minutes..." $(call logwrap)
	@for svc in $(SERVICES); do \
		IMAGE=$(IMAGE_REGISTRY)/$$svc:$(LATEST_TAG); \
		echo "Comprehensive scan for $$IMAGE..."; \
		trivy image --exit-code 0 --severity HIGH,CRITICAL,MEDIUM --format sarif -o $(LOG_DIR)/nightly-scan-$$svc-$$(date +%Y%m%d).sarif $$IMAGE; \
		echo "✅ Scan completed for $$svc"; \
	done $(call logwrap)
	@echo "🌙 Nightly security scans completed! Reports saved in $(LOG_DIR)/" $(call logwrap)

# --------------------------------------
# Helm & GitOps Dry-Run
# --------------------------------------
.PHONY: dry-run
dry-run: log-setup ## Helm template + GitOps manifest validation
	@echo "🚀 Helm dry-run validation..." $(call logwrap)
	@for chart in helm-charts/charts/*; do \
		echo "==> Dry-run $$chart"; \
		helm lint $$chart || exit 1; \
		helm template $$chart --values $$chart/values.yaml > /dev/null || exit 1; \
	done $(call logwrap)

	@echo "🔎 GitOps manifest validation (kubectl dry-run)..." $(call logwrap)
	@for env in staging prod; do \
		FILE=infra/gitops/applications/$$env/gitops-bootstrap.yaml; \
		if [ -f $$FILE ]; then \
			echo "Validating $$FILE..."; \
			kubectl apply --dry-run=client -f $$FILE -n argocd || exit 1; \
		fi; \
	done $(call logwrap)

# --------------------------------------
# Deployment via ArgoCD
# --------------------------------------
.PHONY: check-cluster deploy deploy-staging deploy-prod
check-cluster: ## Verify Kubernetes cluster is accessible
	@kubectl cluster-info > /dev/null || \
		(echo "❌ Kubernetes cluster not reachable"; exit 1)

deploy: check-cluster log-setup ## Deploy GitOps application for $(ENV)
	@echo "🚀 Deploying to $(ENV)..." $(call logwrap)
	@kubectl apply -f infra/gitops/applications/$(ENV)/gitops-bootstrap.yaml -n argocd $(call logwrap)
	@echo "✅ Deploy $(ENV) completed" $(call logwrap)

deploy-staging: ## Deploy to staging
	@$(MAKE) ENV=staging deploy

deploy-prod: ## Deploy to production (requires explicit confirmation)
	@if [ "$(CONFIRM)" != "true" ]; then \
		echo "⚠️  To deploy to prod, run: make deploy-prod CONFIRM=true"; \
		exit 1; \
	fi
	@$(MAKE) ENV=prod deploy

# --------------------------------------
# Clean Targets
# --------------------------------------
.PHONY: clean clean-maven clean-scans
clean: clean-logs clean-maven clean-scans ## Clean all generated files

clean-maven: ## Clean Maven target directories
	@echo "🧹 Cleaning Maven target directories..."
	@find . -name target -type d -exec rm -rf {} + || true
	@for svc in $(SERVICES); do \
		echo "Cleaning $$svc..."; \
		cd services/$$svc && mvn clean || exit 1; \
		cd - > /dev/null; \
	done $(call logwrap)

clean-scans: ## Clean scan reports
	@echo "🧹 Cleaning scan reports..." $(call logwrap)
	@rm -f $(LOG_DIR)/trivy-scan-*.sarif $(LOG_DIR)/nightly-scan-*.sarif 2>/dev/null || true

# --------------------------------------
# CI/CD Orchestration
# --------------------------------------
.PHONY: ci ci-fast ci-nightly

ci: log-setup  lint test build scan deploy-staging ## Full CI pipeline (staging auto-deploy)
	@echo "✅ CI/CD pipeline completed successfully!" $(call logwrap)

ci-fast: log-setup clean test build deploy-staging ## Fast CI pipeline (staging only, no scans)
	@echo "✅ Fast CI/CD pipeline (staging, no scans) completed successfully!"

ci-nightly: log-setup  lint test build nightly-scan ## Nightly CI pipeline with comprehensive scans
	@echo "✅ Nightly CI/CD pipeline completed successfully!" $(call logwrap)

.PHONY: verify-cluster

NAMESPACE ?= staging

verify-cluster: log-setup ## Vérifie l'état des pods, services et logs dans le cluster
	@echo "🔍 Vérification du cluster Kubernetes ($(NAMESPACE))..." $(call logwrap)
	@echo "🟢 Pods:" $(call logwrap)
	@kubectl get pods -n $(NAMESPACE) $(call logwrap)
	@echo "🟢 Services:" $(call logwrap)
	@kubectl get svc -n $(NAMESPACE) $(call logwrap)
	@echo "🟢 Deployments:" $(call logwrap)
	@kubectl get deployments -n $(NAMESPACE) $(call logwrap)
	@echo "🟢 StatefulSets:" $(call logwrap)
	@kubectl get statefulsets -n $(NAMESPACE) $(call logwrap)
	@echo "🟢 ReplicaSets:" $(call logwrap)
	@kubectl get rs -n $(NAMESPACE) $(call logwrap)
	@echo "🟢 Events récents:" $(call logwrap)
	@kubectl get events -n $(NAMESPACE) --sort-by='.metadata.creationTimestamp' | tail -20 $(call logwrap)
	@echo "🟢 Logs récents des pods (10 dernières lignes de chaque pod):" $(call logwrap)
	@for pod in $$(kubectl get pods -n $(NAMESPACE) -o jsonpath='{.items[*].metadata.name}'); do \
		echo "--- Logs $$pod ---" $(call logwrap); \
		kubectl logs --tail=10 $$pod -n $(NAMESPACE) || echo "⚠️ Pas de logs pour $$pod"; \
	done $(call logwrap)
	@echo "✅ Vérification du cluster terminée !" $(call logwrap)


# --------------------------------------
# Development Quick Targets
# --------------------------------------
.PHONY: dev dev-test dev-build

dev: compile test ## Development: compile and test (staging context)
	@echo "✅ Development build completed (ENV=$(ENV))" $(call logwrap)

dev-test: test ## Quick test only (staging context)
	@echo "✅ Tests completed (ENV=$(ENV))" $(call logwrap)

dev-build: package ## Quick package without tests
	@echo "✅ Packaging completed" $(call logwrap)
