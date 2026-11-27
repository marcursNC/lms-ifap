import test from 'node:test'
import assert from 'node:assert/strict'
import worker from '../player/src/worker.mjs'
import { encodeKey } from '../player/public/scorm-keys.mjs'

const TOKEN = 'a'.repeat(64), SECRET = 'sb_secret_FICTIF', LMS = 'https://lms.test'
const PREFIX = 'course-1/package-1'
const stored = new Map([[`${PREFIX}/index.html`, '<h1>module</h1>'], [`${PREFIX}/${encodeKey('images/été à.png')}`, 'PNG'], ['course-2/autre/secret.html', 'SECRET']])
const calls = []
const env = {
  SUPABASE_URL: 'https://db.test', SUPABASE_SECRET_KEY: SECRET, LMS_ORIGIN: LMS,
  ASSETS: { fetch: async req => new Response('// ' + new URL(req.url).pathname, { headers: { 'content-type': 'text/javascript' } }) }
}
globalThis.fetch = async (url, init = {}) => {
  const u = new URL(url); calls.push({ url: String(url), headers: new Headers(init.headers), body: init.body })
  if (u.pathname === '/rest/v1/rpc/scorm_resolve_ticket') return Response.json(JSON.parse(init.body).p_token === TOKEN ? PREFIX : null)
  const key = decodeURIComponent(u.pathname.replace('/storage/v1/object/scorm-packages/', ''))
  if (!stored.has(key)) return new Response('{"error":"not found"}', { status: 400 })
  const range = new Headers(init.headers).get('range')
  return range ? new Response('NG', { status: 206, headers: { 'content-range': 'bytes 1-2/3' } }) : new Response(stored.get(key), { headers: { 'content-type': 'text/plain' } })
}
const get = (path, init) => worker.fetch(new Request('https://lecteur.test' + path, init), env)

test('ticket valide : fichier, type et protections', async () => {
  const r = await get(`/c/${TOKEN}/index.html?v=2`)
  assert.equal(r.status, 200)
  assert.equal(await r.text(), '<h1>module</h1>')
  assert.equal(r.headers.get('content-type'), 'text/html; charset=utf-8')
  assert.equal(r.headers.get('x-content-type-options'), 'nosniff')
  assert.equal(r.headers.get('referrer-policy'), 'no-referrer')
  assert.match(r.headers.get('cache-control'), /private/)
  assert.equal(r.headers.get('content-security-policy'), `frame-ancestors 'self' ${LMS}`)
})
test('nom accentué retrouvé', async () => {
  const r = await get(`/c/${TOKEN}/images/${encodeURIComponent('été à.png')}`)
  assert.equal(r.status, 200)
  assert.equal(r.headers.get('content-type'), 'image/png')
})
test('lecture partielle (vidéo)', async () => {
  const r = await get(`/c/${TOKEN}/index.html`, { headers: { range: 'bytes=1-2' } })
  assert.equal(r.status, 206)
  assert.equal(r.headers.get('content-range'), 'bytes 1-2/3')
})
test('ticket inconnu ou mal formé', async () => {
  for (const t of ['b'.repeat(64), 'abc']) {
    const r = await get(`/c/${t}/index.html`)
    assert.equal(r.status, 403)
    assert.match(await r.text(), /expiré/)
  }
})
test('aucune sortie du paquet', async () => {
  for (const path of ['..%2f..%2fcourse-2%2fautre%2fsecret.html', '%2e%2e/%2e%2e/course-2/autre/secret.html',
    '%252e%252e/course-2/autre/secret.html', 'a%5c..%5csecret', '', 'a//b', 'course-2%2fautre%2fsecret.html']) {
    const r = await get(`/c/${TOKEN}/${path}`)
    assert.ok([403, 404].includes(r.status), `${path} → ${r.status}`)
    assert.doesNotMatch(await r.text(), /SECRET/)
  }
  // Toute lecture reste sous le dossier du paquet, après normalisation de l’adresse.
  for (const c of calls.filter(c => c.url.includes('/storage/'))) assert.ok(new URL(c.url).pathname.startsWith(`/storage/v1/object/scorm-packages/${PREFIX}/`), c.url)
})
test('pas de service worker, pas d’écriture', async () => {
  assert.equal((await get(`/c/${TOKEN}/index.html`, { headers: { 'service-worker': 'script' } })).status, 403)
  assert.equal((await get(`/c/${TOKEN}/index.html`, { method: 'POST' })).status, 405)
  assert.equal((await get('/autre')).status, 404)
})
test('page du lecteur : réservée au LMS, scripts autorisés', async () => {
  const r = await get('/play')
  assert.equal(r.status, 200)
  const html = await r.text()
  assert.match(html, new RegExp(`data-lms="${LMS}"`))
  assert.match(r.headers.get('content-security-policy'), new RegExp(`frame-ancestors ${LMS}`))
  assert.match(r.headers.get('content-security-policy'), /default-src 'self'/)
  for (const f of ['/player.js', '/scorm-runtime.mjs']) assert.equal((await get(f)).status, 200)
})
test('la clé secrète ne part que vers la base, jamais dans une réponse', async () => {
  calls.length = 0
  const r = await get(`/c/${TOKEN}/index.html`, { headers: { 'user-agent': 'Mozilla/5.0', cookie: 'a=1' } })
  const seen = JSON.stringify([...r.headers]) + await r.text()
  assert.doesNotMatch(seen, /sb_secret/)
  for (const c of calls) {
    assert.ok(c.url.startsWith('https://db.test/'))
    assert.equal(c.headers.get('apikey'), SECRET)
    assert.equal(c.headers.get('authorization'), null)
    assert.equal(c.headers.get('cookie'), null)
    assert.equal(c.headers.get('user-agent'), null)
  }
})
test('lecteur mal configuré : message clair', async () => {
  const r = await worker.fetch(new Request(`https://lecteur.test/c/${TOKEN}/index.html`), { ...env, SUPABASE_SECRET_KEY: '' })
  assert.equal(r.status, 503)
})
test('adresse en caractères décomposés : même fichier', async () => {
  const r = await get(`/c/${TOKEN}/images/${encodeURIComponent('été à.png'.normalize('NFD'))}`)
  assert.equal(r.status, 200)
})
