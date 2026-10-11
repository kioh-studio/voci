-- 0007_rewards.sql
--
-- Feature 011 (iOS companion): "Earned break" — bảng `rewards` + luồng thứ ba trong `sync_exchange`.
-- Thiết kế: `specs/011-ios-companion/plan.md` §2.4, wire contract: `implementation-contract.md` §5.
-- Mọi giải thích nền (RLS thật, cổng `volar_sync_allowed()`, hai đồng hồ, tombstone, overlap 2 giây,
-- cursor riêng mỗi luồng) nằm ở `0005_sync_schema.sql` — file này chỉ mirror, không nhắc lại.
--
-- 🔴 ÁP DỤNG MIGRATION NÀY LÀ QUYẾT ĐỊNH CỦA anh Khôi. File này chỉ được VIẾT, chưa chạy lên Supabase.
--
-- VÌ SAO `drop function` + `create function` (không `create or replace`): đổi danh sách tham số của
-- `sync_exchange` thì `create or replace` sinh thêm MỘT OVERLOAD, và PostgREST báo lỗi ambiguous khi
-- client gọi RPC theo tên. Hai lệnh nằm trong cùng migration (một transaction) nên không có khoảnh
-- khắc nào hàm bị thiếu. Hai tham số mới đặt CUỐI và có default ⇒ client cũ (macOS bản trước, Windows)
-- vẫn bind được; chúng chỉ phải bỏ qua key `rewards`/`cursorRewards` lạ trong response.
-- `drop function` này chỉ nhắm đúng chữ ký 7 tham số do 0005 tạo ra — không đụng gì khác.
--
-- VÌ SAO KHÔNG ghi `sync_rejects` cho rewards (plan §2.4, ponytail): xung đột reward giá trị thấp,
-- thua LWW thì bỏ im lặng. Cần hộp đen thì thêm sau bằng migration cộng thêm.

-- -----------------------------------------------------------------------------------------------
-- rewards — giống `tasks` (0005), payload nhỏ hơn (8192 byte)
-- -----------------------------------------------------------------------------------------------
create table if not exists public.rewards (
  profile_id        uuid        not null references public.profiles(id) on delete cascade,
  id                uuid        not null,
  updated_at        timestamptz not null,
  deleted_at        timestamptz,
  payload           jsonb       not null,
  schema_version    int         not null default 1,
  origin_device     text,
  server_updated_at timestamptz not null default now(),
  primary key (profile_id, id),
  constraint rewards_payload_is_object check (jsonb_typeof(payload) = 'object'),
  constraint rewards_payload_size check (octet_length(payload::text) <= 8192)
);

create index if not exists rewards_pull_idx
  on public.rewards (profile_id, server_updated_at);

alter table public.rewards enable row level security;

-- Không cấp `delete` (xoá là `deleted_at`; purge đi đường definer) — như `tasks`.
grant select, insert, update on public.rewards to authenticated;

drop policy if exists rewards_select on public.rewards;
create policy rewards_select on public.rewards
  for select to authenticated
  using ((select auth.uid()) = profile_id and (select public.volar_sync_allowed()));

drop policy if exists rewards_insert on public.rewards;
create policy rewards_insert on public.rewards
  for insert to authenticated
  with check ((select auth.uid()) = profile_id and (select public.volar_sync_allowed()));

drop policy if exists rewards_update on public.rewards;
create policy rewards_update on public.rewards
  for update to authenticated
  using ((select auth.uid()) = profile_id and (select public.volar_sync_allowed()))
  with check ((select auth.uid()) = profile_id and (select public.volar_sync_allowed()));

-- -----------------------------------------------------------------------------------------------
-- volar_sync_purge — như 0005, thêm xoá rewards; các key cũ giữ nguyên, thêm key `deletedRewards`
-- -----------------------------------------------------------------------------------------------
create or replace function public.volar_sync_purge()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid;
  v_tasks   int;
  v_comps   int;
  v_rewards int;
begin
  v_user := (select auth.uid());
  if v_user is null then
    raise exception 'sync_not_authenticated' using errcode = '28000';
  end if;

  delete from public.tasks where profile_id = v_user;
  get diagnostics v_tasks = row_count;
  delete from public.completions where profile_id = v_user;
  get diagnostics v_comps = row_count;
  delete from public.rewards where profile_id = v_user;
  get diagnostics v_rewards = row_count;
  delete from public.sync_rejects  where profile_id = v_user;
  delete from public.sync_devices  where profile_id = v_user;

  return jsonb_build_object(
    'deletedTasks', v_tasks,
    'deletedCompletions', v_comps,
    'deletedRewards', v_rewards
  );
end;
$$;

revoke all on function public.volar_sync_purge() from public;
revoke all on function public.volar_sync_purge() from anon;
grant execute on function public.volar_sync_purge() to authenticated;

-- -----------------------------------------------------------------------------------------------
-- sync_exchange — thêm luồng rewards (push + pull). Thân hàm = 0005 nguyên văn + khối rewards.
-- -----------------------------------------------------------------------------------------------
drop function if exists public.sync_exchange(timestamptz, timestamptz, text, text, jsonb, jsonb, int);

