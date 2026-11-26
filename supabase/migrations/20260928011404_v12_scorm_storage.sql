insert into storage.buckets (id,name,public)
values ('scorm-packages','scorm-packages',false)
on conflict (id) do update set public=false;

drop policy if exists scorm_storage_select on storage.objects;
create policy scorm_storage_select on storage.objects
for select to authenticated
using (bucket_id='scorm-packages');

drop policy if exists scorm_storage_insert on storage.objects;
create policy scorm_storage_insert on storage.objects
for insert to authenticated
with check (bucket_id='scorm-packages');

drop policy if exists scorm_storage_update on storage.objects;
create policy scorm_storage_update on storage.objects
for update to authenticated
using (bucket_id='scorm-packages')
with check (bucket_id='scorm-packages');

drop policy if exists scorm_storage_delete on storage.objects;
create policy scorm_storage_delete on storage.objects
for delete to authenticated
using (bucket_id='scorm-packages');