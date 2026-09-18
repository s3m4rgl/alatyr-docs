{{/*
Проверки, которые обязаны РОНЯТЬ установку, а не предупреждать.

Каждая из них закрывает случай, где неверная установка выглядит рабочей:
пустой образ даёт ImagePullBackOff, отсутствующий Secret — CreateContainerConfigError,
пустой адрес Vault — сервер, который стартует и отказывает на первой заявке.
Ошибка на `helm install` дешевле любого из этих трёх.
*/}}
{{- define "alatyr.validate" -}}
{{- if not .Values.image.server }}
{{- fail "image.server не задан: образы собираются в ВАШ registry, публичных нет" }}
{{- end }}
{{- if not .Values.image.frontend }}
{{- fail "image.frontend не задан" }}
{{- end }}
{{- if not .Values.image.tag }}
{{- fail "image.tag не задан: `latest` в проде означает «неизвестно, что развёрнуто»" }}
{{- end }}
{{- if not .Values.secrets.existingSecret }}
{{- fail "secrets.existingSecret не задан: значений секретов в values нет намеренно — они уезжают в git и в `helm get values`" }}
{{- end }}
{{- if not .Values.vault.addr }}
{{- fail "vault.addr не задан: чарт ожидает ГОТОВЫЙ Vault и не поднимает УЦ внутри себя (docs/SELFHOSTED-CA.md — если УЦ ещё нет)" }}
{{- end }}
{{- if not (has .Values.vault.auth (list "approle" "token")) }}
{{- fail "vault.auth должен быть approle или token" }}
{{- end }}
{{- if not (has .Values.postgres.mode (list "external" "embedded")) }}
{{- fail "postgres.mode должен быть external или embedded" }}
{{- end }}
{{- if and (gt (int .Values.server.replicas) 1) (not .Values.server.acknowledgeMultiReplicaLimits) }}
{{- fail "server.replicas > 1: поллинг SCEP рассчитан на ОДНУ реплику, а ограничение частоты не общее между репликами. Если это осознанное решение — server.acknowledgeMultiReplicaLimits: true" }}
{{- end }}
{{- if and (eq .Values.postgres.mode "embedded") (not .Values.postgres.backup.enabled) }}
{{- fail "postgres.mode=embedded без postgres.backup.enabled: один под без резервной копии — это отложенная потеря данных. Включите копию либо возьмите внешнюю базу" }}
{{- end }}
{{- end -}}
