import "native:string";
import { base32Decode } from "./base32";
import { hmacSha1 } from "./hmac-sha1";

function pow10(digits: number): number {
  let value = 1;
  let index = 0;
  while (index < digits) {
    value *= 10;
    index += 1;
  }
  return value;
}

function zeroPad(value: number, digits: number): string {
  let text = "" + value;
  while (text.length < digits) text = "0" + text;
  return text;
}

function counterBytes(counter: number): number[] {
  const bytes: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  let value = counter;
  let index = 7;

  while (index >= 0) {
    bytes[index] = value & 255;
    value = (value / 256) | 0;
    index -= 1;
  }

  return bytes;
}

export function generateHOTP(secret: string, counter: number, digits: number): string {
  const key = base32Decode(secret);
  const digest = hmacSha1(key, counterBytes(counter));
  const offset = digest[19] & 15;
  const binary =
    (((digest[offset] & 127) << 24) |
      ((digest[offset + 1] & 255) << 16) |
      ((digest[offset + 2] & 255) << 8) |
      (digest[offset + 3] & 255)) |
    0;

  return zeroPad(binary % pow10(digits), digits);
}

// `|0` trunca para int32 e o counter TOTP viraria negativo a partir de 2038-01-19
// (e ja e negativo com epoch em ms). Math.floor nao existe no ntsc; esta identidade
// e exata para inteiros positivos e sobrevive a 2^31.
function floorDiv(value: number, divisor: number): number {
  return (value - (value % divisor)) / divisor;
}

export function getTotpCounter(nowMs: number, period: number): number {
  return floorDiv(floorDiv(nowMs, 1000), period);
}

export function generateTOTP(secret: string, nowMs: number, digits: number, period: number): string {
  return generateHOTP(secret, getTotpCounter(nowMs, period), digits);
}
