---
fecha: 2026-10-01
hora: 19:17
sesion: mefisto-planner
tema: lectura externa sin prompts en OpenCode publicado
---

## Contexto
El usuario reporto prompts Access external directory para la release de Mefisto y ~/.config/opencode al ejecutar el plugin publicado desde un consumidor.

## Descubrimientos
El mapping publicado niega external_directory globalmente y deniega expresamente lectura de .env, auth.json, .aws y .ssh. Abrir el permiso externo sin probar el resto de herramientas no equivale a lectura solamente.

## Decisiones
El usuario prefiere lectura ordinaria sin prompts, manteniendo secretos y escritura externa denegados. Se creo #1761 como borrador para verificar primero si OpenCode permite garantizar ese contrato; #1750 depende de #1761, esta bloqueado y se acoto al arranque del test-writer.

## Descartado
No habilitar external_directory: allow global ni convertir deny en ask para sortear la solicitud.

## Preguntas abiertas
Demostrar experimentalmente que lectura ordinaria externa y bloqueo de escritura externa/secretos coexisten para los agentes publicados en la version soportada. Si no, elegir alternativa antes de marcar #1761 como listo.

## Referencias
Issues creados: #1761, Permitir lecturas externas ordinarias sin prompts en OpenCode publicado.
Issues refinados: #1750, Permitir al test-writer de OpenCode consultar la release activa.
