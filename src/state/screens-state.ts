// Estado das telas secundarias. Nomes prefixados com o modulo de proposito:
// const/funcao de topo compartilham um escopo GLOBAL PLANO entre modulos no ntsc,
// e um homonimo aliasa em silencio (dados) ou quebra o link (funcoes).
import { computed, signal } from "ts-native-ui";

// --- Add Account: abas de modo (URI / Manual / Google) ---

export const screensAddMode = signal<string>("manual");

export function screensSelectUriMode(): void {
  screensAddMode.set("uri");
}

export function screensSelectManualMode(): void {
  screensAddMode.set("manual");
}

export function screensSelectGoogleMode(): void {
  screensAddMode.set("google");
}

function screensModeTabClass(mode: string): string {
  return screensAddMode.get() === mode ? "mode-tab mode-tab-active" : "mode-tab";
}

export const screensUriTabClass = computed(() => screensModeTabClass("uri"));
export const screensManualTabClass = computed(() => screensModeTabClass("manual"));
export const screensGoogleTabClass = computed(() => screensModeTabClass("google"));

// --- Add Account: segmentos de digitos e periodo ---

export const screensDigits = signal<number>(6);
export const screensPeriod = signal<number>(30);

export function screensSetDigits6(): void {
  screensDigits.set(6);
}

export function screensSetDigits8(): void {
  screensDigits.set(8);
}

export function screensSetPeriod30(): void {
  screensPeriod.set(30);
}

export function screensSetPeriod60(): void {
  screensPeriod.set(60);
}

function screensSegmentClass(active: boolean): string {
  return active ? "segment segment-active" : "segment";
}

export const screensDigits6Class = computed(() => screensSegmentClass(screensDigits.get() === 6));
export const screensDigits8Class = computed(() => screensSegmentClass(screensDigits.get() === 8));
export const screensPeriod30Class = computed(() => screensSegmentClass(screensPeriod.get() === 30));
export const screensPeriod60Class = computed(() => screensSegmentClass(screensPeriod.get() === 60));

// --- Settings: secoes de backup que abrem e fecham ---

export const screensShowExport = signal<boolean>(false);
export const screensShowImport = signal<boolean>(false);

export function screensToggleExport(): void {
  screensShowExport.update((open) => !open);
}

export function screensToggleImport(): void {
  screensShowImport.update((open) => !open);
}

export const screensExportChevron = computed(() => (screensShowExport.get() ? "Hide" : "Open"));
export const screensImportChevron = computed(() => (screensShowImport.get() ? "Hide" : "Open"));

// --- visibilidade por CLASSE, nao por renderizacao condicional ---
//
// `cond ? <A/> : null` com `cond` lido de um signal no corpo do componente NAO
// re-renderiza (o compilador so torna reativa a expressao JSX que contem `.get()`).
// O idioma provado neste codigo-base — e o que o pos-poc usa em producao — e
// manter o no na arvore e alternar a CLASSE, que e relida a cada quadro.
function screensBlockClass(visible: boolean): string {
  return visible ? "screen-block" : "screen-block screen-block-hidden";
}

export const screensUriBlockClass = computed(() => screensBlockClass(screensAddMode.get() === "uri"));
export const screensManualBlockClass = computed(() => screensBlockClass(screensAddMode.get() === "manual"));
export const screensGoogleBlockClass = computed(() => screensBlockClass(screensAddMode.get() === "google"));

export const screensExportBlockClass = computed(() => screensBlockClass(screensShowExport.get()));
export const screensImportBlockClass = computed(() => screensBlockClass(screensShowImport.get()));
