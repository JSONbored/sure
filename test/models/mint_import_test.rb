require "test_helper"

class MintImportTest < ActiveSupport::TestCase
  test "default column mappings are applied after create" do
    import = families(:dylan_family).imports.create!(type: "MintImport")

    MintImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
  end
end
