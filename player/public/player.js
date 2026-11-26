// Page du lecteur : fournit l'API SCORM au module et relaie les résultats au LMS.
import { createApi } from './scorm-runtime.mjs'
import { moduleUrl } from './scorm-keys.mjs'

const lms = document.body.dataset.lms
const frame = document.getElementById('module')
const tell = message => window.parent.postMessage(message, lms)
let started = false

window.addEventListener('message', event => {
  // Seul le LMS, qui encadre cette page, peut la piloter.
  if (event.origin !== lms || event.source !== window.parent) return
  const message = event.data
  if (message?.type === 'scorm:init' && !started) {
    started = true
    window.API = createApi(message.state, { onCommit: (data, info) => tell({ type: 'scorm:commit', data, final: info.final }) })
    frame.src = moduleUrl(message.token, message.launch)
  } else if (message?.type === 'scorm:close' && started) {
    // Décharger le module lui laisse enregistrer ; on clôt ensuite s'il ne l'a pas fait.
    frame.addEventListener('load', () => { window.API.LMSFinish(''); tell({ type: 'scorm:closed' }) }, { once: true })
    frame.src = 'about:blank'
  }
})
tell({ type: 'scorm:ready' })
