// Relogio: base de parede vinda de `time(2)` da libc por FFI (src/platform/wall-clock.ts,
// que documenta por que `native:time` e `native:performance` estao fechados hoje) e um
// tique de 1s para o contador regressivo e a rotacao de codigo.
import { clearInterval, setInterval, type NativeTimeout } from "native:timers";

import { computed, signal } from "ts-native-ui";
import { wallClockMs } from "../platform/wall-clock";
import { DEMO_ACCOUNTS, getTotpSnapshot, type TotpAccount } from "../domain/accounts";

// Comeca em 0 e o relogio real entra no primeiro render (armClock): chamar a FFI no
// escopo do modulo rodaria dentro do `main` gerado, que no Android e invocado pelo
// .init_array antes de o GC estar servivel.
export const nowMs = signal<number>(0);
export const selectedGroup = signal<string>("All");
export const statusMessage = signal<string>("Ready");

let clockArmed = false;
let clockTimer: NativeTimeout | undefined = undefined;

// Tique de 1s. Armado no PRIMEIRO RENDER, nunca no escopo do modulo: no Android o
// `main` gerado roda a partir do .init_array antes de o GC estar servivel. O host
// macOS bombeia os timers pela thread NtuiTimerWaiter; no Android, pela ponte JNI.
export function armClock(): void {
  if (clockArmed) return;
  clockArmed = true;
  nowMs.set(wallClockMs());
  clockTimer = setInterval(() => {
    nowMs.set(wallClockMs());
  }, 1000);
}

// Um setInterval pendente segura o processo vivo para sempre. Cenas de teste
// (describeScene) renderizam a pagina, armam o relogio e nunca terminariam sem
// isto — o binario da fixture imprimia o marcador DONE e pendurava.
// Congela o relogio num instante fixo e impede que armClock() arme o tique. E o que
// permite cena de teste ter golden: sem isto, renderizar AccountListPage pega o
// relogio de parede e o codigo esperado muda a cada execucao.
export function freezeClockForTest(atMs: number): void {
  stopClock();
  clockArmed = true;
  nowMs.set(atMs);
}

export function stopClock(): void {
  if (clockTimer === undefined) return;
  clearInterval(clockTimer);
  clockTimer = undefined;
  clockArmed = false;
}

export function advanceClock(): void {
  nowMs.set(wallClockMs());
  statusMessage.set("Codes refreshed");
}

export function selectAllAccounts(): void {
  selectedGroup.set("All");
  statusMessage.set("Showing all accounts");
}

export function selectWorkAccounts(): void {
  selectedGroup.set("Work");
  statusMessage.set("Showing work accounts");
}

export function copyPrimaryCode(): void {
  const first = DEMO_ACCOUNTS[0];
  if (first === undefined) {
    statusMessage.set("No account selected");
    return;
  }
  const snapshot = getTotpSnapshot(first, nowMs.get());
  statusMessage.set(`Copied ${snapshot.formattedCode}`);
}

// CONTRATO DE RENDER: no ts-native-ui so repinta o que e Signal DENTRO da expressao
// JSX. Ler `nowMs.get()` no corpo do componente e montar a string derivada congela o
// valor no primeiro quadro (o compilador so embrulha em reactive() a expressao JSX que
// contem `.get()` — lower.ts:1798). Por isso TUDO que muda por segundo — codigo,
// contador, largura da barra e as classes de urgencia — sai daqui como computed().

// RN (TOTPCode): o contador so aparece nos ultimos 10 segundos.
function remainingLabel(account: TotpAccount): string {
  const snapshot = getTotpSnapshot(account, nowMs.get());
  if (snapshot.remainingSeconds > 10) return "";
  return snapshot.remainingSeconds + "s";
}

export const demoCode0 = computed(() => getTotpSnapshot(DEMO_ACCOUNTS[0], nowMs.get()).formattedCode);
export const demoCode1 = computed(() => getTotpSnapshot(DEMO_ACCOUNTS[1], nowMs.get()).formattedCode);
export const demoCode2 = computed(() => getTotpSnapshot(DEMO_ACCOUNTS[2], nowMs.get()).formattedCode);

export const demoRemaining0 = computed(() => remainingLabel(DEMO_ACCOUNTS[0]));
export const demoRemaining1 = computed(() => remainingLabel(DEMO_ACCOUNTS[1]));
export const demoRemaining2 = computed(() => remainingLabel(DEMO_ACCOUNTS[2]));

// Classes SIMPLES separadas por espaco. Composta (`.account-code.urgent`) NAO casa
// neste motor: selParseFields (ts-native-ui-css/src/selectors/runtime.ts) concatena os
// nomes e vai procurar a classe "account-codeurgent". Falha em silencio.
function codeClassFor(account: TotpAccount): string {
  const urgency = getTotpSnapshot(account, nowMs.get()).urgencyClass;
  return urgency.length > 0 ? "account-code account-code-urgent" : "account-code";
}

function valueClassFor(account: TotpAccount): string {
  const urgency = getTotpSnapshot(account, nowMs.get()).urgencyClass;
  return urgency.length > 0 ? "timer-value timer-value-urgent" : "timer-value";
}

function fillClassFor(account: TotpAccount): string {
  const snapshot = getTotpSnapshot(account, nowMs.get());
  if (snapshot.urgencyClass.length > 0) {
    return "timer-fill " + snapshot.progressClass + " timer-fill-urgent";
  }
  return "timer-fill " + snapshot.progressClass;
}

export const demoCodeClass0 = computed(() => codeClassFor(DEMO_ACCOUNTS[0]));
export const demoCodeClass1 = computed(() => codeClassFor(DEMO_ACCOUNTS[1]));
export const demoCodeClass2 = computed(() => codeClassFor(DEMO_ACCOUNTS[2]));

export const demoValueClass0 = computed(() => valueClassFor(DEMO_ACCOUNTS[0]));
export const demoValueClass1 = computed(() => valueClassFor(DEMO_ACCOUNTS[1]));
export const demoValueClass2 = computed(() => valueClassFor(DEMO_ACCOUNTS[2]));

export const demoFillClass0 = computed(() => fillClassFor(DEMO_ACCOUNTS[0]));
export const demoFillClass1 = computed(() => fillClassFor(DEMO_ACCOUNTS[1]));
export const demoFillClass2 = computed(() => fillClassFor(DEMO_ACCOUNTS[2]));
