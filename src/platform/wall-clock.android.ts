// Relogio de parede no Android: `time(2)` da libc (bionic) por FFI.
// Selecionado automaticamente em `--platform=android`; ver o contrato em
// ./wall-clock.ts.
//
// POR QUE TAMBEM LIBC AQUI, E NAO JNI `System.currentTimeMillis()`: a chamada FFI
// nao depende do JNIEnv nem da thread, e o relogio e lido dentro de um timer que
// o bridge JNI bombeia. Trocar por JNI so paga se o app precisar de MILISSEGUNDO
// de verdade — e quando precisar, muda SO ESTE ARQUIVO: nenhum chamador conhece a
// plataforma.
//
// Prefixo de proposito em todo simbolo de topo: o escopo do emissor e global e
// plano entre modulos.
import { foreign, type ptr, type usize } from "native:ffi";

const __wallClockAndroid_libc = foreign.lib("c");

// `ptr<"void">`, NAO `usize`: os dois sao `number` no TS, mas `usize` num
// parametro de ponteiro da SIGSEGV no marshalling.
const __wallClockAndroid_time =
  __wallClockAndroid_libc.fn<(out: ptr<"void">) => usize>("time");

export function wallClockSeconds(): number {
  return __wallClockAndroid_time(0);
}

// Segundos * 1000: `time()` nao tem resolucao de ms. Ver a nota acima sobre JNI.
export function wallClockMs(): number {
  return __wallClockAndroid_time(0) * 1000;
}
