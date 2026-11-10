-- Yummy Nom: order system
-- Run this whole file once in Supabase > SQL Editor.

-- Staff accounts allowed to open dashboard.html
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins a where a.user_id = auth.uid());
$$;

-- Prices live here. The browser never decides a price.
create table if not exists public.menu_items (
  id text primary key,
  name text not null,
  price numeric(8,2) not null check (price >= 0),
  active boolean not null default true
);

alter table public.menu_items
  add column if not exists name_ar text,
  add column if not exists category text not null default 'ramyun'
    check (category in ('ramyun', 'corndog')),
  add column if not exists img text,
  add column if not exists sort_order int not null default 0;

-- Seed only once: later edits made from the dashboard are never overwritten.
insert into public.menu_items (id, name, name_ar, price, category, img, sort_order) values
  ('sweet',      'Sweet & Spicy Ramyun', 'رامن حار وحلو',     30, 'ramyun',  'images/sweet-spicy-ramyun.png?v=10', 10),
  ('carbonara',  'Carbonara Ramyun',     'رامن كاربونارا',    30, 'ramyun',  'images/carbonara-ramyun.png?v=10',   20),
  ('cheese',     'Cheese Ramyun',        'رامن بالجبنة',      30, 'ramyun',  'images/cheese-ramyun.png?v=10',      30),
  ('sausage',    'Sausage Corn Dog',     'كورن دوغ بالنقانق', 12, 'corndog', 'images/sausage-corn-dog.png?v=1',    40),
  ('cheesedog',  'Cheese Corn Dog',      'كورن دوغ بالجبنة',  12, 'corndog', 'images/cheese-corn-dog.png?v=1',      50)
on conflict (id) do nothing;

-- Fills in the new columns for rows created by an earlier version of this file.
update public.menu_items m
set name_ar = s.name_ar, category = s.category, img = s.img, sort_order = s.sort_order
from (values
  ('sweet',     'رامن حار وحلو',     'ramyun',  'images/sweet-spicy-ramyun.png?v=10', 10),
  ('carbonara', 'رامن كاربونارا',    'ramyun',  'images/carbonara-ramyun.png?v=10',   20),
  ('cheese',    'رامن بالجبنة',      'ramyun',  'images/cheese-ramyun.png?v=10',      30),
  ('sausage',   'كورن دوغ بالنقانق', 'corndog', 'images/sausage-corn-dog.png?v=1',    40),
  ('cheesedog', 'كورن دوغ بالجبنة',  'corndog', 'images/cheese-corn-dog.png?v=1',      50)
) as s(id, name_ar, category, img, sort_order)
where m.id = s.id and m.name_ar is null;

alter table public.menu_items enable row level security;

-- Anyone can read the menu (the site shows it). Only staff can change it.
drop policy if exists "public read menu" on public.menu_items;
create policy "public read menu" on public.menu_items
  for select to anon, authenticated
  using (true);

drop policy if exists "admins write menu" on public.menu_items;
create policy "admins write menu" on public.menu_items
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Order hours shown on the site and enforced by the site's checkout.
create table if not exists public.settings (
  key text primary key,
  value text not null
);

insert into public.settings (key, value) values
  ('order_days', 'Sun,Mon,Tue,Wed,Thu'),
  ('order_open_hour', '18'),
  ('order_close_hour', '21')
on conflict (key) do nothing;

alter table public.settings enable row level security;

drop policy if exists "public read settings" on public.settings;
create policy "public read settings" on public.settings
  for select to anon, authenticated
  using (true);

drop policy if exists "admins write settings" on public.settings;
create policy "admins write settings" on public.settings
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Public bucket for menu photos. Only staff can upload, replace or delete.
insert into storage.buckets (id, name, public)
values ('menu-images', 'menu-images', true)
on conflict (id) do nothing;

drop policy if exists "admins upload menu images" on storage.objects;
create policy "admins upload menu images" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'menu-images' and public.is_admin());

drop policy if exists "admins update menu images" on storage.objects;
create policy "admins update menu images" on storage.objects
  for update to authenticated
  using (bucket_id = 'menu-images' and public.is_admin())
  with check (bucket_id = 'menu-images' and public.is_admin());

