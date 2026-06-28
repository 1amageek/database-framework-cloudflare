export function compareBytes(lhs, rhs) {
  const count = Math.min(lhs.length, rhs.length);
  for (let index = 0; index < count; index += 1) {
    if (lhs[index] !== rhs[index]) {
      return lhs[index] < rhs[index] ? -1 : 1;
    }
  }
  if (lhs.length === rhs.length) {
    return 0;
  }
  return lhs.length < rhs.length ? -1 : 1;
}
