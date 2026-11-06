{{- define "llama-server.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "llama-server.fullname" -}}
{{- printf "%s" (include "llama-server.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "llama-server.labels" -}}
app.kubernetes.io/name: {{ include "llama-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{-
    define "llama-server.modelPath" -}}
{{- printf "/models/%s" .Values.model.key -}}
{{- end -}}
