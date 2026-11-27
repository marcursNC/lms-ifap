// Lecture d'un paquet SCORM 1.2 déjà décompressé : contrôles, fichier de démarrage, noms de stockage.
import { XMLParser, XMLValidator } from 'fast-xml-parser'

export { encodeKey, decodeKey } from '../player/public/scorm-keys.mjs'

export const LIMITS = { fileBytes: 52428800, totalBytes: 157286400, files: 1000 }
const IGNORED = /(^|\/)(\.DS_Store|Thumbs\.db|desktop\.ini)$|(^|\/)__MACOSX\//

const list = x => x === undefined ? [] : Array.isArray(x) ? x : [x]
const unsafe = path => path.startsWith('/') || path.includes('\\') || path.split('/').some(s => s === '' || s === '.' || s === '..')
const fail = message => { throw new Error(message) }

// Lettres accentuées de la page de codes 850, utilisée par d'anciens outils zip sous Windows.
const CP850 = new Map([...'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ'].map((c, i) => [0x80 + i, c]).concat([...'áíóúñÑ'].map((c, i) => [0xA0 + i, c])))

// Sans l'indicateur UTF-8 du zip, les noms arrivent octet par octet : on les relit, puis on recompose les accents.
function readableName(name) {
  const codes = [...name].map(c => c.codePointAt(0))
  if (codes.some(c => c > 0x7F) && codes.every(c => c <= 0xFF)) {
    try {
      name = new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(codes))
    } catch {
      if (codes.some(c => c >= 0x80 && c <= 0x9F)) name = [...name].map(c => CP850.get(c.codePointAt(0)) || c).join('')
    }
  }
  return name.normalize('NFC')
}

function rootOf(names) {
  if (names.includes('imsmanifest.xml')) return ''
  const tops = new Set(names.map(n => n.split('/')[0]))
  const [top] = tops
  if (tops.size === 1 && names.includes(top + '/imsmanifest.xml')) return top + '/'
  return fail('Ce fichier n’est pas un paquet SCORM : imsmanifest.xml est introuvable à la racine du zip.')
}

function parseManifest(bytes) {
  const xml = new TextDecoder().decode(bytes)
  if (XMLValidator.validate(xml) !== true) fail('Le manifeste du paquet est illisible.')
  const doc = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@', removeNSPrefix: true, parseTagValue: false, parseAttributeValue: false }).parse(xml)
  if (!doc.manifest) fail('Le manifeste du paquet est illisible.')
  const version = String(doc.manifest.metadata?.schemaversion ?? '').trim()
  if ((version && version !== '1.2') || /adlcp_v1p3|imsss/.test(xml)) fail('Seul le format SCORM 1.2 est pris en charge.')
  return doc.manifest
}

function findLaunch(manifest) {
  const organizations = list(manifest.organizations?.organization)
  const organization = organizations.find(o => o['@identifier'] === manifest.organizations?.['@default']) || organizations[0]
  const items = []
  const walk = node => list(node?.item).forEach(i => { items.push(i); walk(i) })
  walk(organization)
  const resources = list(manifest.resources?.resource)
  const byId = new Map(resources.map(r => [r['@identifier'], r]))
  let used = items.filter(i => byId.get(i['@identifierref'])?.['@href'])
  const distinct = new Set(used.map(i => i['@identifierref']))
  if (distinct.size > 1) fail('Ce paquet contient plusieurs modules : seul un module par paquet est pris en charge.')
  let item = used[0], resource = item && byId.get(item['@identifierref'])
  if (!resource) {
    const scos = resources.filter(r => String(r['@scormtype'] || r['@scormType'] || '').toLowerCase() === 'sco' && r['@href'])
    if (scos.length > 1) fail('Ce paquet contient plusieurs modules : seul un module par paquet est pris en charge.')
    resource = scos[0]
  }
  if (!resource) fail('Le manifeste n’indique aucun fichier de démarrage.')
  const score = Number(String(item?.masteryscore ?? '').trim() || NaN)
  return {
    href: (manifest.resources?.['@base'] || '') + (resource['@base'] || '') + resource['@href'],
    title: String(organization?.title ?? item?.title ?? '').trim(),
    mastery: score >= 0 && score <= 100 ? score : null
  }
}

export function readPackage(entries) {
  const kept = [...entries].map(([name, bytes]) => [readableName(name), bytes]).filter(([name]) => !name.endsWith('/') && !IGNORED.test(name))
  if (new Set(kept.map(([name]) => name)).size !== kept.length) fail('Le paquet contient deux fichiers portant le même nom.')
  const bad = kept.find(([name]) => unsafe(name))
  if (bad) fail(`Chemin de fichier refusé dans le paquet : ${bad[0]}`)
  if (kept.length > LIMITS.files) fail('Le paquet dépasse 1 000 fichiers.')
  let total = 0
  for (const [name, bytes] of kept) {
    if (bytes.byteLength > LIMITS.fileBytes) fail(`Le fichier « ${name} » dépasse 50 Mo.`)
    total += bytes.byteLength
  }
  if (total > LIMITS.totalBytes) fail('Le paquet dépasse 150 Mo une fois décompressé.')
  const root = rootOf(kept.map(([name]) => name))
  const files = new Map(kept.map(([name, bytes]) => [name.slice(root.length), bytes]))
  const { href, title, mastery } = findLaunch(parseManifest(files.get('imsmanifest.xml')))
  const cut = href.search(/[?#]/)
  let path = cut < 0 ? href : href.slice(0, cut)
  try { path = decodeURIComponent(path) } catch { /* nom contenant un « % » littéral */ }
  path = path.normalize('NFC')
  if (!files.has(path)) fail('Le fichier de démarrage indiqué par le manifeste est absent du paquet.')
  return { files, launch: path + (cut < 0 ? '' : href.slice(cut)), title, mastery }
}
