import { playQuarkSourceEpisode } from "./cloud-pan.mjs";
import { GatewayError } from "./errors.mjs";

function invalidEpisode() {
  throw new GatewayError("INVALID_CLOUD_EPISODE", "夸克剧集信息无效，请重新打开资源详情", 400);
}

function field(value, maximum) {
  if (typeof value !== "string" || !value.trim() || value.length > maximum || /[\x00-\x1f\x7f]/.test(value)) {
    invalidEpisode();
  }
  return value;
}

function decodeCatVodEpisode(id) {
  if (typeof id !== "string" || id.length > 4096 || !/^[A-Za-z0-9+/_-]+={0,2}(?![\s\S])/.test(id)) return null;
  let episode;
  try { episode = JSON.parse(Buffer.from(id, "base64").toString("utf8")); } catch { return null; }
  return episode && typeof episode === "object" && !Array.isArray(episode) ? episode : null;
}

// Decode the modern CatVod cloud contract without executing provider code.
// Account credentials never become part of this public episode descriptor.
export function parseCatVodQuarkEpisode(id) {
  const episode = decodeCatVodEpisode(id);
  if (episode?.providerId !== "quark") return null;
  let token;
  try { token = JSON.parse(episode.playToken); } catch { invalidEpisode(); }
  if (!token || typeof token !== "object" || Array.isArray(token)) invalidEpisode();
  const file = {
    provider: "quark",
    shareId: field(token.shareId, 256),
    stoken: field(token.stoken, 8192),
    fileId: field(token.fid, 256),
    fileToken: field(token.shareFidToken, 8192),
    fileName: field(token.fileName, 1024)
  };
  if (episode.shareId !== file.shareId || episode.fileId !== file.fileId) invalidEpisode();
  const mode = episode.mode || "original";
  if (!["original", "speed"].includes(mode)) invalidEpisode();
  return { file, mode };
}

export async function resolveCatVodCloudPlayer(argumentsValue, credentials, fetchValue) {
  if (decodeCatVodEpisode(argumentsValue.id)?.providerId === "baidu") {
    throw new GatewayError("CLOUD_PROVIDER_UNSUPPORTED",
      "TVBox 暂未接入百度网盘播放，请选择夸克或普通影视线路；夸克 Cookie 不能用于百度网盘", 422);
  }
  const episode = parseCatVodQuarkEpisode(argumentsValue.id);
  if (!episode) return null;
  if (!credentials.quarkCookie) {
    throw new GatewayError("CLOUD_AUTH_REQUIRED", "请先在 TVBox“设置 → 网盘设置”中保存夸克 Cookie", 401);
  }
  // Prefer the source's requested mode. Original-file size restrictions may
  // use a transcode with a UI notice. Credentials stay in the trusted parent.
  try {
    return await playQuarkSourceEpisode(episode.file, credentials, fetchValue, episode.mode === "original");
  } catch (error) {
    const authentication = error?.code === "CLOUD_AUTH_REQUIRED";
    throw new GatewayError(authentication ? "CLOUD_AUTH_REQUIRED" : "CLOUD_PLAYBACK_FAILED",
      authentication ? "夸克登录已失效，请在 TVBox 网盘设置中更新 Cookie"
        : "夸克播放地址解析失败，请重新打开资源详情或稍后重试", authentication ? 401 : 502);
  }
}
