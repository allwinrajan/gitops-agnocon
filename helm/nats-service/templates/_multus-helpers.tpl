{{/*
Generate the Multus network annotation value.
Usage: {{ include "nats.multusAnnotation" . }}
*/}}
{{- define "nats.multusAnnotation" -}}
{{- if .Values.multus.enabled -}}
{{ .Values.multus.networkAttachmentDefinition }}
{{- end -}}
{{- end -}}
