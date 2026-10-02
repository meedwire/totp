import "native:string";

const BASE32_A = 65;
const BASE32_Z = 90;
const BASE32_LOWER_A = 97;
const BASE32_LOWER_Z = 122;
const BASE32_TWO = 50;
const BASE32_SEVEN = 55;

function base32Value(code: number): number {
  if (code >= BASE32_A && code <= BASE32_Z) return code - BASE32_A;
  if (code >= BASE32_LOWER_A && code <= BASE32_LOWER_Z) return code - BASE32_LOWER_A;
  if (code >= BASE32_TWO && code <= BASE32_SEVEN) return 26 + code - BASE32_TWO;
  return -1;
}

function isIgnoredBase32Code(code: number): boolean {
  return code === 32 || code === 9 || code === 10 || code === 13 || code === 61;
}

export function base32Decode(input: string): number[] {
  const bytes: number[] = [];
  let buffer = 0;
  let bitsLeft = 0;
  let index = 0;

  while (index < input.length) {
    const code = input.charCodeAt(index);
    const value = base32Value(code);

    if (value >= 0) {
      buffer = (buffer << 5) | value;
      bitsLeft += 5;

      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        bytes.push((buffer >>> bitsLeft) & 255);
      }
    } else if (!isIgnoredBase32Code(code)) {
      throw new Error("invalid base32 secret");
    }

    index += 1;
  }

  return bytes;
}

export function isValidBase32(input: string): boolean {
  let found = false;
  let index = 0;

  while (index < input.length) {
    const code = input.charCodeAt(index);
    if (base32Value(code) >= 0) found = true;
    else if (!isIgnoredBase32Code(code)) return false;
    index += 1;
  }

  return found;
}
