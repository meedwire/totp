import "native:string";
import { generateTOTP, getTotpCounter } from "../crypto/totp";

export type TotpAccount = {
  id: string;
  issuer: string;
  accountName: string;
  secret: string;
  digits: number;
  period: number;
  algorithm: string;
};

export type TotpSnapshot = {
  code: string;
  formattedCode: string;
  counter: number;
  remainingSeconds: number;
  progressClass: string;
  urgencyClass: string;
};

export const DEMO_ACCOUNTS: TotpAccount[] = [
  {
    id: "demo-rfc-sha1",
    issuer: "RFC 6238",
    accountName: "demo@example.com",
    secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
    digits: 8,
    period: 30,
    algorithm: "SHA1",
  },
  {
    id: "demo-work",
    issuer: "Meedwire",
    accountName: "admin@meedwire.local",
    secret: "JBSWY3DPEHPK3PXP",
    digits: 6,
    period: 30,
    algorithm: "SHA1",
  },
  {
    id: "demo-cloud",
    issuer: "Cloud Console",
    accountName: "ops@meedwire.local",
    secret: "KRSXG5DSNFXGOIDJ",
    digits: 6,
    period: 30,
    algorithm: "SHA1",
  },
];

// O global `String` nao existe no ntsc (nem Math/parseInt): sem String.fromCharCode,
// a maiuscula sai de um lookup. Nome prefixado porque const de topo compartilha um
// escopo global PLANO entre modulos e um homonimo aliasa em silencio.
const ACCOUNTS_UPPER_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

// RN (TOTPCode.getInitials): UMA letra, a inicial do issuer em maiuscula.
export function getAccountInitials(account: TotpAccount): string {
  if (account.issuer.length === 0) return "?";
  const code = account.issuer.charCodeAt(0);
  if (code >= 97 && code <= 122) return ACCOUNTS_UPPER_ALPHA.charAt(code - 97);
  return account.issuer.charAt(0);
}

// RN (TOTPCode.getAvatarColor): cinco cinzas escolhidos por issuer.charCodeAt(0) % 5.
export function getAccountTone(account: TotpAccount): string {
  if (account.issuer.length === 0) return "1";
  const tone = account.issuer.charCodeAt(0) % 5;
  if (tone === 0) return "1";
  if (tone === 1) return "2";
  if (tone === 2) return "3";
  if (tone === 3) return "4";
  return "5";
}

function formatCode(code: string): string {
  if (code.length === 8) {
    return (
      code.charAt(0) +
      code.charAt(1) +
      code.charAt(2) +
      code.charAt(3) +
      " " +
      code.charAt(4) +
      code.charAt(5) +
      code.charAt(6) +
      code.charAt(7)
    );
  }

  if (code.length === 6) {
    return (
      code.charAt(0) +
      code.charAt(1) +
      code.charAt(2) +
      " " +
      code.charAt(3) +
      code.charAt(4) +
      code.charAt(5)
    );
  }

  return code;
}

// A barra do RN e continua (width: progress*100%). Sem prop `style` inline, o porte
// arredonda para degraus de 2px sobre a trilha de 40px -> classes .w0 .. .w40.
function getProgressClass(remainingSeconds: number, period: number): string {
  if (period <= 0) return "timer-fill-w40";
  let filled = ((remainingSeconds * 40) / period) | 0;
  if (filled < 0) filled = 0;
  if (filled > 40) filled = 40;
  const snapped = (filled / 2) | 0;
  return "timer-fill-w" + snapped * 2;
}

// RN: isUrgent = remaining <= 5 pinta codigo, barra e contador de vermelho.
function getUrgencyClass(remainingSeconds: number): string {
  return remainingSeconds <= 5 ? "urgent" : "";
}

export function getTotpSnapshot(account: TotpAccount, nowMs: number): TotpSnapshot {
  const periodMs = account.period * 1000;
  const counter = getTotpCounter(nowMs, account.period);
  const validFromMs = counter * periodMs;
  const validUntilMs = validFromMs + periodMs;
  const remainingMs = validUntilMs - nowMs;
  let remainingSeconds = ((remainingMs + 999) / 1000) | 0;

  if (remainingSeconds < 0) remainingSeconds = 0;
  if (remainingSeconds > account.period) remainingSeconds = account.period;

  const code = generateTOTP(account.secret, nowMs, account.digits, account.period);

  return {
    code,
    formattedCode: formatCode(code),
    counter,
    remainingSeconds,
    progressClass: getProgressClass(remainingSeconds, account.period),
    urgencyClass: getUrgencyClass(remainingSeconds),
  };
}
