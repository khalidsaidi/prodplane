#!/bin/bash

# Environment Deployment Script
# This script deploys environment-specific resources to an existing cluster
# (application environments and related resources)

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

# Save original stdin to file descriptor 3
exec 3<&0

# Debug function
debug_log() {
  if [ "$DEBUG" = true ]; then
    echo "[DEBUG] $1" >&2
  fi
}

# Function to start CodeBuild projects for an environment
start_codebuild_projects() {
  local environment="$1"

  if [ -z "$environment" ]; then
    echo "Please provide an environment name (e.g., dev, demo, staging)"
    return 1
  fi

  echo "========================================================================="
  echo "        CODEBUILD PROJECTS FOR $environment"
  echo "========================================================================="

  # Names alone cannot identify ownership: dev-* also includes dev-tools-*.
  # Read the projects owned by the selected state instead of scanning the account.
  local module_dir="$SCRIPT_DIR/environments/app_deploy"
  local backend="config/$CLUSTER_ENV/$environment/$REGION/$CLUSTER_ENV-$environment-$REGION-backend.hcl"
  local projects_json projects account_id
  terraform -chdir="$module_dir" init -input=false -reconfigure -backend-config="$backend" >&2 || return 1
  projects_json=$(terraform -chdir="$module_dir" output -json codebuild_project_arns) || {
    echo "Unable to read CodeBuild projects from the selected environment state." >&2
    return 1
  }
  account_id=$(aws sts get-caller-identity --region "$REGION" --query Account --output text --no-cli-pager) || return 1
  projects=$(jq -r --arg region "$REGION" --arg account "$account_id" '
    if type != "object" then error("Expected a map of CodeBuild project ARNs") else
      [.[] |
        if type != "string" then error("Invalid CodeBuild project ARN") else
          if test("^arn:[^:]+:codebuild:[^:]+:[0-9]{12}:project/[A-Za-z0-9][A-Za-z0-9_-]*$") then
            capture("^arn:[^:]+:codebuild:(?<region>[^:]+):(?<account>[0-9]{12}):project/(?<name>.+)$") |
            if .region == $region and .account == $account then .name
            else error("Project state does not match the selected region and current AWS account") end
          else error("Invalid CodeBuild project ARN") end
        end
      ] | unique | .[]
    end' <<< "$projects_json") || return 1

  if [ -z "$projects" ]; then
    echo "No CodeBuild projects are managed by the selected environment state."
    return 1
  fi

  # Convert projects to array for easier handling
  mapfile -t project_array <<< "$projects"

  echo "Found ${#project_array[@]} CodeBuild projects for $environment:"
  echo ""
  echo "[0] *** START ALL PROJECTS ***"
  echo "-----------------------------"
  for i in "${!project_array[@]}"; do
    echo "[$((i+1))] ${project_array[$i]}"
  done
  echo "-----------------------------"
  echo "[q] Quit/Cancel"
  echo ""

  # Ask which projects to start
  echo "Enter your selection (0 for all projects, or specific numbers like '1 3 5', or 'q' to cancel):"
  read -r selection

  # Handle quit option
  if [[ "$selection" == "q" ]]; then
    echo "Operation cancelled."
    return 0
  fi

  # Create an array to hold selected projects
  declare -a selected_projects

  # Handle 'all' option (option 0)
  if [[ "$selection" == "0" ]]; then
    selected_projects=("${project_array[@]}")
    echo "Selected all ${#selected_projects[@]} projects"
  else
    # Parse selected numbers
    for num in $selection; do
      if [[ "$num" =~ ^[0-9]+$ ]]; then
        # Convert the displayed 1-based index to an array index.
        idx=$((10#$num-1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#project_array[@]}" ]; then
          selected_projects+=("${project_array[$idx]}")
          echo "Selected: ${project_array[$idx]}"
        else
          echo "Warning: Invalid selection '$num', ignoring"
        fi
      else
        echo "Warning: Invalid selection '$num', ignoring"
      fi
    done
  fi

  # If no valid selections, exit
  if [ ${#selected_projects[@]} -eq 0 ]; then
    echo "No valid projects selected. Operation cancelled."
    return 0
  fi

  # Confirm selections
  echo ""
  echo "You've selected the following ${#selected_projects[@]} projects:"
  for project in "${selected_projects[@]}"; do
    echo "- $project"
  done
  echo ""
  echo "Do you want to start builds for these projects? (y/n)"
  read -r confirmation
  if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    return 0
  fi

  # Start builds for selected projects
  echo "Starting builds..."
  local count=0
  for project in "${selected_projects[@]}"; do
    echo "Starting build for $project..."
    if aws codebuild start-build --region "$REGION" --project-name "$project" --output json --no-cli-pager >/dev/null 2>&1; then
      echo "✓ Build successfully started for $project"
      ((count+=1))
    else
      echo "✗ Failed to start build for $project"
    fi
  done

  echo "========================================================================="
  echo "        STARTED $count CODEBUILD PROJECTS FOR $environment"
  echo "========================================================================="
  [[ "$count" -eq "${#selected_projects[@]}" ]]
}

# Function to validate paths
validate_paths() {
  echo "========================================================================="
  echo "                   VALIDATING DIRECTORY PATHS"
  echo "========================================================================="

  local valid=true
  local errors=()
  local warnings=()

  # Check the root directory
  if [ ! -d "$ROOT_DIR" ]; then
    valid=false
    errors+=("ERROR: Root directory does not exist: $ROOT_DIR")
  else
    echo "✓ Root directory exists: $ROOT_DIR"
  fi

  # Check environments directory
  if [ ! -d "$ROOT_DIR/environments" ]; then
    valid=false
    errors+=("ERROR: Environments directory does not exist: $ROOT_DIR/environments")
  else
    echo "✓ Environments directory exists: $ROOT_DIR/environments"
  fi

  # Check each environment component directory
  for COMPONENT in "${SELECTED_COMPONENTS[@]}"; do
    if [ ! -d "$ROOT_DIR/environments/$COMPONENT" ]; then
      echo "INFO: Environment component directory '$COMPONENT' does not exist (skipping): $ROOT_DIR/environments/$COMPONENT"
      continue
    else
      echo "✓ Environment component directory exists: $ROOT_DIR/environments/$COMPONENT"
    fi

    # Check config directories for each environment
    for ENV in "${SELECTED_ENVIRONMENTS[@]}"; do
      local env_config_dir="$ROOT_DIR/environments/$COMPONENT/config/$CLUSTER_ENV/$ENV/$REGION"
      if [ ! -d "$env_config_dir" ]; then
        echo "INFO: Config directory for '$COMPONENT/$ENV' does not exist (skipping): $env_config_dir"
        continue
      else
        echo "✓ Config directory exists for $COMPONENT/$ENV: $env_config_dir"
      fi

      # Check backend config file
      local backend_file="$env_config_dir/$CLUSTER_ENV-$ENV-$REGION-backend.hcl"
      if [ ! -f "$backend_file" ]; then
        echo "WARNING: Backend config file for '$COMPONENT/$ENV' does not exist: $backend_file"
        warnings+=("WARNING: Backend config file missing: $backend_file")
      else
        echo "✓ Backend config file exists for $COMPONENT/$ENV: $backend_file"
      fi

      # Check tfvars file
      local tfvars_file="$env_config_dir/$CLUSTER_ENV-$ENV-$REGION.tfvars"
      if [ ! -f "$tfvars_file" ]; then
        echo "WARNING: Terraform vars file for '$COMPONENT/$ENV' does not exist: $tfvars_file"
        warnings+=("WARNING: Terraform vars file missing: $tfvars_file")
      else
        echo "✓ Terraform vars file exists for $COMPONENT/$ENV: $tfvars_file"

        # Parse the input file without rejecting literal application strings such
        # as "var.name". Input types/references are checked by the target plan.
        if ! terraform fmt -write=false "$tfvars_file" >/dev/null; then
          valid=false
          errors+=("ERROR: Invalid Terraform input syntax in $tfvars_file")
        fi
      fi
    done
  done

  echo ""
  echo "========================================================================="
  echo "                   RUNNING TERRAFORM VALIDATION"
  echo "========================================================================="

  # Run terraform validate for each component
  for COMPONENT in "${SELECTED_COMPONENTS[@]}"; do
    if [ ! -d "$ROOT_DIR/environments/$COMPONENT" ]; then
      continue # Skip if the component directory doesn't exist
    fi

    echo "Validating component: $COMPONENT"

    # Store current directory
    local current_dir=$(pwd)

    # Change to component directory
    cd "$ROOT_DIR/environments/$COMPONENT"

    # Check if terraform is initialized
    if [ ! -d ".terraform" ]; then
      echo "Initializing Terraform for $COMPONENT..."
      # Use a sample backend config if available, otherwise init without backend
      local sample_backend=""
      for ENV in "${SELECTED_ENVIRONMENTS[@]}"; do
        if [ -f "config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION-backend.hcl" ]; then
          sample_backend="config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION-backend.hcl"
          break
        fi
      done

      if [ -n "$sample_backend" ]; then
        terraform init -backend=false > /dev/null 2>&1 || {
          echo "ERROR: Failed to initialize Terraform for $COMPONENT"
          valid=false
          errors+=("ERROR: Terraform initialization failed for $COMPONENT")
          cd "$current_dir"
          continue
        }
      else
        terraform init -backend=false > /dev/null 2>&1 || {
          echo "ERROR: Failed to initialize Terraform for $COMPONENT"
          valid=false
          errors+=("ERROR: Terraform initialization failed for $COMPONENT")
          cd "$current_dir"
          continue
        }
      fi
    fi

    # Run terraform validate
    echo "Running terraform validate for $COMPONENT..."
    if ! terraform validate; then
      echo "ERROR: Terraform validation failed for $COMPONENT"
      valid=false
      errors+=("ERROR: Terraform validation failed for $COMPONENT")
    else
      echo "✓ Terraform validation passed for $COMPONENT"
    fi

    # Return to original directory
    cd "$current_dir"

    echo ""
  done

  echo ""
  if [ "$valid" = false ]; then
    echo "========================================================================="
    echo "                     VALIDATION FAILED"
    echo "========================================================================="
    for error in "${errors[@]}"; do
      echo "$error"
    done

    if [ ${#warnings[@]} -gt 0 ]; then
      echo ""
      echo "WARNINGS:"
      for warning in "${warnings[@]}"; do
        echo "$warning"
      done
    fi

    echo ""
    return 1
  else
    echo "========================================================================="
    echo "                 ALL VALIDATIONS PASSED"
    echo "========================================================================="

    if [ ${#warnings[@]} -gt 0 ]; then
      echo ""
      echo "WARNINGS:"
      for warning in "${warnings[@]}"; do
        echo "$warning"
      done
    fi

    echo ""
    return 0
  fi
}

# Helper function to display usage
show_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "  Interactive mode if no options provided"
  echo ""
  echo "Options:"
  echo "  --cluster-env CLUSTER_ENV    Cluster environment (non-prod or prod)"
  echo "  --region REGION              AWS region (us-east-1 or us-west-2)"
  echo "  --environments LIST          Comma-separated environments for non-interactive selection"
  echo "  --component COMPONENT        Specific component to deploy/destroy (app_deploy, aws_deploy, eventbridge, storage)"
  echo "  --execute                    Execute the commands (rather than just displaying them)"
  echo "  --destroy                    Generate destroy commands instead of deploy commands"
  echo "  --auto-approve               Automatically approve terraform apply/destroy for non-prod environments"
  echo "  --debug                      Enable debug logging"
  echo "  --no-debug                   Disable debug logging (default)"
  echo "  --dry-run                    Dry run mode - validate paths without executing commands"
  echo "  --start-codebuilds           Select and start CodeBuild projects for the selected environments"
  echo "  --help                       Show this help message"
  exit 1
}

# Selectors become paths and generated commands, so validate their syntax first.
validate_target_inputs() {
  if [[ -n "$CLUSTER_ENV" ]] && ! [[ "$CLUSTER_ENV" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "Invalid cluster-class identifier." >&2
    exit 2
  fi
  if [[ -n "$REGION" ]] && ! [[ "$REGION" =~ ^[a-z][a-z0-9-]*[0-9]$ ]]; then
    echo "Invalid AWS region identifier." >&2
    exit 2
  fi
  local target_env
  for target_env in "${SELECTED_ENVIRONMENTS[@]}"; do
    if [[ ${#target_env} -gt 63 ]] || ! [[ "$target_env" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      echo "Environment names must be valid Kubernetes namespace identifiers." >&2
      exit 2
    fi
  done
  return 0
}

# Default values
CLUSTER_ENV=""
REGION=""
COMPONENT=""
INTERACTIVE=true
EXECUTE=false
DESTROY=false
AUTO_APPROVE=false
DEBUG=false  # Disable debugging by default
DRY_RUN=false # Dry run mode - validate paths without executing commands
START_CODEBUILDS=false # Start CodeBuild projects for environments
SELECTED_ENVIRONMENTS=()

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-env)
      CLUSTER_ENV="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --environments)
      IFS=',' read -r -a SELECTED_ENVIRONMENTS <<< "$2"
      shift 2
      ;;
    --component)
      COMPONENT="$2"
      shift 2
      ;;
    --execute)
      EXECUTE=true
      shift
      ;;
    --destroy)
      DESTROY=true
      shift
      ;;
    --auto-approve)
      AUTO_APPROVE=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --no-debug)
      DEBUG=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --start-codebuilds)
      START_CODEBUILDS=true
      shift
      ;;
    --help)
      show_usage
      ;;
    *)
      echo "Unknown option: $1"
      show_usage
      ;;
  esac
done

validate_target_inputs

# Select interactive mode when no options are supplied.
if [[ -n "$CLUSTER_ENV" && -n "$REGION" ]]; then
  INTERACTIVE=false

  # Production safeguards for non-interactive mode
  if [ "$CLUSTER_ENV" = "prod" ]; then
    if [ -t 0 ]; then  # Only if stdin is a terminal
      echo -e "\033[1;31mWARNING: You are targeting PRODUCTION resources!\033[0m"
      echo -e "Cluster Environment: \033[1;31m$CLUSTER_ENV\033[0m"
      echo -e "Region: $REGION"

      if [ "$DESTROY" = true ]; then
        echo -e "\033[1;31mYou are about to DESTROY PRODUCTION resources!\033[0m"
        echo "This operation is IRREVERSIBLE and may cause service disruption."
      fi

      echo -e "\nAre you sure you want to proceed? Type 'yes-prod' to confirm:"
      read -r PROD_CONFIRM
      if [[ "$PROD_CONFIRM" != "yes-prod" ]]; then
        echo "Operation cancelled by user. Exiting."
        exit 1
      fi
    fi
  fi
fi

# Interactive mode if parameters not provided
if [ "$INTERACTIVE" = true ]; then
  # Ask if destroying or deploying
  echo "Do you want to deploy or destroy resources?"
  select ACTION in "deploy" "destroy"; do
    if [ -n "$ACTION" ]; then
      if [ "$ACTION" = "destroy" ]; then
        DESTROY=true
      fi
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done

  # Cluster environment selection
  echo "Select cluster environment:"
  select CLUSTER_ENV in "non-prod" "prod"; do
    if [ -n "$CLUSTER_ENV" ]; then
      # Production safeguard
      if [ "$CLUSTER_ENV" = "prod" ]; then
        echo -e "\033[1;31mWARNING: You have selected a PRODUCTION cluster environment!\033[0m"
        echo "Are you sure you want to proceed with the production cluster? Type 'yes' to confirm:"
        read -r PROD_CONFIRM
        if [[ "$PROD_CONFIRM" != "yes" ]]; then
          echo "Operation cancelled by user. Exiting."
          exit 1
        fi
      fi
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done

  # Environment selection
  read -r -a ENVIRONMENT_OPTIONS <<< "${PRODPLANE_ENVIRONMENTS:-dev staging prod demo dev-recovery prod-recovery}"
  AVAILABLE_ENVIRONMENTS=("${ENVIRONMENT_OPTIONS[@]}" "all")
  SELECTED_ENVIRONMENTS=()

  echo "Select environments to deploy/destroy:"
  echo "Available environments: ${AVAILABLE_ENVIRONMENTS[*]}"
  echo "Enter environments one by one (e.g., 'dev', then 'staging'), or type 'all' for all environments."
  echo "Type 'done' when finished selecting."

  while true; do
    read -r ENV_CHOICE

    if [[ "$ENV_CHOICE" == "done" ]]; then
      if [ ${#SELECTED_ENVIRONMENTS[@]} -eq 0 ]; then
        echo "No environments selected. Please select at least one environment."
      else
        break
      fi
    elif [[ "$ENV_CHOICE" == "all" ]]; then
      SELECTED_ENVIRONMENTS=("${ENVIRONMENT_OPTIONS[@]}")
      echo "Selected all environments: ${SELECTED_ENVIRONMENTS[*]}"
      break
    elif [[ " ${AVAILABLE_ENVIRONMENTS[*]} " =~ " ${ENV_CHOICE} " ]]; then
      if [[ " ${SELECTED_ENVIRONMENTS[*]} " =~ " ${ENV_CHOICE} " ]]; then
        echo "Environment '$ENV_CHOICE' is already selected."
      else
        SELECTED_ENVIRONMENTS+=("$ENV_CHOICE")
        echo "Added '$ENV_CHOICE'. Currently selected: ${SELECTED_ENVIRONMENTS[*]}"
        echo "Type 'done' when finished selecting or enter another environment."
      fi
    else
      echo "Invalid environment '$ENV_CHOICE'. Available: ${AVAILABLE_ENVIRONMENTS[*]}"
    fi
  done

  # Convert selected environments to a comma-separated list for terraform variables
  ENVIRONMENTS_VAR=$(IFS=, ; echo "${SELECTED_ENVIRONMENTS[*]}")
  echo "Environments to deploy/destroy: $ENVIRONMENTS_VAR"

  # Region selection
  echo "Select region:"
  read -r -a REGION_OPTIONS <<< "${PRODPLANE_REGIONS:-us-east-1 us-west-2 eu-west-1}"
  select REGION in "${REGION_OPTIONS[@]}"; do
    if [ -n "$REGION" ]; then
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done

  # After environment selection, add component selection
  ENV_COMPONENT_OPTIONS=("all" "app_deploy" "aws_deploy" "eventbridge" "storage")
  echo "Select component to deploy/destroy (select 'all' for all components):"
  select ENV_COMPONENT in "${ENV_COMPONENT_OPTIONS[@]}"; do
    if [ -n "$ENV_COMPONENT" ]; then
      if [ "$ENV_COMPONENT" = "all" ]; then
        # If "all" is selected, set COMPONENT to empty string
        COMPONENT=""
      else
        COMPONENT="$ENV_COMPONENT"
      fi
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done

  # Ask if user wants to execute commands or start codebuilds
  echo "What action would you like to perform?"
  select ACTION_TYPE in "execute-terraform" "start-codebuilds" "display-commands"; do
    if [ -n "$ACTION_TYPE" ]; then
      if [ "$ACTION_TYPE" = "execute-terraform" ]; then
        EXECUTE=true

        # Only ask for auto-approve if not targeting production
        if [ "$CLUSTER_ENV" != "prod" ]; then
          echo "Do you want to auto-approve terraform commands? (y/n)"
          read -r AUTO_APPROVE_CHOICE
          if [[ "$AUTO_APPROVE_CHOICE" =~ ^[Yy]$ ]]; then
            AUTO_APPROVE=true
          fi
        fi
      elif [ "$ACTION_TYPE" = "start-codebuilds" ]; then
        START_CODEBUILDS=true
      fi
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done
fi

if [ "$INTERACTIVE" = false ] && [ ${#SELECTED_ENVIRONMENTS[@]} -eq 0 ]; then
  echo "Provide --environments (for example: dev,demo)." >&2
  exit 2
fi

# Start all CodeBuild projects if requested
validate_target_inputs
if [[ -z "$CLUSTER_ENV" || -z "$REGION" ]]; then
  echo "Select a cluster class and AWS region." >&2
  exit 2
fi

if [ "$START_CODEBUILDS" = true ] && { [ "$DRY_RUN" = true ] || [ "$DESTROY" = true ]; }; then
  echo "--start-codebuilds cannot be combined with --dry-run or --destroy." >&2
  exit 2
fi

if [ "$START_CODEBUILDS" = true ]; then
  if [ ${#SELECTED_ENVIRONMENTS[@]} -eq 0 ]; then
    echo "No environments selected. Please select environments with --environments."
    exit 1
  fi

  for ENV in "${SELECTED_ENVIRONMENTS[@]}"; do
    start_codebuild_projects "$ENV"
  done
  exit 0
fi

# Output header
echo ""
echo "========================================================================="
if [ "$DESTROY" = true ]; then
  echo "           ENVIRONMENT RESOURCES DESTRUCTION"
else
  echo "           ENVIRONMENT RESOURCES DEPLOYMENT"
fi
echo "========================================================================="
echo "Cluster Environment: $CLUSTER_ENV"

if [ ${#SELECTED_ENVIRONMENTS[@]} -gt 0 ]; then
  echo "Selected Environments:"
  for ENV in "${SELECTED_ENVIRONMENTS[@]}"; do
    echo " - $ENV"
  done
else
  echo "Selected Environments: all"
fi

echo "Region: $REGION"
if [ -n "$COMPONENT" ]; then
  echo "Component: $COMPONENT"
else
  echo "Component: all"
fi
if [ "$DESTROY" = true ]; then
  echo "Action: Destroying application environments and related resources"
else
  echo "Action: Creating application environments and related resources"
fi
if [ "$DRY_RUN" = true ]; then
  echo "Mode: DRY RUN - Validating paths only, no commands will be executed"
elif [ "$EXECUTE" = true ]; then
  echo "Mode: Commands will be executed"
elif [ "$START_CODEBUILDS" = true ]; then
  echo "Mode: Starting CodeBuild projects"
else
  echo "Mode: Commands will be displayed only"
fi
echo "========================================================================="
echo ""

# Create temporary command file
CMDFILE=$(mktemp)
trap 'rm -f "$CMDFILE"' EXIT

COMPONENTS=(
  "environments"
)

# Environment component types to validate
# app_deploy creates the namespace used by storage. Full environment teardown
# also removes that namespace first: its pods must release their PVCs before
# the storage component can remove the remaining persistent volumes.
ENV_COMPONENTS=(
  "app_deploy"
  "aws_deploy"
  "eventbridge"
  "storage"
)

# Store the root directory
ROOT_DIR=$(pwd)

# If a specific component is selected, validate it
if [ -n "$COMPONENT" ]; then
  valid_component=false
  for comp in "${ENV_COMPONENTS[@]}"; do
    if [ "$COMPONENT" = "$comp" ]; then
      valid_component=true
      break
    fi
  done

  if [ "$valid_component" = false ]; then
    echo "Error: Invalid component '$COMPONENT'. Valid components are: ${ENV_COMPONENTS[*]}"
    exit 1
  fi

  # Use a temporary array with just the selected component
  SELECTED_COMPONENTS=("$COMPONENT")
else
  # If no specific component is selected, use all components
  SELECTED_COMPONENTS=("${ENV_COMPONENTS[@]}")
fi

UNCONFIGURED_TARGETS=0

# Generate deployment/destruction commands for each component
if [ "$DESTROY" = true ]; then
  # Destroy in reverse order
  for ((i=${#COMPONENTS[@]}-1; i>=0; i--)); do
    COMPONENT="${COMPONENTS[$i]}"

    if [ "$COMPONENT" = "environments" ] && [ ${#SELECTED_ENVIRONMENTS[@]} -gt 0 ]; then
      # For environments component, handle each environment separately
      for ENV in "${SELECTED_ENVIRONMENTS[@]}"; do
        for ENV_COMPONENT in "${SELECTED_COMPONENTS[@]}"; do
          if [ ! -d "$ROOT_DIR/environments/$ENV_COMPONENT" ]; then
            echo "Unconfigured target: $ENV_COMPONENT/$CLUSTER_ENV/$ENV/$REGION (component directory missing)."
            ((UNCONFIGURED_TARGETS+=1))
            continue
          fi

          # Skip if config directory doesn't exist
          if [ ! -d "$ROOT_DIR/environments/$ENV_COMPONENT/config/$CLUSTER_ENV/$ENV/$REGION" ]; then
            echo "Unconfigured target: $ENV_COMPONENT/$CLUSTER_ENV/$ENV/$REGION (configuration directory missing)."
            ((UNCONFIGURED_TARGETS+=1))
            continue
          fi

          echo "# Destroy $ENV_COMPONENT for environment: $ENV" | tee -a "$CMDFILE"
          printf 'cd %q\n' "$ROOT_DIR/environments/$ENV_COMPONENT" | tee -a "$CMDFILE"
          echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
          echo "terraform plan -input=false -destroy -var-file=config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION.tfvars -var=environment=$ENV -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
          echo "terraform destroy -var-file=config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION.tfvars -var=environment=$ENV -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
          echo "" | tee -a "$CMDFILE"
        done
      done
    else
      # Handle a standalone component.
      echo "# Destroy $COMPONENT" | tee -a "$CMDFILE"
      printf 'cd %q\n' "$ROOT_DIR/$COMPONENT" | tee -a "$CMDFILE"
      echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
      echo "terraform plan -input=false -destroy -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
      echo "terraform destroy -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
      echo "" | tee -a "$CMDFILE"
    fi
  done
else
  # Create in forward order
  for COMPONENT in "${COMPONENTS[@]}"; do
    if [ "$COMPONENT" = "environments" ] && [ ${#SELECTED_ENVIRONMENTS[@]} -gt 0 ]; then
      # For environments component, handle each environment separately
      for ENV in "${SELECTED_ENVIRONMENTS[@]}"; do
        for ENV_COMPONENT in "${SELECTED_COMPONENTS[@]}"; do
          if [ ! -d "$ROOT_DIR/environments/$ENV_COMPONENT" ]; then
            echo "Unconfigured target: $ENV_COMPONENT/$CLUSTER_ENV/$ENV/$REGION (component directory missing)."
            ((UNCONFIGURED_TARGETS+=1))
            continue
          fi

          # Skip if config directory doesn't exist
          if [ ! -d "$ROOT_DIR/environments/$ENV_COMPONENT/config/$CLUSTER_ENV/$ENV/$REGION" ]; then
            echo "Unconfigured target: $ENV_COMPONENT/$CLUSTER_ENV/$ENV/$REGION (configuration directory missing)."
            ((UNCONFIGURED_TARGETS+=1))
            continue
          fi

          echo "# Create $ENV_COMPONENT for environment: $ENV" | tee -a "$CMDFILE"
          printf 'cd %q\n' "$ROOT_DIR/environments/$ENV_COMPONENT" | tee -a "$CMDFILE"
          echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
          echo "terraform plan -input=false -var-file=config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION.tfvars -var=environment=$ENV -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
          echo "terraform apply -var-file=config/$CLUSTER_ENV/$ENV/$REGION/$CLUSTER_ENV-$ENV-$REGION.tfvars -var=environment=$ENV -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
          echo "" | tee -a "$CMDFILE"
        done
      done
    else
      # Handle a standalone component.
      echo "# Create $COMPONENT" | tee -a "$CMDFILE"
      printf 'cd %q\n' "$ROOT_DIR/$COMPONENT" | tee -a "$CMDFILE"
      echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
      echo "terraform plan -input=false -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
      echo "terraform apply -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
      echo "" | tee -a "$CMDFILE"
    fi
  done

  # Add instructions for next steps
  echo "# After successfully deploying the environment resources:" | tee -a "$CMDFILE"
  echo "# 1. Verify application deployments: kubectl get deployments -n $ENV" | tee -a "$CMDFILE"
  echo "# 2. Check application services: kubectl get svc -n $ENV" | tee -a "$CMDFILE"
  echo "# 3. Check ingress endpoints: kubectl get ingress -n $ENV" | tee -a "$CMDFILE"
  echo "" | tee -a "$CMDFILE"
fi

# Execute the dry run validation if requested
if [ "$DRY_RUN" = true ]; then
  validate_paths
  exit $?
fi

if [ "$EXECUTE" = true ]; then
  echo "========================================================================="
  if [ "$DESTROY" = true ]; then
    echo "           EXECUTING ENVIRONMENT RESOURCES DESTROY COMMANDS"
  else
    echo "           EXECUTING ENVIRONMENT RESOURCES COMMANDS"
  fi
  echo "========================================================================="
  echo "The following commands will be executed. Press Ctrl+C to abort."
  if [ "$DESTROY" = true ]; then
    echo "YOU WILL BE DESTROYING RESOURCES. You will be prompted for confirmation before terraform destroy."
    echo "This operation is IRREVERSIBLE. Make sure you understand what will be destroyed."
  else
    echo "You will be prompted for confirmation before terraform apply."
  fi
  echo ""

  # Store the current directory to return to at the end
  ORIGINAL_DIR=$(pwd)
  COMPLETED_OPERATIONS=0
  SKIPPED_OPERATIONS=0

  # A retained resource or invalid later target must fail before removing an
  # earlier environment's namespace. Re-plan during execution because preceding
  # destroys may change remote state. Runtime failures are still nontransactional.
  if [ "$DESTROY" = true ]; then
    echo "Checking all selected destroy plans before removing resources."
    while IFS= read -r cmd; do
      if [[ "$cmd" =~ ^cd\  || "$cmd" =~ ^terraform\ (init|plan) ]]; then
        eval "$cmd" </dev/null || { echo "Destroy preflight failed; no resources were destroyed."; exit 1; }
      fi
    done < "$CMDFILE"
    cd "$ORIGINAL_DIR" || exit 1
  fi

  # Execute the commands from the command file
  while IFS= read -r cmd; do
    # Skip comments and empty lines
    if [[ "$cmd" =~ ^#.*$ || -z "$cmd" ]]; then
      echo ">>> $cmd"
      continue
    fi

    # For cd commands, change directory but don't execute a subprocess
    if [[ "$cmd" =~ ^cd ]]; then
      echo ">>> $cmd"
      eval "$cmd" || { echo "Error changing directory. Aborting."; exit 1; }
      continue
    fi

    # Terraform init and plan commands
    if [[ "$cmd" =~ ^terraform\ (init|plan) ]]; then
      echo ">>> $cmd"
      eval "$cmd" || { echo "Terraform command failed. Aborting."; exit 1; }
      continue
    fi

    # Terraform apply commands - handle the "yes" requirement properly
    if [[ "$cmd" =~ ^terraform\ apply ]]; then
      debug_log "Processing terraform apply command: $cmd"
      debug_log "CLUSTER_ENV=$CLUSTER_ENV, AUTO_APPROVE=$AUTO_APPROVE"

      # Extra confirmation for production apply
      if [[ "$CLUSTER_ENV" = "prod" ]]; then
        echo ">>> $cmd"
        echo -e "\033[1;31mWARNING: You are about to MODIFY PRODUCTION resources!\033[0m"
        echo "This operation may cause service disruption if not carefully planned."
        echo "Type 'apply-prod' to proceed:"
        read -r -u3 apply_prod_confirm || apply_prod_confirm=""
        debug_log "Production confirmation input: '$apply_prod_confirm'"
        if [[ "$apply_prod_confirm" != "apply-prod" ]]; then
          echo "Skipping terraform apply to production."
          ((SKIPPED_OPERATIONS+=1))
          continue
        fi
        # Execute the terraform apply with auto-approve for production
        cmd="$cmd -auto-approve"
        debug_log "Running production command with auto-approve: $cmd"
        eval "$cmd" || { echo "Terraform apply to production failed. Aborting."; exit 1; }
      else
        if [ "$AUTO_APPROVE" = true ]; then
          # For non-production with auto-approve selected
          echo ">>> $cmd -auto-approve"
          cmd="$cmd -auto-approve"
          debug_log "Running non-prod command with auto-approve: $cmd"
          eval "$cmd" || { echo "Terraform apply failed. Aborting."; exit 1; }
        else
          # For non-production without auto-approve
          echo ">>> $cmd"
          echo "========================================================================"
          echo "IMPORTANT: Type 'yes' to approve this terraform apply"
          echo "========================================================================"
          debug_log "Running non-prod command without auto-approve: $cmd"

          # Clear input buffer and read from original stdin
          while read -r -t 0; do read -r || break; done <&3
          echo -n "Do you want to approve? Type 'yes': "
          read -r -u3 tf_approve || tf_approve=""
          debug_log "User entered: '$tf_approve'"

          if [[ "$tf_approve" == "yes" ]]; then
            debug_log "Executing with forced approval"
            eval "$cmd -auto-approve"
          else
            echo "Terraform apply not approved by user. Skipping."
            ((SKIPPED_OPERATIONS+=1))
            continue
          fi
        fi
      fi
      ((COMPLETED_OPERATIONS+=1))
      continue
    fi

    # Terraform destroy commands - handle the "yes" requirement properly
    if [[ "$cmd" =~ ^terraform\ destroy ]]; then
      debug_log "Processing terraform destroy command: $cmd"
      debug_log "CLUSTER_ENV=$CLUSTER_ENV, AUTO_APPROVE=$AUTO_APPROVE"

      # Extra confirmation for production destroy
      if [[ "$CLUSTER_ENV" = "prod" ]]; then
        echo ">>> $cmd"
        echo -e "\033[1;31mWARNING: You are about to DESTROY PRODUCTION resources!\033[0m"
        echo "This operation is IRREVERSIBLE and may cause service disruption."
        echo "Type 'destroy-prod-confirm' to proceed:"
        read -r -u3 destroy_prod_confirm || destroy_prod_confirm=""
        debug_log "Production confirmation input: '$destroy_prod_confirm'"
        if [[ "$destroy_prod_confirm" != "destroy-prod-confirm" ]]; then
          echo "Skipping production terraform destroy."
          ((SKIPPED_OPERATIONS+=1))
          continue
        fi
        # Execute the terraform destroy with auto-approve for production
        cmd="$cmd -auto-approve"
        debug_log "Running production command with auto-approve: $cmd"
        eval "$cmd" || { echo "Terraform destroy of production resources failed. Aborting."; exit 1; }
      else
        if [ "$AUTO_APPROVE" = true ]; then
          # For non-production with auto-approve selected
          echo ">>> $cmd -auto-approve"
          cmd="$cmd -auto-approve"
          debug_log "Running non-prod command with auto-approve: $cmd"
          eval "$cmd" || { echo "Terraform destroy failed. Aborting."; exit 1; }
        else
          # For non-production without auto-approve
          echo ">>> $cmd"
          echo "========================================================================"
          echo "WARNING: This will DESTROY resources."
          echo "IMPORTANT: Type 'yes-destroy' to approve this terraform destroy"
          echo "========================================================================"
          debug_log "Running non-prod command without auto-approve: $cmd"

          # Clear input buffer and read from original stdin
          while read -r -t 0; do read -r || break; done <&3
          echo -n "Do you want to approve? Type 'yes-destroy': "
          read -r -u3 tf_approve || tf_approve=""
          debug_log "User entered: '$tf_approve'"

          if [[ "$tf_approve" == "yes-destroy" ]]; then
            debug_log "Executing with forced approval"
            eval "$cmd -auto-approve"
          else
            echo "Terraform destroy not approved by user. Skipping."
            ((SKIPPED_OPERATIONS+=1))
            continue
          fi
        fi
      fi
      ((COMPLETED_OPERATIONS+=1))
      continue
    fi

    # Other commands
    echo ">>> $cmd"
    eval "$cmd" || { echo "Command failed. Aborting."; exit 1; }
  done < "$CMDFILE"

  # Return to the original directory
  cd "$ORIGINAL_DIR" || { echo "Error returning to original directory."; exit 1; }

  echo "========================================================================="
  if [ "$COMPLETED_OPERATIONS" -eq 0 ]; then
    if [ "$SKIPPED_OPERATIONS" -gt 0 ]; then
      echo "           ENVIRONMENT OPERATIONS SKIPPED"
      echo "Completed: 0; skipped: $SKIPPED_OPERATIONS"
    else
      echo "           NO ENVIRONMENT OPERATIONS EXECUTED"
    fi
  elif [ "$SKIPPED_OPERATIONS" -gt 0 ] || [ "$UNCONFIGURED_TARGETS" -gt 0 ]; then
    echo "           ENVIRONMENT OPERATIONS PARTIALLY COMPLETED"
    echo "Completed: $COMPLETED_OPERATIONS; skipped: $SKIPPED_OPERATIONS; unconfigured: $UNCONFIGURED_TARGETS"
  elif [ "$DESTROY" = true ]; then
    echo "           ENVIRONMENT RESOURCES DESTROYED"
  else
    echo "           ENVIRONMENT RESOURCES DEPLOYED"
    echo ""
    echo "NEXT STEPS:"
    echo "1. Verify application deployments: kubectl get deployments -n $ENV"
    echo "2. Check application services: kubectl get svc -n $ENV"
    echo "3. Check ingress endpoints: kubectl get ingress -n $ENV"
  fi
  echo "========================================================================="
else
  echo "========================================================================="
  if [ "$DESTROY" = true ]; then
    echo "           ENVIRONMENT RESOURCES DESTRUCTION COMMANDS GENERATED"
    echo "========================================================================="
    echo "Copy and run these commands to destroy your environment resources."
    echo "Make sure to check each command before running and verify the plan output."
    echo "WARNING: These commands will DESTROY resources. Proceed with caution."
  else
    echo "           ENVIRONMENT RESOURCES DEPLOYMENT COMMANDS GENERATED"
    echo "========================================================================="
    echo "Copy and run these commands to deploy your environment resources."
    echo "Make sure to check each command before running and verify the plan output."
    echo ""
    echo "NEXT STEPS AFTER DEPLOYMENT:"
    echo "1. Verify application deployments: kubectl get deployments -n $ENV"
    echo "2. Check application services: kubectl get svc -n $ENV"
    echo "3. Check ingress endpoints: kubectl get ingress -n $ENV"
  fi
  ENVIRONMENT_SELECTION=$(IFS=,; printf '%s' "${SELECTED_ENVIRONMENTS[*]}")
  NEXT_COMMAND=("$0" --cluster-env "$CLUSTER_ENV" --region "$REGION" --environments "$ENVIRONMENT_SELECTION")
  if [ "${#SELECTED_COMPONENTS[@]}" -eq 1 ]; then
    NEXT_COMMAND+=(--component "${SELECTED_COMPONENTS[0]}")
  fi
  if [ "$DESTROY" = true ]; then
    NEXT_COMMAND+=(--destroy)
  fi
  echo ""
  echo "To save these commands to a file, run:"
  printf '%q ' "${NEXT_COMMAND[@]}"
  printf '> environment_commands.sh\n'
  echo ""
  echo "To execute these commands automatically, run:"
  printf '%q ' "${NEXT_COMMAND[@]}" --execute
  printf '\n'
  echo ""
  echo "To validate paths without executing commands, run:"
  printf '%q ' "${NEXT_COMMAND[@]}" --dry-run
  printf '\n'
fi
