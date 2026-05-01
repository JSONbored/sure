class AddBackupCodeMetadataToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :otp_backup_codes_generated_at, :datetime
  end
end
