import dns from "node:dns/promises";
import net from "node:net";
import { GatewayError } from "./errors.mjs";

const CHECKSUM_PATTERN = /;(md5|sha256);([a-fA-F0-9]+)$/i;

export function parseJarReference(value) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new GatewayError("MISSING_JAR", "site.jar is required", 400);
  }

  const trimmed = value.trim();
  const match = trimmed.match(CHECKSUM_PATTERN);
  const rawURL = match ? trimmed.slice(0, match.index) : trimmed;
  let url;
  try {
    url = new URL(rawURL);
  } catch {
    throw new GatewayError("INVALID_JAR_URL", "site.jar must be an HTTP or HTTPS URL", 400);
  }

  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) {
    throw new GatewayError("INVALID_JAR_URL", "site.jar must be an HTTP or HTTPS URL without credentials", 400);
  }
  url.hash = "";

  const checksum = match
    ? { algorithm: match[1].toLowerCase(), value: match[2].toLowerCase() }
    : null;
  if (checksum && checksum.value.length !== (checksum.algorithm === "md5" ? 32 : 64)) {
    throw new GatewayError("INVALID_JAR_CHECKSUM", `Invalid ${checksum.algorithm} checksum`, 400);
  }
  return { url, checksum };
}

export function hostMatchesAllowlist(hostname, allowlist) {
  if (allowlist.length === 0) return true;
  const host = hostname.toLowerCase();
  return allowlist.some((entry) => {
    if (entry.startsWith("*.")) {
      const suffix = entry.slice(1);
      return host.endsWith(suffix) && host.length > suffix.length;
    }
    return host === entry;
  });
}

export function isPrivateAddress(address) {
  const normalized = String(address || "").toLowerCase().split("%")[0];
  const isPrivateIPv4 = (value) => {
    if (net.isIP(value) !== 4) return false;
    const parts = value.split(".").map(Number);
    return parts[0] === 0
      || parts[0] === 10
      || parts[0] === 127
      || (parts[0] === 169 && parts[1] === 254)
      || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)
      || (parts[0] === 192 && parts[1] === 168)
      || (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127)
      || parts[0] >= 224;
  };
  if (isPrivateIPv4(normalized)) return true;
  if (net.isIP(normalized) !== 6) return false;
  if (normalized === "::1" || normalized === "::") return true;

  // IPv4-mapped IPv6 may be emitted in dotted or hexadecimal form.
  const dotted = normalized.match(/(?:^|:)(\d{1,3}(?:\.\d{1,3}){3})$/)?.[1];
  if (dotted && isPrivateIPv4(dotted)) return true;
  const mapped = normalized.match(/(?:^|:)ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
  if (mapped) {
    const high = Number.parseInt(mapped[1], 16);
    const low = Number.parseInt(mapped[2], 16);
    const ipv4 = `${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`;
    if (isPrivateIPv4(ipv4)) return true;
  }

  const first = Number.parseInt(normalized.split(":")[0] || "0", 16);
  // fe80::/10 link-local, fc00::/7 unique-local, ff00::/8 multicast.
  return (first & 0xffc0) === 0xfe80
    || (first & 0xfe00) === 0xfc00
    || (first & 0xff00) === 0xff00;
}

export async function validateJarDestination(url, options) {
  if (!hostMatchesAllowlist(url.hostname, options.allowedHosts)) {
    throw new GatewayError("JAR_HOST_NOT_ALLOWED", "The JAR host is not allowed", 403);
  }
  if (options.allowPrivateNetwork) return;

  let addresses;
  try {
    addresses = await dns.lookup(url.hostname, { all: true, verbatim: true });
  } catch {
    throw new GatewayError("JAR_DNS_FAILED", "Unable to resolve the JAR host", 400);
  }
  if (addresses.length === 0 || addresses.some(({ address }) => isPrivateAddress(address))) {
    throw new GatewayError("JAR_PRIVATE_ADDRESS", "JAR downloads from private networks are blocked", 403);
  }
}
