
revoke select on public.evaluation_options from authenticated;

grant select (id, question_id, option_text, position)
on public.evaluation_options to authenticated;

create or replace function app_private.submit_evaluation(
  p_evaluation_id uuid,
  p_answers jsonb
)
returns table (
  attempt_id uuid,
  score numeric,
  passed boolean
)
language plpgsql
security definer
set search_path = public, app_private
as $$
declare
  v_learner_id uuid;
  v_attempt_id uuid;
  v_max numeric := 0;
  v_earned numeric := 0;
  v_pass_score numeric := 0;
  v_selected uuid[];
  v_correct uuid[];
  v_ok boolean;
  q record;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select l.id
    into v_learner_id
  from public.learners l
  where l.user_id = auth.uid()
    and l.is_active = true
  limit 1;

  if v_learner_id is null then
    raise exception 'Learner profile not found';
  end if;

  if not exists (
    select 1
    from public.evaluations e
    join public.deployments d on d.course_id = e.course_id
    join public.enrollments en on en.deployment_id = d.id
    where e.id = p_evaluation_id
      and en.learner_id = v_learner_id
  ) then
    raise exception 'Evaluation is not available for this learner';
  end if;

  select coalesce(e.pass_score, 0)
    into v_pass_score
  from public.evaluations e
  where e.id = p_evaluation_id;

  select coalesce(sum(q.points), 0)
    into v_max
  from public.evaluation_questions q
  where q.evaluation_id = p_evaluation_id;

  if v_max = 0 then
    raise exception 'Evaluation has no scored questions';
  end if;

  insert into public.evaluation_attempts (
    evaluation_id, learner_id, score, max_score, passed, attempted_at
  )
  values (
    p_evaluation_id, v_learner_id, 0, v_max, false, now()
  )
  returning id into v_attempt_id;

  for q in
    select id, points
    from public.evaluation_questions
    where evaluation_id = p_evaluation_id
    order by position
  loop
    if not (p_answers ? q.id::text) then
      raise exception 'All questions must be answered';
    end if;

    select coalesce(array_agg(distinct (value::text)::uuid), '{}'::uuid[])
      into v_selected
    from jsonb_array_elements(p_answers -> q.id::text) as x(value);

    select coalesce(array_agg(o.id order by o.id), '{}'::uuid[])
      into v_correct
    from public.evaluation_options o
    where o.question_id = q.id
      and o.is_correct = true;

    v_ok :=
      cardinality(v_selected) = cardinality(v_correct)
      and cardinality(v_selected) = (
        select count(*)
        from unnest(v_selected) s
        where s = any(v_correct)
      );

    if v_ok then
      v_earned := v_earned + q.points;
    end if;

    insert into public.evaluation_responses (
      attempt_id, question_id, selected_option_ids, is_correct, points_awarded
    )
    values (
      v_attempt_id, q.id, v_selected, v_ok,
      case when v_ok then q.points else 0 end
    );
  end loop;

  score := round((v_earned / v_max) * 100, 2);
  passed := score >= v_pass_score;

  update public.evaluation_attempts
  set score = submit_evaluation.score,
      max_score = v_max,
      passed = submit_evaluation.passed,
      feedback = case
        when submit_evaluation.passed then 'Évaluation réussie.'
        else 'Évaluation non réussie. Vous pouvez reprendre le parcours.'
      end
  where id = v_attempt_id;

  attempt_id := v_attempt_id;
  return next;
end;
$$;

revoke all on function app_private.submit_evaluation(uuid, jsonb) from public;
grant execute on function app_private.submit_evaluation(uuid, jsonb) to authenticated;

create or replace function public.submit_evaluation(
  p_evaluation_id uuid,
  p_answers jsonb
)
returns table (
  attempt_id uuid,
  score numeric,
  passed boolean
)
language sql
security invoker
set search_path = public, app_private
as $$
  select * from app_private.submit_evaluation(p_evaluation_id, p_answers);
$$;

revoke all on function public.submit_evaluation(uuid, jsonb) from public;
grant execute on function public.submit_evaluation(uuid, jsonb) to authenticated;
