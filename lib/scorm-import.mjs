// Import d'un module SCORM depuis le navigateur du gestionnaire : décompression, contrôles, envoi.
import { unzipSync } from 'fflate'
import { LIMITS, readPackage } from './scorm-package.mjs'
import { contentType, encodeKey } from '../player/public/scorm-keys.mjs'
import { frenchError } from './deployment-rules.mjs'

const BUCKET = 'scorm-packages'
const TOO_BIG = 'Le paquet dépasse 150 Mo une fois décompressé.'
const LEFTOVER = ' Un envoi incomplet reste à supprimer dans la liste des contenus.'

async function unzip(file) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  let total = 0, tooBig = false
  try {
    return unzipSync(bytes, { filter: entry => {
      total += entry.originalSize
      if (total > LIMITS.totalBytes) { tooBig = true; throw new Error(TOO_BIG) }
      return true
    } })
  } catch {
    throw new Error(tooBig ? TOO_BIG : 'Ce fichier zip n’est pas lisible.')
  }
}

async function listAll(bucket, folder) {
  const paths = []
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await bucket.list(folder, { limit: 1000, offset })
    if (error) throw error
    for (const entry of data || []) {
      const path = `${folder}/${entry.name}`
      if (entry.id) paths.push(path)
      else paths.push(...await listAll(bucket, path))
    }
    if ((data || []).length < 1000) return paths
  }
}

export async function discardPackage(s, pkg) {
  try {
    const bucket = s.storage.from(BUCKET)
    const paths = await listAll(bucket, pkg.storage_path)
    for (let i = 0; i < paths.length; i += 100) {
      const { error } = await bucket.remove(paths.slice(i, i + 100))
      if (error) throw error
    }
    const { error } = await s.rpc('scorm_discard_package', { p_package: pkg.id })
    return { error: error ? frenchError(error) : null }
  } catch (e) {
    return { error: frenchError(e) }
  }
}

// Après la suppression d'un contenu jamais suivi, ses fichiers n'ont plus d'usage.
export async function cleanOrphanPackages(s, courseId) {
  const { data } = await s.from('scorm_packages').select('id,storage_path')
    .eq('course_id', courseId).eq('status', 'ready').is('resource_id', null)
  for (const pkg of data || []) await discardPackage(s, pkg)
}

export async function importPackage(s, { courseId, moduleId, title, file }, onProgress = () => {}) {
  if (!title?.trim()) return { error: 'Saisissez un titre.' }
  if (!file || !/\.zip$/i.test(file.name)) return { error: 'Choisissez le fichier .zip du module.' }
  if (file.size > LIMITS.totalBytes) return { error: 'Le fichier dépasse 150 Mo.' }
  let pack
  try { pack = readPackage(new Map(Object.entries(await unzip(file)))) } catch (e) { return { error: e.message } }

  const files = [...pack.files]
  const cut = pack.launch.search(/[?#]/)
  const launch = cut < 0 ? encodeKey(pack.launch) : encodeKey(pack.launch.slice(0, cut)) + pack.launch.slice(cut)
  const registered = await s.rpc('scorm_register_package', {
    p_course: courseId, p_module: moduleId, p_title: title.trim(), p_launch: launch, p_mastery: pack.mastery,
    p_files: files.length, p_bytes: files.reduce((sum, [, bytes]) => sum + bytes.byteLength, 0)
  })
  if (registered.error) return { error: frenchError(registered.error) }
  const pkg = { id: registered.data, storage_path: `${courseId}/${registered.data}` }

  let next = 0, done = 0, failure = null
  const send = async () => {
    while (!failure && next < files.length) {
      const [path, bytes] = files[next++]
      try {
        const type = contentType(path)
        const { error } = await s.storage.from(BUCKET).upload(`${pkg.storage_path}/${encodeKey(path)}`,
          new Blob([bytes], { type }), { contentType: type, upsert: false })
        if (error) throw error
        onProgress(++done, files.length)
      } catch (e) {
        failure = failure || e
      }
    }
  }
  // Quatre envois à la fois ; on attend les derniers avant tout ménage.
  await Promise.all([send(), send(), send(), send()])

  if (!failure) {
    const finalized = await s.rpc('scorm_finalize_package', { p_package: pkg.id })
    if (!finalized.error) return { error: null, resourceId: finalized.data }
    failure = finalized.error
  }
  const cleaned = await discardPackage(s, pkg)
  return { error: frenchError(failure) + (cleaned.error ? LEFTOVER : '') }
}
