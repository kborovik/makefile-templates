.EXPORT_ALL_VARIABLES:
.ONESHELL:
.SILENT:

MAKEFLAGS += --no-builtin-rules --no-builtin-variables

###############################################################################
# Variables
###############################################################################

google_project ?= coroil-ocrdoc-dev1

google_project_dev1 := coroil-ocrdoc-dev1
google_project_prd1 := coroil-ocrdoc-prd1

###############################################################################
# Settings
###############################################################################

root_dir := $(abspath .)

terraform_dir := $(root_dir)/terraform
terraform_config := $(root_dir)/config/$(google_project)
terraform_tfvars := $(terraform_config)/terraform.tfvars
terraform_output := $(terraform_config)/$(google_project).json
terraform_bucket := terraform-$(google_project)

ifeq ($(wildcard $(terraform_tfvars)),)
  $(error ==> Missing configuration file $(terraform_tfvars) <==)
endif

app_id := $(shell grep app_id $(terraform_tfvars) | cut -d '"' -f2)
google_region := $(shell grep google_region $(terraform_tfvars) | cut -d '"' -f2)

ifneq ($(wildcard VERSION),)
	VERSION := $(file < VERSION)
endif

###############################################################################
# Info
###############################################################################

default: settings

settings: terraform-config
	$(call header,Settings)
	$(call var,app_id,$(app_id))
	$(call var,google_region,$(google_region))
	$(call var,google_project,$(google_project))
	$(call var,gcloud_project,$(shell gcloud config list --format=json | jq -r '.core.project'))

help:
	$(call header,Help)
	$(call help,make google,Configure Google CLI)
	$(call help,make google-auth,Authenticate Google CLI)
	$(call help,make terraform,Run Terraform plan and apply)
	$(call help,make shutdown,Remove selected Terraform resources)
	$(call help,make release,Trigger GitHub pipeline deployment)

secretes:
	$(call header,Secrets)

###############################################################################
# End-to-End Pipeline
###############################################################################

deploy: terraform

deploy-dev1:
	google_project=$(google_project_dev1) $(MAKE) terraform

deploy-prd1:
	google_project=$(google_project_prd1) $(MAKE) terraform

shutdown: 
	google_project=$(google_project_dev1) $(MAKE) terraform-destroy-selected
	google_project=$(google_project_prd1) $(MAKE) terraform-destroy-selected

clean: terraform-clean

###############################################################################
# Terraform
###############################################################################

.PHONY: terraform

terraform: terraform-plan prompt terraform-apply

terraform-fmt: terraform-version
	$(call header,Check Terraform Code Format)
	cd $(terraform_dir)
	terraform fmt -check -recursive

terraform-config:
	ln -rfs $(terraform_tfvars) $(terraform_dir)/terraform.tfvars

terraform-validate:
	$(call header,Validate Terraform)
	cd $(terraform_dir)
	terraform validate

terraform-init: terraform-fmt terraform-config
	$(call header,Initialize Terraform)
	cd $(terraform_dir)
	terraform init -upgrade -input=false -reconfigure -backend-config="bucket=$(terraform_bucket)" -backend-config="prefix=$(app_id)"

terraform-plan: terraform-init terraform-validate
	$(call header,Run Terraform Plan)
	cd $(terraform_dir)
	terraform plan -input=false -refresh=true -var-file="$(terraform_tfvars)"

terraform-apply: terraform-init terraform-validate
	$(call header,Run Terraform Apply)
	set -e
	cd $(terraform_dir)
	terraform apply -auto-approve -input=false -refresh=true -var-file="$(terraform_tfvars)"

terraform-destroy-all: terraform-init
	$(call header,Run Terraform Apply)
	cd $(terraform_dir)
	terraform apply -destroy -input=false -refresh=true -var-file="$(terraform_tfvars)"

terraform-destroy-selected: terraform-init
	$(call header,Run Terraform Apply)
	cd $(terraform_dir)
	terraform apply -auto-approve -destroy -var-file="$(terraform_tfvars)" \
	-target=google_compute_address.cloud_nat \
	-target=google_container_cluster.gke1

