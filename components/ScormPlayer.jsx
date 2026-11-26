'use client'
import { useEffect, useRef, useState } from 'react'
import { createClient } from '../lib/supabase-browser'
import { frenchError } from '../lib/deployment-rules.mjs'

const PLAYER = process.env.NEXT_PUBLIC_PLAYER_URL || 'https://lms-ifap-lecteur.marcdelareunion.workers.dev'
const RETRY_MS = 5000

// Module SCORM affiché depuis le lecteur isolé. Les résultats passent par la session du LMS.
// Sans inscription (aperçu du gestionnaire), rien n'est enregistré.
export default function ScormPlayer({ resource, enrollment, onResult, onClose }) {
  const frame = useRef(null)
  const box = useRef(null)
  const live = useRef({ pending: null, sending: null, closing: null, session: null, packageId: null, retry: null, gone: false })
  const [opening, setOpening] = useState(null)
  const [error, setError] = useState('')
  const [unsaved, setUnsaved] = useState('')
  const [closing, setClosing] = useState(false)
  const [blocked, setBlocked] = useState(false)

  useEffect(() => {
    const l = live.current
    l.gone = false
    l.session = crypto.randomUUID()
    createClient().rpc('scorm_open', { p_resource: resource.id, p_enrollment: enrollment?.id ?? null }).then(({ data, error }) => {
      if (l.gone) return
      if (error || !data) setError(frenchError(error))
      else { l.packageId = data.package_id; setOpening(data) }
    })
    box.current?.focus()
    return () => { l.gone = true; clearTimeout(l.retry) }
  }, [resource.id, enrollment?.id])

  // Un envoi à la fois. Les données d'une séance sont cumulées : la dernière version suffit.
  function flush() {
    const l = live.current
    if (l.sending) return l.sending
    clearTimeout(l.retry)
    l.sending = (async () => {
      while (l.pending) {
        const data = l.pending
        let result
        try {
          result = await createClient().rpc('scorm_save', { p_enrollment: enrollment.id, p_package: l.packageId, p_session: l.session, p_data: data })
        } catch (e) { result = { error: e } }
        if (result.error) {
          setUnsaved(frenchError(result.error))
          if (!l.gone) l.retry = setTimeout(flush, RETRY_MS)
          return false
        }
        if (l.pending === data) l.pending = null
        setUnsaved('')
        onResult?.(result.data)
      }
      return true
    })().finally(() => { l.sending = null })
    return l.sending
  }

  useEffect(() => {
    if (!opening) return
    const receive = event => {
      // Seule la page du lecteur, à son adresse, est écoutée.
      if (event.origin !== new URL(PLAYER).origin || event.source !== frame.current?.contentWindow) return
      const message = event.data
      if (message?.type === 'scorm:ready') {
        event.source.postMessage({ type: 'scorm:init', token: opening.token, launch: opening.launch_path, state: opening.state }, event.origin)
      } else if (message?.type === 'scorm:commit' && enrollment && message.data) {
        live.current.pending = message.data
        flush()
      } else if (message?.type === 'scorm:closed') live.current.closing?.()
    }
    const warn = event => { if (live.current.pending) { event.preventDefault(); event.returnValue = '' } }
    window.addEventListener('message', receive)
    window.addEventListener('beforeunload', warn)
    return () => { window.removeEventListener('message', receive); window.removeEventListener('beforeunload', warn) }
  }, [opening])

  // Laisse le module enregistrer avant de fermer ; reste ouvert si l'envoi échoue.
  async function close() {
    if (closing) return
    setClosing(true)
    const l = live.current
    if (opening && frame.current) {
      await new Promise(resolve => {
        const timer = setTimeout(resolve, 1500)
        l.closing = () => { clearTimeout(timer); resolve() }
        frame.current.contentWindow.postMessage({ type: 'scorm:close' }, new URL(PLAYER).origin)
      })
    }
    await save()
  }

  async function save() {
    setClosing(true)
    if (!live.current.pending || await flush()) return onClose()
    setBlocked(true); setClosing(false)
  }

  return (
    <div className="scorm-overlay" role="dialog" aria-modal="true" aria-label={resource.title} tabIndex={-1} ref={box}>
      <div className="scorm-bar">
        <b>{resource.title}{!enrollment && ' (aperçu, rien n’est enregistré)'}</b>
        <button type="button" className="btn" disabled={closing} onClick={close}>{closing ? 'Fermeture…' : 'Fermer le module'}</button>
      </div>
      <div className="scorm-notice">
        {error && <div className="error" role="alert">{error}</div>}
        {unsaved && (
          <div className="error" role="alert">
            Votre avancement n’est pas encore enregistré. Nouvel essai automatique ; gardez cette page ouverte. ({unsaved})
            {blocked && (
              <div className="actions">
                <button type="button" className="btn" disabled={closing} onClick={save}>Réessayer</button>
                <button type="button" className="btn secondary" onClick={onClose}>Fermer sans enregistrer</button>
              </div>
            )}
          </div>
        )}
      </div>
      {opening && <iframe ref={frame} title={resource.title} src={`${PLAYER}/play`} allow="fullscreen" allowFullScreen
        sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads allow-modals" />}
    </div>
  )
}
