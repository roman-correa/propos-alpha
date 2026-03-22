-- ============================================================
-- PROPOS — SUPABASE SETUP
-- Run this entire file in: Supabase → SQL Editor → New query
-- ============================================================

-- ── EXTENSIONS ──────────────────────────────────────────────
create extension if not exists "uuid-ossp";

-- ── ENUMS ────────────────────────────────────────────────────
create type user_role      as enum ('owner', 'tenant', 'worker');
create type property_status as enum ('ok', 'alert', 'critical');
create type repair_status   as enum ('pending', 'quoted', 'approved', 'in_progress', 'done', 'guarantee');
create type task_status     as enum ('new', 'active', 'done');
create type case_verdict    as enum ('pending', 'guilty', 'innocent', 'warning');
create type payment_status  as enum ('paid', 'overdue', 'pending');

-- ── BUILDINGS ────────────────────────────────────────────────
create table buildings (
  id          uuid primary key default uuid_generate_v4(),
  name        text not null,
  address     text,
  icon        text default '🏢',
  color       text default '#A855F7',
  total_units int  default 0,
  total_m2    numeric default 0,
  monthly_fee numeric default 0,
  floors      int  default 1,
  created_at  timestamptz default now()
);

-- ── PROFILES (extends Supabase auth.users) ───────────────────
create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        user_role not null,
  name        text,
  building_id uuid references buildings(id),
  apt         text,
  floor       int,
  worker_role text,        -- e.g. 'Cleaning specialist'
  theme       text default 'ad',
  lang        text default 'es',
  created_at  timestamptz default now()
);

-- ── PROPERTIES ───────────────────────────────────────────────
create table properties (
  id          uuid primary key default uuid_generate_v4(),
  apt         text not null,
  floor       int,
  building_id uuid references buildings(id) on delete cascade,
  owner_id    uuid references profiles(id),
  tenant_id   uuid references profiles(id),
  m2          numeric default 0,
  rooms       int default 1,
  bathrooms   int default 1,
  pct_share   numeric default 0,   -- % of building m2
  monthly_fee numeric default 0,
  status      property_status default 'ok',
  created_at  timestamptz default now()
);

-- ── PAYMENTS ─────────────────────────────────────────────────
create table payments (
  id          uuid primary key default uuid_generate_v4(),
  property_id uuid references properties(id) on delete cascade,
  month       text not null,        -- e.g. '2026-03'
  amount      numeric not null,
  status      payment_status default 'pending',
  paid_at     timestamptz,
  days_late   int default 0,
  created_at  timestamptz default now()
);

-- ── REPAIR REQUESTS ──────────────────────────────────────────
create table repair_requests (
  id          uuid primary key default uuid_generate_v4(),
  property_id uuid references properties(id) on delete cascade,
  tenant_id   uuid references profiles(id),
  worker_id   uuid references profiles(id),
  icon        text default '🔧',
  title       text not null,
  description text,
  type        text,                 -- pipes, electricity, ac, door, lights, other
  status      repair_status default 'pending',
  urgent      boolean default false,
  quote       numeric,
  approved_at timestamptz,
  completed_at timestamptz,
  guarantee_expires_at timestamptz, -- completed_at + 90 days
  evidence_url text,
  created_at  timestamptz default now()
);

-- ── RATINGS ──────────────────────────────────────────────────
create table ratings (
  id          uuid primary key default uuid_generate_v4(),
  repair_id   uuid references repair_requests(id) on delete cascade,
  tenant_id   uuid references profiles(id),
  worker_id   uuid references profiles(id),
  stars       int check (stars between 1 and 5),
  comment     text,
  rated_at    timestamptz,
  expires_at  timestamptz,          -- completed_at + 5 days
  auto_closed boolean default false,
  created_at  timestamptz default now()
);

-- ── WORKER TASKS ─────────────────────────────────────────────
create table worker_tasks (
  id          uuid primary key default uuid_generate_v4(),
  worker_id   uuid references profiles(id),
  building_id uuid references buildings(id),
  repair_id   uuid references repair_requests(id), -- null if standalone task
  icon        text default '🔧',
  title       text not null,
  location    text,
  scheduled_at timestamptz,
  status      task_status default 'new',
  pay         numeric default 0,
  completed_at timestamptz,
  created_at  timestamptz default now()
);

-- ── COMMUNITY CASES ──────────────────────────────────────────
create table community_cases (
  id           uuid primary key default uuid_generate_v4(),
  building_id  uuid references buildings(id) on delete cascade,
  reporter_id  uuid references profiles(id),
  accused_apt  text,
  type         text,                -- noise, behaviour, mess, other
  title        text,
  description  text,
  evidence_url text,
  peak_db      numeric,
  violations   int default 0,
  incident_time timestamptz,
  verdict      case_verdict default 'pending',
  ai_reasoning text,
  fine_amount  numeric default 0,
  fine_paid    boolean default false,
  repeat_offence boolean default false,
  created_at   timestamptz default now()
);

