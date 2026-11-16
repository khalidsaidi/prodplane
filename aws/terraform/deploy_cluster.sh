#!/bin/bash

# Cluster Infrastructure Deployment Script
# This script should be run on the bastion host to deploy cluster infrastructure
# (Security groups, EKS cluster, and cluster add-ons)

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

# Helper function to display usage
show_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "  Interactive mode if no options provided"
  echo ""
  echo "Options:"
  echo "  --cluster-env CLUSTER_ENV    Cluster environment (non-prod or prod)"
  echo "  --region REGION              AWS region (eu-west-1)"
  echo "  --component COMPONENT        Specific component to deploy/destroy (security, storage, eks, eks_addons)"
  echo "  --execute                    Execute the commands (rather than just displaying them)"
  echo "  --destroy                    Generate destroy commands instead of deploy commands"
  echo "  --auto-approve               Automatically approve terraform apply/destroy for non-prod environments"
  echo "  --debug                      Enable debug logging"
  echo "  --no-debug                   Disable debug logging (default)"
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

  # Component selection
  COMPONENT_OPTIONS=("all" "security" "eks" "storage" "eks_addons")
  echo "Select component to deploy/destroy (select 'all' for all components):"
  select COMPONENT in "${COMPONENT_OPTIONS[@]}"; do
    if [ -n "$COMPONENT" ]; then
      break
    else
      echo "Invalid selection. Please try again."
    fi
  done

  # If "all" is selected, set COMPONENT to empty string
  if [ "$COMPONENT" = "all" ]; then
    COMPONENT=""
  fi

  # Ask if user wants to execute commands
  echo "Do you want to execute the commands? (y/n)"
  read -r EXECUTE_CHOICE
  if [[ "$EXECUTE_CHOICE" =~ ^[Yy]$ ]]; then
    EXECUTE=true

    # Only ask for auto-approve if not targeting production
    if [ "$CLUSTER_ENV" != "prod" ]; then
      echo "Do you want to auto-approve terraform commands? (y/n)"
      read -r AUTO_APPROVE_CHOICE
      if [[ "$AUTO_APPROVE_CHOICE" =~ ^[Yy]$ ]]; then
        AUTO_APPROVE=true
      fi
    fi
  fi
fi

# List of all available components
COMPONENTS=(
  "security"
  "eks"
  "storage"
  "eks_addons"
)

# If a specific component is selected, validate it
if [ -n "$COMPONENT" ]; then
  valid_component=false
  for comp in "${COMPONENTS[@]}"; do
    if [ "$COMPONENT" = "$comp" ]; then
      valid_component=true
      break
    fi
  done

  if [ "$valid_component" = false ]; then
    echo "Error: Invalid component '$COMPONENT'. Valid components are: ${COMPONENTS[*]}"
    exit 1
  fi

  # Use a temporary array with just the selected component
  if [ "$DESTROY" = true ]; then
    # Locate the component in deployment order.
    SELECTED_COMPONENTS=()
    for comp in "${COMPONENTS[@]}"; do
      if [ "$comp" = "$COMPONENT" ]; then
        SELECTED_COMPONENTS+=("$comp")
      fi
    done
  else
    SELECTED_COMPONENTS=("$COMPONENT")
  fi
else
  # If no specific component is selected, use all components
  SELECTED_COMPONENTS=("${COMPONENTS[@]}")
fi

validate_target_inputs
if [[ -z "$CLUSTER_ENV" || -z "$REGION" ]]; then
  echo "Select a cluster class and AWS region." >&2
  exit 2
fi

# Output header
echo ""
echo "========================================================================="
if [ "$DESTROY" = true ]; then
  echo "           CLUSTER INFRASTRUCTURE DESTRUCTION (BASTION)"
else
  echo "           CLUSTER INFRASTRUCTURE DEPLOYMENT (BASTION)"
fi
echo "========================================================================="
echo "Cluster Environment: $CLUSTER_ENV"
echo "Region: $REGION"
if [ -n "$COMPONENT" ]; then
  echo "Component: $COMPONENT"
else
  echo "Component: all"
fi
if [ "$DESTROY" = true ]; then
  echo "Action: Destroying cluster infrastructure"
else
  echo "Action: Creating cluster infrastructure"
fi
if [ "$EXECUTE" = true ]; then
  echo "Mode: Commands will be executed"
else
  echo "Mode: Commands will be displayed only"
fi
echo "========================================================================="
echo ""

# Create temporary command file
CMDFILE=$(mktemp)
trap 'rm -f "$CMDFILE"' EXIT

# Store the root directory
ROOTDIR=$(pwd)

