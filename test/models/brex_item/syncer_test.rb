# frozen_string_literal: true

require "test_helper"

class BrexItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @brex_item = brex_items(:one)
    @syncer = BrexItem::Syncer.new(@brex_item)
  end

  test "passes sync window start date to importer" do
    window_start_date = Date.new(2026, 2, 1)
    sync = mock_sync(window_start_date: window_start_date)

    @brex_item.expects(:import_latest_brex_data).with(sync_start_date: window_start_date).once

    @syncer.perform_sync(sync)
  end

  private

    def mock_sync(window_start_date:)
      sync = mock("sync")
      sync.stubs(:respond_to?).with(:status_text).returns(true)
      sync.stubs(:respond_to?).with(:sync_stats).returns(true)
      sync.stubs(:sync_stats).returns({})
      sync.stubs(:window_start_date).returns(window_start_date)
      sync.stubs(:window_end_date).returns(nil)
      sync.stubs(:update!)
      sync
    end
end
