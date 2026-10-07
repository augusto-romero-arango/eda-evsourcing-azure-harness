# Rulesets de GitHub

`main.json` protege `main`: PR obligatorio (0 aprobaciones), check `tests` del CI (`.github/workflows/ci.yml`) sin "require branches to be up to date", sin force-push ni borrado. Bypass solo para el rol admin del repo (`actor_id: 5`), uso humano deliberado (`gh pr merge --admin`) si el propio CI se rompe; ningun script lo usa.

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
