export function compareBytes(lhs: Uint8Array, rhs: Uint8Array): number {
  const count = Math.min(lhs.length, rhs.length);
  for (let index = 0; index < count; index += 1) {
    const lhsByte = lhs[index] ?? 0;
    const rhsByte = rhs[index] ?? 0;
    if (lhsByte !== rhsByte) {
      return lhsByte < rhsByte ? -1 : 1;
    }
  }
  if (lhs.length === rhs.length) {
    return 0;
  }
  return lhs.length < rhs.length ? -1 : 1;
}