-- ── CLEANING SESSIONS ────────────────────────────────────────
create table cleaning_sessions (
  id          uuid primary key default uuid_generate_v4(),
  building_id uuid references buildings(id),
  worker_id   uuid references profiles(id),
  location    text,
  scheduled_at timestamptz,
  completed_at timestamptz,
  status      text default 'scheduled',  -- scheduled, done, missed
  created_at  timestamptz default now()
);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table buildings          enable row level security;
alter table profiles           enable row level security;
alter table properties         enable row level security;
alter table payments           enable row level security;
alter table repair_requests    enable row level security;
alter table ratings            enable row level security;
alter table worker_tasks       enable row level security;
alter table community_cases    enable row level security;
alter table cleaning_sessions  enable row level security;

-- Helper: get current user's role
create or replace function get_my_role()
returns user_role language sql security definer
as $$ select role from profiles where id = auth.uid() $$;

-- Helper: get current user's building
create or replace function get_my_building()
returns uuid language sql security definer
as $$ select building_id from profiles where id = auth.uid() $$;

-- BUILDINGS: everyone in the building can read
create policy "Building members can read"
  on buildings for select
  using (
    id in (select building_id from profiles where id = auth.uid())
    or id in (select building_id from properties where owner_id = auth.uid())
  );

-- PROFILES: users can read their own + people in same building
create policy "Read own profile"
  on profiles for select using (id = auth.uid());

create policy "Read building members"
  on profiles for select
  using (building_id = get_my_building());

create policy "Update own profile"
  on profiles for update using (id = auth.uid());

create policy "Insert own profile"
  on profiles for insert with check (id = auth.uid());

-- PROPERTIES: owners see their own, tenants see their unit
create policy "Owner sees own properties"
  on properties for select
  using (owner_id = auth.uid());

create policy "Tenant sees own property"
  on properties for select
  using (tenant_id = auth.uid());

create policy "Owner manages properties"
  on properties for all
  using (owner_id = auth.uid());

-- PAYMENTS: owner sees their properties' payments
create policy "Owner sees payments"
  on payments for select
  using (
    property_id in (select id from properties where owner_id = auth.uid())
  );

create policy "Tenant sees own payments"
  on payments for select
  using (
    property_id in (select id from properties where tenant_id = auth.uid())
  );

-- REPAIR REQUESTS: tenant creates, owner approves, worker sees assigned
create policy "Tenant creates repair request"
  on repair_requests for insert
  with check (tenant_id = auth.uid());

create policy "Tenant sees own requests"
  on repair_requests for select
  using (tenant_id = auth.uid());

create policy "Owner sees property repairs"
  on repair_requests for select
  using (
    property_id in (select id from properties where owner_id = auth.uid())
  );

create policy "Owner approves repairs"
  on repair_requests for update
  using (
    property_id in (select id from properties where owner_id = auth.uid())
  );

create policy "Worker sees assigned tasks"
  on repair_requests for select
  using (worker_id = auth.uid());

create policy "Worker updates status"
  on repair_requests for update
  using (worker_id = auth.uid());

-- RATINGS: tenant rates, worker reads own ratings
create policy "Tenant rates job"
  on ratings for insert
  with check (tenant_id = auth.uid());

create policy "Worker reads own ratings"
  on ratings for select
  using (worker_id = auth.uid());

create policy "Tenant reads own ratings"
  on ratings for select
  using (tenant_id = auth.uid());

-- WORKER TASKS: worker sees own tasks
create policy "Worker sees own tasks"
  on worker_tasks for select
  using (worker_id = auth.uid());

create policy "Worker updates own tasks"
  on worker_tasks for update
  using (worker_id = auth.uid());

-- COMMUNITY CASES: building members can read, tenants can create
create policy "Building members read cases"
  on community_cases for select
  using (building_id = get_my_building());

create policy "Tenant creates case"
  on community_cases for insert
  with check (reporter_id = auth.uid());

-- CLEANING: building members can read
create policy "Building members read cleaning"
  on cleaning_sessions for select
  using (building_id = get_my_building());

-- ============================================================
-- SEED DATA — demo building + test accounts
-- Run AFTER creating accounts via Supabase Auth → Users
-- Replace UUIDs below with your actual auth user IDs
-- ============================================================

