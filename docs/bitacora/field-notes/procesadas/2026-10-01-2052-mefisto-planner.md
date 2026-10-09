---
fecha: 2026-10-01
hora: 20:52
sesion: mefisto-planner
tema: restringir auditoria NuGet a consumidores nuevos
---

## Contexto
El usuario aclaro que #1760 debe servir solo a nuevos consumidores, no migrar los existentes.

## Descubrimientos
/infra-base delega en infra-base-scaffolder, que genera infra-cd.yml en la primera inicializacion greenfield; /onboard es diagnostico y provision opt-in incluso para repos existentes.

## Decisiones
#1760 permanece listo y cambia su componente principal a infra-base-scaffolder publicado. El gate greenfield se toma antes de crear infra/main.tf o infra-cd.yml; un consumidor ya inicializado no recibe nuget-audit.yml por rerun. La auditoria cubre todos los PR del nuevo consumidor sin bloquearlos.

## Descartado
No anadir una via de provision o migracion en /onboard ni tocar ci.yml o workflows de consumidores existentes.

## Preguntas abiertas
Ninguna de alcance; implementar y verificar el workflow con pruebas hermeticas antes de una nueva release.

## Referencias
Issues refinados: #1760, Generar avisos NuGet no bloqueantes al inicializar consumidores nuevos.
Issues creados: ninguno.
