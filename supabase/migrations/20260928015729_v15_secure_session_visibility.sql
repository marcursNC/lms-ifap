drop policy if exists sessions_select on public.sessions;
create policy sessions_select on public.sessions
for select to authenticated
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
);
create index if not exists session_enrollments_session_idx on public.session_enrollments(session_id);
create index if not exists attendance_session_idx on public.attendance(session_id);