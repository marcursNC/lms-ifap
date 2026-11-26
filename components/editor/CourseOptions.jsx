'use client'
import { useState } from 'react'

const FIELDS = [
  ['title', 'Titre', 'input'], ['description', 'Description', 'textarea'], ['objectives', 'Objectifs', 'textarea'],
  ['target_audience', 'Public visé', 'input'], ['duration_minutes', 'Durée (minutes)', 'number'],
  ['modality', 'Modalité', 'input'], ['prerequisites', 'Prérequis', 'textarea']
]

export default function CourseOptions({ course, busy, onSave, onError }) {
  const [values, setValues] = useState(() => Object.fromEntries(FIELDS.map(([k]) => [k, course[k] ?? ''])))
  function submit(e) {
    e.preventDefault()
    const clean = Object.fromEntries(FIELDS.map(([k]) => [k, String(values[k]).trim() || null]))
    if (!clean.title) return onError('Saisissez un titre.')
    if (clean.duration_minutes !== null) {
      clean.duration_minutes = Number(clean.duration_minutes)
      if (!Number.isInteger(clean.duration_minutes) || clean.duration_minutes < 0) return onError('La durée est un nombre entier de minutes.')
    }
    onSave(clean)
  }
  return (
    <form className="editor-form" noValidate onSubmit={submit}>
      <h2>Options de la formation</h2>
      {FIELDS.map(([key, label, kind]) => {
        const props = { value: values[key], onChange: e => setValues(v => ({ ...v, [key]: e.target.value })) }
        return <label key={key}>{label}{kind === 'textarea' ? <textarea rows="3" {...props} /> : <input type={kind === 'number' ? 'number' : 'text'} min={kind === 'number' ? 0 : undefined} {...props} />}</label>
      })}
      <button type="submit" className="btn" disabled={busy}>Enregistrer</button>
    </form>
  )
}
