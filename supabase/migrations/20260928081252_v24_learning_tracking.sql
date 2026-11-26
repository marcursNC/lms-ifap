create type public.session_tracking_mode as enum ('manual','webinar','virtual_classroom','meeting');

alter table public.sessions
  add column if not exists tracking_mode public.session_tracking_mode not null default 'manual',
  add column if not exists join_url text,
  add column if not exists external_event_id text,
  add column if not exists required_attendance_percent numeric not null default 80,
  add column if not exists recording_url text;

alter table public.attendance
  add column if not exists joined_at timestamptz,
  add column if not exists left_at timestamptz,
  add column if not exists attended_seconds integer not null default 0,
  add column if not exists attendance_percent numeric,
  add column if not exists source text,
  add column if not exists external_participant_id text,
  add column if not exists participation_data jsonb not null default '{}';

create table if not exists public.learning_activity_log (
  id uuid primary key default gen_random_uuid(),
  enrollment_id uuid not null references public.enrollments(id) on delete cascade,
  resource_id uuid references public.course_resources(id) on delete set null,
  session_id uuid references public.sessions(id) on delete set null,
  activity_type text not null,
  started_at timestamptz,
  ended_at timestamptz,
  duration_seconds integer not null default 0,
  progress numeric,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now(),
  constraint learning_activity_duration_check check (duration_seconds >= 0),
  constraint learning_activity_progress_check check (progress is null or (progress >= 0 and progress <= 100))
);

create index if not exists learning_activity_enrollment_idx on public.learning_activity_log(enrollment_id,created_at desc);
create index if not exists learning_activity_session_idx on public.learning_activity_log(session_id,created_at desc);
create index if not exists attendance_session_learner_idx on public.attendance(session_id,learner_id);

alter table public.learning_activity_log enable row level security;

create policy learning_activity_select on public.learning_activity_log
for select to authenticated
using (
  exists (
    select 1
    from public.enrollments e
    join public.learners l on l.id=e.learner_id
    where e.id=learning_activity_log.enrollment_id
      and (
        l.user_id=auth.uid()
        or app_private.is_platform_admin()
        or app_private.is_org_member(l.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
      )
  )
);

create policy learning_activity_insert_self on public.learning_activity_log
for insert to authenticated
with check (
  exists (
    select 1 from public.enrollments e
    join public.learners l on l.id=e.learner_id
    where e.id=learning_activity_log.enrollment_id and l.user_id=auth.uid()
  )
);

create policy learning_activity_manage on public.learning_activity_log
for all to authenticated
using (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.enrollments e
    join public.learners l on l.id=e.learner_id
    where e.id=learning_activity_log.enrollment_id
      and app_private.is_org_member(l.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
)
with check (
  app_private.is_platform_admin()
  or exists (
    select 1 from public.enrollments e
    join public.learners l on l.id=e.learner_id
    where e.id=learning_activity_log.enrollment_id
      and app_private.is_org_member(l.organization_id, array['org_admin'::member_role,'trainer'::member_role,'platform_admin'::member_role])
  )
);

create or replace function app_private.recalculate_attendance_percent()
returns trigger
language plpgsql
security definer
set search_path=public,app_private
as $$
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
$$;

drop trigger if exists attendance_percent_trigger on public.attendance;
create trigger attendance_percent_trigger
before insert or update on public.attendance
for each row execute function app_private.recalculate_attendance_percent();