-- P0 : seul un platform_admin peut attribuer, modifier ou retirer le rôle platform_admin.
alter policy members_manage on public.organization_members
  using (
    app_private.is_platform_admin()
    or (
      role <> 'platform_admin'::public.member_role
      and app_private.is_org_member(organization_id, array['org_admin'::public.member_role])
    )
  )
  with check (
    app_private.is_platform_admin()
    or (
      role <> 'platform_admin'::public.member_role
      and app_private.is_org_member(organization_id, array['org_admin'::public.member_role])
    )
  );