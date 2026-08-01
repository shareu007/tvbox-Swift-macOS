import { GatewayError } from "./errors.mjs";

const ACTIONS = new Set(["home", "category", "detail", "search", "player"]);
const CATVOD_API = /^\/spider\/[A-Za-z0-9_-]+\/\d{1,2}$/;

function requiredString(value, name, maximum = 4096) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new GatewayError("INVALID_REQUEST", `${name} must be a non-empty string`, 400);
  }
  if (value.length > maximum) {
    throw new GatewayError("INVALID_REQUEST", `${name} is too long`, 400);
  }
  return value;
}

function optionalString(value, name, maximum = 256 * 1024) {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string" || value.length > maximum) {
    throw new GatewayError("INVALID_REQUEST", `${name} must be a string`, 400);
  }
  return value;
}

export function validateInvokeRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new GatewayError("INVALID_REQUEST", "Request body must be a JSON object", 400);
  }
  if (body.version !== 1) throw new GatewayError("UNSUPPORTED_VERSION", "Only protocol version 1 is supported", 400);
  if (!ACTIONS.has(body.action)) throw new GatewayError("UNSUPPORTED_ACTION", "Unsupported Spider action", 400);
  if (!body.site || typeof body.site !== "object" || Array.isArray(body.site)) {
    throw new GatewayError("INVALID_REQUEST", "site must be an object", 400);
  }
  const site = {
    key: requiredString(body.site.key, "site.key", 256),
    api: requiredString(body.site.api, "site.api", 512),
    jar: requiredString(body.site.jar, "site.jar", 8192),
    ext: optionalString(body.site.ext, "site.ext"),
    quickSearch: body.site.quickSearch === true
  };
  if (!site.api.startsWith("csp_") && !CATVOD_API.test(site.api)) {
    throw new GatewayError("UNSUPPORTED_API", "site.api must be csp_* or a valid /spider/<key>/<type> path", 400);
  }
  const args = body.arguments;
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    throw new GatewayError("INVALID_REQUEST", "arguments must be an object", 400);
  }
  validateArguments(body.action, args);
  return { action: body.action, site, arguments: args };
}

export function validateCatalogRequest(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new GatewayError("INVALID_REQUEST", "Request body must be a JSON object", 400);
  }
  return { bundle: requiredString(body.bundle, "bundle", 8192) };
}

function validateArguments(action, args) {
  switch (action) {
    case "home":
      if (typeof args.filter !== "boolean") invalid("arguments.filter must be a boolean");
      break;
    case "category":
      requiredString(args.tid, "arguments.tid");
      requiredString(args.page, "arguments.page", 32);
      if (typeof args.filter !== "boolean") invalid("arguments.filter must be a boolean");
      if (!args.extend || typeof args.extend !== "object" || Array.isArray(args.extend)) invalid("arguments.extend must be an object");
      break;
    case "detail":
      if (!Array.isArray(args.ids) || args.ids.length === 0 || args.ids.length > 100 || args.ids.some((id) => typeof id !== "string" || id === "")) {
        invalid("arguments.ids must be a non-empty string array");
      }
      break;
    case "search":
      requiredString(args.keyword, "arguments.keyword");
      requiredString(args.page, "arguments.page", 32);
      if (typeof args.quick !== "boolean") invalid("arguments.quick must be a boolean");
      break;
    case "player":
      if (typeof args.flag !== "string") invalid("arguments.flag must be a string");
      requiredString(args.id, "arguments.id");
      if (!Array.isArray(args.vipFlags) || args.vipFlags.some((flag) => typeof flag !== "string")) invalid("arguments.vipFlags must be a string array");
      break;
  }
}

function invalid(message) {
  throw new GatewayError("INVALID_REQUEST", message, 400);
}
