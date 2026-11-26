// Noms de fichiers dans le stockage. Partagé par l'import (LMS), le lecteur et son navigateur.
// Le stockage refuse accents et caractères spéciaux : on les écrit « !XX » (octet en hexadécimal).
export const encodeKey = path => path.replace(/[^A-Za-z0-9_.\- ()/]/gu, c =>
  [...new TextEncoder().encode(c)].map(b => '!' + b.toString(16).toUpperCase().padStart(2, '0')).join(''))
export const decodeKey = key => key.replace(/(![0-9A-F]{2})+/g, run =>
  new TextDecoder().decode(Uint8Array.from(run.slice(1).split('!'), h => parseInt(h, 16))))

// Adresse, sur le lecteur, du fichier de démarrage enregistré (« chemin encodé » puis « ?… » éventuel).
export function moduleUrl(token, launch) {
  const cut = launch.search(/[?#]/)
  const path = decodeKey(cut < 0 ? launch : launch.slice(0, cut))
  return `/c/${token}/${path.split('/').map(encodeURIComponent).join('/')}${cut < 0 ? '' : launch.slice(cut)}`
}

const TYPES = {
  html: 'text/html; charset=utf-8', htm: 'text/html; charset=utf-8', xhtml: 'application/xhtml+xml',
  js: 'text/javascript; charset=utf-8', mjs: 'text/javascript; charset=utf-8', css: 'text/css; charset=utf-8',
  json: 'application/json', xml: 'application/xml', txt: 'text/plain; charset=utf-8', vtt: 'text/vtt', srt: 'text/plain',
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', svg: 'image/svg+xml', ico: 'image/x-icon',
  mp3: 'audio/mpeg', ogg: 'audio/ogg', wav: 'audio/wav', m4a: 'audio/mp4', mp4: 'video/mp4', webm: 'video/webm',
  woff: 'font/woff', woff2: 'font/woff2', ttf: 'font/ttf', otf: 'font/otf', eot: 'application/vnd.ms-fontobject',
  pdf: 'application/pdf', wasm: 'application/wasm', swf: 'application/octet-stream'
}
export const contentType = path => TYPES[path.slice(path.lastIndexOf('.') + 1).toLowerCase()] || 'application/octet-stream'
