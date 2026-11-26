drop policy if exists enrollments_insert_learner on public.enrollments;
create policy enrollments_insert_learner on public.enrollments
for insert to authenticated
with check (
  enrollment_mode='self_service'
  and exists (
    select 1
    from public.learners l
    join public.deployments d on d.target_organization_id=l.organization_id
    where l.id=enrollments.learner_id
      and l.user_id=auth.uid()
      and d.id=enrollments.deployment_id
      and d.status='available'
      and d.enrollment_mode='self_service'
      and (d.available_from is null or d.available_from <= now())
      and (d.available_until is null or d.available_until >= now())
      and (d.enrollment_deadline is null or d.enrollment_deadline >= now())
  )
);

create or replace function app_private.enroll_with_link(p_token uuid)
returns public.enrollments
language plpgsql
security definer
set search_path=public,app_private
as $$
declare
  v_link public.enrollment_links;
  v_learner public.learners;
  v_enrollment public.enrollments;
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;

  select * into v_link
  from public.enrollment_links
  where token=p_token and is_active=true
    and (expires_at is null or expires_at >= now())
    and (max_uses is null or uses_count < max_uses)
  for update;

  if not found then raise exception 'invalid_or_expired_link'; end if;

  select * into v_learner
  from public.learners
  where user_id=auth.uid() and is_active=true
  limit 1;

  if not found then raise exception 'learner_profile_not_found'; end if;

  if not exists (
    select 1 from public.deployments d
    where d.id=v_link.deployment_id
      and d.status='available'
      and d.enrollment_mode='link'
      and d.target_organization_id=v_learner.organization_id
      and (d.available_from is null or d.available_from <= now())
      and (d.available_until is null or d.available_until >= now())
      and (d.enrollment_deadline is null or d.enrollment_deadline >= now())
  ) then
    raise exception 'link_not_available_for_learner';
  end if;

  select * into v_enrollment from public.enrollments
  where deployment_id=v_link.deployment_id and learner_id=v_learner.id;

  if found then return v_enrollment; end if;

  insert into public.enrollments(deployment_id,learner_id,enrollment_mode,enrollment_source,status)
  values(v_link.deployment_id,v_learner.id,'link',p_token::text,'enrolled')
  returning * into v_enrollment;

  update public.enrollment_links set uses_count=uses_count+1 where id=v_link.id;

  return v_enrollment;
end;
$$;

revoke all on function app_private.enroll_with_link(uuid) from public;
grant execute on function app_private.enroll_with_link(uuid) to authenticated;

create or replace function public.enroll_with_link(p_token uuid)
returns public.enrollments
language sql
security invoker
set search_path=public
as $$ select app_private.enroll_with_link(p_token); $$;

revoke all on function public.enroll_with_link(uuid) from public;
grant execute on function public.enroll_with_link(uuid) to authenticated;