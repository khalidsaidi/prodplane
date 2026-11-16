#!/bin/bash

# Network Infrastructure Deployment Script
# This script should be run locally to set up the network infrastructure and bastion host

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
  echo "  --region REGION              AWS region ( eu-west-1)"
  echo "  --execute                    Execute the commands (rather than just displaying them)"
  echo "  --destroy                    Generate destroy commands instead of deploy commands"
  echo "  --allow-current-ip           Add temporary SSH access for this operator IP after apply"
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
INTERACTIVE=true
EXECUTE=false
DESTROY=false
AUTO_APPROVE=false
ALLOW_CURRENT_IP=false
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
    --execute)
      EXECUTE=true
      shift
      ;;
    --destroy)
      DESTROY=true
      shift
      ;;
    --allow-current-ip)
      ALLOW_CURRENT_IP=true
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

if [ "$ALLOW_CURRENT_IP" = true ] && [ "$DESTROY" = true ]; then
  echo "--allow-current-ip is only available when applying the network." >&2
  exit 2
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
  echo "           NETWORK INFRASTRUCTURE DESTRUCTION (LOCAL)"
else
  echo "           NETWORK INFRASTRUCTURE DEPLOYMENT (LOCAL)"
fi
echo "========================================================================="
echo "Cluster Environment: $CLUSTER_ENV"
echo "Region: $REGION"
if [ "$DESTROY" = true ]; then
  echo "Action: Destroying network infrastructure and bastion host"
else
  echo "Action: Creating network infrastructure and bastion host"
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

# Generate deployment commands for network infrastructure
if [ "$DESTROY" = true ]; then
  echo "# Destroy Network Infrastructure (Run Locally)" | tee -a "$CMDFILE"
  echo "cd clusters/network" | tee -a "$CMDFILE"
  echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
  echo "terraform plan -input=false -destroy -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
  echo "terraform destroy -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
  echo "" | tee -a "$CMDFILE"
else
  echo "# Create Network Infrastructure (Run Locally)" | tee -a "$CMDFILE"
  echo "cd clusters/network" | tee -a "$CMDFILE"
  echo "terraform init -input=false -reconfigure -backend-config=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION-backend.hcl" | tee -a "$CMDFILE"
  echo "terraform plan -input=false -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
  echo "terraform apply -var-file=config/$CLUSTER_ENV/$REGION/$CLUSTER_ENV-$REGION.tfvars -var=aws_region=$REGION -var=cluster_environment=$CLUSTER_ENV" | tee -a "$CMDFILE"
  echo "" | tee -a "$CMDFILE"

  if [ "$ALLOW_CURRENT_IP" = true ]; then
    echo "# After apply, --allow-current-ip adds this operator's IP to the selected bastion security group." | tee -a "$CMDFILE"
  fi
  # Add instructions for next steps
  echo "# After successfully deploying the network infrastructure:" | tee -a "$CMDFILE"
  echo "# 1. Connect to the bastion host using your SSH key" | tee -a "$CMDFILE"
  echo "# 2. Make this checkout and the selected private .tfvars/backend .hcl files available there (transfer securely or configure from examples)" | tee -a "$CMDFILE"
  echo "# 3. Ensure Terraform, AWS CLI, kubectl and jq are installed and AWS credentials are configured" | tee -a "$CMDFILE"
  echo "# 4. Run deploy_cluster.sh on the bastion host" | tee -a "$CMDFILE"
  echo "" | tee -a "$CMDFILE"
fi

