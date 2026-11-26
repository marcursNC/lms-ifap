alter table public.sessions
  add column if not exists status text not null default 'planned',
  add column if not exists notes text;
alter table public.sessions
  add constraint sessions_dates_check check (end_at is null or start_at is null or end_at >= start_at),
  add constraint sessions_capacity_check check (capacity is null or capacity > 0);

create table if not exists public.session_enrollments (
  session_id uuid not null references public.sessions(id) on delete cascade,
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (session_id,enrollment_id)
);
alter table public.session_enrollments enable row level security;

create unique index if not exists attendance_session_learner_uidx on public.attendance(session_id,learner_id);
alter table public.evaluation_attempts
  add column if not exists max_score numeric,
  add column if not exists feedback text;
alter table public.evaluations
  add column if not exists description text,
  add column if not exists is_required boolean not null default false;

do $$ begin
  if not exists(select 1 from pg_constraint where conname='enrollments_progress_check') then
    alter table public.enrollments add constraint enrollments_progress_check check (progress >= 0 and progress <= 100);
  end if;
  if not exists(select 1 from pg_constraint where conname='evaluation_pass_score_check') then
    alter table public.evaluations add constraint evaluation_pass_score_check check (pass_score is null or pass_score between 0 and 100);
  end if;
  if not exists(select 1 from pg_constraint where conname='evaluation_attempt_score_check') then
    alter table public.evaluation_attempts add constraint evaluation_attempt_score_check check (score is null or score >= 0);
  end if;
end $$;

create or replace function app_private.enforce_session_enrollment()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
declare d_id uuid; target_org uuid; cap integer; cnt integer;
begin
  select deployment_id into d_id from public.sessions where id=new.session_id;
  select target_organization_id,capacity into target_org,cap from public.deployments where id=d_id;
  if not exists(
    select 1 from public.enrollments e
    join public.learners l on l.id=e.learner_id
    where e.id=new.enrollment_id and e.deployment_id=d_id and l.organization_id=target_org
  ) then raise exception 'Session enrollment must reference an enrollment of the same deployment'; end if;
  if cap is not null then
    select count(*) into cnt from public.session_enrollments where session_id=new.session_id;
    if cnt >= cap then raise exception 'Session capacity reached'; end if;
  end if;
  return new;
end; $$;

drop trigger if exists session_enrollments_enforce on public.session_enrollments;
create trigger session_enrollments_enforce before insert on public.session_enrollments
for each row execute function app_private.enforce_session_enrollment();

drop policy if exists session_enrollments_select on public.session_enrollments;
create policy session_enrollments_select on public.session_enrollments for select to authenticated
using (exists(select 1 from public.sessions s join public.deployments d on d.id=s.deployment_id where s.id=session_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id))));
drop policy if exists session_enrollments_manage on public.session_enrollments;
create policy session_enrollments_manage on public.session_enrollments for all to authenticated
using (exists(select 1 from public.sessions s join public.deployments d on d.id=s.deployment_id where s.id=session_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))))
with check (exists(select 1 from public.sessions s join public.deployments d on d.id=s.deployment_id where s.id=session_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

drop policy if exists attendance_select on public.attendance;
create policy attendance_select on public.attendance for select to authenticated
using (exists(select 1 from public.sessions s join public.deployments d on d.id=s.deployment_id where s.id=session_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id) or exists(select 1 from public.learners l where l.id=attendance.learner_id and l.user_id=(select auth.uid())))));
drop policy if exists attendance_manage on public.attendance;
create policy attendance_manage on public.attendance for all to authenticated
using (exists(select 1 from public.sessions s join public.deployments d on d.id=s.deployment_id where s.id=session_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))))
with check (exists(select 1 from public.sessions s join public.deployments d on d.id=s.deployment_id where s.id=session_id and (app_private.is_platform_admin() or app_private.is_org_member(d.target_organization_id,array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role]))));

create or replace function app_private.update_enrollment_progress()
returns trigger language plpgsql set search_path=public,pg_catalog as $$
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
end; $$;

drop trigger if exists attendance_updates_progress on public.attendance;
create trigger attendance_updates_progress after insert or update of present on public.attendance
for each row execute function app_private.update_enrollment_progress();

create index if not exists session_enrollments_enrollment_idx on public.session_enrollments(enrollment_id);
create index if not exists attendance_session_idx on public.attendance(session_id);
create index if not exists evaluation_attempts_learner_idx on public.evaluation_attempts(learner_id);