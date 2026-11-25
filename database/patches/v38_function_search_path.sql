-- V38: Pin the search_path of the learner-facing completion wrapper.
-- Applied directly to the Supabase database on 2026-11-25.
alter function public.recalculate_enrollment_completion_for_current_user(uuid)
set search_path = pg_catalog, public, app_private;
