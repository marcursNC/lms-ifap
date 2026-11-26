// Écritures des contenus. Chaque action reçoit le client Supabase et répond { error }.
import { frenchError, NOT_ALLOWED } from './deployment-rules.mjs'
import { linkError, pdfError, pdfPath } from './content-rules.mjs'

const BUCKET = 'course-resources'
const NO_TITLE = 'Saisissez un titre.'

// Une écriture refusée par la RLS ne renvoie parfois aucune erreur, seulement aucune ligne.
async function write(query) {
  const { data, error } = await query.select('id')
  if (error) return { error: frenchError(error) }
  return { error: data?.length ? null : NOT_ALLOWED }
}

const resourceRow = ({ courseId, moduleId, title, required, position }, more) => ({
  course_id: courseId, module_id: moduleId, title: title.trim(), is_required: required, position, ...more
})

export async function addModule(s, courseId, title, position) {
  if (!title?.trim()) return { error: NO_TITLE }
  return write(s.from('course_modules').insert({ course_id: courseId, title: title.trim(), position, content_type: 'module' }))
}

export async function addLink(s, content) {
  if (!content.title?.trim()) return { error: NO_TITLE }
  const invalid = linkError(content.url)
  if (invalid) return { error: invalid }
  return write(s.from('course_resources').insert(resourceRow(content, { resource_type: 'link', external_url: content.url.trim() })))
}

export async function addPdf(s, content) {
  if (!content.title?.trim()) return { error: NO_TITLE }
  const invalid = pdfError(content.file)
  if (invalid) return { error: invalid }
  const path = pdfPath(content.courseId, content.uuid)
  const { error } = await s.storage.from(BUCKET).upload(path, content.file, { contentType: 'application/pdf', upsert: false })
  if (error) return { error: `L’envoi du fichier a échoué : ${error.message || 'erreur inconnue'}` }
  const result = await write(s.from('course_resources').insert(resourceRow(content, { resource_type: 'pdf', storage_path: path })))
  if (result.error) await s.storage.from(BUCKET).remove([path])
  return result
}

export const updateItem = (s, table, id, values) => write(s.from(table).update(values).eq('id', id))

export async function removeItem(s, kind, item) {
  const { data, error } = await s.rpc('remove_course_item', { p_kind: kind, p_id: item.id })
  if (error) return { error: frenchError(error) }
  if (data === 'deleted') {
    const paths = (kind === 'module' ? item.resources || [] : [item]).map(r => r.storage_path).filter(Boolean)
    // Un échec ici ne laisse qu'un fichier sans référence, invisible des stagiaires.
    if (paths.length) await s.storage.from(BUCKET).remove(paths)
  }
  return { error: null, outcome: data }
}

export async function saveOrder(s, courseId, moduleIds, resourceIds) {
  const { error } = await s.rpc('reorder_course_content', { p_course: courseId, p_modules: moduleIds, p_resources: resourceIds })
  return { error: error ? frenchError(error) : null }
}
