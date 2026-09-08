---
{"kind":"agent","id":"agent-completo","description":"Lee, edita y ejecuta.","mode":"subagent","profile":"deep","capabilities":["read","edit","shell","web","task"]}
---
{{mefisto:assert-consumer-repo}}
Ruta: {{mefisto:config-path}}.
{{mefisto:state-path logs/con-espacio.log}}
Ejecuta {{mefisto:run prueba.sh "$ARGUMENTS con espacios"}} ahora.
Consulta {{mefisto:command otra-orden}}.
{{mefisto:package-root}}
