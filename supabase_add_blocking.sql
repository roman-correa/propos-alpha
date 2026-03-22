-- ============================================================
-- PROPOS — ADD BLOCKING SYSTEM
-- Run this in Supabase SQL Editor if you already ran the full setup
-- ============================================================

-- Add blocking columns to profiles
alter table profiles
  add column if not exists blocked boolean default false,
  add column if not exists blocked_reason uuid,
  add column if not exists blocked_fine numeric default 0;

-- Add foreign key separately (safer)
alter table profiles
  add constraint fk_blocked_reason
  foreign key (blocked_reason) references community_cases(id)
  on delete set null;

-- Function: owner unblocks tenant after fine is paid
create or replace function unblock_tenant_on_payment(case_id uuid)
returns void language plpgsql security definer as $$
begin
  update community_cases
    set fine_paid = true
    where id = case_id;

  update profiles
    set blocked = false, blocked_reason = null, blocked_fine = 0
    where blocked_reason = case_id;
end $$;

-- View: active blocks for owner dashboard
create or replace view active_blocks as
select
  p.id          as tenant_id,
  p.name        as tenant_name,
  p.apt,
  p.building_id,
  p.blocked_fine,
  c.title       as case_title,
  c.created_at  as blocked_since,
  c.id          as case_id
from profiles p
join community_cases c on c.id = p.blocked_reason
where p.blocked = true;

-- RLS: owners can read blocks in their building
create policy "Owner reads active blocks"
  on profiles for select
  using (
    building_id in (
      select building_id from properties where owner_id = auth.uid()
    )
  );

-- Done
select 'Blocking system added ✓' as result;
