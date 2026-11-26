-- Retour arrière de 20261127000000_editeur_contenu.sql
-- Rétablit politiques, droits et fonctions. Conservés : les colonnes retired_at et position (les contenus
-- retirés redeviennent donc visibles et comptés) et le bucket course-resources avec ses fichiers.
begin;
drop trigger courses_publication_content on public.courses;
drop trigger completion_on_resource on public.course_resources;
drop trigger completion_on_module on public.course_modules;
drop trigger course_resources_same_course on public.course_resources;
drop trigger course_modules_same_course on public.course_modules;
drop function public.remove_course_item(text, uuid);
drop function public.reorder_course_content(uuid, uuid[], uuid[]);
drop function app_private.enforce_publication_content();
drop function app_private.completion_from_content();
drop function app_private.enforce_content_course();

create or replace function app_private.apply_completion(p_enrollment uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  e record;
  n_total integer := 0; n_done integer := 0; n integer; d integer;
  third_party boolean; met boolean; active boolean; new_status text;
begin
  select en.status, en.learner_id, en.started_at, dep.id as deployment_id, dep.status as deployment_status,
         dep.course_id, dep.target_organization_id <> c.owner_organization_id as external
    into e
  from public.enrollments en
  join public.deployments dep on dep.id = en.deployment_id
  join public.courses c on c.id = dep.course_id
  where en.id = p_enrollment
  for update of en;
  if not found or e.status in ('cancelled','completed','pending')
     or e.deployment_status = 'archived'::public.deployment_status then
    return;
  end if;

  -- ressources obligatoires (hors module ou dans un module obligatoire)
  select count(*), count(*) filter (where exists (
           select 1 from public.learning_activity_log a
           where a.enrollment_id = p_enrollment and a.resource_id = r.id and a.activity_type = 'resource_completed'))
    into n, d
  from public.course_resources r
  where r.course_id = e.course_id and r.is_required
    and (r.module_id is null or exists (select 1 from public.course_modules m where m.id = r.module_id and m.is_required));
  n_total := n_total + n; n_done := n_done + d;

  -- évaluations obligatoires, toutes
  select count(*), count(*) filter (where exists (
           select 1 from public.evaluation_attempts t
           where t.evaluation_id = ev.id and t.learner_id = e.learner_id and t.passed))
    into n, d
  from public.evaluations ev where ev.course_id = e.course_id and ev.is_required;
  n_total := n_total + n; n_done := n_done + d;

  -- séances où l'inscription est portée ; chez un tiers le seuil ne descend pas sous 80 %
  select count(*), count(*) filter (where exists (
           select 1 from public.attendance a
           where a.session_id = s.id and a.learner_id = e.learner_id and a.present
             and coalesce(a.attendance_percent, 0) >= case when e.external
                   then greatest(coalesce(s.required_attendance_percent, 80), 80)
                   else coalesce(s.required_attendance_percent, 80) end))
    into n, d
  from public.session_enrollments se join public.sessions s on s.id = se.session_id
  where se.enrollment_id = p_enrollment and s.status <> 'cancelled';
  n_total := n_total + n; n_done := n_done + d;

  third_party := e.external and exists (select 1 from public.sessions s where s.deployment_id = e.deployment_id);
  met := n_total > 0 and n_done = n_total;
  active := e.started_at is not null
    or exists (select 1 from public.learning_activity_log a where a.enrollment_id = p_enrollment)
    or exists (select 1 from public.evaluation_attempts t join public.evaluations ev on ev.id = t.evaluation_id
               where t.learner_id = e.learner_id and ev.course_id = e.course_id)
    or exists (select 1 from public.session_enrollments se join public.attendance a on a.session_id = se.session_id
               where se.enrollment_id = p_enrollment and a.learner_id = e.learner_id and a.present);
  if not active and not met then
    return;
  end if;

  new_status := case when not met then 'in_progress'
                     when third_party then 'awaiting_validation'
                     else 'completed' end;
  update public.enrollments set
    status = new_status,
    progress = case when n_total = 0 then 0 else round(n_done::numeric / n_total * 100, 2) end,
    started_at = coalesce(started_at, now()),
    completed_at = case when new_status = 'completed' then now() end
  where id = p_enrollment;
end $$;

drop policy course_files_select on storage.objects;
drop policy course_files_insert on storage.objects;
drop policy course_files_delete on storage.objects;
drop policy modules_select on public.course_modules;
create policy modules_select on public.course_modules for select to authenticated
using (exists (select 1 from public.courses c where c.id = course_modules.course_id));
drop policy course_resources_select on public.course_resources;
create policy course_resources_select on public.course_resources for select to authenticated
using (exists (select 1 from public.courses c where c.id = course_resources.course_id));
drop policy learning_activity_log_insert_self on public.learning_activity_log;
create policy learning_activity_log_insert_self on public.learning_activity_log
for insert to authenticated with check (
  exists (
    select 1 from public.enrollments e
    join public.learners l on l.id = e.learner_id
    join public.deployments d on d.id = e.deployment_id
    where e.id = learning_activity_log.enrollment_id
      and e.status <> 'cancelled'
      and l.user_id = (select auth.uid())
      and (learning_activity_log.resource_id is null or exists (
            select 1 from public.course_resources r
            where r.id = learning_activity_log.resource_id and r.course_id = d.course_id))
      and (learning_activity_log.module_id is null or exists (
            select 1 from public.course_modules cm
            where cm.id = learning_activity_log.module_id and cm.course_id = d.course_id))
  ));

drop function app_private.can_view_course_content(uuid);
drop function app_private.can_manage_course_content(uuid);
alter table public.course_resources
  drop constraint course_resources_https_check, drop constraint course_resources_path_check;
grant delete, truncate on public.course_modules, public.course_resources to anon, authenticated;
commit;
