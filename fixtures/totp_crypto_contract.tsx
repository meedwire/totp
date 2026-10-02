import "native:string";
import { console } from "native:console";
import {
  DEMO_ACCOUNTS,
  getAccountInitials,
  getAccountTone,
  getTotpSnapshot,
  type TotpAccount,
} from "../src/domain/accounts";
import { generateHOTP, generateTOTP } from "../src/crypto/totp";

function expectString(actual: string, expected: string, label: string): void {
  if (actual !== expected) throw new Error(label + ": expected " + expected + ", got " + actual);
}

function expectNumber(actual: number, expected: number, label: string): void {
  if (actual !== expected) throw new Error(label + ": expected number mismatch");
}

const account: TotpAccount = {
  id: "rfc-vector",
  issuer: "RFC",
  accountName: "sha1@example.com",
  secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
  digits: 8,
  period: 30,
  algorithm: "SHA1",
};

const snapshot = getTotpSnapshot(account, 45000);
expectString(snapshot.code, "94287082", "rfc code");
expectString(snapshot.formattedCode, "9428 7082", "rfc formatted code");
expectNumber(snapshot.counter, 1, "rfc counter");
expectNumber(snapshot.remainingSeconds, 15, "rfc remaining seconds");
// A barra do RN e continua; o porte arredonda para degraus de 2px sobre 40px de
// trilha. 15s de 30 -> metade -> w20. Urgencia so abaixo de 5s, entao aqui e vazia.
expectString(snapshot.progressClass, "timer-fill-w20", "rfc progress class");
expectString(snapshot.urgencyClass, "", "rfc urgency class");

const demo = DEMO_ACCOUNTS[0];
expectString(demo.id, "demo-rfc-sha1", "demo id");
// RN (TOTPCode.getInitials): UMA letra, a inicial do issuer em maiuscula.
expectString(getAccountInitials(demo), "R", "demo initials");
if (getAccountTone(demo).length === 0) throw new Error("demo tone missing");
const demoSnapshot = getTotpSnapshot(demo, 45000);
expectString(demoSnapshot.code, "94287082", "demo code");
expectNumber(demoSnapshot.remainingSeconds, 15, "demo remaining seconds");

// ATE 2026-08-26 ESTE GATE ERA TAUTOLOGICO: generateHOTP tinha um atalho
// `if (secret === "GEZDGNBVGY3TQOJQ..." && counter === 1) return "287082"`, entao as
// assercoes acima nunca exercitaram base32/sha1/hmac. O atalho saiu junto com o clamp
// de 6 digitos; daqui para baixo sao os vetores publicados, com counters variados.

// RFC 4226 Apendice D — HOTP de 6 digitos, segredo ASCII "12345678901234567890".
const RFC_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
expectString(generateHOTP(RFC_SECRET, 0, 6), "755224", "hotp c=0");
expectString(generateHOTP(RFC_SECRET, 1, 6), "287082", "hotp c=1");
expectString(generateHOTP(RFC_SECRET, 2, 6), "359152", "hotp c=2");
expectString(generateHOTP(RFC_SECRET, 3, 6), "969429", "hotp c=3");
expectString(generateHOTP(RFC_SECRET, 9, 6), "520489", "hotp c=9");

// RFC 6238 — TOTP de 8 digitos, SHA1. O ultimo vetor (T=20000000000s) passa de 2^31
// e so fecha porque getTotpCounter usa floorDiv em vez de `|0`.
expectString(generateTOTP(RFC_SECRET, 59000, 8, 30), "94287082", "totp T=59");
expectString(generateTOTP(RFC_SECRET, 1111111109000, 8, 30), "07081804", "totp T=1111111109");
expectString(generateTOTP(RFC_SECRET, 1111111111000, 8, 30), "14050471", "totp T=1111111111");
expectString(generateTOTP(RFC_SECRET, 1234567890000, 8, 30), "89005924", "totp T=1234567890");
expectString(generateTOTP(RFC_SECRET, 2000000000000, 8, 30), "69279037", "totp T=2000000000");
expectString(generateTOTP(RFC_SECRET, 20000000000000, 8, 30), "65353130", "totp T=20000000000");

// Segundo segredo, para o gate nao depender de um unico vetor.
expectString(generateTOTP("JBSWY3DPEHPK3PXP", 45000, 6, 30), "996554", "totp segredo 2");

console.log("TOTP_CRYPTO_CONTRACT_DONE");
