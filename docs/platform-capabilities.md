# Capability boundary

Prodplane supplies shared infrastructure and deployment mechanisms. Applications configure the resources they use and own their runtime behavior.

| Capability | Platform responsibility | Application responsibility |
| --- | --- | --- |
| Stateless and stateful deployment | Run a supplied chart; optional Deployment/StatefulSet template, stable peer discovery, per-replica claims, init containers, sidecars and lifecycle hooks | Images, replica topology, protocols, health checks and data behavior |
| Persistent storage | EFS/storage class, dynamic claims or explicit existing storage | Which workloads need data, mount paths and data lifecycle |
| Logging | Collect container output with Kubernetes metadata; CloudWatch, optional file archive, additional configured outputs | Log content, specialized parsing and retention requirements |
| Artifact delivery | Retrieve explicitly selected artifacts, run a supplied build definition, export selected build outputs, publish an image and deploy a chart | Package coordinates, output location/format, runtime packaging, release selection and application compatibility |
| Events and observability | Configured build targets, event-log routes and optional schema discovery | Event schemas, business meanings, filters and downstream behavior |
| Identity and secrets | Infrastructure IAM/OIDC, service-account wiring, explicit secret/configuration mappings | Workload IAM permissions, user identity service, business authorization and application key names |
| Migration and recovery | Optional migration Job and deployment status/rollback mechanics | Migration commands, schema compatibility, data rollback and restoration policy |

Application resource maps are empty by default; migration jobs, ingress, file archives and event observability require explicit configuration. Shared controllers and container logging have platform defaults.
