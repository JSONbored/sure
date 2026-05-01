# frozen_string_literal: true

syncable = sync.syncable

json.id sync.id
json.status sync.status
json.in_progress sync.pending? || sync.syncing?
json.terminal sync.completed? || sync.failed? || sync.stale?
json.syncable do
  json.type sync.syncable_type
  json.id sync.syncable_id
  json.name syncable.respond_to?(:name) ? syncable.name : nil
end
json.parent_id sync.parent_id
json.children_count sync.children.size
json.window_start_date sync.window_start_date
json.window_end_date sync.window_end_date
json.pending_at sync.pending_at
json.syncing_at sync.syncing_at
json.completed_at sync.completed_at
json.failed_at sync.failed_at
json.error sync_error_payload(sync)
json.created_at sync.created_at
json.updated_at sync.updated_at
