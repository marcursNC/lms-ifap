'use client'
import { useRef } from 'react'
import { move } from '../../lib/content-rules.mjs'

const TYPE_LABELS = { pdf: 'PDF', link: 'Lien', scorm: 'SCORM' }

// Arbre des modules et contenus : sélection, ordre par glisser-déposer ou par boutons.
export default function ContentTree({ tree, selected, busy, onSelect, onReorder }) {
  const dragged = useRef(null)
  const moduleIds = tree.filter(m => m.id).map(m => m.id)

  const send = (modules, resourcesByModule) =>
    onReorder(modules, modules.concat(null).flatMap(id => resourcesByModule.get(id) || []))
  const current = () => new Map(tree.map(m => [m.id, m.resources.map(r => r.id)]))
  const shiftModule = (index, delta) => send(move(moduleIds, index, delta), current())
  const shiftResource = (moduleId, index, delta) => {
    const map = current()
    map.set(moduleId, move(map.get(moduleId), index, delta))
    send(moduleIds, map)
  }

  // Un élément ne se déplace que parmi ses semblables du même niveau.
  const draggable = (group, index, apply) => ({
    draggable: !busy,
    onDragStart: e => { e.stopPropagation(); e.dataTransfer.setData('text/plain', group); dragged.current = { group, index } },
    onDragOver: e => { if (dragged.current?.group === group) e.preventDefault() },
    onDrop: e => {
      const from = dragged.current
      if (from?.group !== group) return
      e.preventDefault(); e.stopPropagation(); dragged.current = null
      if (from.index !== index) apply(from.index, index - from.index)
    }
  })
  const arrows = (title, index, length, apply) => (
    <span className="editor-arrows">
      <button type="button" aria-label={`Monter ${title}`} disabled={busy || index === 0} onClick={() => apply(index, -1)}>↑</button>
      <button type="button" aria-label={`Descendre ${title}`} disabled={busy || index === length - 1} onClick={() => apply(index, 1)}>↓</button>
    </span>
  )
  const isSelected = (type, id) => selected?.type === type && selected.id === id

  return (
    <ol className="editor-tree">
      {tree.map((m, mi) => (
        <li key={m.id || 'loose'} className="editor-module" data-item={m.id || 'loose'} {...(m.id ? draggable('modules', mi, shiftModule) : {})}>
          <div className={`editor-row ${isSelected('module', m.id) ? 'selected' : ''}`}>
            {m.id
              ? <button type="button" className="editor-item" onClick={() => onSelect({ type: 'module', id: m.id })}><b>{mi + 1}. {m.title}</b></button>
              : <span className="editor-item"><b>{m.title}</b></span>}
            {m.id && arrows(m.title, mi, moduleIds.length, shiftModule)}
          </div>
          <ol>
            {m.resources.map((r, ri) => (
              <li key={r.id} data-item={r.id} className={`editor-row ${isSelected('resource', r.id) ? 'selected' : ''}`}
                {...draggable(`resources-${m.id}`, ri, (i, delta) => shiftResource(m.id, i, delta))}>
                <button type="button" className="editor-item" onClick={() => onSelect({ type: 'resource', id: r.id })}>
                  <span className="editor-type">{TYPE_LABELS[r.resource_type] || r.resource_type}</span>{r.title}
                </button>
                {arrows(r.title, ri, m.resources.length, (i, delta) => shiftResource(m.id, i, delta))}
              </li>
            ))}
          </ol>
          {m.id && <button type="button" className="editor-add" disabled={busy} onClick={() => onSelect({ type: 'new', id: m.id })}>+ Ajouter un contenu</button>}
        </li>
      ))}
    </ol>
  )
}
