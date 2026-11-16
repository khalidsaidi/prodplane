#!/bin/bash

# Validation script for all Terraform projects
# Can be invoked from any working directory.

# Select formatting mode.
FIX_FORMAT=false
TFVARS_CHECK=true  # Default to checking tfvars files

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fix)
      FIX_FORMAT=true
      echo "Running in fix mode - will automatically format Terraform files"
      shift
      ;;
    --no-tfvars-check)
      TFVARS_CHECK=false
      echo "Skipping tfvars validation check"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--fix] [--no-tfvars-check]"
      exit 1
      ;;
  esac
done

set -e  # Exit on error

WORKSPACE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$WORKSPACE_ROOT"
echo "Starting validation from: $WORKSPACE_ROOT"

# Color codes for output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
NC="\033[0m" # No Color

# Initialize counters
TOTAL_PROJECTS=0
SUCCESSFUL=0
FAILED=0
FIXED=0
TFVARS_ISSUES=0
FAILED_PROJECTS=()
TFVARS_ISSUES_PATHS=()

# Find all directories with main.tf files
PROJECT_DIRS=$(find . -name "main.tf" -not -path "*/\.*" | sort | xargs -n1 dirname | sort | uniq)

echo -e "${YELLOW}Found $(echo "$PROJECT_DIRS" | wc -l) Terraform projects to validate${NC}"
echo "==============================================================="

# Function to check tfvars syntax
validate_tfvars() {
    local project_dir=$1
    local issues_found=0

    if [ "$TFVARS_CHECK" != true ]; then
        return 0
    fi

    echo -e "${YELLOW}Checking syntax of .tfvars files...${NC}"

    # Find all .tfvars files in the project directory and its subdirectories
    local tfvars_files=$(find "$project_dir" -type f -name "*.tfvars" | sort)

    if [ -z "$tfvars_files" ]; then
        echo -e "${YELLOW}No .tfvars files found in $project_dir${NC}"
        return 0
    fi

    echo -e "${YELLOW}Found $(echo "$tfvars_files" | wc -l) .tfvars files to check${NC}"

    for tfvars_file in $tfvars_files; do
        relative_path="${tfvars_file#$WORKSPACE_ROOT/}"
        echo -e "${YELLOW}Checking: $relative_path${NC}"

        # Syntax only: literal application values may contain text like var.foo.
        # Terraform plan validates expressions and types with the selected inputs.
        if ! terraform fmt -write=false "$tfvars_file" >/dev/null; then
            issues_found=1
            TFVARS_ISSUES=$((TFVARS_ISSUES + 1))
            TFVARS_ISSUES_PATHS+=("$tfvars_file")
            echo -e "${RED}✗ $relative_path: Invalid Terraform input syntax${NC}"
        else
            echo -e "${GREEN}✓ $relative_path: Input syntax is valid${NC}"
        fi
    done

    return $issues_found
}

# Function to validate a project
validate_project() {
    local project_dir=$1
    local project_name=$(basename "$project_dir")
    local parent_dir=$(basename "$(dirname "$project_dir")")
    local validation_failed=0

    echo -e "${YELLOW}Validating: $parent_dir/$project_name${NC}"

    cd "$project_dir"

    # If in fix mode, fix formatting first
    if [ "$FIX_FORMAT" = true ]; then
        echo -e "${YELLOW}Fixing formatting in $parent_dir/$project_name${NC}"
        terraform fmt -recursive
        FIXED=$((FIXED + 1))
    fi

    # Check input syntax; target plans check input values and types.
    if ! validate_tfvars "$project_dir"; then
        validation_failed=1
    fi

    # Run terraform init with -backend=false to skip backend initialization
    if terraform init -backend=false -input=false > /dev/null 2>&1; then
        # Run terraform validate
        if terraform validate > /dev/null 2>&1; then
            echo -e "${GREEN}✓ $parent_dir/$project_name: Terraform configuration is valid${NC}"
        else
            echo -e "${RED}✗ $parent_dir/$project_name: Invalid Terraform configuration${NC}"
            terraform validate
            validation_failed=1
        fi
    else
        echo -e "${RED}✗ $parent_dir/$project_name: Failed to initialize Terraform${NC}"
        validation_failed=1
    fi

    if [ $validation_failed -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Use 'find -type f -name "*.tf" | xargs grep -l "remote_state"' to check if there are any remote state references
echo -e "${YELLOW}Checking for modules using remote state:${NC}"
REMOTE_STATE_MODULES=$(find . -type f -name "*.tf" | xargs grep -l "terraform_remote_state" | xargs -n1 dirname | sort | uniq 2>/dev/null || echo "")
if [ -n "$REMOTE_STATE_MODULES" ]; then
    echo -e "${YELLOW}The following modules use remote state and may have validation issues:${NC}"
    echo "$REMOTE_STATE_MODULES" | sed 's/^/  - /'
    echo "All modules will be validated using the same approach"
    echo "---------------------------------------------------------------"
fi

# Loop through each project directory and validate
for dir in $PROJECT_DIRS; do
    TOTAL_PROJECTS=$((TOTAL_PROJECTS + 1))

    if validate_project "$WORKSPACE_ROOT/$dir"; then
        SUCCESSFUL=$((SUCCESSFUL + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_PROJECTS+=("$dir")
    fi

    # Return to workspace root
    cd "$WORKSPACE_ROOT"
    echo "---------------------------------------------------------------"
done

# Print summary
echo "==============================================================="
echo -e "${YELLOW}Validation Summary:${NC}"
echo -e "Total projects: $TOTAL_PROJECTS"
echo -e "${GREEN}Successful: $SUCCESSFUL${NC}"
if [ "$FIX_FORMAT" = true ]; then
    echo -e "${YELLOW}Projects with formatting fixed: $FIXED${NC}"
fi
if [ $TFVARS_ISSUES -gt 0 ]; then
    echo -e "${RED}Files with invalid tfvars syntax: $TFVARS_ISSUES${NC}"
    echo -e "${RED}Issue locations:${NC}"
    for path in "${TFVARS_ISSUES_PATHS[@]}"; do
        relative_path="${path#$WORKSPACE_ROOT/}"
        echo -e "${RED}- $relative_path${NC}"
    done
    echo -e "${YELLOW}Fix the input syntax, then plan the selected target to check values and types.${NC}"
fi
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
    echo -e "${RED}Failed projects:${NC}"
    for project in "${FAILED_PROJECTS[@]}"; do
        echo -e "${RED}- $project${NC}"
    done
    echo -e "${YELLOW}Run with --fix option to automatically fix formatting issues${NC}"
    exit 1
else
    echo -e "${GREEN}All projects validated successfully!${NC}"
fi
