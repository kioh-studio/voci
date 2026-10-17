-- 0008_pull_rejected_rows.sql
--
-- VÌ SAO: một máy thua LWW (updated_at của nó cũ hơn bản trên server) mà cursor của máy đó ĐÃ vượt
-- qua server_updated_at của bản thắng thì bản thắng không bao giờ được kéo xuống nữa (pull chỉ lấy
-- server_updated_at > cursor - 2s). Máy đó giữ mãi bản thua ở trạng thái pending, đẩy lại mỗi vòng,
-- bị từ chối mỗi vòng — không hội tụ (thường gặp khi đồng hồ máy chậm). Sửa: trang pull của task và
-- reward cũng trả các hàng có id nằm trong tập vừa bị từ chối ở chính lần gọi này; client áp dụng
-- bằng LWW như mọi hàng pull thường (bản thắng có updatedAt mới hơn nên ghi đè bản pending cục bộ).
-- Reward trước đây không có tập rejected nên thêm một CTE tương tự task (KHÔNG ghi sync_rejects,
-- đúng như 0007).
--
-- Chữ ký giống hệt 0007 nên dùng `create or replace` (không sinh overload). Thân hàm = 0007 nguyên
-- văn, chỉ đổi: (1) khối push reward thành CTE để biết hàng thua, (2) hai điều kiện trang pull.
--
-- 🔴 ÁP DỤNG MIGRATION NÀY LÀ QUYẾT ĐỊNH CỦA anh Khôi (`supabase db push`). File này chỉ được VIẾT.

create or replace function public.sync_exchange(
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
  v_rew_rejected uuid[];
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
  with incoming as (
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
  ),
  applied as (
    insert into public.rewards as rw
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
      where excluded.updated_at > rw.updated_at
    returning rw.id
  )
  select coalesce(array_agg(i.id), '{}'::uuid[]) into v_rew_rejected
  from incoming i
  join public.rewards cur on cur.profile_id = v_user and cur.id = i.id
  where i.id not in (select a.id from applied a)
    and cur.updated_at > i.updated_at;

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
      and (t.server_updated_at > v_cur_tasks - interval '2 seconds' or t.id = any(v_rejected))
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
      and (w.server_updated_at > v_cur_rew - interval '2 seconds' or w.id = any(v_rew_rejected))
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
