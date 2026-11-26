-- Retour à l'état antérieur à 20261127000000_achevement_attestations.
-- Attention : rouvre les failles corrigées et rétablit les fonctions en panne.
-- Aucune donnée supprimée : les colonnes de trace (annulation, validation, révocation) sont conservées.
begin;

drop function public.cancel_enrollment(uuid);
drop function public.reactivate_enrollment(uuid);
drop function public.validate_enrollment(uuid, text);
drop function public.revoke_attestation(uuid, text);
drop function public.list_course_enrollments(uuid);

drop trigger completion_on_activity on public.learning_activity_log;
drop trigger completion_on_attempt on public.evaluation_attempts;
drop trigger completion_on_attendance on public.attendance;
drop trigger completion_on_registration on public.session_enrollments;
drop trigger enrollments_initial_state on public.enrollments;
drop trigger enrollments_protect_history on public.enrollments;
drop trigger session_enrollments_protect on public.session_enrollments;
drop trigger sessions_protect on public.sessions;
drop policy learning_activity_log_insert_self on public.learning_activity_log;

alter table public.enrollments drop constraint enrollments_status_check;
drop index public.attestations_one_active_per_enrollment;
alter table public.attestations drop constraint attestations_enrollment_id_fkey;
alter table public.attestations add constraint attestations_enrollment_id_fkey
  foreign key (enrollment_id) references public.enrollments(id) on delete cascade;

