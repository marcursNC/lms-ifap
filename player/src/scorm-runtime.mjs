// API SCORM 1.2 fournie au module. Fichier autonome : le lecteur l'envoie tel quel au navigateur.
const STATUSES = ['passed', 'completed', 'failed', 'incomplete', 'browsed', 'not attempted']
const ERRORS = {
  '0': 'Aucune erreur', '101': 'Erreur générale', '201': 'Argument invalide', '301': 'Non initialisé',
  '401': 'Élément non pris en charge', '403': 'Élément en lecture seule', '404': 'Élément en écriture seule',
  '405': 'Type de donnée incorrect'
}
const number = v => v === '' || (/^\d{1,3}(\.\d+)?$/.test(v) && Number(v) <= 100)

export function parseSessionTime(value) {
  const m = /^(\d{2,4}):([0-5]\d):([0-5]\d)(\.\d{1,2})?$/.exec(value)
  return m ? Number(m[1]) * 3600 + Number(m[2]) * 60 + Number(m[3]) : null
}
const clock = seconds => [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60]
  .map((n, i) => String(n).padStart(i ? 2 : 4, '0')).join(':')

// state : réponse de scorm_open, ou null pour un aperçu (rien n'est alors transmis).
export function createApi(state, { onCommit }) {
  let running = false, finished = false, error = '0'
  const changed = {}
  const values = {
    'cmi.core.student_id': state?.student_id ?? 'apercu',
    'cmi.core.student_name': state?.student_name ?? 'Aperçu',
    'cmi.core.lesson_location': state?.lesson_location ?? '',
    'cmi.core.lesson_status': state?.lesson_status ?? 'not attempted',
    'cmi.core.credit': state ? 'credit' : 'no-credit',
    'cmi.core.entry': state?.entry === 'resume' ? 'resume' : 'ab-initio',
    'cmi.core.lesson_mode': state ? 'normal' : 'browse',
    'cmi.core.score.raw': state?.score_raw == null ? '' : String(state.score_raw),
    'cmi.core.score.min': '', 'cmi.core.score.max': '',
    'cmi.core.total_time': clock(state?.total_time_seconds ?? 0),
    'cmi.core._children': 'student_id,student_name,lesson_location,credit,lesson_status,entry,score,total_time,lesson_mode,exit,session_time',
    'cmi.core.score._children': 'raw,min,max',
    'cmi.suspend_data': state?.suspend_data ?? '',
    'cmi.launch_data': '', 'cmi.comments': '', 'cmi.comments_from_lms': '',
    'cmi.student_data.mastery_score': state?.mastery_score == null ? '' : String(state.mastery_score),
    'cmi.interactions._count': '0', 'cmi.objectives._count': '0'
  }
  // élément modifiable -> [contrôle, clé transmise au LMS]
  const writable = {
    'cmi.core.lesson_location': [v => v.length <= 1000, 'lesson_location'],
    'cmi.core.lesson_status': [v => STATUSES.includes(v) && v !== 'not attempted', 'lesson_status'],
    'cmi.core.score.raw': [number, 'score_raw'],
    'cmi.core.score.min': [number], 'cmi.core.score.max': [number],
    'cmi.core.exit': [v => ['', 'time-out', 'suspend', 'logout'].includes(v)],
    'cmi.core.session_time': [v => parseSessionTime(v) !== null, 'session_seconds'],
    'cmi.suspend_data': [v => v.length <= 64000, 'suspend_data'],
    'cmi.comments': [v => v.length <= 4096]
  }
  const writeOnly = ['cmi.core.exit', 'cmi.core.session_time']
  const done = (code, result) => { error = code; return result }
  const send = final => { if (state) onCommit({ ...changed }, { final }) }

  return {
    LMSInitialize() {
      if (running || finished) return done('101', 'false')
      running = true
      return done('0', 'true')
    },
    LMSGetValue(key) {
      if (!running) return done('301', '')
      if (writeOnly.includes(key)) return done('404', '')
      return key in values ? done('0', values[key]) : done('401', '')
    },
    LMSSetValue(key, value) {
      if (!running) return done('301', 'false')
      if (/^cmi\.(interactions|objectives)\.\d+\./.test(key)) return done('0', 'true')
      const rule = writable[key]
      if (!rule) return done(key in values ? '403' : '401', 'false')
      const text = String(value)
      if (!rule[0](text)) return done('405', 'false')
      values[key] = text
      const name = rule[1]
      if (name === 'session_seconds') changed[name] = parseSessionTime(text)
      else if (name && !(name === 'score_raw' && text === '')) changed[name] = text
      return done('0', 'true')
    },
    LMSCommit() {
      if (!running) return done('301', 'false')
      send(false)
      return done('0', 'true')
    },
    LMSFinish() {
      if (!running) return done('301', 'false')
      if (values['cmi.core.lesson_status'] === 'not attempted') changed.lesson_status = 'incomplete'
      running = false; finished = true
      send(true)
      return done('0', 'true')
    },
    LMSGetLastError: () => error,
    LMSGetErrorString: code => ERRORS[code] ?? '',
    LMSGetDiagnostic: code => ERRORS[code || error] ?? ''
  }
}