if [ "$EXECUTE" = true ]; then
  echo "========================================================================="
  if [ "$DESTROY" = true ]; then
    echo "           EXECUTING NETWORK INFRASTRUCTURE DESTROY COMMANDS"
  else
    echo "           EXECUTING NETWORK INFRASTRUCTURE COMMANDS"
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
    echo "           NETWORK OPERATIONS SKIPPED"
    echo "Completed: 0; skipped: $SKIPPED_OPERATIONS"
  elif [ "$DESTROY" = true ]; then
    echo "           NETWORK INFRASTRUCTURE DESTROYED"
  else
    echo "           NETWORK INFRASTRUCTURE DEPLOYED"
    echo ""
    echo "NEXT STEPS:"

    # Add inbound rule to bastion security group for local IP
    if [ "$ALLOW_CURRENT_IP" = true ]; then
      echo "Adding inbound rule to bastion security group for your local IP..."

      # Get local public IP address
      LOCAL_IP=$(curl -s https://checkip.amazonaws.com)
      if [ -z "$LOCAL_IP" ]; then
        echo "Warning: Could not determine your public IP address. Inbound rule not added."
      else
        # Use the group owned by this target, never the first matching tag in
        # the account (several VPCs may legitimately use the same tag).
        if ! BASTION_SG=$(terraform -chdir="$SCRIPT_DIR/clusters/network" output -raw bastion_sg_id); then
          echo "Warning: Could not read the selected bastion security group from state."
          BASTION_SG=""
        fi

        if [ -z "$BASTION_SG" ] || [ "$BASTION_SG" = "None" ]; then
          echo "Warning: Could not find bastion security group. Inbound rule not added."
        else
          # Add the inbound rule
          if aws ec2 authorize-security-group-ingress \
            --region "$REGION" \
            --group-id "$BASTION_SG" \
            --protocol tcp \
            --port 22 \
            --cidr "$LOCAL_IP/32" > /dev/null 2>&1; then
            echo "Successfully added inbound rule to bastion security group for $LOCAL_IP"
          else
            echo "Warning: Failed to add inbound rule to bastion security group."
          fi
        fi
      fi
    fi

    echo "1. Connect to the bastion host using your SSH key"
    echo "2. Make this checkout and the selected private .tfvars/backend .hcl files available there (transfer securely or configure from examples)"
    echo "3. Ensure Terraform, AWS CLI, kubectl and jq are installed and AWS credentials are configured"
    echo "4. Run deploy_cluster.sh on the bastion host"
  fi
  echo "========================================================================="
else
  echo "========================================================================="
  if [ "$DESTROY" = true ]; then
    echo "           NETWORK DESTRUCTION COMMANDS GENERATED"
    echo "========================================================================="
    echo "Copy and run these commands to destroy your network infrastructure locally."
    echo "Make sure to check each command before running and verify the plan output."
    echo "WARNING: These commands will DESTROY resources. Proceed with caution."
  else
    echo "           NETWORK DEPLOYMENT COMMANDS GENERATED"
    echo "========================================================================="
    echo "Copy and run these commands to deploy your network infrastructure locally."
    echo "Make sure to check each command before running and verify the plan output."
    echo ""
    echo "NEXT STEPS AFTER DEPLOYMENT:"
    echo "1. Connect to the bastion host using your SSH key"
    echo "2. Make this checkout and the selected private .tfvars/backend .hcl files available there (transfer securely or configure from examples)"
    echo "3. Ensure Terraform, AWS CLI, kubectl and jq are installed and AWS credentials are configured"
    echo "4. Run deploy_cluster.sh on the bastion host"
  fi
  NEXT_COMMAND=("$0" --cluster-env "$CLUSTER_ENV" --region "$REGION")
  if [ "$DESTROY" = true ]; then
    NEXT_COMMAND+=(--destroy)
  fi
  if [ "$ALLOW_CURRENT_IP" = true ]; then
    NEXT_COMMAND+=(--allow-current-ip)
  fi
  echo ""
  echo "To save these commands to a file, run:"
  printf '%q ' "${NEXT_COMMAND[@]}"
  printf '> network_commands.sh\n'
  echo ""
  echo "To execute these commands automatically, run:"
  printf '%q ' "${NEXT_COMMAND[@]}" --execute
  printf '\n'
fi