terraform-clean:
	$(call header,Delete Terraform providers and state)
	-rm -rf $(terraform_dir)/.terraform

terraform-show:
	cd $(terraform_dir)
	terraform show

terraform-version:
	$(call header,Terraform Version)
	terraform version

terraform-state-list:
	cd $(terraform_dir)
	terraform state list

terraform-state-recursive:
	gsutil ls -r gs://$(terraform_bucket)/**

terraform-state-versions:
	gsutil ls -a gs://$(terraform_bucket)/$(app_id)/default.tfstate

terraform-state-unlock:
	gsutil rm gs://$(terraform_bucket)/$(app_id)/default.tflock

terraform-bucket:
	$(call header,Create Terrafomr state GCS bucket)
	set -e
	gsutil mb -p $(google_project) -l $(google_region) -b on gs://$(terraform_bucket) || true
	gsutil ubla set on gs://$(terraform_bucket)
	gsutil versioning set on gs://$(terraform_bucket)

###############################################################################
# Google CLI
###############################################################################

google: google-config

google-auth:
	$(call header,Configure Google CLI)
	gcloud auth revoke --all
	gcloud auth login --update-adc --no-launch-browser

google-config:
	set -e
	gcloud auth application-default set-quota-project $(google_project)
	gcloud config set core/project $(google_project)
	gcloud config set compute/region $(google_region)
	gcloud config list

google-project:
	$(call header,Create Google Project)
	$(eval google_organization := $(shell pass lab5/google/organization_id))
	$(eval google_billing_account := $(shell pass lab5/google/billing_account))
	set -e
	echo -n "$(blue)Create Google Project $(yellow)$(google_project)$(reset)? $(green)(yes/no)$(reset)"
	read -p ": " answer && [ "$$answer" = "yes" ] || exit 1
	gcloud projects create $(google_project) --organization=$(google_organization)
	gcloud billing projects link $(google_project) --billing-account=$(google_billing_account)
	gcloud services enable cloudresourcemanager.googleapis.com --project=$(google_project)
	gcloud services enable compute.googleapis.com --project=$(google_project)
	$(MAKE) terraform-bucket

###############################################################################
# Repo Version
###############################################################################

commit:
	git commit -m "$(shell date +%Y.%m.%d-%H%M)"

release:
	$(if $(shell git diff --name-only --exit-code),$(error ==> Stage Git Changes <==),)
	$(if $(shell git diff --staged --name-only --exit-code),$(error ==> Commit Git Changes <==),)
	$(eval git_current_branch := $(shell git branch --show-current))
	$(if $(shell git diff --name-only --exit-code $(git_current_branch) origin/$(git_current_branch)),$(error ==> Push Git Changes <==),)
	echo -n "$(blue)GitHub deploy $(yellow)$(google_project)$(reset)? $(green)(yes/no)$(reset)"
	read -p ": " answer && [ "$$answer" = "yes" ] || exit 1
	git tag --force $(google_project) -m "$(google_project)"
	git push --force --tags

###############################################################################
# Colors and Headers
###############################################################################

TERM := xterm-256color

black := $$(tput setaf 0)
red := $$(tput setaf 1)
green := $$(tput setaf 2)
yellow := $$(tput setaf 3)
blue := $$(tput setaf 4)
magenta := $$(tput setaf 5)
cyan := $$(tput setaf 6)
white := $$(tput setaf 7)
reset := $$(tput sgr0)

define header
echo "$(blue)==> $(1) <==$(reset)"
endef

define help
echo "$(green)$(1)$(reset) - $(white)$(2)$(reset)"
endef

define var
echo "$(magenta)$(1)$(reset)=$(yellow)$(2)$(reset)"
endef

prompt:
	echo -n "$(blue)Deploy $(yellow)$(google_project)? $(green)(yes/no)$(reset)"
	read -p ": " answer && [ "$$answer" = "yes" ] || exit 1

###############################################################################
# Errors
###############################################################################
ifeq ($(shell which gcloud),)
  $(error ==> Install Google CLI https://cloud.google.com/sdk/docs/install <==)
endif

ifeq ($(shell which terraform),)
  $(error ==> Install terraform https://www.terraform.io/downloads <==)
endif