set check_function_bodies = off;
CREATE OR REPLACE FUNCTION public.recalculate_enrollment_completion_for_current_user(p_enrollment_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'app_private'
AS $function$
declare learner_id_value uuid; result numeric;
begin
 select learner_id into learner_id_value from enrollments where id=p_enrollment_id;
 if not exists(select 1 from learners where id=learner_id_value and user_id=auth.uid()) then
   raise exception 'not allowed';
 end if;
 select app_private.recalculate_enrollment_completion(p_enrollment_id) into result;
 return result;
end $function$
;
revoke all on function public.recalculate_enrollment_completion_for_current_user(uuid) from public, anon, authenticated, service_role;
grant execute on function public.recalculate_enrollment_completion_for_current_user(uuid) to authenticated;
grant execute on function public.recalculate_enrollment_completion_for_current_user(uuid) to anon;
grant execute on function public.recalculate_enrollment_completion_for_current_user(uuid) to service_role;

CREATE OR REPLACE FUNCTION app_private.recalculate_from_attendance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare v_enrollment uuid;
begin
  select se.enrollment_id into v_enrollment
  from public.session_enrollments se
  where se.session_id=new.session_id
    and exists (select 1 from public.enrollments en where en.id=se.enrollment_id and en.learner_id=new.learner_id)
  limit 1;
  if v_enrollment is not null then
    perform app_private.recalculate_enrollment_completion(v_enrollment);
  end if;
  return new;
end;
$function$
;
revoke all on function app_private.recalculate_from_attendance() from public, anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION app_private.recalculate_from_evaluation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare v_enrollment uuid;
begin
  select en.id into v_enrollment
  from public.enrollments en
  join public.deployments d on d.id=en.deployment_id
  join public.evaluations ev on ev.course_id=d.course_id
  where ev.id=new.evaluation_id and en.learner_id=new.learner_id
  limit 1;
  if v_enrollment is not null then
    perform app_private.recalculate_enrollment_completion(v_enrollment);
  end if;
  return new;
end;
$function$
;
revoke all on function app_private.recalculate_from_evaluation() from public, anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION app_private.trigger_recalculate_on_attendance()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare eid uuid;
begin
 select e.id into eid from enrollments e where e.learner_id=new.learner_id and exists(select 1 from session_enrollments se where se.session_id=new.session_id and se.enrollment_id=e.id) limit 1;
 if eid is not null then perform app_private.recalculate_enrollment_session_progress(eid); end if;
 return new;
end $function$
;
revoke all on function app_private.trigger_recalculate_on_attendance() from public, anon, authenticated, service_role;
grant execute on function app_private.trigger_recalculate_on_attendance() to authenticated;

CREATE OR REPLACE FUNCTION app_private.trigger_recalculate_on_evaluation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare eid uuid;
begin
 select e.id into eid from enrollments e where e.learner_id=new.learner_id and e.deployment_id in (select d.id from deployments d join evaluations ev on ev.course_id=d.course_id where ev.id=new.evaluation_id) limit 1;
 if eid is not null then perform app_private.recalculate_enrollment_completion(eid); end if;
 return new;
end $function$
;
revoke all on function app_private.trigger_recalculate_on_evaluation() from public, anon, authenticated, service_role;
grant execute on function app_private.trigger_recalculate_on_evaluation() to authenticated;

CREATE OR REPLACE FUNCTION app_private.recalculate_activity_enrollment_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare total_required integer; completed_required integer; new_progress numeric; course_id_value uuid;
begin
  select d.course_id into course_id_value
  from enrollments e join deployments d on d.id=e.deployment_id where e.id=new.enrollment_id;

  select count(*) into total_required from course_modules where course_id=course_id_value and is_required=true;
  if total_required=0 then return new; end if;

  select count(*) into completed_required
  from course_modules cm
  where cm.course_id=course_id_value and cm.is_required=true
    and exists (
      select 1 from learning_activity_log lal
      where lal.enrollment_id=new.enrollment_id
        and lal.module_id=cm.id
        and lal.activity_type='module_completed'
    );

  new_progress := round((completed_required::numeric / total_required::numeric) * 100, 2);

  update enrollments
  set progress=new_progress,
      status=case when new_progress >= 100 then 'completed' else case when status='not_started' then 'in_progress' else status end end,
      started_at=coalesce(started_at, now()),
      completed_at=case when new_progress >= 100 then coalesce(completed_at, now()) else null end
  where id=new.enrollment_id;
  return new;
end;
$function$
;
revoke all on function app_private.recalculate_activity_enrollment_progress() from public, anon, authenticated, service_role;
grant execute on function app_private.recalculate_activity_enrollment_progress() to authenticated;

CREATE OR REPLACE FUNCTION app_private.recalculate_enrollment_session_progress(p_enrollment_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare total_required integer:=0; done_required integer:=0; s record; new_progress numeric; attendance_ok boolean;
begin
 for s in
   select s.id,s.start_at,s.end_at,s.required_attendance_percent,se.enrollment_id
   from session_enrollments se join sessions s on s.id=se.session_id
   where se.enrollment_id=p_enrollment_id
 loop
   total_required:=total_required+1;
   select coalesce(a.attendance_percent,case when a.present then 100 else 0 end,0) >= coalesce(s.required_attendance_percent,80)
     into attendance_ok
   from attendance a
   join enrollments e on e.learner_id=a.learner_id
   where a.session_id=s.id and e.id=p_enrollment_id
   limit 1;
   if coalesce(attendance_ok,false) then done_required:=done_required+1; end if;
 end loop;
 if total_required=0 then return null; end if;
 new_progress:=round(done_required::numeric/total_required*100,2);
 perform app_private.recalculate_enrollment_completion(p_enrollment_id);
 return new_progress;
end $function$
;
revoke all on function app_private.recalculate_enrollment_session_progress(uuid) from public, anon, authenticated, service_role;
grant execute on function app_private.recalculate_enrollment_session_progress(uuid) to authenticated;

CREATE OR REPLACE FUNCTION app_private.recalculate_enrollment_progress_v27(p_enrollment_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare course_id_value uuid; total_weight numeric:=0; done_weight numeric:=0; r record; module_done boolean; new_progress numeric;
begin
 select d.course_id into course_id_value from enrollments e join deployments d on d.id=e.deployment_id where e.id=p_enrollment_id;
 if course_id_value is null then return 0; end if;

 for r in
   select cm.id,cm.is_required
   from course_modules cm where cm.course_id=course_id_value
   order by cm.position
 loop
   if r.is_required then
     total_weight:=total_weight+1;
     select exists(select 1 from learning_activity_log where enrollment_id=p_enrollment_id and module_id=r.id and activity_type='module_completed') into module_done;
     if module_done then done_weight:=done_weight+1; end if;
   end if;
 end loop;

 new_progress:=case when total_weight=0 then 0 else round(done_weight/total_weight*100,2) end;
 update enrollments set progress=new_progress,
   status=case when new_progress>=100 then 'completed' else case when status='not_started' then 'in_progress' else status end end,
   started_at=coalesce(started_at,now()),
   completed_at=case when new_progress>=100 then coalesce(completed_at,now()) else null end
 where id=p_enrollment_id;
 return new_progress;
end $function$
;
revoke all on function app_private.recalculate_enrollment_progress_v27(uuid) from public, anon, authenticated, service_role;
grant execute on function app_private.recalculate_enrollment_progress_v27(uuid) to authenticated;

CREATE OR REPLACE FUNCTION app_private.recalculate_enrollment_completion(p_enrollment_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare course_id_value uuid; learner_id_value uuid; total_required integer:=0; completed_required integer:=0; m record; ok boolean; new_progress numeric;
begin
 select d.course_id,e.learner_id into course_id_value,learner_id_value from enrollments e join deployments d on d.id=e.deployment_id where e.id=p_enrollment_id;
 if course_id_value is null then return 0; end if;

 for m in select id from course_modules where course_id=course_id_value and is_required=true loop
   total_required:=total_required+1;
   ok:=true;
   if exists(select 1 from course_resources r where r.module_id=m.id and r.is_required=true
             and not exists(select 1 from learning_activity_log a where a.enrollment_id=p_enrollment_id and a.resource_id=r.id and a.activity_type='resource_completed')) then ok:=false; end if;
   if exists(select 1 from evaluations ev where ev.course_id=course_id_value and ev.is_required=true)
      and not exists(select 1 from evaluations ev join evaluation_attempts ea on ea.evaluation_id=ev.id where ev.course_id=course_id_value and ev.is_required=true and ea.learner_id=learner_id_value and ea.passed=true) then ok:=false; end if;
   if ok then completed_required:=completed_required+1; end if;
 end loop;

 new_progress:=case when total_required=0 then 0 else round(completed_required::numeric/total_required*100,2) end;
 update enrollments set progress=new_progress,status=case when new_progress>=100 then 'completed' else case when status='not_started' then 'in_progress' else status end end,started_at=coalesce(started_at,now()),completed_at=case when new_progress>=100 then coalesce(completed_at,now()) else null end where id=p_enrollment_id;
 return new_progress;
end $function$
;
revoke all on function app_private.recalculate_enrollment_completion(uuid) from public, anon, authenticated, service_role;
grant execute on function app_private.recalculate_enrollment_completion(uuid) to authenticated;

CREATE OR REPLACE FUNCTION app_private.update_enrollment_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare total integer; done integer; new_progress numeric;
begin
  select count(*) into total from public.session_enrollments se join public.sessions s on s.id=se.session_id where se.enrollment_id=new.enrollment_id;
  select count(*) into done from public.session_enrollments se join public.sessions s on s.id=se.session_id join public.attendance a on a.session_id=s.id
    join public.enrollments e on e.id=se.enrollment_id
    where se.enrollment_id=new.enrollment_id and a.learner_id=e.learner_id and a.present;
  if total > 0 then
    new_progress := round((done::numeric / total::numeric)*100,2);
    update public.enrollments set progress=greatest(progress,new_progress), started_at=coalesce(started_at,now()) where id=new.enrollment_id;
  end if;
  return new;
end; $function$
;
revoke all on function app_private.update_enrollment_progress() from public, anon, authenticated, service_role;
grant execute on function app_private.update_enrollment_progress() to public;

CREATE OR REPLACE FUNCTION app_private.update_scorm_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
  update public.enrollments
  set progress=greatest(progress,new.progress),
      started_at=coalesce(started_at,new.started_at),
      completed_at=case when new.status in ('completed','passed') or new.lesson_status in ('completed','passed') then coalesce(new.completed_at,now()) else completed_at end,
      status=case when new.status in ('completed','passed') or new.lesson_status in ('completed','passed') then 'completed' else status end
  where id=new.enrollment_id;
  return new;
end; $function$
;
revoke all on function app_private.update_scorm_progress() from public, anon, authenticated, service_role;
grant execute on function app_private.update_scorm_progress() to public;

CREATE OR REPLACE FUNCTION app_private.recalculate_attendance_percent()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
declare v_duration integer;
begin
  if new.joined_at is not null and new.left_at is not null then
    v_duration := greatest(0, extract(epoch from (new.left_at-new.joined_at))::integer);
    new.attended_seconds := greatest(new.attended_seconds, v_duration);
  end if;

  select greatest(1, extract(epoch from (s.end_at-s.start_at))::integer)
  into v_duration
  from public.sessions s where s.id=new.session_id;

  if v_duration is not null then
    new.attendance_percent := least(100, round((new.attended_seconds::numeric / v_duration::numeric)*100,2));
  end if;
  return new;
end;
$function$
;
revoke all on function app_private.recalculate_attendance_percent() from public, anon, authenticated, service_role;
grant execute on function app_private.recalculate_attendance_percent() to public;

CREATE OR REPLACE FUNCTION app_private.issue_attestation_on_completion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  v_org_name text;
  v_token uuid;
begin
  if new.status='completed' and new.completed_at is not null
     and not exists (select 1 from public.attestations a where a.enrollment_id=new.id) then
    select o.name into v_org_name
    from public.learners l
    join public.organizations o on o.id=l.organization_id
    where l.id=new.learner_id;

    v_token := gen_random_uuid();
    insert into public.attestations (
      enrollment_id, verification_token, issuer_name, verification_url
    )
    values (
      new.id,
      v_token,
      coalesce(v_org_name,'IFAP'),
      '/verify/' || v_token::text
    );
  end if;
  return new;
end;
$function$
;
revoke all on function app_private.issue_attestation_on_completion() from public, anon, authenticated, service_role;


CREATE OR REPLACE FUNCTION app_private.enforce_enrollment_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target_org uuid; cap integer; current_count integer; deadline timestamptz;
  dep_status public.deployment_status; c_owner uuid; c_visibility text;
begin
  select d.target_organization_id, d.capacity, d.enrollment_deadline, d.status, c.owner_organization_id, c.visibility
    into target_org, cap, deadline, dep_status, c_owner, c_visibility
  from public.deployments d join public.courses c on c.id = d.course_id
  where d.id = new.deployment_id;

  if not exists (select 1 from public.learners l
                 where l.id = new.learner_id and l.organization_id = target_org and l.is_active) then
    raise exception 'L''apprenant doit être actif et appartenir à l''organisation destinataire';
  end if;
  if dep_status <> 'available'::public.deployment_status then
    raise exception 'Ce déploiement n''accepte plus d''inscription';
  end if;
  if new.enrollment_mode = 'self_service'::public.enrollment_mode
     and target_org <> c_owner and c_visibility <> 'ifap_catalog' then
    raise exception 'L''auto-inscription est impossible pour cette formation';
  end if;
  if tg_op = 'INSERT' and deadline is not null and now() > deadline then
    raise exception 'La date limite d''inscription est dépassée';
  end if;
  if tg_op = 'INSERT' and cap is not null then
    select count(*) into current_count from public.enrollments e
    where e.deployment_id = new.deployment_id and e.status in ('enrolled', 'started');
    if current_count >= cap then
      raise exception 'La capacité du déploiement est atteinte';
    end if;
  end if;
  return new;
end $function$
;
revoke all on function app_private.enforce_enrollment_rules() from public, anon, authenticated, service_role;


CREATE TRIGGER attendance_recalculate_completion AFTER INSERT OR UPDATE ON public.attendance FOR EACH ROW EXECUTE FUNCTION app_private.recalculate_from_attendance();
CREATE TRIGGER attendance_updates_progress AFTER INSERT OR UPDATE OF present ON public.attendance FOR EACH ROW EXECUTE FUNCTION app_private.update_enrollment_progress();
CREATE TRIGGER evaluation_recalculate_completion AFTER INSERT OR UPDATE ON public.evaluation_attempts FOR EACH ROW EXECUTE FUNCTION app_private.recalculate_from_evaluation();
CREATE TRIGGER scorm_attempt_progress AFTER INSERT OR UPDATE ON public.scorm_attempts FOR EACH ROW EXECUTE FUNCTION app_private.update_scorm_progress();
CREATE TRIGGER trg_attendance_recalculate_completion AFTER INSERT OR UPDATE ON public.attendance FOR EACH ROW EXECUTE FUNCTION app_private.trigger_recalculate_on_attendance();
CREATE TRIGGER trg_eval_recalculate_completion AFTER INSERT OR UPDATE ON public.evaluation_attempts FOR EACH ROW EXECUTE FUNCTION app_private.trigger_recalculate_on_evaluation();
CREATE TRIGGER trg_recalculate_activity_enrollment_progress AFTER INSERT ON public.learning_activity_log FOR EACH ROW WHEN ((new.activity_type = 'module_completed'::text)) EXECUTE FUNCTION app_private.recalculate_activity_enrollment_progress();
create policy attempts_manage on public.evaluation_attempts for all to authenticated
using ((EXISTS ( SELECT 1
   FROM learners l
  WHERE ((l.id = evaluation_attempts.learner_id) AND app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role, 'trainer'::member_role, 'platform_admin'::member_role])))))
with check ((EXISTS ( SELECT 1
   FROM learners l
  WHERE ((l.id = evaluation_attempts.learner_id) AND app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role, 'trainer'::member_role, 'platform_admin'::member_role])))));
