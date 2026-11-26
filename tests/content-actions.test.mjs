import { test } from 'node:test'
import assert from 'node:assert/strict'
import { addModule, addLink, addPdf, removeItem, saveOrder, updateItem } from '../lib/content-actions.mjs'
import { NOT_ALLOWED } from '../lib/deployment-rules.mjs'

// Faux client : note les appels et répond ce qu'on lui demande.
function fake({ upload = {}, write = { data: [{ id: 'x' }] }, rpc = { data: null } } = {}) {
  const calls = []
  const query = table => {
    const q = {
      insert: v => { calls.push(['insert', table, v]); return q },
      update: v => { calls.push(['update', table, v]); return q },
      eq: () => q,
      select: async () => write
    }
    return q
  }
  return {
    calls,
    from: query,
    rpc: async (name, args) => { calls.push(['rpc', name, args]); return rpc },
    storage: { from: bucket => ({
      upload: async (path, file, options) => { calls.push(['upload', bucket, path, options]); return upload },
      remove: async paths => { calls.push(['remove', bucket, paths]); return {} }
    }) }
  }
}
const pdf = { name: 'a.pdf', type: 'application/pdf', size: 10 }
const base = { courseId: 'c', moduleId: 'm', title: ' Guide ', required: true, position: 1 }

test('module et lien', async () => {
  const s = fake()
  assert.deepEqual(await addModule(s, 'c', ' Accueil ', 1), { error: null })
  assert.deepEqual(s.calls[0], ['insert', 'course_modules', { course_id: 'c', title: 'Accueil', position: 1, content_type: 'module' }])
  assert.equal((await addLink(s, { ...base, url: ' https://ifap.nc ' })).error, null)
  assert.equal(s.calls[1][2].external_url, 'https://ifap.nc')
  assert.equal(s.calls[1][2].resource_type, 'link')
})

test('lien et titre invalides : aucun appel', async () => {
  const s = fake()
  assert.match((await addLink(s, { ...base, url: 'http://ifap.nc' })).error, /https/)
  assert.match((await addLink(s, { ...base, title: '  ', url: 'https://ifap.nc' })).error, /titre/)
  assert.match((await addPdf(s, { ...base, file: { ...pdf, type: 'image/png' }, uuid: 'u' })).error, /PDF/)
  assert.equal(s.calls.length, 0)
})

test('addPdf : envoi puis enregistrement', async () => {
  const s = fake()
  assert.equal((await addPdf(s, { ...base, file: pdf, uuid: 'u' })).error, null)
  assert.deepEqual(s.calls[0].slice(0, 3), ['upload', 'course-resources', 'c/u.pdf'])
  assert.equal(s.calls[1][2].storage_path, 'c/u.pdf')
  assert.equal(s.calls.length, 2)
})

test('addPdf : enregistrement refusé → fichier supprimé', async () => {
  for (const write of [{ error: { code: '42501' } }, { data: [] }]) {
    const s = fake({ write })
    assert.equal((await addPdf(s, { ...base, file: pdf, uuid: 'u' })).error, NOT_ALLOWED)
    assert.deepEqual(s.calls.at(-1), ['remove', 'course-resources', ['c/u.pdf']])
  }
})

test('addPdf : envoi refusé → aucune insertion', async () => {
  const s = fake({ upload: { error: { message: 'new row violates row-level security policy' } } })
  assert.ok((await addPdf(s, { ...base, file: pdf, uuid: 'u' })).error)
  assert.equal(s.calls.length, 1)
})

test('retrait : le fichier n’est supprimé que si la ligne l’est', async () => {
  const item = { id: 'r', storage_path: 'c/u.pdf' }
  const retired = fake({ rpc: { data: 'retired' } })
  assert.deepEqual(await removeItem(retired, 'resource', item), { error: null, outcome: 'retired' })
  assert.equal(retired.calls.length, 1)
  const deleted = fake({ rpc: { data: 'deleted' } })
  await removeItem(deleted, 'resource', item)
  assert.deepEqual(deleted.calls.at(-1), ['remove', 'course-resources', ['c/u.pdf']])
  const module = fake({ rpc: { data: 'deleted' } })
  await removeItem(module, 'module', { id: 'm', resources: [item, { id: 'l' }] })
  assert.deepEqual(module.calls.at(-1), ['remove', 'course-resources', ['c/u.pdf']])
  const refused = fake({ rpc: { error: { code: 'P0001', message: 'Cet élément est déjà retiré' } } })
  assert.equal((await removeItem(refused, 'resource', item)).error, 'Cet élément est déjà retiré')
})

test('mise à jour sans ligne → refus ; ordre transmis', async () => {
  assert.equal((await updateItem(fake({ write: { data: [] } }), 'course_modules', 'm', { title: 'T' })).error, NOT_ALLOWED)
  const s = fake()
  assert.equal((await saveOrder(s, 'c', ['m'], ['r'])).error, null)
  assert.deepEqual(s.calls[0], ['rpc', 'reorder_course_content', { p_course: 'c', p_modules: ['m'], p_resources: ['r'] }])
})
