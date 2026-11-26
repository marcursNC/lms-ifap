import { test } from 'node:test'
import assert from 'node:assert/strict'
import { MAX_PDF_BYTES, linkError, pdfError, pdfPath, move, orderedTree, publishError } from '../lib/content-rules.mjs'

test('liens : https uniquement', () => {
  assert.equal(linkError('https://ifap.nc'), null)
  assert.equal(linkError('  https://ifap.nc/a?b=1 '), null)
  for (const u of ['http://ifap.nc', 'javascript:alert(1)', '', 'https://', 'ifap.nc', 'HTTPS://ifap.nc']) assert.match(linkError(u), /https/)
})

test('PDF : type et taille', () => {
  const pdf = size => ({ name: 'a.pdf', type: 'application/pdf', size })
  assert.equal(MAX_PDF_BYTES, 20971520)
  assert.equal(pdfError(pdf(20971520)), null)
  assert.match(pdfError(pdf(20971521)), /20 Mo/)
  assert.match(pdfError(pdf(0)), /vide/)
  assert.match(pdfError({ name: 'a.png', type: 'image/png', size: 10 }), /PDF/)
  assert.match(pdfError(undefined), /PDF/)
})

test('chemin et déplacement', () => {
  assert.equal(pdfPath('c', 'u'), 'c/u.pdf')
  assert.deepEqual(move(['a', 'b'], 0, -1), ['a', 'b'])
  assert.deepEqual(move(['a', 'b'], 1, 1), ['a', 'b'])
  assert.deepEqual(move(['a', 'b'], 0, 1), ['b', 'a'])
  assert.deepEqual(move(['a', 'b', 'c'], 2, -2), ['c', 'a', 'b'])
})

test('arbre : ordonné, sans les retirés, contenus hors module à la fin', () => {
  const modules = [{ id: 'm2', position: 2 }, { id: 'm1', position: 1 }, { id: 'm3', position: 3, retired_at: 'x' }]
  const resources = [
    { id: 'r2', module_id: 'm1', position: 2 }, { id: 'r1', module_id: 'm1', position: 1 },
    { id: 'r3', module_id: 'm1', position: 3, retired_at: 'x' }, { id: 'r4', module_id: 'm3', position: 1 },
    { id: 'r5', module_id: null, position: 1 }]
  const tree = orderedTree(modules, resources)
  assert.deepEqual(tree.map(m => m.id), ['m1', 'm2', null])
  assert.deepEqual(tree[0].resources.map(r => r.id), ['r1', 'r2'])
  assert.deepEqual(tree[2].resources.map(r => r.id), ['r5'])
  assert.equal(orderedTree(modules, []).length, 2)
})

test('publication : au moins un contenu', () => {
  assert.match(publishError({ status: 'draft' }, []), /au moins un contenu/)
  assert.match(publishError({ status: 'draft' }, [{ retired_at: 'x' }]), /au moins un contenu/)
  assert.equal(publishError({ status: 'draft' }, [{ id: 'r' }]), null)
  assert.equal(publishError({ status: 'published' }, []), null)
})