create policy attestations_insert on public.attestations for insert to authenticated
with check ((EXISTS ( SELECT 1
   FROM (enrollments e
     JOIN learners l ON ((l.id = e.learner_id)))
  WHERE ((e.id = attestations.enrollment_id) AND app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role, 'trainer'::member_role, 'platform_admin'::member_role])))));
create policy certificates_insert on storage.objects for insert to authenticated
with check (((bucket_id = 'certificates'::text) AND (EXISTS ( SELECT 1
   FROM ((attestations a
     JOIN enrollments e ON ((e.id = a.enrollment_id)))
     JOIN learners l ON ((l.id = e.learner_id)))
  WHERE ((a.pdf_path = objects.name) AND app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role, 'trainer'::member_role, 'platform_admin'::member_role]))))));
create policy certificates_update on storage.objects for update to authenticated
using (((bucket_id = 'certificates'::text) AND (EXISTS ( SELECT 1
   FROM ((attestations a
     JOIN enrollments e ON ((e.id = a.enrollment_id)))
     JOIN learners l ON ((l.id = e.learner_id)))
  WHERE ((a.pdf_path = objects.name) AND app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role, 'trainer'::member_role, 'platform_admin'::member_role]))))))
with check ((bucket_id = 'certificates'::text));
create policy learning_activity_insert_self on public.learning_activity_log for insert to authenticated
with check ((EXISTS ( SELECT 1
   FROM (enrollments e
     JOIN learners l ON ((l.id = e.learner_id)))
  WHERE ((e.id = learning_activity_log.enrollment_id) AND (l.user_id = auth.uid())))));
