{{/*
Common chart helpers.
*/}}
{{- define "fubox.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fubox.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "fubox.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fubox.labels" -}}
helm.sh/chart: {{ include "fubox.chart" . }}
app.kubernetes.io/name: {{ include "fubox.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "fubox.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fubox.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}

{{- define "fubox.componentName" -}}
{{- printf "%s-%s" (include "fubox.fullname" .root) .name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fubox.configMapName" -}}
{{- $config := default dict .Values.global.config -}}
{{- $configuredName := default "runtime-config" (get $config "name") -}}
{{- printf "%s-%s" (include "fubox.fullname" .) $configuredName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fubox.image" -}}
{{- $root := .root -}}
{{- $image := .image -}}
{{- $tag := default $root.Chart.AppVersion $image.tag -}}
{{- if $root.Values.global.imageRegistry -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $root.Values.global.imageRegistry) $image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $image.repository $tag -}}
{{- end -}}
{{- end -}}

{{- define "fubox.validateFrontendEnv" -}}
{{- $scope := .scope -}}
{{- range $key, $value := .env }}
{{- $name := toString $key -}}
{{- if regexMatch "^(VITE_|REACT_APP_|NEXT_PUBLIC_)" $name -}}
{{- fail (printf "%s must not define browser-bundled env %q; use same-origin /api/* or server-side upstream env instead" $scope $name) -}}
{{- end -}}
{{- if regexMatch "(?i)(^|_)(secret|token|password|credential|api_key|private_key|key)($|_)" $name -}}
{{- fail (printf "%s must not define secret-like env %q for admin-ui" $scope $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "fubox.validateService" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $svc := .svc -}}
{{- $image := default dict $svc.image -}}
{{- if not (get $image "repository") -}}
{{- fail (printf "services.%s.image.repository is required" $name) -}}
{{- end -}}
{{- if not (get $image "tag") -}}
{{- fail (printf "services.%s.image.tag is required" $name) -}}
{{- end -}}
{{- $containerPort := int (default 0 $svc.containerPort) -}}
{{- if or (lt $containerPort 1) (gt $containerPort 65535) -}}
{{- fail (printf "services.%s.containerPort must be between 1 and 65535" $name) -}}
{{- end -}}
{{- $service := default dict $svc.service -}}
{{- $servicePort := int (default 0 (get $service "port")) -}}
{{- if or (lt $servicePort 1) (gt $servicePort 65535) -}}
{{- fail (printf "services.%s.service.port must be between 1 and 65535" $name) -}}
{{- end -}}
{{- $app := default dict $root.Values.application -}}
{{- $appSecretRef := default dict (get $app "secretRef") -}}
{{- $appSecretName := default "" (get $appSecretRef "name") -}}
{{- $database := default dict $root.Values.database -}}
{{- $databaseSecretRef := default dict (get $database "secretRef") -}}
{{- $databaseSecretName := default "" (get $databaseSecretRef "name") -}}
{{- $redis := default dict $root.Values.redis -}}
{{- $redisSecretRef := default dict (get $redis "secretRef") -}}
{{- $redisSecretName := default "" (get $redisSecretRef "name") -}}
{{- if and $svc.applicationSecretRef (not $appSecretName) -}}
{{- fail (printf "services.%s.applicationSecretRef requires application.secretRef.name" $name) -}}
{{- end -}}
{{- if and $svc.databaseSecretRef (not $databaseSecretName) -}}
{{- fail (printf "services.%s.databaseSecretRef requires database.secretRef.name" $name) -}}
{{- end -}}
{{- if and $svc.redisSecretRef (not $redisSecretName) -}}
{{- fail (printf "services.%s.redisSecretRef requires redis.secretRef.name" $name) -}}
{{- end -}}
{{- $globalConfig := default dict $root.Values.global.config -}}
{{- $env := default dict $svc.env -}}
{{- $configPath := default "" (get $env "AI_GATEWAY_CONFIG") -}}
{{- if $svc.configMapRef -}}
{{- if not (default false (get $globalConfig "enabled")) -}}
{{- fail (printf "services.%s.configMapRef requires global.config.enabled=true" $name) -}}
{{- end -}}
{{- else if $configPath -}}
{{- fail (printf "services.%s.env.AI_GATEWAY_CONFIG requires services.%s.configMapRef=true" $name $name) -}}
{{- end -}}
{{- $mountPath := default "" (get $globalConfig "mountPath") -}}
{{- if and $svc.configMapRef $configPath $mountPath (ne $configPath $mountPath) -}}
{{- fail (printf "services.%s.env.AI_GATEWAY_CONFIG must match global.config.mountPath" $name) -}}
{{- end -}}
{{- $resources := default dict $svc.resources -}}
{{- $requests := default dict (get $resources "requests") -}}
{{- $limits := default dict (get $resources "limits") -}}
{{- range $field := list "cpu" "memory" -}}
{{- if not (get $requests $field) -}}
{{- fail (printf "services.%s.resources.requests.%s is required" $name $field) -}}
{{- end -}}
{{- if not (get $limits $field) -}}
{{- fail (printf "services.%s.resources.limits.%s is required" $name $field) -}}
{{- end -}}
{{- end -}}
{{- $probes := default dict $svc.probes -}}
{{- range $probeName := list "liveness" "readiness" -}}
{{- $probe := default dict (get $probes $probeName) -}}
{{- if (default false (get $probe "enabled")) -}}
{{- $path := default "" (get $probe "path") -}}
{{- if not (hasPrefix "/" $path) -}}
{{- fail (printf "services.%s.probes.%s.path must start with /" $name $probeName) -}}
{{- end -}}
{{- if lt (int (default 0 (get $probe "initialDelaySeconds"))) 0 -}}
{{- fail (printf "services.%s.probes.%s.initialDelaySeconds must be >= 0" $name $probeName) -}}
{{- end -}}
{{- if lt (int (default 10 (get $probe "periodSeconds"))) 1 -}}
{{- fail (printf "services.%s.probes.%s.periodSeconds must be >= 1" $name $probeName) -}}
{{- end -}}
{{- if lt (int (default 2 (get $probe "timeoutSeconds"))) 1 -}}
{{- fail (printf "services.%s.probes.%s.timeoutSeconds must be >= 1" $name $probeName) -}}
{{- end -}}
{{- if lt (int (default 3 (get $probe "failureThreshold"))) 1 -}}
{{- fail (printf "services.%s.probes.%s.failureThreshold must be >= 1" $name $probeName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq $name "admin-ui" -}}
{{- if or $svc.applicationSecretRef $svc.databaseSecretRef $svc.redisSecretRef -}}
{{- fail "services.admin-ui must not mount application/database/redis secretRef env into the frontend container" -}}
{{- end -}}
{{- if $svc.configMapRef -}}
{{- fail "services.admin-ui.configMapRef must remain false" -}}
{{- end -}}
{{- include "fubox.validateFrontendEnv" (dict "scope" "services.admin-ui.env" "env" (default dict $svc.env)) -}}
{{- include "fubox.validateFrontendEnv" (dict "scope" "global.commonEnv" "env" (default dict $root.Values.global.commonEnv)) -}}
{{- end -}}
{{- end -}}

{{- define "fubox.validateIngressPath" -}}
{{- $root := .root -}}
{{- $serviceName := .serviceName -}}
{{- $path := default "" .path -}}
{{- $pathType := default "Prefix" .pathType -}}
{{- if not (hasPrefix "/" $path) -}}
{{- fail (printf "ingress path for service %q must start with /" $serviceName) -}}
{{- end -}}
{{- if not (has $pathType (list "ImplementationSpecific" "Exact" "Prefix")) -}}
{{- fail (printf "ingress path %q for service %q has invalid pathType %q" $path $serviceName $pathType) -}}
{{- end -}}
{{- $service := get $root.Values.services $serviceName -}}
{{- if not $service -}}
{{- fail (printf "ingress path %q references unknown service %q" $path $serviceName) -}}
{{- end -}}
{{- if not (get $service "enabled") -}}
{{- fail (printf "ingress path %q references disabled service %q" $path $serviceName) -}}
{{- end -}}
{{- $serviceSpec := default dict (get $service "service") -}}
{{- $servicePort := int (default 0 (get $serviceSpec "port")) -}}
{{- if or (lt $servicePort 1) (gt $servicePort 65535) -}}
{{- fail (printf "ingress path %q references service %q without a valid service.port" $path $serviceName) -}}
{{- end -}}
{{- end -}}
