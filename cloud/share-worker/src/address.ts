// What an address is counted as. One IPv6 customer holds a whole /64 (often more), so an IPv6 address counts
// as its first four groups; an IPv4 address counts as itself.
export function clientKey(address: string): string {
  if (!address.includes(":")) return address;
  const [head, tail = ""] = address.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = address.includes("::")
    ? [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill("0"), ...right]
    : left;
  return groups
    .slice(0, 4)
    .map((group) => (Number.parseInt(group, 16) || 0).toString(16))
    .join(":");
}
