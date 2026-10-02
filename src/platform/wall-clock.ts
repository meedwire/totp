// Relogio de parede do app TOTP — CONTRATO e fallback.
//
// A implementacao e escolhida POR ALVO pelo compilador, nao por `if` em tempo de
// execucao: `--platform=darwin` resolve `wall-clock.macos.ts`, `--platform=android`
// resolve `wall-clock.android.ts`, e qualquer outro alvo cai NESTE arquivo
// (packages/compiler/src/pipeline/compiler-options.ts:21, ligado em
// packages/compiler/src/index.ts:230). Quem importa `./wall-clock` nao sabe de
// plataforma nenhuma — `src/state/app-state.ts` nao muda uma linha.
//
// POR QUE O FALLBACK FALHA EM VEZ DE CHUTAR: num autenticador TOTP um relogio
// errado nao da erro, da CODIGO ERRADO — falha silenciosa que so aparece quando o
// servidor recusa o login. Alvo sem relogio proprio tem que quebrar alto.
//
// POR QUE NAO OS MODULOS OFICIAIS (`native:date`/`native:time`): o link quebra com
// "symbol '_parse' is already defined" — o `parse` do modulo colide, no escopo
// global plano do emissor, com `export function parse` de
// packages/ts-native-ui-css/src/stylesheet/parse-stylesheet.ts:61. Medido em
// 2026-08-26 e RE-MEDIDO em 2026-09-11 no tip 933c482: continua valendo.
// `native:performance` linka mas mata o app na inicializacao (exit 0, sem janela).

const WALL_CLOCK_UNSUPPORTED =
  "wall-clock: alvo sem relogio de parede; crie src/platform/wall-clock.<plataforma>.ts";

export function wallClockSeconds(): number {
  throw new Error(WALL_CLOCK_UNSUPPORTED);
}

export function wallClockMs(): number {
  throw new Error(WALL_CLOCK_UNSUPPORTED);
}
