# Workload

Supply an application image through `image.repository` and `image.tag`. The chart creates a Deployment by default. `kind: StatefulSet` enables stable replica identity, a headless peer-discovery Service and caller-supplied `volumeClaimTemplates`. Neither mode prescribes a runtime framework or database.

The regular Service remains optional in either mode. Stateful workloads can set `statefulSet.podManagementPolicy` and `statefulSet.updateStrategy`. Claim lifecycle and storage-class choices belong to the application/operator. Derived resource names reserve space for suffixes by limiting the base name to 53 characters.

Application configuration uses native Kubernetes `env`, `envFrom`, `volumes`, `volumeMounts`, probe, resource and scheduling values. Secrets, ConfigMaps and persistent claims referenced by those values must exist.

Updating a ConfigMap consumed through environment variables requires a container restart; Kubernetes does not refresh those values in a running process. An application can request a configuration-only Deployment rollout by changing `podAnnotations`, for example `configuration-revision: "config-002"`. This changes the Pod template while retaining the image. StatefulSets follow their selected update strategy. See [ConfigMap update behavior](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically) and [Deployment rollout behavior](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#updating-a-deployment).

`initContainers`, `extraContainers` and `lifecycle` accept application-owned native definitions. The chart supports these mechanisms without embedding a particular file-tail sidecar, initializer or runtime script.

Ingress is disabled by default. Enabling it with supplied hosts selects Prodplane's `alb` class and IP targets, which work with the chart's ClusterIP Service. The ALB is internal unless `alb.ingress.kubernetes.io/scheme: internet-facing` is supplied. Use ALB annotations for health checks, HTTPS listeners and ACM certificates; Kubernetes TLS Secret references do not install certificates into ALB. See the [pinned controller's ingress settings](https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.8/guide/ingress/annotations/).

Enable/create switches require YAML booleans (`true` / `false`), rather than quoted strings. Helm validates those types before rendering resources or running hooks.

Migrations are disabled by default. When enabled, supply a migration image and its command/arguments or image entrypoint. The Job runs before install and upgrade and must use an existing service account and existing dependencies. Its default service account is the namespace's `default` account. Failed jobs remain for diagnosis; successful jobs are removed. Application data rollback is outside the chart's control.
