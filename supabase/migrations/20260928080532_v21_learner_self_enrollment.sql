drop policy if exists enrollments_insert_learner on public.enrollments;
create policy enrollments_insert_learner on public.enrollments
for insert to authenticated
with check (
  exists (
    select 1
    from public.learners l
    join public.deployments d on d.target_organization_id=l.organization_id
    where l.id=enrollments.learner_id
      and l.user_id=auth.uid()
      and d.id=enrollments.deployment_id
      and d.status='available'
  )
);