create policy learning_activity_log_insert_self on public.learning_activity_log for insert to authenticated
with check ((EXISTS ( SELECT 1
   FROM ((enrollments e
     JOIN learners l ON ((l.id = e.learner_id)))
     JOIN deployments d ON ((d.id = e.deployment_id)))
  WHERE ((e.id = learning_activity_log.enrollment_id) AND (l.user_id = auth.uid()) AND ((learning_activity_log.resource_id IS NULL) OR (EXISTS ( SELECT 1
           FROM course_resources r
          WHERE ((r.id = learning_activity_log.resource_id) AND (r.course_id = d.course_id))))) AND ((learning_activity_log.module_id IS NULL) OR (EXISTS ( SELECT 1
           FROM course_modules cm
          WHERE ((cm.id = learning_activity_log.module_id) AND (cm.course_id = d.course_id)))))))));
create policy learning_activity_manage on public.learning_activity_log for all to authenticated
using ((app_private.is_platform_admin() OR (EXISTS ( SELECT 1
   FROM (enrollments e
     JOIN learners l ON ((l.id = e.learner_id)))
  WHERE ((e.id = learning_activity_log.enrollment_id) AND app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role, 'trainer'::member_role, 'platform_admin'::member_role]))))))
with check ((app_private.is_platform_admin() OR (EXISTS ( SELECT 1
   FROM (enrollments e
     JOIN learners l ON ((l.id = e.learner_id)))
  WHERE ((e.id = learning_activity_log.enrollment_id) AND app_private.is_org_member(l.organization_id, ARRAY['org_admin'::member_role, 'trainer'::member_role, 'platform_admin'::member_role]))))));
grant delete, insert, truncate, update on public.attestations to anon;
grant delete, insert, truncate, update on public.attestations to authenticated;
grant delete, truncate, update on public.enrollments to anon;
grant delete, truncate, update on public.enrollments to authenticated;
grant delete, insert, truncate, update on public.evaluation_attempts to anon;
grant delete, insert, truncate, update on public.evaluation_attempts to authenticated;

drop function app_private.completion_from_activity();
drop function app_private.completion_from_attempt();
drop function app_private.completion_from_attendance();
drop function app_private.completion_from_registration();
drop function app_private.apply_completion(uuid);
drop function app_private.issue_attestation(uuid);
drop function app_private.enforce_enrollment_initial_state();
drop function app_private.protect_enrollment_history();
drop function app_private.protect_session_registration();
drop function app_private.protect_session();
drop function app_private.assert_session_owner(uuid);
drop function app_private.is_course_owner_admin(uuid);

commit;
