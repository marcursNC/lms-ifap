'use client'
import Link from 'next/link'
import {useEffect,useState} from 'react'
import {useParams} from 'next/navigation'
import Shell from '../../../../components/Shell'
import {createClient} from '../../../../lib/supabase-browser'

export default function LearnerEvaluation(){
  const {id}=useParams()
  const [evaluation,setEvaluation]=useState(null),[questions,setQuestions]=useState([]),[answers,setAnswers]=useState({}),[loading,setLoading]=useState(true),[error,setError]=useState(''),[result,setResult]=useState(null),[busy,setBusy]=useState(false)

  useEffect(()=>{(async()=>{
    const s=createClient();const {data:{user}}=await s.auth.getUser();if(!user){location.href='/login';return}
    const {data:l}=await s.from('learners').select('id').eq('user_id',user.id).maybeSingle()
    if(!l){setError('Profil apprenant introuvable.');setLoading(false);return}
    const {data:e,error:ee}=await s.from('evaluations').select('id,course_id,title,description,pass_score,is_required,courses(title)').eq('id',id).maybeSingle()
    if(ee||!e){setError('Évaluation introuvable ou inaccessible.');setLoading(false);return}
    const {data:q,error:qe}=await s.from('evaluation_questions').select('id,question_text,question_type,position,points,explanation,evaluation_options(id,option_text,position)').eq('evaluation_id',id).order('position')
    if(qe){setError(qe.message);setLoading(false);return}
    setEvaluation(e);setQuestions(q||[]);setLoading(false)
  })()},[id])

  function choose(q,opt){
    setAnswers(prev=>({...prev,[q.id]:q.question_type==='multiple_choice'?[...new Set([...(prev[q.id]||[]),opt.id])]:opt.id}))
  }
  function toggle(q,opt){
    setAnswers(prev=>{const cur=prev[q.id]||[];return {...prev,[q.id]:cur.includes(opt.id)?cur.filter(x=>x!==opt.id):[...cur,opt.id]}})
  }
  async function submit(){
    if(questions.some(q=>!answers[q.id]||(Array.isArray(answers[q.id])&&!answers[q.id].length))){setError('Répondez à toutes les questions avant de valider.');return}
    setBusy(true);setError('')
    const s=createClient();const {data:{user}}=await s.auth.getUser();const {data:l}=await s.from('learners').select('id').eq('user_id',user.id).single()
    const {data:attempt,error:ae}=await s.from('evaluation_attempts').insert({evaluation_id:id,learner_id:l.id,score:0,max_score:questions.reduce((n,q)=>n+Number(q.points||1),0),passed:false,attempted_at:new Date().toISOString()}).select().single()
    if(ae){setError(ae.message);setBusy(false);return}
    let earned=0
    for(const q of questions){
      const selected=Array.isArray(answers[q.id])?answers[q.id]:[answers[q.id]]
      const correct=(q.evaluation_options||[]).filter(o=>o.is_correct).map(o=>o.id)
      const ok=selected.length===correct.length&&selected.every(x=>correct.includes(x))
      if(ok)earned+=Number(q.points||1)
      await s.from('evaluation_responses').insert({attempt_id:attempt.id,question_id:q.id,selected_option_ids:selected,is_correct:ok,points_awarded:ok?Number(q.points||1):0})
    }
    const max=questions.reduce((n,q)=>n+Number(q.points||1),0),score=max?Math.round(earned/max*100):0,passed=score>=Number(evaluation.pass_score||0)
    const {error:ue}=await s.from('evaluation_attempts').update({score,max_score:max,passed,feedback:passed?'Évaluation réussie.':'Évaluation non réussie. Vous pouvez reprendre le parcours.'}).eq('id',attempt.id)
    if(ue)setError(ue.message);else setResult({score,passed,attemptId:attempt.id})
    setBusy(false)
  }

  if(loading)return <Shell active="learner"><div className="card" role="status">Chargement de l’évaluation…</div></Shell>
  return <Shell active="learner"><main className="evaluation-page">
    <Link className="back-link" href="/learner">← Mon espace</Link>
    {error&&<div className="error" role="alert">{error}</div>}
    <header className="card evaluation-header"><div className="eyebrow">ÉVALUATION</div><h1>{evaluation?.title}</h1><p className="muted">{evaluation?.description||'Vérifiez vos acquis.'}</p><p className="small muted">Seuil de réussite : {evaluation?.pass_score||0}%</p></header>
    {result?<section className="card evaluation-result" aria-live="polite"><div className="eyebrow">{result.passed?'RÉUSSIE':'À REPRENDRE'}</div><h2>{result.score}%</h2><p>{result.passed?'Bravo, vous avez validé cette évaluation.':'Cette tentative n’atteint pas encore le seuil de réussite.'}</p><Link className="btn" href="/learner">Retour à mon espace</Link></section>:<section className="evaluation-questions" aria-label="Questions de l’évaluation">{questions.map((q,i)=><article className="card evaluation-question" key={q.id}><h2>{i+1}. {q.question_text}</h2>{q.question_type==='multiple_choice'&&<p className="small muted">Plusieurs réponses possibles.</p>}<div className="evaluation-options">{(q.evaluation_options||[]).map(o=><label key={o.id} className="evaluation-option"><input type={q.question_type==='multiple_choice'?'checkbox':'radio'} name={q.id} checked={q.question_type==='multiple_choice'?(answers[q.id]||[]).includes(o.id):answers[q.id]===o.id} onChange={()=>q.question_type==='multiple_choice'?toggle(q,o):choose(q,o)}/><span>{o.option_text}</span></label>)}</div></article>)}<button className="btn" type="button" disabled={busy||!questions.length} onClick={submit}>{busy?'Correction en cours…':'Valider mon évaluation'}</button></section>}
  </main></Shell>
}