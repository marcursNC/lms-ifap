import test from 'node:test'
import assert from 'node:assert/strict'
import { createApi, parseSessionTime } from '../player/src/scorm-runtime.mjs'

const state = { student_id: 'e1', student_name: 'Test, Agent', lesson_status: 'incomplete', score_raw: 40, lesson_location: '3', suspend_data: '{"a":1}', total_time_seconds: 3723, mastery_score: null, entry: 'resume' }
const make = (s = state) => { const sent = []; const api = createApi(s, { onCommit: (data, info) => sent.push({ data, ...info }) }); return { api, sent } }
const err = api => api.LMSGetLastError()

test('rien avant Initialize', () => {
  const { api, sent } = make()
  assert.equal(api.LMSGetValue('cmi.core.lesson_status'), '')
  assert.equal(err(api), '301')
  assert.equal(api.LMSSetValue('cmi.suspend_data', 'x'), 'false')
  assert.equal(api.LMSCommit(''), 'false')
  assert.equal(api.LMSFinish(''), 'false')
  assert.equal(sent.length, 0)
})
test('état précédent restitué', () => {
  const { api } = make()
  assert.equal(api.LMSInitialize(''), 'true')
  assert.equal(api.LMSInitialize(''), 'false')
  const get = k => api.LMSGetValue(k)
  assert.equal(get('cmi.core.entry'), 'resume')
  assert.equal(get('cmi.core.lesson_location'), '3')
  assert.equal(get('cmi.suspend_data'), '{"a":1}')
  assert.equal(get('cmi.core.lesson_status'), 'incomplete')
  assert.equal(get('cmi.core.score.raw'), '40')
  assert.equal(get('cmi.core.total_time'), '0001:02:03')
  assert.equal(get('cmi.core.student_name'), 'Test, Agent')
  assert.equal(err(api), '0')
})
test('lecture seule, écriture seule, élément inconnu', () => {
  const { api } = make(); api.LMSInitialize('')
  assert.equal(api.LMSSetValue('cmi.core.student_name', 'X'), 'false'); assert.equal(err(api), '403')
  assert.equal(api.LMSSetValue('cmi.core.student_id', 'X'), 'false'); assert.equal(err(api), '403')
  assert.equal(api.LMSGetValue('cmi.core.session_time'), ''); assert.equal(err(api), '404')
  assert.equal(api.LMSGetValue('cmi.nawak'), ''); assert.equal(err(api), '401')
  assert.equal(api.LMSSetValue('cmi.nawak', '1'), 'false'); assert.equal(err(api), '401')
  assert.notEqual(api.LMSGetErrorString('401'), '')
})
test('valeurs invalides refusées', () => {
  const { api } = make(); api.LMSInitialize('')
  for (const [k, v] of [['cmi.core.lesson_status', 'fini'], ['cmi.core.score.raw', '101'], ['cmi.core.score.raw', 'abc'],
    ['cmi.suspend_data', 'a'.repeat(64001)], ['cmi.core.session_time', '12'], ['cmi.core.exit', 'x']]) {
    assert.equal(api.LMSSetValue(k, v), 'false', k); assert.equal(err(api), '405', k)
  }
})
test('interactions et objectifs acceptés sans être conservés', () => {
  const { api, sent } = make(); api.LMSInitialize('')
  assert.equal(api.LMSSetValue('cmi.interactions.0.id', 'q1'), 'true')
  assert.equal(api.LMSSetValue('cmi.objectives.0.status', 'passed'), 'true')
  api.LMSCommit('')
  assert.deepEqual(sent.at(-1).data, {})
})
test('Commit transmet tout ce qui a changé, Finish clôt avec le temps', () => {
  const { api, sent } = make(); api.LMSInitialize('')
  api.LMSSetValue('cmi.core.lesson_location', '4'); api.LMSSetValue('cmi.core.score.raw', '75')
  assert.equal(api.LMSCommit(''), 'true')
  assert.deepEqual(sent[0], { data: { lesson_location: '4', score_raw: '75' }, final: false })
  api.LMSSetValue('cmi.core.lesson_status', 'completed'); api.LMSSetValue('cmi.core.session_time', '0000:01:30.50')
  assert.equal(api.LMSFinish(''), 'true')
  assert.deepEqual(sent[1], { data: { lesson_location: '4', score_raw: '75', lesson_status: 'completed', session_seconds: 90 }, final: true })
  assert.equal(api.LMSGetValue('cmi.core.lesson_status'), ''); assert.equal(err(api), '301')
})
test('un module sans statut reste en cours à la clôture', () => {
  const { api, sent } = make({ ...state, lesson_status: 'not attempted', entry: 'ab-initio' }); api.LMSInitialize('')
  api.LMSFinish('')
  assert.equal(sent[0].data.lesson_status, 'incomplete')
})
test('aperçu : sans stagiaire, rien n’est transmis', () => {
  const { api, sent } = make(null)
  assert.equal(api.LMSInitialize(''), 'true')
  assert.equal(api.LMSGetValue('cmi.core.lesson_mode'), 'browse')
  assert.equal(api.LMSSetValue('cmi.core.lesson_status', 'completed'), 'true')
  api.LMSCommit(''); api.LMSFinish('')
  assert.equal(sent.length, 0)
})
test('durées', () => {
  assert.equal(parseSessionTime('0001:02:03'), 3723)
  assert.equal(parseSessionTime('00:00:09.99'), 9)
  assert.equal(parseSessionTime('1:2'), null)
})
