.PHONY: install lint dry-run run clean help

RUN_DIR := Analysis_Run
CONFIG  := $(RUN_DIR)/config/experiment.config

help: ## Show available Makefile targets
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install: ## Verify Nextflow installation and environment
	@nextflow -version

lint: ## Validate Nextflow syntax and configuration
	cd $(RUN_DIR) && nextflow -c config/experiment.config config ../ >/dev/null && echo "Configuration valid."

dry-run: ## Preview pipeline execution from Analysis_Run without running tasks
	cd $(RUN_DIR) && nextflow -c config/experiment.config run ../ -preview

run: ## Execute the CUT&RUN downstream pipeline from Analysis_Run
	./$(RUN_DIR)/run.sh

test: lint dry-run ## Run configuration lint and Nextflow dry-run preview

clean: ## Clean Nextflow work directory and transient logs in Analysis_Run
	rm -rf $(RUN_DIR)/work $(RUN_DIR)/.nextflow*

