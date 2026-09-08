---
{"kind":"command","id":"example-command","description":"Fixture válido de comando publicado.","capabilities":["shell"],"agent":"example-agent","arguments":"<issue>","mcp":["terraform"]}
---

{{mefisto:assert-consumer-repo}}
{{mefisto:launch-agent example-agent}}
{{mefisto:run tooling-pipeline.sh $ARGUMENTS}}
{{mefisto:package-root}}
{{mefisto:state-path pipeline/events.log}}
{{mefisto:command example-command}}
