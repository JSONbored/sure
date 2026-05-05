# frozen_string_literal: true

require "test_helper"

class ProviderConnectionStatusTest < ActiveSupport::TestCase
  test "provider registry covers syncable family provider item associations" do
    expected_registry = Family.reflect_on_all_associations(:has_many).filter_map do |association|
      next unless association.name.to_s.end_with?("_items")
      next unless association.klass.included_modules.include?(Syncable)

      { association: association.name, type: association.klass.name }
    end

    registered_registry = ProviderConnectionStatus::PROVIDERS.map do |provider|
      { association: provider[:association], type: provider[:type] }
    end

    assert_equal expected_registry.sort_by { |entry| entry[:association].to_s },
                 registered_registry.sort_by { |entry| entry[:association].to_s }
  end

  test "status summary is computed without calling provider item summary" do
    provider = ProviderConnectionStatus::PROVIDERS.find { |entry| entry[:association] == :mercury_items }
    item = mercury_items(:one)
    sync = item.syncs.create!(
      status: "completed",
      completed_at: Time.current,
      sync_stats: {
        total_accounts: 2,
        linked_accounts: 1,
        unlinked_accounts: 1
      }
    )

    item.expects(:sync_status_summary).never

    status = ProviderConnectionStatus.new(
      provider,
      item,
      latest_sync: sync,
      latest_completed_sync: sync,
      syncing: false
    ).to_h

    assert_equal "1 synced, 1 need setup", status.dig(:sync, :status_summary)
  end
end
