import test from 'node:test'
import assert from 'node:assert/strict'
import { readPackage, encodeKey, decodeKey, LIMITS } from '../lib/scorm-package.mjs'

const enc = s => new TextEncoder().encode(s)
const manifest = ({ version = '1.2', items = '<item identifier="I1" identifierref="R1"><title>Module</title></item>', resources = '<resource identifier="R1" type="webcontent" adlcp:scormtype="sco" href="index.html"/>', ns = 'adlcp_rootv1p2' } = {}) =>
  `<?xml version="1.0"?><manifest identifier="M" xmlns="http://www.imsproject.org/xsd/imscp_rootv1p1p2" xmlns:adlcp="http://www.adlnet.org/xsd/${ns}">
  <metadata><schema>ADL SCORM</schema>${version ? `<schemaversion>${version}</schemaversion>` : ''}</metadata>
  <organizations default="O"><organization identifier="O"><title>Titre du cours</title>${items}</organization></organizations>
  <resources>${resources}</resources></manifest>`
const pkg = (files, m = manifest()) => new Map([['imsmanifest.xml', enc(m)], ...files.map(f => [f, enc('x')])])
const refuse = (entries, motif) => assert.throws(() => readPackage(entries), motif)

test('paquet valide', () => {
  const p = readPackage(pkg(['index.html', 'assets/a.png']))
  assert.equal(p.launch, 'index.html')
  assert.equal(p.title, 'Titre du cours')
  assert.equal(p.mastery, null)
  assert.deepEqual([...p.files.keys()].sort(), ['assets/a.png', 'imsmanifest.xml', 'index.html'])
})

test('dossier racine unique, __MACOSX et fichiers système ignorés', () => {
  const entries = new Map([['cours/', new Uint8Array()], ['cours/imsmanifest.xml', enc(manifest())], ['cours/index.html', enc('x')],
    ['__MACOSX/cours/._index.html', enc('x')], ['cours/.DS_Store', enc('x')]])
  const p = readPackage(entries)
  assert.deepEqual([...p.files.keys()].sort(), ['imsmanifest.xml', 'index.html'])
})

test('accents, espaces et adresse encodée du démarrage', () => {
  const m = manifest({ resources: '<resource identifier="R1" adlcp:scormtype="sco" href="d%C3%A9but%20ici.html?v=2"/>' })
  const p = readPackage(pkg(['début ici.html', 'images/été.png'], m))
  assert.equal(p.launch, 'début ici.html?v=2')
  assert.ok(p.files.has('images/été.png'))
})

test('clés de stockage : réversibles et limitées aux caractères admis', () => {
  for (const path of ['index.html', 'images/été à l’œil.png', 'a!b~c#d%e?.js', 'plan (v2)/x_y-z.css']) {
    const key = encodeKey(path)
    assert.match(key, /^[A-Za-z0-9_.\- ()!/]+$/)
    assert.equal(decodeKey(key), path)
  }
  assert.equal(encodeKey('assets/01_ouverture.webp'), 'assets/01_ouverture.webp')
  assert.notEqual(encodeKey('é'), encodeKey('!C3!A9'))
})

test('refus : manifeste absent ou trop profond', () => {
  refuse(new Map([['index.html', enc('x')]]), /imsmanifest\.xml/)
  refuse(new Map([['a/b/imsmanifest.xml', enc(manifest())], ['a/b/index.html', enc('x')]]), /imsmanifest\.xml/)
})
test('refus : SCORM 2004', () => {
  refuse(pkg(['index.html'], manifest({ version: '2004 3rd Edition' })), /1\.2/)
  refuse(pkg(['index.html'], manifest({ version: '', ns: 'adlcp_v1p3' })), /1\.2/)
})
test('refus : plusieurs modules', () => {
  const m = manifest({ items: '<item identifier="I1" identifierref="R1"/><item identifier="I2" identifierref="R2"/>',
    resources: '<resource identifier="R1" adlcp:scormtype="sco" href="index.html"/><resource identifier="R2" adlcp:scormtype="sco" href="b.html"/>' })
  refuse(pkg(['index.html', 'b.html'], m), /plusieurs modules/)
})
test('refus : démarrage absent, externe ou manifeste illisible', () => {
  refuse(pkg(['autre.html']), /démarrage/)
  refuse(pkg(['index.html'], manifest({ resources: '<resource identifier="R1" adlcp:scormtype="sco" href="https://exemple.nc/x.html"/>' })), /démarrage/)
  refuse(pkg(['index.html'], '<manifest><oups'), /manifeste/i)
})
test('refus : chemins sortants', () => {
  for (const bad of ['../x.js', 'a/../../x.js', '/x.js', 'a\\x.js', 'a//x.js', './x.js'])
    refuse(pkg(['index.html', bad]), /chemin/i)
})
test('refus : limites', () => {
  refuse(pkg(Array.from({ length: LIMITS.files }, (_, i) => `f${i}.js`).concat('index.html')), /1 000/)
  const gros = pkg(['index.html']); gros.set('v.mp4', { byteLength: LIMITS.fileBytes + 1 })
  refuse(gros, /50 Mo/)
  const total = pkg(['index.html']); for (let i = 0; i < 4; i++) total.set(`v${i}.mp4`, { byteLength: LIMITS.fileBytes })
  refuse(total, /150 Mo/)
})
test('score minimal lu', () => {
  const m = manifest({ items: '<item identifier="I1" identifierref="R1"><title>M</title><adlcp:masteryscore>80</adlcp:masteryscore></item>' })
  assert.equal(readPackage(pkg(['index.html'], m)).mastery, 80)
})
