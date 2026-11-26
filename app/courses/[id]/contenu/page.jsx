'use client'

import Link from 'next/link'
import { useEffect, useRef, useState } from 'react'
import { useParams } from 'next/navigation'
import Shell from '../../../../components/Shell'
import ContentTree from '../../../../components/editor/ContentTree'
import CourseOptions from '../../../../components/editor/CourseOptions'
import { ModulePanel, NewResource, ResourcePanel } from '../../../../components/editor/ResourcePanel'
import { createClient } from '../../../../lib/supabase-browser'
import { canEditCourse, frenchError, NOT_ALLOWED } from '../../../../lib/deployment-rules.mjs'
import { orderedTree, publishError } from '../../../../lib/content-rules.mjs'
import { addLink, addModule, addPdf, removeItem, saveOrder, updateItem } from '../../../../lib/content-actions.mjs'

const nextPosition = items => items.reduce((max, x) => Math.max(max, x.position || 0), 0) + 1

export default function CourseEditor() {
  const { id } = useParams()
  const [course, setCourse] = useState(null)
  const [modules, setModules] = useState([])
  const [resources, setResources] = useState([])
  const [allowed, setAllowed] = useState(false)
  const [selected, setSelected] = useState({ type: 'options' })
  const [newModule, setNewModule] = useState(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const running = useRef(false)

  async function load() {
    const s = createClient()
    const { data: { user } } = await s.auth.getUser()
    if (!user) { location.href = '/login'; return }
    const [c, m, r, me] = await Promise.all([
      s.from('courses').select('id,title,description,objectives,target_audience,duration_minutes,modality,prerequisites,status,visibility,owner_organization_id').eq('id', id).maybeSingle(),
      s.from('course_modules').select('id,title,description,position,is_required,retired_at').eq('course_id', id).order('position'),
      s.from('course_resources').select('id,module_id,title,resource_type,storage_path,external_url,is_required,position,retired_at').eq('course_id', id).order('position'),
      s.from('organization_members').select('organization_id,role').eq('user_id', user.id)
    ])
    const failed = [c, m, r, me].find(x => x.error)
    if (failed) setError(frenchError(failed.error))
    setCourse(c.data)
    setModules(m.data || [])
    setResources(r.data || [])
    setAllowed(Boolean(c.data) && canEditCourse(c.data, me.data || []))
    setLoading(false)
  }

  useEffect(() => { if (id) load() }, [id])

  // Une seule écriture à la fois, même en cas de double clic.
  async function run(action, success, then) {
    if (running.current) return
    running.current = true
    setBusy(true); setError(''); setMessage('')
    try {
      const result = await action(createClient())
      if (result.error) setError(result.error)
      else {
        setMessage(typeof success === 'function' ? success(result) : success)
        then?.()
      }
      await load()
    } catch (e) {
      setError(frenchError(e))
    }
    running.current = false
    setBusy(false)
  }

  const tree = orderedTree(modules, resources)
  const select = value => { setSelected(value); setError(''); setMessage('') }
  const module = selected.type === 'module' || selected.type === 'new' ? tree.find(m => m.id === selected.id) : null
  const resource = selected.type === 'resource' ? resources.find(r => r.id === selected.id && !r.retired_at) : null

  const remove = (kind, item) => run(
    s => removeItem(s, kind, item),
    result => result.outcome === 'retired' ? 'Élément retiré : les traces de formation sont conservées.' : 'Élément supprimé.',
    () => setSelected({ type: 'options' })
  )
  const save = (table, itemId, values) => run(
    s => values.title?.trim() ? updateItem(s, table, itemId, { ...values, title: values.title.trim() }) : Promise.resolve({ error: 'Saisissez un titre.' }),
    'Modification enregistrée.'
  )
  const add = ({ type, title, url, file, required }) => {
    const content = { courseId: id, moduleId: selected.id, title, url, file, required, position: nextPosition(resources) }
    run(s => type === 'link' ? addLink(s, content) : addPdf(s, { ...content, uuid: crypto.randomUUID() }), 'Contenu ajouté.', () => setSelected({ type: 'options' }))
  }
  const createModule = e => {
    e.preventDefault()
    run(s => addModule(s, id, newModule, nextPosition(modules)), 'Module créé.', () => setNewModule(null))
  }
  const publish = () => {
    const invalid = publishError(course, resources)
    if (invalid) { setMessage(''); setError(invalid); return }
    run(s => updateItem(s, 'courses', id, { status: 'published' }), 'Formation publiée.')
  }

  return (
    <Shell active="courses">
      <div className="top">
        <div>
          <div className="eyebrow">CONTENU DE LA FORMATION</div>
          <h1>{loading ? 'Chargement…' : course?.title || 'Formation introuvable'}</h1>
          {course && <div className="muted">{course.status === 'published' ? 'Publiée' : 'Brouillon'}</div>}
        </div>
        <div className="actions">
          <Link className="btn secondary" href={`/courses/${id}`}>← Retour à la fiche</Link>
          {allowed && <button type="button" className="btn secondary" onClick={() => select({ type: 'options' })}>Options</button>}
          {allowed && course.status === 'draft' && <button type="button" className="btn" disabled={busy} onClick={publish}>Publier</button>}
        </div>
      </div>

      {message && <div className="success" role="status">{message}</div>}
      {error && <div className="error" role="alert">{error}</div>}
      {!loading && !allowed && <div className="card">{NOT_ALLOWED}</div>}

      {allowed && (
        <div className="editor">
          <aside className="editor-side" aria-label="Plan de la formation">
            {newModule === null
              ? <button type="button" className="btn editor-new-module" disabled={busy} onClick={() => setNewModule('')}>+ Module</button>
              : <form className="editor-form" noValidate onSubmit={createModule}>
                  <label>Titre du module<input autoFocus value={newModule} onChange={e => setNewModule(e.target.value)} /></label>
                  <div className="actions">
                    <button type="submit" className="btn" disabled={busy}>Créer</button>
                    <button type="button" className="btn secondary" disabled={busy} onClick={() => setNewModule(null)}>Annuler</button>
                  </div>
                </form>}
            {tree.length === 0 && <div className="empty">Commencez par créer un module.</div>}
            <ContentTree tree={tree} selected={selected} busy={busy} onSelect={select}
              onReorder={(moduleIds, resourceIds) => run(s => saveOrder(s, id, moduleIds, resourceIds), 'Ordre enregistré.')} />
          </aside>
          <section className="editor-panel card" aria-label="Élément sélectionné">
            {selected.type === 'new' && module ? <NewResource key={selected.id} busy={busy} onAdd={add} />
              : resource ? <ResourcePanel key={resource.id} resource={resource} busy={busy}
                  onSave={values => save('course_resources', resource.id, values)} onRemove={() => remove('resource', resource)} />
              : selected.type === 'module' && module ? <ModulePanel key={module.id} module={module} busy={busy}
                  onSave={values => save('course_modules', module.id, values)} onRemove={() => remove('module', module)} />
              : <CourseOptions key={course.id} course={course} busy={busy} onError={setError}
                  onSave={values => run(s => updateItem(s, 'courses', id, values), 'Options enregistrées.')} />}
          </section>
        </div>
      )}
    </Shell>
  )
}
