import test from 'node:test'
import assert from 'node:assert/strict'
import { zipSync, strToU8 } from 'fflate'
import { importPackage, discardPackage, cleanOrphanPackages } from '../lib/scorm-import.mjs'

const manifest = `<?xml version="1.0"?><manifest identifier="M"><metadata><schemaversion>1.2</schemaversion></metadata>
<organizations default="O"><organization identifier="O"><title>T</title><item identifier="I" identifierref="R"/></organization></organizations>
<resources><resource identifier="R" href="début.html"/></resources></manifest>`
const zip = (files = { 'imsmanifest.xml': strToU8(manifest), 'début.html': strToU8('x'), 'a/b.js': strToU8('y') }) => {
  const bytes = zipSync(files)
  return { name: 'm.zip', size: bytes.length, arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length) }
}
function fake({ failUpload, failFinalize, failRemove } = {}) {
  const calls = [], objects = new Set()
  return {
    calls, objects,
    rpc: async (name, args) => {
      calls.push([name, args])
      if (name === 'scorm_register_package') return { data: 'pk', error: null }
      if (name === 'scorm_finalize_package') return failFinalize ? { error: { code: 'P0001', message: 'Envoi incomplet : 2 fichier(s) sur 3' } } : { data: 'res', error: null }
      return { data: null, error: null }
    },
    storage: { from: bucket => ({
      upload: async (path, body, options) => {
        assert.equal(bucket, 'scorm-packages')
        if (failUpload && path.endsWith(failUpload)) return { error: { message: 'Failed to fetch' } }
        objects.add(path); calls.push(['upload', path, options.contentType, options.upsert]); return { error: null }
      },
      remove: async paths => { calls.push(['remove', paths]); if (failRemove) return { error: { message: 'x' } }; paths.forEach(p => objects.delete(p)); return { data: paths.map(name => ({ name })), error: null } },
      list: async (folder, { offset }) => {
        const names = new Map()
        for (const o of objects) if (o.startsWith(folder + '/')) { const [head, ...rest] = o.slice(folder.length + 1).split('/'); names.set(head, rest.length ? null : 'id') }
        return { data: offset ? [] : [...names].map(([name, id]) => ({ name, id })), error: null }
      }
    }) }
  }
}
const args = { courseId: 'co', moduleId: 'mo', title: ' Module ' }

test('succès : enregistrement, envois, finalisation', async () => {
  const s = fake(), progress = []
  const r = await importPackage(s, { ...args, file: zip() }, (done, total) => progress.push([done, total]))
  assert.deepEqual(r, { error: null, resourceId: 'res' })
  assert.deepEqual(s.calls[0], ['scorm_register_package', { p_course: 'co', p_module: 'mo', p_title: 'Module', p_launch: 'd!C3!A9but.html', p_mastery: null, p_files: 3, p_bytes: Buffer.byteLength(manifest) + 2 }])
  assert.deepEqual([...s.objects].sort(), ['co/pk/a/b.js', 'co/pk/d!C3!A9but.html', 'co/pk/imsmanifest.xml'])
  const html = s.calls.find(c => c[0] === 'upload' && c[1].endsWith('.html'))
  assert.equal(html[2], 'text/html; charset=utf-8'); assert.equal(html[3], false)
  assert.equal(s.calls.at(-1)[0], 'scorm_finalize_package')
  assert.deepEqual(progress.at(-1), [3, 3])
})
test('contrôles avant tout envoi', async () => {
  for (const [file, title, motif] of [[null, 'T', /zip/], [zip(), ' ', /titre/i], [{ name: 'a.zip', size: 4, arrayBuffer: async () => new Uint8Array([1, 2, 3, 4]).buffer }, 'T', /lisible/],
    [zip({ 'index.html': strToU8('x') }), 'T', /imsmanifest/], [{ name: 'a.zip', size: 200 * 1048576 }, 'T', /150 Mo/]]) {
    const s = fake()
    assert.match((await importPackage(s, { ...args, title, file })).error, motif)
    assert.equal(s.calls.length, 0)
  }
})
for (const [nom, option] of [['échec d’un envoi', { failUpload: 'b.js' }], ['finalisation refusée', { failFinalize: true }]]) {
  test(`${nom} : fichiers supprimés, paquet abandonné, message`, async () => {
    const s = fake(option)
    const r = await importPackage(s, { ...args, file: zip() })
    assert.ok(r.error)
    assert.equal(s.objects.size, 0)
    assert.equal(s.calls.at(-1)[0], 'scorm_discard_package')
  })
}
test('ménage impossible : le message le dit', async () => {
  const s = fake({ failFinalize: true, failRemove: true })
  assert.match((await importPackage(s, { ...args, file: zip() })).error, /envoi incomplet/i)
  assert.ok(!s.calls.some(c => c[0] === 'scorm_discard_package'))
})
test('abandon d’un envoi interrompu, sous-dossiers compris', async () => {
  const s = fake(); ['co/pk/index.html', 'co/pk/a/b/c.js'].forEach(o => s.objects.add(o))
  assert.deepEqual(await discardPackage(s, { id: 'pk', storage_path: 'co/pk' }), { error: null })
  assert.equal(s.objects.size, 0)
  assert.deepEqual(s.calls.at(-1), ['scorm_discard_package', { p_package: 'pk' }])
})
test('après suppression d’un contenu : seuls les paquets publiés devenus orphelins partent', async () => {
  const s = fake(); s.objects.add('co/pk/index.html')
  const filters = []
  const q = { select: () => q, eq: (k, v) => { filters.push([k, v]); return q }, is: (k, v) => { filters.push([k, v]); return Promise.resolve({ data: [{ id: 'pk', storage_path: 'co/pk' }], error: null }) } }
  s.from = () => q
  await cleanOrphanPackages(s, 'co')
  assert.deepEqual(filters, [['course_id', 'co'], ['status', 'ready'], ['resource_id', null]])
  assert.equal(s.objects.size, 0)
})
