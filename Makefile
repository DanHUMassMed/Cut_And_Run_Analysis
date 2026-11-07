.PHONY: install lint dry-run run clean base-lint base-dry-run base-stub base-run base-clean test help

RUN_DIR           := Analysis_Run
PIPELINE_DIR      := nf-cutandrun
BASE_RUN_DIR      := Pipeline_Run
BASE_PIPELINE_DIR := nf-cutandrun-base

help: ## Show available Makefile targets
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install: ## Verify Nextflow installation and environment
	@nextflow -version

lint: ## Validate Nextflow syntax and configuration for both pipelines
	cd $(RUN_DIR) && nextflow -c config/experiment.config config ../$(PIPELINE_DIR) >/dev/null && echo "Downstream (nf-cutandrun) configuration valid."
	cd $(BASE_RUN_DIR) && nextflow -c config/experiment.config config ../$(BASE_PIPELINE_DIR) >/dev/null && echo "Upstream (nf-cutandrun-base) configuration valid."

dry-run: ## Preview downstream pipeline execution from Analysis_Run without running tasks
	cd $(RUN_DIR) && nextflow -c config/experiment.config run ../$(PIPELINE_DIR) -preview -resume

run: ## Execute the CUT&RUN downstream pipeline from Analysis_Run
	./$(RUN_DIR)/run.sh

base-lint: ## Validate Nextflow syntax and configuration for nf-cutandrun-base
	cd $(BASE_RUN_DIR) && nextflow -c config/experiment.config config ../$(BASE_PIPELINE_DIR) >/dev/null && echo "Upstream (nf-cutandrun-base) configuration valid."

base-dry-run: ## Preview upstream base pipeline execution from Pipeline_Run without running tasks
	cd $(BASE_RUN_DIR) && nextflow -c config/experiment.config run ../$(BASE_PIPELINE_DIR) -preview -resume

base-stub: ## Run stub test of upstream base pipeline from Pipeline_Run
	cd $(BASE_RUN_DIR) && nextflow -c config/experiment.config run ../$(BASE_PIPELINE_DIR) -stub-run

base-run: ## Execute the CUT&RUN upstream base pipeline from Pipeline_Run
	./$(BASE_RUN_DIR)/run.sh

test: lint dry-run base-dry-run ## Run configuration lint and Nextflow dry-run preview for both pipelines

clean: ## Clean Nextflow work directory and transient logs in Analysis_Run
	rm -rf $(RUN_DIR)/work $(RUN_DIR)/.nextflow*

base-clean: ## Clean Nextflow work directory and transient logs in Pipeline_Run
	rm -rf $(BASE_RUN_DIR)/work $(BASE_RUN_DIR)/.nextflow*
