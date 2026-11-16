# Platform and application boundary

Prodplane provides the shared AWS/EKS infrastructure and deployment mechanisms. Applications supply their services, runtime requirements and business behavior.

The platform owns VPC/EKS infrastructure, IAM for platform operations, shared storage capability, cluster add-ons and logging, environment namespaces, configured build projects and event routing. It also offers an optional workload chart and pipeline recipes.

Applications own their images and Dockerfiles, runtime frameworks, database schemas, identity integration, queues, search configuration, migration logic, secret key names, routes and logging content. Those definitions enter through maps, native Kubernetes values, application repositories or application-owned charts. Empty application maps remain valid.

Resource ownership is explicit:

- The cluster storage root owns the shared EFS filesystem and storage class.
- The environment storage root creates only claims explicitly requested in `volumes`.
- The application environment root owns its namespace and any explicitly supplied secret/configuration mirrors.
- The cluster add-ons root owns cluster logging. The collector tails container stdout/stderr and enriches records with Kubernetes metadata; it does not interpret business log classes or write named application directories.
- An application chart owns its workload resources. The optional workload chart references existing secrets, ConfigMaps and claims rather than creating competing copies.
- Application migrations are optional. The caller owns their command, compatibility, credentials and recovery policy.

The five cluster components and four environment components each own separate Terraform state. Environment components read the selected cluster's outputs through remote-state references.
