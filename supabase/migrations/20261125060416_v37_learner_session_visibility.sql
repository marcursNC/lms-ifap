
create or replace function app_private.is_current_user_enrolled_in_session(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, app_private
as $$
  select exists (
    select 1
    from public.session_enrollments se
    join public.enrollments en on en.id = se.enrollment_id
    join public.learners l on l.id = en.learner_id
    where se.session_id = p_session_id
      and l.user_id = auth.uid()
      and l.is_active = true
  );
$$;

revoke all on function app_private.is_current_user_enrolled_in_session(uuid) from public;
grant execute on function app_private.is_current_user_enrolled_in_session(uuid) to authenticated;

drop policy if exists sessions_select on public.sessions;
create policy sessions_select
on public.sessions
for select
to authenticated
using (
  exists (
    select 1
    from public.deployments d
    where d.id = sessions.deployment_id
      and (
        app_private.is_platform_admin()
        or app_private.is_org_member(d.target_organization_id)
      )
  )
  or app_private.is_current_user_enrolled_in_session(sessions.id)
);

drop policy if exists session_enrollments_select on public.session_enrollments;
create policy session_enrollments_select
on public.session_enrollments
for select
to authenticated
using (
  exists (
    select 1
    from public.sessions s
    join public.deployments d on d.id = s.deployment_id
    where s.id = session_enrollments.session_id
      and (
        app_private.is_platform_admin()
        or app_private.is_org_member(d.target_organization_id)
      )
  )
  or app_private.is_current_user_enrolled_in_session(session_enrollments.session_id)
);
