create or replace view public.dashboard_enrollment_metrics
with (security_invoker=true)
as
select
  e.id as enrollment_id,
  e.status,
  e.progress,
  e.started_at,
  e.completed_at,
  l.id as learner_id,
  l.organization_id,
  o.name as organization_name,
  d.id as deployment_id,
  d.course_id,
  c.title as course_title,
  c.owner_organization_id,
  c.visibility as course_visibility,
  d.status as deployment_status
from public.enrollments e
join public.learners l on l.id=e.learner_id
join public.organizations o on o.id=l.organization_id
join public.deployments d on d.id=e.deployment_id
join public.courses c on c.id=d.course_id;

create or replace view public.dashboard_session_metrics
with (security_invoker=true)
as
select
  s.id as session_id,
  s.start_at,
  s.end_at,
  s.mode,
  s.status,
  d.id as deployment_id,
  d.target_organization_id as organization_id,
  o.name as organization_name,
  d.course_id,
  c.title as course_title,
  count(distinct se.enrollment_id) as registered_count,
  count(distinct case when a.present then a.learner_id end) as present_count
from public.sessions s
join public.deployments d on d.id=s.deployment_id
join public.organizations o on o.id=d.target_organization_id
join public.courses c on c.id=d.course_id
left join public.session_enrollments se on se.session_id=s.id
left join public.attendance a on a.session_id=s.id
group by s.id,d.id,o.id,c.id;

create or replace view public.dashboard_evaluation_metrics
with (security_invoker=true)
as
select
  ev.id as evaluation_id,
  ev.course_id,
  c.title as course_title,
  ev.title as evaluation_title,
  ev.is_required,
  ev.pass_score,
  ea.learner_id,
  l.organization_id,
  o.name as organization_name,
  ea.score,
  ea.passed,
  ea.attempted_at
from public.evaluations ev
join public.courses c on c.id=ev.course_id
left join public.evaluation_attempts ea on ea.evaluation_id=ev.id
left join public.learners l on l.id=ea.learner_id
left join public.organizations o on o.id=l.organization_id;

create or replace view public.dashboard_certificate_metrics
with (security_invoker=true)
as
select
  a.id as attestation_id,
  a.certificate_number,
  a.issued_at,
  a.revoked_at,
  e.id as enrollment_id,
  l.id as learner_id,
  l.organization_id,
  o.name as organization_name,
  d.course_id,
  c.title as course_title
from public.attestations a
join public.enrollments e on e.id=a.enrollment_id
join public.learners l on l.id=e.learner_id
join public.organizations o on o.id=l.organization_id
join public.deployments d on d.id=e.deployment_id
join public.courses c on c.id=d.course_id;

-- Explicit RLS-like protection through security_invoker views: users can only see
-- rows they can see in the underlying tables.
grant select on public.dashboard_enrollment_metrics to authenticated;
grant select on public.dashboard_session_metrics to authenticated;
grant select on public.dashboard_evaluation_metrics to authenticated;
grant select on public.dashboard_certificate_metrics to authenticated;