# Generate deployment/destruction commands for each component
if [ "$DESTROY" = true ]; then
  # Destroy in reverse order
  for ((i=${#SELECTED_COMPONENTS[@]}-1; i>=0; i--)); do
    COMPONENT="${SELECTED_COMPONENTS[$i]}"
    echo "# Destroy $COMPONENT" | tee -a "$CMDFILE"
    printf 'cd %q\n' "$ROOTDIR/clusters/$COMPONENT" | tee -a "$CMDFILE"
    echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
    echo "terraform plan -input=false -destroy -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
    echo "terraform destroy -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
    echo "" | tee -a "$CMDFILE"
  done
else
  # Create in forward order
  for COMPONENT in "${SELECTED_COMPONENTS[@]}"; do
    echo "# Create $COMPONENT" | tee -a "$CMDFILE"
    printf 'cd %q\n' "$ROOTDIR/clusters/$COMPONENT" | tee -a "$CMDFILE"
    echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
    echo "terraform plan -input=false -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
    echo "terraform apply -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
    echo "" | tee -a "$CMDFILE"
  done

  # Add instructions for next steps
  echo "# After successfully deploying the cluster infrastructure:" | tee -a "$CMDFILE"
  echo "# 1. Prepare the selected environment .tfvars and backend .hcl files on this machine" | tee -a "$CMDFILE"
  echo "# 2. Run deploy_environment.sh to configure environments on the cluster" | tee -a "$CMDFILE"
  echo "" | tee -a "$CMDFILE"
fi

# The generation loop uses COMPONENT as its iterator; restore the selected scope
# for the execution summary and preview instructions.
COMPONENT=""
if [ "${#SELECTED_COMPONENTS[@]}" -eq 1 ]; then
  COMPONENT="${SELECTED_COMPONENTS[0]}"
fi

function execute_commands() {
    if [ "$DESTROY" = true ]; then
        echo -e "\n${YELLOW}=========================================================================
           EXECUTING CLUSTER INFRASTRUCTURE DESTROY COMMANDS
=========================================================================
The following commands will be executed. Press Ctrl+C to abort.
You will be prompted for confirmation before terraform destroy.${RESET}"

        # Validate all selected targets while their upstream state still exists.
        # A predictable error must not first remove controllers or storage.
        echo "Checking all selected destroy plans before removing resources."
        while IFS= read -r cmd; do
            if [[ "$cmd" =~ ^cd\  || "$cmd" =~ ^terraform\ (init|plan) ]]; then
                eval "$cmd" </dev/null || { echo "Destroy preflight failed; no resources were destroyed."; exit 1; }
            fi
        done < "$CMDFILE"
        cd "$ROOTDIR" || exit 1

        # Destroy selected components in reverse order
        for ((i=${#SELECTED_COMPONENTS[@]}-1; i>=0; i--)); do
            comp="${SELECTED_COMPONENTS[$i]}"
            # Destroy component
            echo -e "\n>>> # Destroy $comp"
            echo ">>> cd clusters/$comp"
            cd "$ROOTDIR/clusters/$comp" || { echo "Error changing directory. Aborting."; exit 1; }

            echo ">>> terraform init -input=false -reconfigure -backend-config=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}-backend.hcl"
            terraform init -input=false -reconfigure -backend-config=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}-backend.hcl || { echo "Terraform command failed. Aborting."; exit 1; }

            echo ">>> terraform plan -input=false -destroy -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV"
            terraform plan -input=false -destroy -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV || { echo "Terraform command failed. Aborting."; exit 1; }

            if [ "$AUTO_APPROVE" = true ] && [ "$CLUSTER_ENV" != "prod" ]; then
                echo ">>> terraform destroy -auto-approve -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV"
                terraform destroy -auto-approve -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV || { echo "Terraform command failed. Aborting."; exit 1; }
            else
                echo ">>> terraform destroy -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV"
                terraform destroy -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV || { echo "Terraform command failed. Aborting."; exit 1; }
            fi

            # Return to root directory
            cd "$ROOTDIR" || { echo "Error changing directory. Aborting."; exit 1; }
        done
    else
        echo -e "\n${YELLOW}=========================================================================
           EXECUTING CLUSTER INFRASTRUCTURE COMMANDS
=========================================================================
The following commands will be executed. Press Ctrl+C to abort.
You will be prompted for confirmation before terraform apply.${RESET}"

        # Create selected components in forward order
        for comp in "${SELECTED_COMPONENTS[@]}"; do
            # Create component
            echo -e "\n>>> # Create $comp"
            echo ">>> cd clusters/$comp"
            cd "$ROOTDIR/clusters/$comp" || { echo "Error changing directory. Aborting."; exit 1; }

            echo ">>> terraform init -input=false -reconfigure -backend-config=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}-backend.hcl"
            terraform init -input=false -reconfigure -backend-config=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}-backend.hcl || { echo "Terraform command failed. Aborting."; exit 1; }

            echo ">>> terraform plan -input=false -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV"
            terraform plan -input=false -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV || { echo "Terraform command failed. Aborting."; exit 1; }

            if [ "$AUTO_APPROVE" = true ] && [ "$CLUSTER_ENV" != "prod" ]; then
                echo ">>> terraform apply -auto-approve -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV"
                terraform apply -auto-approve -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV || { echo "Terraform command failed. Aborting."; exit 1; }
            else
                echo ">>> terraform apply -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV"
                terraform apply -var-file=config/${CLUSTER_ENV}/${REGION}/${CLUSTER_ENV}-${REGION}.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV || { echo "Terraform command failed. Aborting."; exit 1; }
            fi

            # Update kubeconfig and check connectivity after EKS deployment.
            if [ "$comp" = "eks" ]; then
                # Update kubeconfig to access the newly created cluster
                echo -e "\n>>> # Update kubeconfig for the EKS cluster"
                echo ">>> Updating kubeconfig from the EKS component output in ${REGION}"
                aws eks update-kubeconfig --name="$(terraform output -raw eks_cluster_id)" --region="${REGION}" || { echo "Failed to update kubeconfig. Aborting."; exit 1; }

                # Verify connectivity to the cluster
                echo ">>> kubectl get nodes"
                echo "Verifying connectivity to the cluster. This may take a minute..."
                # Wait for up to 3 minutes for the cluster connection to be established
                for i in {1..18}; do
                    if kubectl get nodes &>/dev/null; then
                        echo -e "${GREEN}Successfully connected to the EKS cluster!${RESET}"
                        kubectl get nodes
                        break
                    else
                        echo "Waiting for cluster connection to be established... ($i/18)"
                        sleep 10
                    fi

                    if [ $i -eq 18 ]; then
                        echo -e "${YELLOW}WARNING: Could not verify connection to the cluster within the timeout period."
                        echo -e "The add-ons deployment may fail if the cluster is not fully ready.${RESET}"
                        echo -e "You can manually verify the connection later with: kubectl get nodes"
                    fi
                done
            fi

            # Return to root directory
            cd "$ROOTDIR" || { echo "Error changing directory. Aborting."; exit 1; }
        done
    fi
}

if [ "$EXECUTE" = true ]; then
  # Just call the execute_commands function directly instead of using the command file
  execute_commands

  echo "========================================================================="
  if [ "$DESTROY" = true ]; then
    if [ -n "$COMPONENT" ]; then
      echo "           CLUSTER INFRASTRUCTURE COMPONENT '$COMPONENT' DESTROYED"
    else
      echo "           CLUSTER INFRASTRUCTURE DESTROYED"
    fi
  else
    if [ -n "$COMPONENT" ]; then
      echo "           CLUSTER INFRASTRUCTURE COMPONENT '$COMPONENT' DEPLOYED"
    else
      echo "           CLUSTER INFRASTRUCTURE DEPLOYED"
    fi
    echo ""
    echo "NEXT STEPS:"
    echo "1. Verify the EKS cluster is operational: kubectl get nodes"
    echo "2. Check the cluster add-ons are working: kubectl get pods -A"
    echo "3. Run deploy_environment.sh to configure environments on this cluster"
  fi
  echo "========================================================================="
else
  echo "========================================================================="
  if [ "$DESTROY" = true ]; then
    if [ -n "$COMPONENT" ]; then
      echo "       CLUSTER INFRASTRUCTURE COMPONENT '$COMPONENT' DESTRUCTION COMMANDS GENERATED"
    else
      echo "           CLUSTER INFRASTRUCTURE DESTRUCTION COMMANDS GENERATED"
    fi
    echo "========================================================================="
    echo "Copy and run these commands to destroy your cluster infrastructure on the bastion."
    echo "Make sure to check each command before running and verify the plan output."
    echo "WARNING: These commands will DESTROY resources. Proceed with caution."
  else
    if [ -n "$COMPONENT" ]; then
      echo "       CLUSTER INFRASTRUCTURE COMPONENT '$COMPONENT' DEPLOYMENT COMMANDS GENERATED"
    else
      echo "           CLUSTER INFRASTRUCTURE DEPLOYMENT COMMANDS GENERATED"
    fi
    echo "========================================================================="
    echo "Copy and run these commands to deploy your cluster infrastructure on the bastion."
    echo "Make sure to check each command before running and verify the plan output."
    echo ""
    echo "NEXT STEPS AFTER DEPLOYMENT:"
    echo "1. Verify the EKS cluster is operational: kubectl get nodes"
    echo "2. Check the cluster add-ons are working: kubectl get pods -A"
    echo "3. Run deploy_environment.sh to configure environments on this cluster"
  fi
  NEXT_COMMAND=("$0" --cluster-env "$CLUSTER_ENV" --region "$REGION")
  if [ "${#SELECTED_COMPONENTS[@]}" -eq 1 ]; then
    NEXT_COMMAND+=(--component "${SELECTED_COMPONENTS[0]}")
  fi
  if [ "$DESTROY" = true ]; then
    NEXT_COMMAND+=(--destroy)
  fi
  echo ""
  echo "To save these commands to a file, run:"
  printf '%q ' "${NEXT_COMMAND[@]}"
  printf '> cluster_commands.sh\n'
  echo ""
  echo "To execute these commands automatically, run:"
  printf '%q ' "${NEXT_COMMAND[@]}" --execute
  printf '\n'
fi
