.ONESHELL:
SHELL := /bin/bash

AWS_REGION ?= eu-north-1
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text)
ECR_REPO_NAME ?= litellm-repo
STACK_NAME ?= litellm-stack
NAME_PREFIX ?= litellm

# Environment-first approach: allow environment variables to override defaults
ANTHROPIC_API_KEY ?= 
LITELLM_MASTER_KEY ?= 

# Load .env file if it exists (for local development convenience)
ifneq (,$(wildcard .env))
    include .env
    export
endif

# Validate required environment variables are set
ifeq ($(ANTHROPIC_API_KEY),)
    $(error ANTHROPIC_API_KEY is not set. Set via environment variable or create .env file with ANTHROPIC_API_KEY=your_key)
endif
ifeq ($(LITELLM_MASTER_KEY),)
    $(error LITELLM_MASTER_KEY is not set. Set via environment variable or create .env file with LITELLM_MASTER_KEY=your_key)
endif

# Generate incrementing image tag based on timestamp. (This will always trigger a re-deploy of the containers when running make deploy-aws, even when nothing has been updated)
IMAGE_TAG := $(shell date +%Y%m%d-%H%M%S)
ECR_URI := $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(ECR_REPO_NAME)
IMAGE_URI := $(ECR_URI):$(IMAGE_TAG)

.DEFAULT_GOAL := help

.PHONY: help deploy-local deploy-aws delete clean

help: ## Show this help message
	@echo "Simple LiteLLM Deployment"
	@echo "========================="
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables (can be overridden):"
	@echo "  AWS_REGION=$(AWS_REGION)"
	@echo "  ECR_REPO_NAME=$(ECR_REPO_NAME)"
	@echo "  STACK_NAME=$(STACK_NAME)"
	@echo "  NAME_PREFIX=$(NAME_PREFIX)"
	@echo "  ANTHROPIC_API_KEY=***masked***"
	@echo "  LITELLM_MASTER_KEY=***masked***"
	@echo "  IMAGE_TAG=$(IMAGE_TAG) (auto-generated if not overriden in environment)"

deploy-local: ## Deploy LiteLLM locally with docker-compose
	@echo "Starting LiteLLM locally..."
	@if [ -z "$$AWS_ACCESS_KEY_ID" ] || [ -z "$$AWS_SECRET_ACCESS_KEY" ]; then \
		echo "❌ AWS credentials not found in environment"; \
		echo "Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"; \
		echo "Or run: aws sso login"; \
		exit 1; \
	fi
	@echo "Starting containers..."
	@docker-compose up --build -d
	@echo "LiteLLM running at: http://localhost:4000"
	@echo ""
	@echo "🔧 Configure Claude Code to use this local endpoint:"
	@echo "export ANTHROPIC_BASE_URL=http://localhost:4000"
	@echo "export ANTHROPIC_AUTH_TOKEN=$(LITELLM_MASTER_KEY)"
	@echo "export ANTHROPIC_MODEL=sonnet-4"


deploy-aws: ## Deploy LiteLLM to AWS
	@echo "Deploying to AWS ($(AWS_REGION))..."
	@echo "Image tag: $(IMAGE_TAG)"
	
	@echo "Ensuring ECR repository exists..."
	@aws ecr describe-repositories --repository-names $(ECR_REPO_NAME) --region $(AWS_REGION) >/dev/null 2>&1 || \
	(aws ecr create-repository --repository-name $(ECR_REPO_NAME) --region $(AWS_REGION) \
		--image-scanning-configuration scanOnPush=true && \
	aws ecr put-lifecycle-policy --repository-name $(ECR_REPO_NAME) --region $(AWS_REGION) \
		--lifecycle-policy-text '{"rules":[{"rulePriority":1,"selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":7},"action":{"type":"expire"}}]}')
	
	@echo "Logging in to ECR..."
	@aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	
	@echo "Building Docker image..."
	@docker build --platform linux/amd64 -t $(ECR_REPO_NAME):$(IMAGE_TAG) litellm-image/
	
	@echo "Pushing to ECR..."
	@docker tag $(ECR_REPO_NAME):$(IMAGE_TAG) $(IMAGE_URI)
	@docker push $(IMAGE_URI)
	
	@echo "Getting CloudFront prefix list ID for region $(AWS_REGION)..."
	@CLOUDFRONT_PREFIX_LIST_ID=$$(aws ec2 describe-managed-prefix-lists \
		--region $(AWS_REGION) \
		--filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" \
		--query 'PrefixLists[0].PrefixListId' \
		--output text); \
	echo "CloudFront prefix list ID: $$CLOUDFRONT_PREFIX_LIST_ID"; \
	\
	echo "Deploying CloudFormation stack..."; \
	sam deploy --template-file template.yaml \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides \
			ImageUri=$(IMAGE_URI) \
			NamePrefix=$(NAME_PREFIX) \
			AnthropicApiKey=$(ANTHROPIC_API_KEY) \
			LiteLLMMasterKey=$(LITELLM_MASTER_KEY) \
			CloudFrontPrefixListId=$$CLOUDFRONT_PREFIX_LIST_ID \
		--tags project=$(NAME_PREFIX) \
		--no-confirm-changeset
	
	@echo "Deployment complete!"
	@CF_DOMAIN=$$(aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--query 'Stacks[0].Outputs[?OutputKey==`CloudFrontURL`].OutputValue' \
		--output text); \
	echo "LiteLLM HTTPS URL: $$CF_DOMAIN"; \
	echo ""; \
	echo "🔧 Configure Claude Code to use this AWS endpoint:"; \
	echo "export ANTHROPIC_BASE_URL=$$CF_DOMAIN"; \
	echo "export ANTHROPIC_AUTH_TOKEN=$(LITELLM_MASTER_KEY)"; \
	echo "export ANTHROPIC_MODEL=sonnet-4"

delete: ## Delete the CloudFormation stack and all AWS resources
	@echo "Deleting deployment..."
	@echo "This will delete ALL resources including ECR repository and images."
	@read -p "Are you sure? (y/N): " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		echo "Deleting CloudFormation stack..."; \
		aws cloudformation delete-stack --stack-name $(STACK_NAME) --region $(AWS_REGION); \
		echo "Waiting for stack deletion..."; \
		aws cloudformation wait stack-delete-complete --stack-name $(STACK_NAME) --region $(AWS_REGION); \
		echo "Deleting ECR repository..."; \
		aws ecr delete-repository --repository-name $(ECR_REPO_NAME) --region $(AWS_REGION) --force 2>/dev/null || true; \
		echo "Cleanup complete"; \
	else \
		echo "Deletion cancelled"; \
	fi

clean: ## Stop local containers and clean up
	@echo "Cleaning up local environment..."
	@docker-compose down --volumes --remove-orphans 2>/dev/null || true
	@echo "Removing project-specific images..."
	@docker images --filter "reference=$(ECR_REPO_NAME)*" --quiet | xargs -r docker rmi -f 2>/dev/null || true
	@echo "Local cleanup complete"