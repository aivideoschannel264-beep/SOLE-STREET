-- SOLE STREET: paste this whole file into Supabase > SQL Editor > Run

create table profiles(id uuid primary key references auth.users on delete cascade,email text,full_name text,phone text,role text default 'customer',created_at timestamptz default now());
create table products(id bigserial primary key,name text not null,category text not null,description text,price numeric not null,images text[] default '{}',sizes jsonb default '{}',active boolean default true,created_at timestamptz default now());
create table product_private(product_id bigint primary key references products on delete cascade,cost numeric default 0,supplier_name text,supplier_url text,supplier_notes text);
create table banners(id bigserial primary key,title text,subtitle text,image_url text,category text,sort int default 0,active boolean default true);
create table coupons(code text primary key,percent int not null check(percent between 1 and 90),active boolean default true);
create table orders(id bigserial primary key,user_id uuid references auth.users,name text,phone text,address text,city text,items jsonb,subtotal numeric,discount numeric,total numeric,coupon text,payment_method text,payment_ref text,status text default 'pending',note text,created_at timestamptz default now());
create table order_private(order_id bigint primary key references orders on delete cascade,cost_total numeric default 0);
create table messages(id bigserial primary key,name text,email text,message text,created_at timestamptz default now());

create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,email,full_name,phone) values(new.id,new.email,new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'phone'); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create function is_admin() returns boolean language sql security definer stable set search_path=public as $$
select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;

alter table profiles enable row level security; alter table products enable row level security; alter table product_private enable row level security;
alter table banners enable row level security; alter table coupons enable row level security; alter table orders enable row level security;
alter table order_private enable row level security; alter table messages enable row level security;

create policy p1 on profiles for select using(id=auth.uid() or is_admin());
create policy p2 on profiles for update using(is_admin());
create policy p3 on products for select using(active or is_admin());
create policy p4 on products for all using(is_admin()) with check(is_admin());
create policy p5 on product_private for all using(is_admin()) with check(is_admin());
create policy p6 on banners for select using(active or is_admin());
create policy p7 on banners for all using(is_admin()) with check(is_admin());
create policy p8 on coupons for all using(is_admin()) with check(is_admin());
create policy p9 on orders for select using(user_id=auth.uid() or is_admin());
create policy p10 on orders for update using(is_admin());
create policy p11 on order_private for select using(is_admin());
create policy p12 on messages for insert with check(true);
create policy p13 on messages for select using(is_admin());

-- Validates prices, stock and coupon on the server, then creates the order
create function place_order(p_items jsonb,p_name text,p_phone text,p_address text,p_city text,p_method text,p_ref text,p_coupon text)
returns bigint language plpgsql security definer set search_path=public as $$
declare it jsonb; pr products%rowtype; q int; st int; sub numeric:=0; ctot numeric:=0; c numeric; lines jsonb:='[]'; pct int; disc numeric; oid bigint;
begin
 if auth.uid() is null then raise exception 'Please log in first'; end if;
 if p_method not in('cod','jazzcash','easypaisa') then raise exception 'Invalid payment method'; end if;
 for it in select * from jsonb_array_elements(p_items) loop
  select * into pr from products where id=(it->>'id')::bigint and active;
  if not found then raise exception 'A product is no longer available'; end if;
  q:=(it->>'qty')::int; st:=coalesce((pr.sizes->>(it->>'size'))::int,0);
  if q<1 or st<q then raise exception '% (size %) is out of stock',pr.name,it->>'size'; end if;
  update products set sizes=jsonb_set(sizes,array[it->>'size'],to_jsonb(st-q)) where id=pr.id;
  select pp.cost into c from product_private pp where pp.product_id=pr.id;
  sub:=sub+pr.price*q; ctot:=ctot+coalesce(c,0)*q;
  lines:=lines||jsonb_build_object('id',pr.id,'name',pr.name,'size',it->>'size','qty',q,'price',pr.price,'image',pr.images[1]);
 end loop;
 select percent into pct from coupons where code=upper(p_coupon) and active;
 pct:=coalesce(pct,0); disc:=round(sub*pct/100);
 insert into orders(user_id,name,phone,address,city,items,subtotal,discount,total,coupon,payment_method,payment_ref)
 values(auth.uid(),p_name,p_phone,p_address,p_city,lines,sub,disc,sub-disc,case when pct>0 then upper(p_coupon) end,p_method,p_ref) returning id into oid;
 insert into order_private values(oid,ctot);
 return oid;
end $$;

create function check_coupon(p_code text) returns int language sql security definer set search_path=public as $$
select percent from coupons where code=upper(p_code) and active $$;

create function track_order(p_id bigint,p_phone text) returns table(id bigint,status text,note text,total numeric,created_at timestamptz,items jsonb)
language sql security definer set search_path=public as $$
select o.id,o.status,o.note,o.total,o.created_at,o.items from orders o where o.id=p_id and o.phone=p_phone $$;

-- Image storage bucket
insert into storage.buckets(id,name,public) values('products','products',true) on conflict do nothing;
create policy "img read" on storage.objects for select using(bucket_id='products');
create policy "img admin" on storage.objects for all using(bucket_id='products' and is_admin()) with check(bucket_id='products' and is_admin());

-- AFTER you register on the website, make yourself admin (replace the email):
-- update profiles set role='admin' where email='you@example.com';
