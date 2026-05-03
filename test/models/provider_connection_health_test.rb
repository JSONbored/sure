# frozen_string_literal: true

require "test_helper"

class ProviderConnectionHealthTest < ActiveSupport::TestCase
  test "provider registry covers syncable family provider item associations" do
    syncable_provider_item_associations = Family.reflect_on_all_associations(:has_many).filter_map do |association|
      next unless association.name.to_s.end_with?("_items")
      next unless association.klass.included_modules.include?(Syncable)

      association.name
    end

    registered_associations = ProviderConnectionHealth::PROVIDERS.map { |provider| provider[:association] }

    assert_equal syncable_provider_item_associations.sort, registered_associations.sort
  end
end
