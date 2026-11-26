'use client'
import { useEffect, useState } from 'react'
import { createClient } from '../../lib/supabase-browser'

export function NewResource({ busy, onAdd }) {
  const [type, setType] = useState('pdf')
  const [title, setTitle] = useState('')
  const [url, setUrl] = useState('')
  const [file, setFile] = useState(null)
  const [required, setRequired] = useState(true)
  return (
    <form className="editor-form" noValidate onSubmit={e => { e.preventDefault(); onAdd({ type, title, url, file, required }) }}>
      <h2>Nouveau contenu</h2>
      <label>Type<select value={type} onChange={e => setType(e.target.value)}><option value="pdf">Document PDF</option><option value="link">Lien web</option></select></label>
      <label>Titre du contenu<input value={title} onChange={e => setTitle(e.target.value)} /></label>
      {type === 'link'
        ? <label>Adresse<input type="url" value={url} placeholder="https://…" onChange={e => setUrl(e.target.value)} /></label>
        : <label>Fichier PDF<input type="file" accept="application/pdf,.pdf" onChange={e => setFile(e.target.files?.[0] || null)} /></label>}
      <Required value={required} onChange={setRequired} />
      <button type="submit" className="btn" disabled={busy}>{busy ? 'Envoi…' : 'Ajouter'}</button>
    </form>
  )
}

export function ResourcePanel({ resource, busy, onSave, onRemove }) {
  const [title, setTitle] = useState(resource.title)
  const [required, setRequired] = useState(resource.is_required)
  return (
    <div className="editor-form">
      <form className="editor-form" noValidate onSubmit={e => { e.preventDefault(); onSave({ title, is_required: required }) }}>
        <h2>{resource.title}</h2>
        <label>Titre du contenu<input value={title} onChange={e => setTitle(e.target.value)} /></label>
        <Required value={required} onChange={setRequired} />
        <button type="submit" className="btn" disabled={busy}>Enregistrer</button>
      </form>
      <Preview resource={resource} />
      <Remove busy={busy} onRemove={onRemove} />
    </div>
  )
}

export function ModulePanel({ module, busy, onSave, onRemove }) {
  const [title, setTitle] = useState(module.title)
  const [description, setDescription] = useState(module.description || '')
  const [required, setRequired] = useState(module.is_required)
  return (
    <div className="editor-form">
      <form className="editor-form" noValidate onSubmit={e => { e.preventDefault(); onSave({ title, description: description.trim() || null, is_required: required }) }}>
        <h2>{module.title}</h2>
        <label>Titre du module<input value={title} onChange={e => setTitle(e.target.value)} /></label>
        <label>Description<textarea rows="4" value={description} onChange={e => setDescription(e.target.value)} /></label>
        <Required value={required} onChange={setRequired} />
        <button type="submit" className="btn" disabled={busy}>Enregistrer</button>
      </form>
      <Remove busy={busy} onRemove={onRemove} />
    </div>
  )
}

function Required({ value, onChange }) {
  return <label className="editor-check"><input type="checkbox" checked={value} onChange={e => onChange(e.target.checked)} />Obligatoire pour terminer la formation</label>
}

// Aperçu du gestionnaire : aucune activité n'est enregistrée.
function Preview({ resource }) {
  const [url, setUrl] = useState('')
  const [error, setError] = useState('')
  useEffect(() => {
    if (!resource.storage_path) return
    let alive = true
    createClient().storage.from('course-resources').createSignedUrl(resource.storage_path, 3600).then(({ data, error }) => {
      if (!alive) return
      if (error || !data?.signedUrl) setError('Impossible d’ouvrir ce document.')
      else setUrl(data.signedUrl)
    })
    return () => { alive = false }
  }, [resource.storage_path])
  const href = resource.storage_path ? url : resource.external_url?.startsWith('https://') ? resource.external_url : ''
  return (
    <div className="editor-preview">
      <h3>Aperçu</h3>
      {error && <div className="error" role="alert">{error}</div>}
      {resource.storage_path && url && <iframe title={`Aperçu de ${resource.title}`} src={url} />}
      {href && <a className="text-link" href={href} target="_blank" rel="noopener noreferrer">{resource.storage_path ? 'Ouvrir le PDF dans un nouvel onglet' : href}</a>}
    </div>
  )
}

function Remove({ busy, onRemove }) {
  const [confirm, setConfirm] = useState(false)
  return (
    <div className="editor-remove">
      <p className="muted small">Un élément déjà suivi par un stagiaire est retiré sans effacer les traces. Sinon il est supprimé.</p>
      {confirm
        ? <div className="actions">
            <button type="button" className="btn" disabled={busy} onClick={onRemove}>Confirmer le retrait</button>
            <button type="button" className="btn secondary" disabled={busy} onClick={() => setConfirm(false)}>Annuler</button>
          </div>
        : <button type="button" className="btn secondary" disabled={busy} onClick={() => setConfirm(true)}>Retirer</button>}
    </div>
  )
}
