-- Evaluation attempts: enforce that the learner is actually enrolled in the deployment/course.
create or replace function app_private.enforce_evaluation_attempt_scope()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
begin
  if not exists (
    select 1
    from evaluations ev
    join enrollments en on en.learner_id = new.learner_id
    join deployments d on d.id = en.deployment_id and d.course_id = ev.course_id
    where ev.id = new.evaluation_id
      and en.id is not null
  ) then
    raise exception 'Evaluation attempt requires an enrollment for the same course';
  end if;
  return new;
end;
$$;

revoke all on function app_private.enforce_evaluation_attempt_scope() from public;
grant execute on function app_private.enforce_evaluation_attempt_scope() to authenticated;

drop trigger if exists evaluation_attempt_scope_trigger on public.evaluation_attempts;
create trigger evaluation_attempt_scope_trigger
before insert or update on public.evaluation_attempts
for each row execute function app_private.enforce_evaluation_attempt_scope();

-- Recalculate completion after attendance/evaluation changes.
create or replace function app_private.recalculate_enrollment_completion(p_enrollment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_learner uuid;
  v_total_sessions integer;
  v_attended_sessions integer;
  v_required_evals integer;
  v_passed_required_evals integer;
  v_progress numeric := 0;
begin
  select learner_id into v_learner from public.enrollments where id=p_enrollment_id;
  if v_learner is null then return; end if;

  select count(*) into v_total_sessions
  from public.session_enrollments se
  where se.enrollment_id=p_enrollment_id;

  select count(*) into v_attended_sessions
  from public.session_enrollments se
  join public.attendance a
    on a.session_id=se.session_id
   and a.learner_id=v_learner
   and a.present=true
  where se.enrollment_id=p_enrollment_id;

  select count(*) into v_required_evals
  from public.evaluations ev
  join public.deployments d on d.course_id=ev.course_id
  join public.enrollments en on en.deployment_id=d.id
  where en.id=p_enrollment_id and ev.is_required=true;

  select count(*) into v_passed_required_evals
  from public.evaluations ev
  where ev.is_required=true
    and exists (
      select 1
      from public.enrollments en
      join public.deployments d on d.id=en.deployment_id and d.course_id=ev.course_id
      join public.evaluation_attempts ea on ea.evaluation_id=ev.id and ea.learner_id=en.learner_id
      where en.id=p_enrollment_id and ea.passed=true
    );

  if v_total_sessions > 0 then
    v_progress := greatest(v_progress, round((v_attended_sessions::numeric/v_total_sessions::numeric)*100,2));
  end if;

  if v_required_evals > 0 then
    v_progress := greatest(v_progress, round((v_passed_required_evals::numeric/v_required_evals::numeric)*100,2));
  end if;

  if v_total_sessions > 0
     and v_attended_sessions = v_total_sessions
     and v_passed_required_evals = v_required_evals then
    update public.enrollments
      set progress=100,
          status='completed',
          started_at=coalesce(started_at,now()),
          completed_at=coalesce(completed_at,now())
    where id=p_enrollment_id and status <> 'completed';
  elsif v_total_sessions = 0
        and v_required_evals > 0
        and v_passed_required_evals = v_required_evals then
    update public.enrollments
      set progress=100,
          status='completed',
          started_at=coalesce(started_at,now()),
          completed_at=coalesce(completed_at,now())
    where id=p_enrollment_id and status <> 'completed';
  else
    update public.enrollments
      set progress=greatest(progress,v_progress),
          started_at=case when v_progress > 0 then coalesce(started_at,now()) else started_at end
    where id=p_enrollment_id;
  end if;
end;
$$;

revoke all on function app_private.recalculate_enrollment_completion(uuid) from public;

create or replace function app_private.recalculate_from_attendance()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
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
$$;

revoke all on function app_private.recalculate_from_attendance() from public;

drop trigger if exists attendance_recalculate_completion on public.attendance;
create trigger attendance_recalculate_completion
after insert or update on public.attendance
for each row execute function app_private.recalculate_from_attendance();

create or replace function app_private.recalculate_from_evaluation()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
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
$$;

revoke all on function app_private.recalculate_from_evaluation() from public;

drop trigger if exists evaluation_recalculate_completion on public.evaluation_attempts;
create trigger evaluation_recalculate_completion
after insert or update on public.evaluation_attempts
for each row execute function app_private.recalculate_from_evaluation();

-- Automatic certificate record once an enrollment is completed.
create or replace function app_private.issue_attestation_on_completion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_org_name text;
begin
  if new.status='completed' and new.completed_at is not null
     and not exists (select 1 from public.attestations a where a.enrollment_id=new.id) then
    select o.name into v_org_name
    from public.learners l
    join public.organizations o on o.id=l.organization_id
    where l.id=new.learner_id;

    insert into public.attestations (
      enrollment_id, issuer_name, verification_url
    )
    values (
      new.id,
      coalesce(v_org_name,'IFAP'),
      '/verify/' || gen_random_uuid()::text
    );
  end if;
  return new;
end;
$$;

revoke all on function app_private.issue_attestation_on_completion() from public;

drop trigger if exists enrollment_auto_attestation on public.enrollments;
create trigger enrollment_auto_attestation
after update on public.enrollments
for each row
when (new.status='completed' and old.status is distinct from new.status)
execute function app_private.issue_attestation_on_completion();

-- Public, minimal certificate verification endpoint.
create or replace function public.verify_attestation(p_token uuid)
returns table (
  certificate_number text,
  learner_name text,
  course_title text,
  issued_at timestamptz,
  revoked_at timestamptz,
  issuer_name text
)
language sql
security definer
set search_path = public, pg_catalog
as $$
  select
    a.certificate_number,
    concat(l.first_name,' ',l.last_name),
    c.title,
    a.issued_at,
    a.revoked_at,
    a.issuer_name
  from attestations a
  join enrollments e on e.id=a.enrollment_id
  join learners l on l.id=e.learner_id
  join deployments d on d.id=e.deployment_id
  join courses c on c.id=d.course_id
  where a.verification_token=p_token;
$$;

revoke all on function public.verify_attestation(uuid) from public;
grant execute on function public.verify_attestation(uuid) to anon, authenticated;

-- Tighten evaluation visibility to users who can access the course through ownership or a deployment.
drop policy if exists evaluations_select on public.evaluations;
create policy evaluations_select on public.evaluations
for select to authenticated
using (
  exists (
    select 1 from courses c
    where c.id=evaluations.course_id
      and (
        app_private.is_platform_admin()
        or app_private.is_org_member(c.owner_organization_id)
        or exists (
          select 1 from deployments d
          where d.course_id=c.id
            and app_private.is_org_member(d.target_organization_id)
        )
      )
  )
);

-- Performance indexes.
create index if not exists evaluations_course_required_idx on public.evaluations(course_id,is_required);
create index if not exists evaluation_attempts_eval_learner_idx on public.evaluation_attempts(evaluation_id,learner_id,attempted_at desc);
create index if not exists attestations_verification_token_idx on public.attestations(verification_token);