create function public.sync_exchange(
  p_cursor_tasks       timestamptz default null,
  p_cursor_completions timestamptz default null,
  p_device             text        default null,
  p_device_label       text        default null,
  p_tasks              jsonb       default '[]'::jsonb,
  p_completions        jsonb       default '[]'::jsonb,
  p_limit              int         default 500,
  p_cursor_rewards     timestamptz default null,
  p_rewards            jsonb       default '[]'::jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_user       uuid;
  v_limit      int;
  v_cur_tasks  timestamptz;
  v_cur_comps  timestamptz;
  v_cur_rew    timestamptz;
  v_rejected   uuid[];
  v_tasks_out  jsonb;
  v_comps_out  jsonb;
  v_rew_out    jsonb;
  v_task_n     int;
  v_comp_n     int;
  v_reward_n   int;
  v_task_max   timestamptz;
  v_comp_max   timestamptz;
  v_rew_max    timestamptz;
begin
  v_user := (select auth.uid());
  if v_user is null then
    raise exception 'sync_not_authenticated' using errcode = '28000';
  end if;

  if not public.volar_is_pro() then
    raise exception 'sync_pro_required' using errcode = '42501';
  end if;
  if not public.volar_sync_enabled() then
    raise exception 'sync_disabled' using errcode = '42501';
  end if;

  v_limit     := least(greatest(coalesce(p_limit, 500), 1), 1000);
  v_cur_tasks := coalesce(p_cursor_tasks, '-infinity'::timestamptz);
  v_cur_comps := coalesce(p_cursor_completions, '-infinity'::timestamptz);
  v_cur_rew   := coalesce(p_cursor_rewards, '-infinity'::timestamptz);

  -- ── PUSH: task (giải thích ở 0005) ───────────────────────────────────────────────────────────
  with incoming as (
    select distinct on (e ->> 'id')
           (e ->> 'id')::uuid                                                     as id,
           least((e ->> 'updatedAt')::timestamptz, now() + interval '1 minute')    as updated_at,
           nullif(e ->> 'deletedAt', '')::timestamptz                              as deleted_at,
           coalesce(e -> 'payload', '{}'::jsonb)                                   as payload,
           coalesce((e ->> 'schemaVersion')::int, 1)                               as schema_version
    from jsonb_array_elements(coalesce(p_tasks, '[]'::jsonb)) as e
    where (e ->> 'id') is not null
      and (e ->> 'updatedAt') is not null
    order by e ->> 'id', ((e ->> 'updatedAt')::timestamptz) desc
  ),
  applied as (
    insert into public.tasks as t
      (profile_id, id, updated_at, deleted_at, payload, schema_version, origin_device, server_updated_at)
    select v_user, i.id, i.updated_at, i.deleted_at, i.payload, i.schema_version, p_device, now()
    from incoming i
    on conflict (profile_id, id) do update
      set updated_at        = excluded.updated_at,
          deleted_at        = excluded.deleted_at,
          payload           = excluded.payload,
          schema_version    = excluded.schema_version,
          origin_device     = excluded.origin_device,
          server_updated_at = now()
      where excluded.updated_at > t.updated_at
    returning t.id
  ),
  rejected as (
    insert into public.sync_rejects as sr (profile_id, task_id, updated_at, payload, origin_device)
    select v_user, i.id, i.updated_at, i.payload, p_device
    from incoming i
    join public.tasks cur on cur.profile_id = v_user and cur.id = i.id
    where i.id not in (select a.id from applied a)
      and cur.updated_at > i.updated_at
    returning sr.task_id
  )
  select coalesce(array_agg(r.task_id), '{}'::uuid[]) into v_rejected from rejected r;

  -- ── PUSH: completions (chỉ-thêm, không thể xung đột) ──────────────────────────────────────────
  insert into public.completions as c
    (profile_id, id, task_id, completed_at, payload, server_updated_at)
  select distinct on (e ->> 'id')
         v_user,
         (e ->> 'id')::uuid,
         (e ->> 'taskId')::uuid,
         (e ->> 'completedAt')::timestamptz,
         coalesce(e -> 'payload', '{}'::jsonb),
         now()
  from jsonb_array_elements(coalesce(p_completions, '[]'::jsonb)) as e
  where (e ->> 'id') is not null
    and (e ->> 'taskId') is not null
    and (e ->> 'completedAt') is not null
  order by e ->> 'id'
  on conflict (profile_id, id) do nothing;

  -- ── PUSH: rewards (LWW như task, KHÔNG ghi sync_rejects — plan §2.4) ─────────────────────────
  insert into public.rewards as rw
    (profile_id, id, updated_at, deleted_at, payload, schema_version, origin_device, server_updated_at)
  select v_user, i.id, i.updated_at, i.deleted_at, i.payload, i.schema_version, p_device, now()
  from (
    select distinct on (e ->> 'id')
           (e ->> 'id')::uuid                                                     as id,
           least((e ->> 'updatedAt')::timestamptz, now() + interval '1 minute')    as updated_at,
           nullif(e ->> 'deletedAt', '')::timestamptz                              as deleted_at,
           coalesce(e -> 'payload', '{}'::jsonb)                                   as payload,
           coalesce((e ->> 'schemaVersion')::int, 1)                               as schema_version
    from jsonb_array_elements(coalesce(p_rewards, '[]'::jsonb)) as e
    where (e ->> 'id') is not null
      and (e ->> 'updatedAt') is not null
    order by e ->> 'id', ((e ->> 'updatedAt')::timestamptz) desc
  ) i
  on conflict (profile_id, id) do update
    set updated_at        = excluded.updated_at,
        deleted_at        = excluded.deleted_at,
        payload           = excluded.payload,
        schema_version    = excluded.schema_version,
        origin_device     = excluded.origin_device,
        server_updated_at = now()
    where excluded.updated_at > rw.updated_at;

  -- ── Ghi nhận máy này đã sync ──────────────────────────────────────────────────────────────────
  if p_device is not null then
    insert into public.sync_devices as d (profile_id, device_id, label, first_seen, last_seen)
    values (v_user, p_device, p_device_label, now(), now())
    on conflict (profile_id, device_id) do update
      set last_seen = now(),
          label     = coalesce(excluded.label, d.label);
  end if;

  -- ── PULL: task ────────────────────────────────────────────────────────────────────────────────
  with page as (
    select t.id, t.updated_at, t.deleted_at, t.payload, t.schema_version,
           t.server_updated_at, t.origin_device
    from public.tasks t
    where t.profile_id = v_user
      and t.server_updated_at > v_cur_tasks - interval '2 seconds'
    order by t.server_updated_at
    limit v_limit
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id',              p.id,
               'updatedAt',       p.updated_at,
               'deletedAt',       p.deleted_at,
               'payload',         p.payload,
               'schemaVersion',   p.schema_version,
               'serverUpdatedAt', p.server_updated_at,
               'originDevice',    p.origin_device
             )
             order by p.server_updated_at
           ),
           '[]'::jsonb
         ),
         count(*)::int,
         max(p.server_updated_at)
    into v_tasks_out, v_task_n, v_task_max
  from page p;

  -- ── PULL: completions ─────────────────────────────────────────────────────────────────────────
  with page as (
    select c.id, c.task_id, c.completed_at, c.payload, c.server_updated_at
    from public.completions c
    where c.profile_id = v_user
      and c.server_updated_at > v_cur_comps - interval '2 seconds'
    order by c.server_updated_at
    limit v_limit
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id',              p.id,
               'taskId',          p.task_id,
               'completedAt',     p.completed_at,
               'payload',         p.payload,
               'serverUpdatedAt', p.server_updated_at
             )
             order by p.server_updated_at
           ),
           '[]'::jsonb
         ),
         count(*)::int,
         max(p.server_updated_at)
    into v_comps_out, v_comp_n, v_comp_max
  from page p;

  -- ── PULL: rewards ─────────────────────────────────────────────────────────────────────────────
  with page as (
    select w.id, w.updated_at, w.deleted_at, w.payload, w.schema_version,
           w.server_updated_at, w.origin_device
    from public.rewards w
    where w.profile_id = v_user
      and w.server_updated_at > v_cur_rew - interval '2 seconds'
    order by w.server_updated_at
    limit v_limit
  )
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id',              p.id,
               'updatedAt',       p.updated_at,
               'deletedAt',       p.deleted_at,
               'payload',         p.payload,
               'schemaVersion',   p.schema_version,
               'serverUpdatedAt', p.server_updated_at,
               'originDevice',    p.origin_device
             )
             order by p.server_updated_at
           ),
           '[]'::jsonb
         ),
         count(*)::int,
         max(p.server_updated_at)
    into v_rew_out, v_reward_n, v_rew_max
  from page p;

  return jsonb_build_object(
    'cursorTasks',       coalesce(v_task_max, nullif(v_cur_tasks, '-infinity'::timestamptz)),
    'cursorCompletions', coalesce(v_comp_max, nullif(v_cur_comps, '-infinity'::timestamptz)),
    'cursorRewards',     coalesce(v_rew_max, nullif(v_cur_rew, '-infinity'::timestamptz)),
    'tasks',             v_tasks_out,
    'completions',       v_comps_out,
    'rewards',           v_rew_out,
    'hasMore',           (v_task_n >= v_limit or v_comp_n >= v_limit or v_reward_n >= v_limit),
    'rejected',          to_jsonb(coalesce(v_rejected, '{}'::uuid[]))
  );
end;
$$;

revoke all on function public.sync_exchange(timestamptz, timestamptz, text, text, jsonb, jsonb, int, timestamptz, jsonb) from public;
revoke all on function public.sync_exchange(timestamptz, timestamptz, text, text, jsonb, jsonb, int, timestamptz, jsonb) from anon;
grant execute on function public.sync_exchange(timestamptz, timestamptz, text, text, jsonb, jsonb, int, timestamptz, jsonb) to authenticated;
