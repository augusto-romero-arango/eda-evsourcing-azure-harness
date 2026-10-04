# Rulesets de GitHub

`main.json` protege `main`: PR obligatorio (0 aprobaciones), sin force-push ni borrado. **Sin check de CI requerido** (la suite completa corre en una nightly) y **sin bypass** (`bypass_actors: []`): los agentes y pipelines usan las credenciales del admin, asi que un bypass del rol admin dejaria pasar sus pushes directos. Ningun script hace push directo a `main`. Para una intervencion manual urgente, el humano desactiva el ruleset desde la configuracion del repo y lo reactiva despues.

Se aplica **a mano** por un humano admin: ningun pipeline muta la configuracion de seguridad del repo.

## Aplicar (primera vez)

```bash
gh api --method POST repos/{owner}/{repo}/rulesets --input .github/rulesets/main.json
```

## Actualizar

```bash
gh api repos/{owner}/{repo}/rulesets                      # obtener el <id> del ruleset "main"
gh api --method PUT repos/{owner}/{repo}/rulesets/<id> --input .github/rulesets/main.json
```

## Verificar

```bash
gh api repos/{owner}/{repo}/rulesets
git push origin HEAD:main   # desde un commit de prueba: debe ser rechazado
```
