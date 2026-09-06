# opencode-permission-eval.jq -- Evaluador de "ultima coincidencia gana" para
# los tests del bloque `permission` de OpenCode (issue #862 CA-6). Reproduce
# UNICAMENTE la regla de orden que OpenCode 1.18.29 documenta para sus mapas
# de patrones (bash/edit/read): el ULTIMO patron declarado que matchea el
# candidato es el que decide. No pretende ser el motor real de OpenCode (sin
# soporte de rutas absolutas, expansion de `~`, ni parsing real de comandos
# bash) -- si el dogfooding (#874) muestra una discrepancia, se corrige el
# mapping (opencode-permissions.json), nunca este evaluador ni el test que lo
# usa.
#
# Uso:
#   jq -n --argjson permission "$PERM_JSON" --arg key <clave> --arg input <candidato> \
#       -f opencode-permission-eval.jq
#
# <clave> es una clave del vocabulario (bash, edit, read, question, ...).
# Si permission[<clave>] es un string escalar, se imprime tal cual (no hay
# mapa que evaluar). Si es un objeto (mapa de patrones), se convierte cada
# patron glob a una regex ancla (`*` -> `.*`, `?` -> `.`, resto escapado) y se
# imprime el `value` de la ULTIMA entrada -- en el orden de declaracion del
# objeto, que jq preserva desde el JSON de origen sin `-S` -- cuyo patron
# matchea <candidato> completo. Si ninguna entrada matchea, imprime `null`
# (no deberia ocurrir en la practica: todo mapa de este mapping arranca con
# el catch-all "*").

def glob_to_regex:
  explode
  | map(
      . as $c
      | if $c == 42 then ".*"                                           # '*'
        elif $c == 63 then "."                                          # '?'
        elif ([46,43,94,36,40,41,123,125,91,93,124,92] | index($c)) then
          "\\" + ([$c] | implode)                                       # . + ^ $ ( ) { } [ ] | \
        else
          [$c] | implode
        end
    )
  | join("")
  | "^" + . + "$";

($permission[$key]) as $val
| if $val == null then null
  elif ($val | type) == "string" then $val
  else
    ( $val
      | to_entries
      | map(select(. as $entry | $input | test($entry.key | glob_to_regex)))
      | if length == 0 then null else (last | .value) end
    )
  end
