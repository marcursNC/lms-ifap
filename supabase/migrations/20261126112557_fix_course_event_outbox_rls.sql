
create or replace function app_private.create_course_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  insert into public.event_outbox(event_type, aggregate_type, aggregate_id, payload)
  values (
    case when tg_op = 'INSERT' then 'course.created' else 'course.updated' end,
    'course',
    new.id,
    pg_catalog.jsonb_build_object(
      'course_id', new.id,
      'organization_id', new.owner_organization_id,
      'title', new.title,
      'status', new.status
    )
  );
  return new;
end;
$function$;
