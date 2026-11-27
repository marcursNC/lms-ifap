// L'écran « formation » du stagiaire ne doit pas retomber sur les boutons bruts du navigateur.
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const root = new URL('../', import.meta.url)
const read = path => readFileSync(new URL(path, root), 'utf8')
const page = read('app/learner/courses/[id]/page.jsx')
const css = read('app/globals.css')

test('chaque classe de l’écran formation du stagiaire a une règle de style', () => {
  const classes = new Set([...page.matchAll(/className="([^"]+)"/g)].flatMap(m => m[1].split(/\s+/)))
  const missing = [...classes].filter(c => !new RegExp(`\\.${c}(?![\\w-])`).test(css))
  assert.deepEqual(missing.sort(), [])
})