-- Insert buildings
insert into buildings (id, name, address, icon, color, total_units, total_m2, monthly_fee, floors) values
  ('11111111-1111-1111-1111-111111111111', 'Torre Colina Norte', 'Cra 15 #127-40, Bogotá', '🏙️', '#A855F7', 48, 5420, 8400000, 14),
  ('22222222-2222-2222-2222-222222222222', 'Edificio Parque 93',  'Cl 93 #11-24, Bogotá',   '🌿', '#22C55E', 32, 3860, 5600000, 10),
  ('33333333-3333-3333-3333-333333333333', 'Villa Nova',          'Av Boyacá #68-15, Bogotá','🏡', '#4A9EFF', 24, 2980, 3800000, 7);

-- ============================================================
-- USEFUL VIEWS
-- ============================================================

-- Property detail view for owner dashboard
create or replace view property_detail as
select
  p.id, p.apt, p.floor, p.m2, p.rooms, p.bathrooms, p.pct_share, p.monthly_fee, p.status,
  b.name as building_name, b.color as building_color,
  pay.status as payment_status, pay.days_late,
  prof.name as tenant_name,
  (select count(*) from repair_requests r where r.property_id = p.id and r.status not in ('done')) as open_repairs,
  (select count(*) from repair_requests r where r.property_id = p.id and r.status = 'in_progress') as active_repairs
from properties p
join buildings b on b.id = p.building_id
left join payments pay on pay.property_id = p.id and pay.month = to_char(now(), 'YYYY-MM')
left join profiles prof on prof.id = p.tenant_id;

-- Worker stats view
create or replace view worker_stats as
select
  p.id as worker_id, p.name,
  coalesce(avg(r.stars), 0) as avg_rating,
  count(distinct r.id) as total_ratings,
  count(distinct t.id) filter (where t.status = 'done') as jobs_done,
  count(distinct rr.id) filter (where rr.guarantee_expires_at > now() and rr.status = 'done') as active_guarantees
from profiles p
left join ratings r on r.worker_id = p.id
left join worker_tasks t on t.worker_id = p.id
left join repair_requests rr on rr.worker_id = p.id
where p.role = 'worker'
group by p.id, p.name;

-- ============================================================
-- FUNCTIONS
-- ============================================================

-- Auto-set guarantee expiry when repair is marked done
create or replace function set_guarantee_expiry()
returns trigger language plpgsql as $$
begin
  if NEW.status = 'done' and OLD.status != 'done' then
    NEW.completed_at = now();
    NEW.guarantee_expires_at = now() + interval '90 days';
  end if;
  return NEW;
end $$;

create trigger trg_guarantee_expiry
  before update on repair_requests
  for each row execute function set_guarantee_expiry();

-- Auto-create rating record when repair done (5-day window)
create or replace function create_rating_request()
returns trigger language plpgsql as $$
begin
  if NEW.status = 'done' and OLD.status != 'done' then
    insert into ratings (repair_id, tenant_id, worker_id, expires_at)
    values (NEW.id, NEW.tenant_id, NEW.worker_id, now() + interval '5 days');
  end if;
  return NEW;
end $$;

create trigger trg_create_rating
  after update on repair_requests
  for each row execute function create_rating_request();

-- Auto-close unrated jobs after 5 days
create or replace function auto_close_ratings()
returns void language plpgsql as $$
begin
  update ratings
  set auto_closed = true, rated_at = now(), stars = 5
  where stars is null
    and expires_at < now()
    and auto_closed = false;
end $$;

-- PropOS fee calculation (3%)
create or replace function calculate_propos_fee(amount numeric)
returns numeric language sql as $$
  select round(amount * 0.03, 0);
$$;

-- ============================================================
-- BLOCKING SYSTEM — add to profiles table
-- Run this after initial setup if not already included
-- ============================================================
alter table profiles
  add column if not exists blocked boolean default false,
  add column if not exists blocked_reason uuid references community_cases(id),
  add column if not exists blocked_fine numeric default 0;

-- Function: unblock tenant when owner pays fine
create or replace function unblock_tenant_on_payment(case_id uuid)
returns void language plpgsql security definer as $$
begin
  -- Mark fine as paid on the case
  update community_cases
  set fine_paid = true
  where id = case_id;

  -- Unblock the tenant
  update profiles
  set blocked = false, blocked_reason = null, blocked_fine = 0
  where blocked_reason = case_id;
end $$;

-- Owner unblocks tenant by calling this function
-- Usage: select unblock_tenant_on_payment('<case-uuid>');

-- View: active blocks for owner dashboard
create or replace view active_blocks as
select
  p.id as tenant_id, p.name as tenant_name, p.apt, p.building_id,
  p.blocked_fine,
  c.title as case_title, c.created_at as blocked_since,
  c.id as case_id
from profiles p
join community_cases c on c.id = p.blocked_reason
where p.blocked = true;

-- RLS: owners can see blocks in their building
create policy "Owner sees active blocks"
  on profiles for select
  using (
    building_id in (
      select building_id from properties where owner_id = auth.uid()
    )
    and blocked = true
  );
