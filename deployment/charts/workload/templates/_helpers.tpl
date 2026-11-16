{{- define "workload.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "workload.fullname" -}}
{{- /* Leave room for derived resource suffixes such as -migration. */ -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 53 | trimSuffix "-" -}}
{{- end -}}
{{- define "workload.selectorLabels" -}}
app.kubernetes.io/name: {{ include "workload.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}
{{- define "workload.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "workload.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
