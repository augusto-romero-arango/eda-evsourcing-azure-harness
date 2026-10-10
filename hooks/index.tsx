import type { Register } from 'claude-code'

import { register as pact } from './fausto-blood-pact/register'
import { register as board } from './register'

// Claude Code carga un solo modulo por plugin (`claude plugin validate` rechaza una segunda entrada de `modules`):
// este punto de entrada compone el tablero y la consola, que siguen siendo modulos independientes.
export const register: Register = (on, options) => {
  board(on, options)
  pact(on, options)
}
