import crypto from 'node:crypto'
import { createClient } from '@supabase/supabase-js'

function getAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!url || !key) {
    throw new Error('Configuration Supabase serveur manquante: NEXT_PUBLIC_SUPABASE_URL et SUPABASE_SERVICE_ROLE_KEY sont requis.')
  }
  return createClient(url, key, { auth: { persistSession: false } })
}

function validSignature(raw, signature) {
  const secret = process.env.VIRTUAL_CLASSROOM_WEBHOOK_SECRET
  if (!secret || !signature) return false
  const expected = crypto.createHmac('sha256', secret).update(raw).digest('hex')
  const a = Buffer.from(expected)
  const b = Buffer.from(signature)
  return a.length === b.length && crypto.timingSafeEqual(a, b)
}

function normalizeEvent(body) {
  return {
    provider: body.provider || 'microsoft_teams',
    external_event_id: body.id || body.eventId || crypto.createHash('sha256').update(JSON.stringify(body)).digest('hex'),
    external_session_id: body.sessionId || body.meetingId || body.onlineMeetingId || body.externalSessionId || null,
    event_type: body.type || body.eventType || 'participant.updated',
    occurred_at: body.occurredAt || body.timestamp || new Date().toISOString(),
    participant: body.participant || body.data?.participant || {},
    payload: body,
  }
}

export async function GET(req) {
  const { searchParams } = new URL(req.url)
  const token = searchParams.get('validationToken')
  if (token) return new Response(token, { status: 200, headers: { 'Content-Type': 'text/plain' } })
  return Response.json({ ok: true, service: 'virtual-classroom-webhook' })
}

export async function POST(req) {
  const raw = await req.text()
  if (!validSignature(raw, req.headers.get('x-lms-signature'))) {
    return Response.json({ error: 'invalid_signature' }, { status: 401 })
  }

  let supabase
  try {
    supabase = getAdminClient()
    const body = JSON.parse(raw)
    const event = normalizeEvent(body)

    const { data: recorded, error: recordError } = await supabase.rpc('record_virtual_classroom_event', {
      p_provider: event.provider,
      p_external_event_id: event.external_event_id,
      p_external_session_id: event.external_session_id,
      p_event_type: event.event_type,
      p_occurred_at: event.occurred_at,
      p_payload: event.payload,
    })
    if (recordError) throw recordError

    if (!recorded) return Response.json({ ok: true, duplicate: true })

    const { data: session } = await supabase
      .from('sessions')
      .select('id, external_event_id, start_at, end_at')
      .eq('external_event_id', event.external_session_id)
      .maybeSingle()

    if (!session) return Response.json({ ok: true, recorded: true, matched: false })

    const participant = event.participant || {}
    const externalId = participant.id || participant.externalParticipantId || null
    const email = (participant.email || participant.userPrincipalName || '').toLowerCase().trim()

    let learnerQuery = supabase.from('learners').select('id,email').eq('is_active', true)
    if (email) learnerQuery = learnerQuery.ilike('email', email)
    else if (externalId) learnerQuery = learnerQuery.eq('external_reference', externalId)
    else return Response.json({ ok: true, recorded: true, matched: true, participantMatched: false })

    const { data: learner } = await learnerQuery.maybeSingle()
    if (!learner) return Response.json({ ok: true, recorded: true, matched: true, participantMatched: false })

    const { data: existing } = await supabase
      .from('attendance')
      .select('*')
      .eq('session_id', session.id)
      .eq('learner_id', learner.id)
      .maybeSingle()

    const eventType = event.event_type.toLowerCase()
    const joined = eventType.includes('join') || eventType.includes('connected')
    const left = eventType.includes('leave') || eventType.includes('disconnected')
    const patch = {
      session_id: session.id,
      learner_id: learner.id,
      present: true,
      checked_at: new Date().toISOString(),
      source: event.provider,
      external_participant_id: externalId,
      participation_data: participant,
    }
    if (joined && !existing?.joined_at) patch.joined_at = event.occurred_at
    if (left) {
      patch.left_at = event.occurred_at
      if (existing?.joined_at) {
        patch.attended_seconds = Math.max(0, Math.floor((new Date(event.occurred_at) - new Date(existing.joined_at)) / 1000))
      }
    }

    const { error: attendanceError } = await supabase
      .from('attendance')
      .upsert(patch, { onConflict: 'session_id,learner_id' })
    if (attendanceError) throw attendanceError

    return Response.json({ ok: true, recorded: true, matched: true, participantMatched: true })
  } catch (error) {
    console.error('virtual classroom webhook:', error)
    return Response.json({ error: 'webhook_processing_failed' }, { status: 400 })
  }
}
