# Rulesets de GitHub

`main.json` protege `main`: PR obligatorio (0 aprobaciones), sin force-push ni borrado, y **sin bypass**: ningun actor, ni el admin ni los agentes que corren con su cuenta, empuja directo a `main`. Los merges de los pipelines (`gh pr merge --squash`) siguen funcionando.

No exige status checks: `ci.yml` corre solo de noche y por `workflow_dispatch` (#2036), asi que un check requerido nunca se reportaria en un PR y bloquearia todos los merges. Si el CI vuelve a correr en `pull_request`, agrega la regla `required_status_checks` con el contexto `tests`.

Aplicado el 2026-10-10 (ruleset id `24852837`).

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
