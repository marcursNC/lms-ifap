// Lecteur SCORM isolé : une autre adresse que le LMS, aucune session d'utilisateur.
// Il ne délivre que les fichiers du paquet ouvert par un ticket valide.
import { contentType, encodeKey } from '../public/scorm-keys.mjs'

const ASSETS = ['/player.js', '/player.css', '/scorm-runtime.mjs', '/scorm-keys.mjs']
const SAFE = { 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' }
const text = (status, message) => new Response(message, { status, headers: { ...SAFE, 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' } })
const EXPIRED = 'Accès au module expiré ou refusé. Fermez le module puis relancez-le.'
const NOT_FOUND = 'Fichier introuvable dans ce module.'

// Les clés « sb_secret » ne vont que dans « apikey » ; une ancienne clé JWT va aussi dans « authorization ».
function supabase(env, path, init = {}) {
  const key = env.SUPABASE_SECRET_KEY
  const headers = { apikey: key, ...(key.startsWith('eyJ') ? { authorization: `Bearer ${key}` } : {}), ...init.headers }
  return fetch(env.SUPABASE_URL + path, { ...init, headers })
}

function page(env) {
  const html = `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lecteur de module</title><link rel="stylesheet" href="/player.css"></head>
<body data-lms="${env.LMS_ORIGIN}"><iframe id="module" title="Module de formation" allow="fullscreen" allowfullscreen></iframe>
<script type="module" src="/player.js"></script></body></html>`
  return new Response(html, { headers: { ...SAFE, 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store',
    'content-security-policy': `default-src 'self'; frame-ancestors ${env.LMS_ORIGIN}` } })
}

// Segments décodés un à un : ni remontée, ni séparateur caché.
function filePath(raw) {
  try {
    const parts = raw.split('/').map(decodeURIComponent)
    return parts.some(p => p === '' || p === '.' || p === '..' || /[/\\]/.test(p)) ? null : parts.join('/').normalize('NFC')
  } catch { return null }
}

async function file(request, env, token, raw) {
  if (!/^[0-9a-f]{64}$/.test(token)) return text(403, EXPIRED)
  const resolved = await supabase(env, '/rest/v1/rpc/scorm_resolve_ticket', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ p_token: token }) })
  if (!resolved.ok) return text(502, 'Le module est momentanément indisponible.')
  const prefix = await resolved.json()
  if (!prefix) return text(403, EXPIRED)
  const path = filePath(raw)
  if (!path) return text(404, NOT_FOUND)
  const key = `${prefix}/${encodeKey(path)}`
  const range = request.headers.get('range')
  const found = await supabase(env, `/storage/v1/object/scorm-packages/${key.split('/').map(encodeURIComponent).join('/')}`,
    range ? { headers: { range } } : {})
  if (!found.ok) return text(found.status === 416 ? 416 : 404, NOT_FOUND)
  const headers = new Headers({ ...SAFE, 'content-type': contentType(path), 'cache-control': 'private, max-age=3600',
    'content-security-policy': `frame-ancestors 'self' ${env.LMS_ORIGIN}` })
  for (const name of ['content-length', 'content-range', 'accept-ranges']) {
    const value = found.headers.get(name)
    if (value) headers.set(name, value)
  }
  return new Response(request.method === 'HEAD' ? null : found.body, { status: found.status, headers })
}

export default {
  async fetch(request, env) {
    if (!['GET', 'HEAD'].includes(request.method)) return text(405, 'Méthode non autorisée.')
    // Aucun module ne s'installe durablement dans le navigateur.
    if (request.headers.has('service-worker')) return text(403, 'Interdit.')
    const { pathname } = new URL(request.url)
    if (pathname === '/play') return page(env)
    if (ASSETS.includes(pathname)) return env.ASSETS.fetch(request)
    const match = /^\/c\/([^/]+)\/(.*)$/.exec(pathname)
    if (!match) return text(404, NOT_FOUND)
    if (!env.SUPABASE_SECRET_KEY) return text(503, 'Lecteur non configuré : la clé d’accès au stockage est absente.')
    try {
      return await file(request, env, match[1], match[2])
    } catch {
      return text(502, 'Le module est momentanément indisponible.')
    }
  }
}