drop policy if exists "admins delete menu images" on storage.objects;
create policy "admins delete menu images" on storage.objects
  for delete to authenticated
  using (bucket_id = 'menu-images' and public.is_admin());

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated always as identity unique,
  client_request_id uuid not null unique,
  customer_name text not null check (char_length(customer_name) between 2 and 40),
  customer_phone text not null check (customer_phone ~ '^\+?[0-9]{7,15}$'),
  items jsonb not null,
  total numeric(10,2) not null check (total > 0),
  status text not null default 'new'
    check (status in ('new', 'preparing', 'ready', 'completed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists orders_phone_created_idx
  on public.orders (customer_phone, created_at);

alter table public.orders enable row level security;

-- Anonymous visitors cannot read or insert directly; they must use place_order().
drop policy if exists "admins read orders" on public.orders;
create policy "admins read orders" on public.orders
  for select to authenticated
  using (public.is_admin());

drop policy if exists "admins update orders" on public.orders;
create policy "admins update orders" on public.orders
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- Staff can delete orders (e.g. end-of-day cleanup from the dashboard).
drop policy if exists "admins delete orders" on public.orders;
create policy "admins delete orders" on public.orders
  for delete to authenticated
  using (public.is_admin());

-- Staff may only change status; everything the customer sent is locked.
create or replace function public.orders_guard_update()
returns trigger
language plpgsql
as $$
begin
  if new.id is distinct from old.id
     or new.order_number is distinct from old.order_number
     or new.client_request_id is distinct from old.client_request_id
     or new.customer_name is distinct from old.customer_name
     or new.customer_phone is distinct from old.customer_phone
     or new.items is distinct from old.items
     or new.total is distinct from old.total
     or new.created_at is distinct from old.created_at then
    raise exception 'Only the status of an order can be changed';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists orders_guard_update on public.orders;
create trigger orders_guard_update
  before update on public.orders
  for each row execute function public.orders_guard_update();

-- The only way customers can create an order.
-- Validates input, recalculates prices from menu_items, prevents duplicates
-- (same p_request_id), and rate-limits each phone number.
create or replace function public.place_order(
  p_request_id uuid,
  p_name text,
  p_phone text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[\s\-()]', '', 'g');
  v_items jsonb := '[]'::jsonb;
  v_total numeric(10,2) := 0;
  v_line jsonb;
  v_menu public.menu_items%rowtype;
  v_qty numeric;
  v_spice text;
  v_existing_no bigint;
  v_row public.orders%rowtype;
  v_recent int;
begin
  if p_request_id is null then
    raise exception 'INVALID_REQUEST';
  end if;

  -- Repeat submit of the same checkout: return the original order.
  select order_number into v_existing_no
    from public.orders where client_request_id = p_request_id;
  if found then
    return jsonb_build_object('ok', true, 'order_number', v_existing_no, 'duplicate', true);
  end if;

  if char_length(v_name) < 2 or char_length(v_name) > 40 then
    raise exception 'INVALID_NAME';
  end if;

  if v_phone !~ '^\+?[0-9]{7,15}$' then
    raise exception 'INVALID_PHONE';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    raise exception 'INVALID_ITEMS';
  end if;

  select count(*) into v_recent from public.orders
    where customer_phone = v_phone and created_at > now() - interval '10 minutes';
  if v_recent >= 3 then
    raise exception 'RATE_LIMITED';
  end if;

  for v_line in select * from jsonb_array_elements(p_items) loop
    select * into v_menu from public.menu_items
      where id = v_line->>'id' and active;
    if not found then
      raise exception 'INVALID_ITEM';
    end if;

    if jsonb_typeof(v_line->'qty') <> 'number' then
      raise exception 'INVALID_QTY';
    end if;
    v_qty := (v_line->>'qty')::numeric;
    if v_qty <> trunc(v_qty) or v_qty < 1 or v_qty > 20 then
      raise exception 'INVALID_QTY';
    end if;

    v_spice := coalesce(v_line->>'spice', '');
    if v_spice not in ('', 'Mild', 'Medium', 'Hot', 'Extra Hot') then
      raise exception 'INVALID_SPICE';
    end if;

    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'id', v_menu.id,
      'name', v_menu.name,
      'spice', nullif(v_spice, ''),
      'qty', v_qty,
      'unit_price', v_menu.price,
      'line_total', v_menu.price * v_qty
    ));
    v_total := v_total + v_menu.price * v_qty;
  end loop;

  insert into public.orders (client_request_id, customer_name, customer_phone, items, total)
  values (p_request_id, v_name, v_phone, v_items, v_total)
  on conflict (client_request_id) do nothing
  returning * into v_row;

  if not found then
    select order_number into v_existing_no
      from public.orders where client_request_id = p_request_id;
    return jsonb_build_object('ok', true, 'order_number', v_existing_no, 'duplicate', true);
  end if;

  return jsonb_build_object('ok', true, 'order_number', v_row.order_number, 'duplicate', false);
end;
$$;

revoke all on function public.place_order(uuid, text, text, jsonb) from public;
grant execute on function public.place_order(uuid, text, text, jsonb) to anon, authenticated;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- Live updates for dashboard.html
do $$
begin
  alter publication supabase_realtime add table public.orders;
exception
  when duplicate_object then null;
end;
$$;
