// Relogio de parede no macOS: `time(2)` da libc por FFI.
// Selecionado automaticamente em `--platform=darwin`; ver o contrato e a razao de
// nao usar `native:date`/`native:time` em ./wall-clock.ts.
//
// Todo simbolo de topo daqui leva prefixo de proposito: constantes e funcoes de
// topo compartilham um escopo GLOBAL PLANO entre modulos, e um nome repetido em
// outro arquivo alias em silencio (dados) ou quebra o link (funcoes).
import { foreign, type ptr, type usize } from "native:ffi";

const __wallClockMacos_libc = foreign.lib("c");

// O parametro e um ponteiro opcional de saida. Tem que ser declarado como
// `ptr<"void">`, NAO `usize`: os dois sao `number` no TS, mas `usize` num
// parametro de ponteiro da SIGSEGV no marshalling.
const __wallClockMacos_time =
  __wallClockMacos_libc.fn<(out: ptr<"void">) => usize>("time");

export function wallClockSeconds(): number {
  return __wallClockMacos_time(0);
}

// `time()` resolve em SEGUNDOS — esta escala e a granularidade real, nao ms.
// E o suficiente para o TOTP: a janela e de 30s e o tique do contador e de 1s.
export function wallClockMs(): number {
  return __wallClockMacos_time(0) * 1000;
}
