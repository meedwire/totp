import { sha1 } from "./sha1";

export function hmacSha1(key: number[], message: number[]): number[] {
  const blockSize = 64;
  let processedKey = key;

  if (processedKey.length > blockSize) processedKey = sha1(processedKey);

  const inner: number[] = [];
  const outer: number[] = [];
  let index = 0;

  while (index < blockSize) {
    let byte = 0;
    if (index < processedKey.length) byte = processedKey[index] & 255;
    inner.push(byte ^ 54);
    outer.push(byte ^ 92);
    index += 1;
  }

  index = 0;
  while (index < message.length) {
    inner.push(message[index] & 255);
    index += 1;
  }

  const innerHash = sha1(inner);
  index = 0;
  while (index < innerHash.length) {
    outer.push(innerHash[index]);
    index += 1;
  }

  return sha1(outer);
}
