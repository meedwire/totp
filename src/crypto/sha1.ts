function rotl(value: number, shift: number): number {
  return ((value << shift) | (value >>> (32 - shift))) | 0;
}

function readU32BE(bytes: number[], offset: number): number {
  return (
    ((bytes[offset] & 255) << 24) |
    ((bytes[offset + 1] & 255) << 16) |
    ((bytes[offset + 2] & 255) << 8) |
    (bytes[offset + 3] & 255)
  ) | 0;
}

function pushU32BE(output: number[], value: number): void {
  output.push((value >>> 24) & 255);
  output.push((value >>> 16) & 255);
  output.push((value >>> 8) & 255);
  output.push(value & 255);
}

export function sha1(message: number[]): number[] {
  const padded: number[] = [];
  let index = 0;

  while (index < message.length) {
    padded.push(message[index] & 255);
    index += 1;
  }

  const bitLength = message.length * 8;
  padded.push(128);
  while ((padded.length + 8) % 64 !== 0) padded.push(0);

  const highBits = (bitLength / 4294967296) | 0;
  const lowBits = bitLength >>> 0;
  pushU32BE(padded, highBits);
  pushU32BE(padded, lowBits);

  let h0 = 1732584193;
  let h1 = -271733879;
  let h2 = -1732584194;
  let h3 = 271733878;
  let h4 = -1009589776;
  const w: number[] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ];

  let block = 0;
  while (block < padded.length) {
    let i = 0;
    while (i < 16) {
      w[i] = readU32BE(padded, block + i * 4);
      i += 1;
    }
    while (i < 80) {
      w[i] = rotl((w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]) | 0, 1);
      i += 1;
    }

    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;

    i = 0;
    while (i < 80) {
      let f = 0;
      let k = 0;

      if (i < 20) {
        f = ((b & c) | (~b & d)) | 0;
        k = 1518500249;
      } else if (i < 40) {
        f = (b ^ c ^ d) | 0;
        k = 1859775393;
      } else if (i < 60) {
        f = ((b & c) | (b & d) | (c & d)) | 0;
        k = -1894007588;
      } else {
        f = (b ^ c ^ d) | 0;
        k = -899497514;
      }

      const temp = (rotl(a, 5) + f + e + k + w[i]) | 0;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = temp;
      i += 1;
    }

    h0 = (h0 + a) | 0;
    h1 = (h1 + b) | 0;
    h2 = (h2 + c) | 0;
    h3 = (h3 + d) | 0;
    h4 = (h4 + e) | 0;
    block += 64;
  }

  const digest: number[] = [];
  pushU32BE(digest, h0);
  pushU32BE(digest, h1);
  pushU32BE(digest, h2);
  pushU32BE(digest, h3);
  pushU32BE(digest, h4);
  return digest;
}
