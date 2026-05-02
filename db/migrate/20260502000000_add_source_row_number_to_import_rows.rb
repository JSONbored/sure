class AddSourceRowNumberToImportRows < ActiveRecord::Migration[7.2]
  def change
    add_column :import_rows, :source_row_number, :integer
  end
end
