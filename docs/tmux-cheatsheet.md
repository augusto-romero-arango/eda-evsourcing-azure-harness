# tmux + iTerm2: Guia de referencia

Guia de uso de tmux con **iTerm2 en modo control** (`-CC`). En este modo, iTerm2 maneja toda la interfaz: no hay keybindings de tmux que aprender. Copiar, pegar, el mouse, las capturas de pantalla, todo funciona igual que siempre.

---

## Regla fundamental

**Claude Code siempre va en una terminal normal. Nunca dentro de tmux.**

tmux es exclusivamente para monitorear pipelines en una ventana separada. Si corres Claude Code dentro de tmux, el clipboard y el pegado de imágenes dejan de funcionar.

```
Terminal normal (Claude Code)     Ventana tmux -CC (pipelines)
┌────────────────────────────┐    ┌──────────────────────────────┐
│ $ claude                   │    │  Tab: dashboard               │
│ > trabajas aqui            │    │  [12:30] test-writer START    │
│ > pegas imagenes           │    │  [12:31] archivo: Tests.cs    │
│ > todo funciona normal     │    │                               │
│                            │    │  Tab: pipeline                │
│                            │    │  (output del agente)          │
└────────────────────────────┘    └──────────────────────────────┘
```

---

## Primeros pasos (una sola vez por maquina)

### 1. Instalar tmux
```bash
brew install tmux
```

### 2. Aplicar la configuracion del proyecto
```bash
# Copia la config del proyecto a tu home
cp .tmux.conf ~/.tmux.conf
```

Esta config esta optimizada para iTerm2 -CC. No tiene keybindings personalizados.

---

## Uso diario

### Iniciar una sesion nueva
```bash
tmux -CC
```
iTerm2 abre una nueva ventana. Trabaja normalmente con Cmd+T, Cmd+D, etc.

### Reconectar a una sesion existente
```bash
tmux -CC attach
```

### Reconectar a una sesion especifica
```bash
tmux -CC attach -t nombre-sesion
```

---

## Atajos de iTerm2 en modo -CC

> En modo -CC **no existe el prefijo de tmux**. Usas los atajos de siempre de iTerm2.

| Accion | Atajo |
|---|---|
| Nueva tab (= nueva ventana tmux) | `Cmd+T` |
| Cerrar tab | `Cmd+W` |
| Dividir pane vertical | `Cmd+D` |
| Dividir pane horizontal | `Cmd+Shift+D` |
| Mover entre panes | `Cmd+Option+Flechas` |
| Mover entre tabs | `Cmd+Numero` o `Cmd+Shift+[]` |
| Buscar en scrollback | `Cmd+F` |
| Copiar texto | `Cmd+C` (o seleccion con mouse) |
| Pegar texto | `Cmd+V` |
| Zoom pane (pantalla completa) | `Cmd+Shift+Enter` |
| Pegar captura de pantalla en Claude | Normal (drag & drop o clipboard) |

---

## Manejar sesiones desde CLI

```bash
# Ver todas las sesiones activas
tmux ls

# Matar una sesion especifica
tmux kill-session -t nombre-sesion

# Matar todas las sesiones
tmux kill-server

# Renombrar la sesion actual
tmux rename-session nombre-nuevo
```

---

## Uso con los pipelines del proyecto

### Issue unico
```bash
./scripts/tmux-pipeline.sh 42
```
Crea dos tabs en iTerm2:
- `dashboard` — muestra `events.log` en tiempo real
- `pipeline` — corre `tdd-pipeline.sh 42`

### Batch secuencial (implementa → PR → merge → siguiente)
```bash
./scripts/tmux-pipeline.sh --batch 42 43 44
```
Crea dos tabs:
- `dashboard` — muestra events.log
- `pipeline` — corre `batch-pipeline.sh 42 43 44`

### Paralelo (un tab por issue)
```bash
./scripts/tmux-pipeline.sh --parallel 42 43 44
./scripts/tmux-pipeline.sh --parallel 42 43 44 --max-parallel 2
```
Crea N+1 tabs:
- `dashboard` — status consolidado
- `issue-42`, `issue-43`, `issue-44` — uno por issue

### Reconectar si cierras iTerm2 por accidente
```bash
tmux -CC attach
# Si hay varias sesiones:
tmux ls
tmux -CC attach -t tdd-42
```

---

## Recuperacion ante fallos

| Situacion | Como recuperar |
|---|---|
| Cerre iTerm2 con pipeline corriendo | `tmux -CC attach` - los agentes siguen en background |
| MacBook suspendido con pipeline activo | `tmux -CC attach` al volver - tmux persiste |
| Quiero ver el log de un issue | `cat .claude/pipeline/logs/tdd-<timestamp>.log` |
| Un agente se colgó en un pane | Ves el tab, usas `Ctrl+C` para interrumpir |

---

## Portabilidad

El archivo `.tmux.conf` en la raiz del proyecto es la fuente de verdad. Para configurar un nuevo equipo:

```bash
git clone https://github.com/augusto-romero-arango/Bitakora.ControlAsistencia.git
cd Bitakora.ControlAsistencia
cp .tmux.conf ~/.tmux.conf
brew install tmux
```

---

## Por que iTerm2 -CC y no tmux normal

| Con tmux normal | Con iTerm2 -CC |
|---|---|
| Prefix + % para dividir pane | `Cmd+D` (el de siempre) |
| Prefix + c para nueva ventana | `Cmd+T` |
| Prefix + [ para entrar en modo copia | Scroll con trackpad directamente |
| Yank plugin para clipboard | `Cmd+C` nativo |
| Conflictos con atajos de macOS | Sin conflictos |
| No funciona pegar screenshots en Claude | Funciona igual que siempre |
