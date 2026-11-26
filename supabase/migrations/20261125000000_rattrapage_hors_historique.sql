-- RATTRAPAGE — objets présents en production mais absents de l'historique des migrations.
-- Reconstitué le 27/11/2026 à partir des définitions de la base de production.
-- NE PAS EXÉCUTER SUR LA PRODUCTION : ces objets y existent déjà.
-- Rôle : permettre de reconstruire une base neuve (la migration v36 en dépend).

-- Colonnes ajoutées
alter table public.course_resources add column is_required boolean not null default true;
create index course_resources_module_required_idx on public.course_resources using btree (module_id, is_required);

alter table public.learning_activity_log add column module_id uuid;
alter table public.learning_activity_log
  add constraint learning_activity_log_module_id_fkey
  foreign key (module_id) references public.course_modules(id) on delete set null;
create index learning_activity_log_module_idx on public.learning_activity_log using btree (module_id);

-- Questions, réponses proposées, réponses données
create table public.evaluation_questions (
  id uuid not null default gen_random_uuid(),
  evaluation_id uuid not null,
  question_text text not null,
  question_type text not null default 'single_choice'::text,
  "position" integer not null default 1,
  points numeric not null default 1,
  explanation text,
  created_at timestamptz not null default now(),
  constraint evaluation_questions_pkey primary key (id),
  constraint evaluation_questions_evaluation_id_fkey foreign key (evaluation_id) references public.evaluations(id) on delete cascade,
  constraint evaluation_questions_points_check check (points > (0)::numeric),
  constraint evaluation_questions_question_type_check check (question_type = any (array['single_choice'::text, 'multiple_choice'::text, 'true_false'::text]))
);
create index evaluation_questions_eval_idx on public.evaluation_questions using btree (evaluation_id, "position");

create table public.evaluation_options (
  id uuid not null default gen_random_uuid(),
  question_id uuid not null,
  option_text text not null,
  is_correct boolean not null default false,
  "position" integer not null default 1,
  created_at timestamptz not null default now(),
  constraint evaluation_options_pkey primary key (id),
  constraint evaluation_options_question_id_fkey foreign key (question_id) references public.evaluation_questions(id) on delete cascade
);
create index evaluation_options_question_idx on public.evaluation_options using btree (question_id, "position");

create table public.evaluation_responses (
  id uuid not null default gen_random_uuid(),
  attempt_id uuid not null,
  question_id uuid not null,
  selected_option_ids uuid[] not null default '{}'::uuid[],
  is_correct boolean,
  points_awarded numeric not null default 0,
  created_at timestamptz not null default now(),
  constraint evaluation_responses_pkey primary key (id),
  constraint evaluation_responses_attempt_id_question_id_key unique (attempt_id, question_id),
  constraint evaluation_responses_attempt_id_fkey foreign key (attempt_id) references public.evaluation_attempts(id) on delete cascade,
  constraint evaluation_responses_question_id_fkey foreign key (question_id) references public.evaluation_questions(id) on delete cascade
);
create index evaluation_responses_attempt_idx on public.evaluation_responses using btree (attempt_id);

alter table public.evaluation_questions enable row level security;
alter table public.evaluation_options enable row level security;
alter table public.evaluation_responses enable row level security;

create policy evaluation_questions_select on public.evaluation_questions for select to authenticated
using (
  exists (
    select 1
    from public.evaluations e
    join public.enrollments en on en.deployment_id in (select d.id from public.deployments d where d.course_id = e.course_id)
    where e.id = evaluation_questions.evaluation_id
      and (
        app_private.is_platform_admin()
        or exists (select 1 from public.learners l where l.id = en.learner_id and l.user_id = auth.uid())
        or app_private.is_org_member(
             (select d.target_organization_id from public.deployments d where d.id = en.deployment_id),
             array['org_admin'::public.member_role, 'trainer'::public.member_role, 'platform_admin'::public.member_role])
      )
  )
);

create policy evaluation_options_select on public.evaluation_options for select to authenticated
using (exists (select 1 from public.evaluation_questions q where q.id = evaluation_options.question_id));

create policy evaluation_responses_self on public.evaluation_responses for all to authenticated
using (
  exists (select 1 from public.evaluation_attempts a join public.learners l on l.id = a.learner_id
          where a.id = evaluation_responses.attempt_id and l.user_id = auth.uid())
)
with check (
  exists (select 1 from public.evaluation_attempts a join public.learners l on l.id = a.learner_id
          where a.id = evaluation_responses.attempt_id and l.user_id = auth.uid())
);

create policy learning_activity_log_insert_self on public.learning_activity_log for insert to authenticated
with check (
  exists (
    select 1
    from public.enrollments e
    join public.learners l on l.id = e.learner_id
    join public.deployments d on d.id = e.deployment_id
    where e.id = learning_activity_log.enrollment_id
      and l.user_id = auth.uid()
      and (learning_activity_log.resource_id is null or exists (
            select 1 from public.course_resources r
            where r.id = learning_activity_log.resource_id and r.course_id = d.course_id))
      and (learning_activity_log.module_id is null or exists (
            select 1 from public.course_modules cm
            where cm.id = learning_activity_log.module_id and cm.course_id = d.course_id))
  )
);

-- Fonctions (corps repris à l'identique de la production)
-- Le type de retour passe de void à numeric : suppression préalable nécessaire.
drop function if exists app_private.recalculate_enrollment_completion(uuid);

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
end $function$;

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
$function$;

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
end $function$;

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
end $function$;

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
end $function$;

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
end $function$;

-- Inclut le réglage search_path de database/patches/v38_function_search_path.sql.
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
end $function$;

-- Droits d'exécution (état de la production)
revoke all on function
  app_private.recalculate_enrollment_completion(uuid),
  app_private.recalculate_activity_enrollment_progress(),
  app_private.recalculate_enrollment_progress_v27(uuid),
  app_private.recalculate_enrollment_session_progress(uuid),
  app_private.trigger_recalculate_on_attendance(),
  app_private.trigger_recalculate_on_evaluation()
from public;
grant execute on function
  app_private.recalculate_enrollment_completion(uuid),
  app_private.recalculate_activity_enrollment_progress(),
  app_private.recalculate_enrollment_progress_v27(uuid),
  app_private.recalculate_enrollment_session_progress(uuid),
  app_private.trigger_recalculate_on_attendance(),
  app_private.trigger_recalculate_on_evaluation()
to authenticated;
revoke all on function public.recalculate_enrollment_completion_for_current_user(uuid) from public;
grant execute on function public.recalculate_enrollment_completion_for_current_user(uuid) to anon, authenticated, service_role;

-- Déclencheurs
create trigger trg_attendance_recalculate_completion
  after insert or update on public.attendance
  for each row execute function app_private.trigger_recalculate_on_attendance();
create trigger trg_eval_recalculate_completion
  after insert or update on public.evaluation_attempts
  for each row execute function app_private.trigger_recalculate_on_evaluation();
create trigger trg_recalculate_activity_enrollment_progress
  after insert on public.learning_activity_log
  for each row when (new.activity_type = 'module_completed'::text)
  execute function app_private.recalculate_activity_enrollment_progress();
