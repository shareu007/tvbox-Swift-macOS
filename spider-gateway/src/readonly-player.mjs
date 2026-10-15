const cloudRoutes = new Set([
  '/spider/cloudpan/3', '/spider/pansearch/3', '/spider/mypan/3', '/spider/wogg/3',
  '/spider/duoduo/3', '/spider/huban/3', '/spider/muou/3', '/spider/kuaiying/3',
  '/spider/shandian/3', '/spider/labi/3', '/spider/huajuan/3', '/spider/guanying/3',
  '/spider/qwmkv/3', '/spider/libvio/3', '/spider/pianku/3', '/spider/woniu4k/3',
  '/spider/zhinan4k/3', '/spider/jutou/3', '/spider/pan123ziyuan/3', '/spider/yidong4k/3'
]);

// Availability checks must never invoke account-backed transfers, including
// cloud episodes appearing under an otherwise ordinary streaming provider.
export function requiresPlaybackConfirmation(site, args) {
  if (cloudRoutes.has(site.api)) return true;
  if (/quark|夸克|aliyun|alipan|阿里|baidu|百度|网盘|天翼|(?:^|\W)(?:uc|115|123)(?:\W|$)/i.test(args.flag || '')) return true;
  const id = args.id || '';
  if (/^(?:quark|ali|alipan|uc|baidu|115|cloud):/i.test(id)) return true;
  if (id.length <= 4096 && /^[A-Za-z0-9+/_-]+={0,2}$/.test(id)) {
    try {
      const value = JSON.parse(Buffer.from(id, 'base64').toString('utf8'));
      if (typeof value?.providerId === 'string' && value.providerId) return true;
    } catch { /* Ordinary opaque episode ID. */ }
  }
  try {
    const host = new URL(id).hostname.toLowerCase();
    return ['pan.quark.cn', 'pan.baidu.com', 'alipan.com', 'aliyundrive.com',
      'drive.uc.cn', 'cloud.189.cn', '115.com', '123pan.com', '123865.com']
      .some(domain => host === domain || host.endsWith(`.${domain}`));
  } catch { return false; }
}
